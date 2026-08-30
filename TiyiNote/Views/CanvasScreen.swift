import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CanvasScreen: View {
    @Environment(\.scenePhase) private var scenePhase

    @ObservedObject var documentStore: DrawingDocumentStore
    let canEditActiveDocument: Bool
    let onCollaborateDocument: (String) -> Void
    let onShowLibrary: () -> Void

    @AppStorage("pdfWorkspace.activeDocumentID") private var activeDocumentID = "congruence"
    @State private var selectedTool = CanvasToolKind.pen
    @AppStorage("canvas.color") private var selectedColor = InkPaletteColor.graphite
    @AppStorage("canvas.penWidth.v2") private var penWidth = 0.7
    @AppStorage("canvas.markerWidth") private var markerWidth = 16.0
    @AppStorage("canvas.eraserSize") private var eraserSize = CanvasEraserSize.medium
    @AppStorage("canvas.eraserMode") private var eraserMode = CanvasEraserMode.precision
    @AppStorage("pdfWorkspace.showsThumbnails") private var showsThumbnails = false

    @State private var activeController: CanvasController?
    @State private var activePageIndex = 0
    @State private var showsPDFImporter = false
    @State private var showsImageImporter = false
    @State private var showsPDFSearch = false
    @State private var showsConflictVersions = false
    @State private var requestedReaderPageIndex: Int?
    @State private var pdfSearchHighlight: PDFSearchHighlight?
    @State private var pageElementInsertionRequest: PageElementInsertionRequest?
    @State private var sharePayload: DocumentSharePayload?
    @State private var isPreparingOutput = false
    @State private var workspaceAlert: WorkspaceAlert?

    init(
        documentStore: DrawingDocumentStore,
        canEditActiveDocument: Bool = true,
        onCollaborateDocument: @escaping (String) -> Void = { _ in },
        onShowLibrary: @escaping () -> Void = {},
        initialPageElementInsertionRequest: PageElementInsertionRequest? = nil
    ) {
        self.documentStore = documentStore
        self.canEditActiveDocument = canEditActiveDocument
        self.onCollaborateDocument = onCollaborateDocument
        self.onShowLibrary = onShowLibrary
        _pageElementInsertionRequest = State(
            initialValue: initialPageElementInsertionRequest
        )
    }

    var body: some View {
        ZStack {
            TiyiNoteTheme.workspace
                .ignoresSafeArea()

            VStack(spacing: 0) {
                PDFDocumentTabBar(
                    openDocuments: documentStore.openDocuments,
                    activeDocumentID: activeDocumentID,
                    onSelectDocument: selectDocument,
                    onCloseDocument: closeDocument,
                    onMoveDocument: { sourceDocumentID, destinationDocumentID in
                        documentStore.moveOpenDocument(
                            sourceDocumentID,
                            relativeTo: destinationDocumentID
                        )
                    },
                    onShowLibrary: onShowLibrary
                )

                if annotationEditingEnabled {
                    ToolPaletteView(
                        selectedTool: $selectedTool,
                        selectedColor: $selectedColor,
                        penWidth: $penWidth,
                        markerWidth: $markerWidth,
                        eraserSize: $eraserSize,
                        eraserMode: $eraserMode,
                        showsThumbnails: $showsThumbnails,
                        activeController: activeController,
                        onSearch: { showsPDFSearch = true },
                        onDocumentAction: handleDocumentOutput,
                        onInsertImage: { showsImageImporter = true },
                        onInsertShape: insertShape,
                        onClear: requestClearCurrentPage
                    )
                } else {
                    ReadOnlyToolPaletteView(
                        showsThumbnails: $showsThumbnails,
                        onSearch: { showsPDFSearch = true },
                        onDocumentAction: handleDocumentOutput
                    )
                }

                if let activeDocument = documentStore.document(withID: activeDocumentID) {
                    PDFDocumentReaderView(
                        documentStore: documentStore,
                        documentID: activeDocument.id,
                        showsThumbnails: $showsThumbnails,
                        pageElementInsertionRequest: $pageElementInsertionRequest,
                        externalPageRequest: $requestedReaderPageIndex,
                        searchHighlight: $pdfSearchHighlight,
                        selectedTool: selectedTool,
                        selectedColor: selectedColor,
                        penWidth: penWidth,
                        markerWidth: markerWidth,
                        eraserSize: eraserSize,
                        eraserMode: eraserMode,
                        isAnnotationEditingEnabled: annotationEditingEnabled,
                        initialPageIndex: documentStore.lastViewedPage(for: activeDocument.id),
                        onSelectLassoTool: {
                            selectedTool = .lasso
                        },
                        onSelectTextTool: {
                            selectedTool = .text
                        },
                        onActiveCanvasChanged: { controller, pageIndex in
                            activeController = controller
                            activePageIndex = pageIndex
                        }
                    )
                    .id(activeDocument.id)
                } else {
                    EmptyPDFWorkspaceView(
                        canImportPDF: PlatformCapabilities.current.canImportPDF,
                        onImportPDF: { showsPDFImporter = true }
                    )
                }
            }
        }
        .onAppear(perform: prepareWorkspace)
        .onChange(of: documentStore.documents.map(\.id)) { _, _ in
            reconcileActiveDocument()
        }
        .onChange(of: selectedTool) { _, tool in
            guard tool != .text,
                  let request = pageElementInsertionRequest,
                  case .text = request.payload else { return }
            // Aa and the destination tool can be tapped in the same render cycle.
            // Do not let that stale text request arrive after lasso has become active,
            // where it would look like a lasso object appeared from tapping Aa.
            pageElementInsertionRequest = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                flushPendingAnnotations()
            }
        }
        .fileImporter(
            isPresented: $showsPDFImporter,
            allowedContentTypes: [.pdf, .tiyiNoteDocument],
            allowsMultipleSelection: true,
            onCompletion: handlePDFImport
        )
        .fileImporter(
            isPresented: $showsImageImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: handleImageImport
        )
        .sheet(isPresented: $showsPDFSearch) {
            if let document = documentStore.document(withID: activeDocumentID) {
                PDFTextSearchSheet(
                    documentStore: documentStore,
                    document: document,
                    onSelect: { result in
                        pdfSearchHighlight = PDFSearchHighlight(
                            documentID: document.id,
                            pageIndex: result.pageIndex,
                            pageBounds: result.pageBounds
                        )
                        requestedReaderPageIndex = result.pageIndex
                        showsPDFSearch = false
                    }
                )
            }
        }
        .sheet(item: $sharePayload) { payload in
            SystemActivityView(items: payload.urls)
        }
        .sheet(isPresented: $showsConflictVersions) {
            if let document = documentStore.document(withID: activeDocumentID) {
                CollaborationConflictSheet(
                    documentStore: documentStore,
                    document: document,
                    onLocate: { item in
                        guard let pageIndex = item.pageIndex else { return }
                        requestedReaderPageIndex = pageIndex
                        showsConflictVersions = false
                    }
                )
            }
        }
        .overlay {
            if isPreparingOutput {
                ZStack {
                    Color.black.opacity(0.22).ignoresSafeArea()
                    ProgressView("正在准备文稿…")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .alert(item: $workspaceAlert) { alert in
            switch alert {
            case .clearPage(let pageNumber):
                Alert(
                    title: Text("清空这一页的批注？"),
                    message: Text("第 \(pageNumber) 页上的笔迹会被移除，你仍可以立即使用撤销恢复。"),
                    primaryButton: .destructive(Text("清空")) {
                        activeController?.clear()
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            case .importFailed(let message):
                Alert(
                    title: Text("PDF 导入失败"),
                    message: Text(message),
                    dismissButton: .default(Text("好"))
                )
            case .objectImportFailed(let message):
                Alert(
                    title: Text("图片导入失败"),
                    message: Text(message),
                    dismissButton: .default(Text("好"))
                )
            case .outputFailed(let message):
                Alert(
                    title: Text("导出失败"),
                    message: Text(message),
                    dismissButton: .default(Text("好"))
                )
            }
        }
    }

    private func prepareWorkspace() {
        if !documentStore.openDocumentIDs.contains(activeDocumentID) {
            activeDocumentID = documentStore.openDocuments.first?.id ?? ""
        }
    }

    private func selectDocument(_ documentID: String) {
        guard documentID != activeDocumentID else {
            documentStore.openDocument(documentID)
            return
        }

        flushPendingAnnotations()
        documentStore.openDocument(documentID)
        activeDocumentID = documentID
        activeController = nil
        activePageIndex = documentStore.lastViewedPage(for: documentID)
    }

    private func closeDocument(_ documentID: String) {
        let isClosingActiveDocument = documentID == activeDocumentID
        if isClosingActiveDocument {
            flushPendingAnnotations()
        }

        documentStore.closeDocument(documentID)

        if isClosingActiveDocument, let nextDocument = documentStore.openDocuments.first {
            activeDocumentID = nextDocument.id
            activeController = nil
            activePageIndex = documentStore.lastViewedPage(for: nextDocument.id)
        }
    }

    private func requestClearCurrentPage() {
        guard annotationEditingEnabled, activeController != nil else {
            return
        }
        workspaceAlert = .clearPage(activePageIndex + 1)
    }

    private func insertShape(_ kind: PageShapeKind) {
        pageElementInsertionRequest = PageElementInsertionRequest(
            pageIndex: activePageIndex,
            payload: .shape(
                PageShapePayload(
                    kind: kind,
                    strokeColorHex: selectedColor.rgbaHex
                )
            )
        )
        selectedTool = .lasso
    }

    private func handleImageImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard let image = UIImage(data: data), let pngData = image.pngData() else {
                    throw PDFWorkspaceError.invalidPDF(url.lastPathComponent)
                }
                pageElementInsertionRequest = PageElementInsertionRequest(
                    pageIndex: activePageIndex,
                    payload: .image(PageImagePayload(pngData: pngData))
                )
                selectedTool = .lasso
            } catch {
                workspaceAlert = .objectImportFailed(error.localizedDescription)
            }
        case .failure(let error):
            workspaceAlert = .objectImportFailed(error.localizedDescription)
        }
    }

    private func handlePDFImport(_ result: Result<[URL], Error>) {
        guard PlatformCapabilities.current.canImportPDF else { return }
        switch result {
        case .success(let urls):
            do {
                let pdfURLs = urls.filter {
                    $0.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
                }
                let editableURLs = urls.filter {
                    $0.pathExtension.caseInsensitiveCompare("tiyinote") == .orderedSame
                }
                var importedDocuments = try documentStore.importPDFs(from: pdfURLs)
                importedDocuments.append(contentsOf: try editableURLs.map {
                    try documentStore.importEditableDocumentPackage(from: $0)
                })
                if let lastImportedDocument = importedDocuments.last {
                    selectDocument(lastImportedDocument.id)
                }
            } catch {
                workspaceAlert = .importFailed(error.localizedDescription)
            }
        case .failure(let error):
            workspaceAlert = .importFailed(error.localizedDescription)
        }
    }

    private func flushPendingAnnotations() {
        guard annotationEditingEnabled else { return }
        _ = documentStore.flushAllPendingSaves()
    }

    private func reconcileActiveDocument() {
        guard documentStore.document(withID: activeDocumentID) == nil else { return }

        activeController = nil
        if let nextDocument = documentStore.openDocuments.first ?? documentStore.documents.first {
            documentStore.openDocument(nextDocument.id)
            activeDocumentID = nextDocument.id
            activePageIndex = documentStore.lastViewedPage(for: nextDocument.id)
        } else {
            activeDocumentID = ""
            activePageIndex = 0
        }
    }

    private func handleDocumentOutput(_ action: DocumentOutputAction) {
        guard !activeDocumentID.isEmpty,
              let document = documentStore.document(withID: activeDocumentID) else { return }
        if action == .conflictVersions {
            showsConflictVersions = true
            return
        }
        if action == .collaboration {
            onCollaborateDocument(document.id)
            return
        }
        flushPendingAnnotations()
        isPreparingOutput = true
        defer { isPreparingOutput = false }
        do {
            switch action {
            case .flattenedPDF:
                sharePayload = DocumentSharePayload(
                    urls: [try documentStore.exportFlattenedPDF(documentID: document.id)]
                )
            case .pageImages:
                sharePayload = DocumentSharePayload(
                    urls: try documentStore.exportPageImages(documentID: document.id)
                )
            case .editablePackage:
                sharePayload = DocumentSharePayload(
                    urls: [try documentStore.exportEditableDocumentPackage(documentID: document.id)]
                )
            case .printDocument:
                let url = try documentStore.exportFlattenedPDF(documentID: document.id)
                presentPrintPanel(for: url, title: document.title)
            case .collaboration:
                break
            case .conflictVersions:
                break
            }
        } catch {
            workspaceAlert = .outputFailed(error.localizedDescription)
        }
    }

    private func presentPrintPanel(for url: URL, title: String) {
        let printController = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = title
        info.outputType = .general
        printController.printInfo = info
        printController.printingItem = url
        printController.present(animated: true)
    }

    private var annotationEditingEnabled: Bool {
        PlatformCapabilities.current.canEditAnnotations && canEditActiveDocument
    }
}

private enum WorkspaceAlert: Identifiable {
    case clearPage(Int)
    case importFailed(String)
    case objectImportFailed(String)
    case outputFailed(String)

    var id: String {
        switch self {
        case .clearPage(let page): "clear-\(page)"
        case .importFailed(let message): "import-\(message)"
        case .objectImportFailed(let message): "object-import-\(message)"
        case .outputFailed(let message): "output-\(message)"
        }
    }
}

private struct DocumentSharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct SystemActivityView: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

private struct EmptyPDFWorkspaceView: View {
    let canImportPDF: Bool
    let onImportPDF: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("没有打开的 PDF", systemImage: "doc.richtext")
        } description: {
            Text(
                canImportPDF
                    ? "从文件中导入一个 PDF 开始批注。"
                    : "其他设备同步的 PDF 会显示在这里。"
            )
        } actions: {
            if canImportPDF {
                Button("导入 PDF", action: onImportPDF)
                    .buttonStyle(.borderedProminent)
            }
        }
        .foregroundStyle(TiyiNoteTheme.textPrimary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
