import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CanvasScreen: View {
    @Environment(\.scenePhase) private var scenePhase

    @ObservedObject var documentStore: DrawingDocumentStore
    let canEditActiveDocument: Bool
    let onShowLibrary: () -> Void
    var practice: TiyiPracticeWorkspace?

    @AppStorage("pdfWorkspace.activeDocumentID") private var activeDocumentID = "congruence"
    @State private var selectedTool = CanvasToolKind.pen
    @AppStorage("canvas.penVariant") private var selectedPenVariant = CanvasToolKind.pen
    @AppStorage("canvas.color") private var selectedColor = InkPaletteColor.graphite
    @AppStorage("canvas.penWidth.v2") private var penWidth = 0.7
    @AppStorage("canvas.markerWidth") private var markerWidth = 16.0
    @AppStorage("canvas.eraserSize") private var eraserSize = CanvasEraserSize.medium
    @AppStorage("canvas.eraserMode") private var eraserMode = CanvasEraserMode.precision
    @AppStorage("canvas.scribbleToErase") private var isScribbleEraseEnabled = true
    @AppStorage("pdfWorkspace.showsThumbnails") private var showsThumbnails = false
    @AppStorage("canvas.toolPaletteDockEdge") private var toolPaletteDockEdge =
        ToolPaletteDockEdge.leading
    @AppStorage("canvas.toolPaletteDockProgress") private var toolPaletteDockProgress = 0.24

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
    @State private var questionSession: DocumentQuestionSession?
    @State private var closingQuestionSession: DocumentQuestionSession?

    private var thumbnailVisibility: Binding<Bool> {
        practice.map { workspace in
            Binding(get: { workspace.showsPages }, set: { workspace.showsPages = $0 })
        } ?? $showsThumbnails
    }

    init(
        documentStore: DrawingDocumentStore,
        canEditActiveDocument: Bool = true,
        onShowLibrary: @escaping () -> Void = {},
        initialPageElementInsertionRequest: PageElementInsertionRequest? = nil,
        practice: TiyiPracticeWorkspace? = nil
    ) {
        self.documentStore = documentStore
        self.canEditActiveDocument = canEditActiveDocument
        self.onShowLibrary = onShowLibrary
        self.practice = practice
        if let practice {
            _activeDocumentID = AppStorage(wrappedValue: practice.documentID, "pdfWorkspace.activeDocumentID", store: practice.defaults)
        }
        _pageElementInsertionRequest = State(
            initialValue: initialPageElementInsertionRequest
        )
    }

    var body: some View {
        ZStack {
            TiyiNoteTheme.documentWorkspace
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if let practice {
                    PracticeEditorHeader(workspace: practice, onExit: onShowLibrary)
                } else {
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
                }

                if annotationEditingEnabled {
                    ToolPaletteView(
                        activeController: activeController,
                        selectedTool: $selectedTool,
                        selectedPenVariant: $selectedPenVariant,
                        eraserMode: $eraserMode,
                        isScribbleEraseEnabled: $isScribbleEraseEnabled,
                        showsThumbnails: thumbnailVisibility,
                        onSearch: practice == nil ? { showsPDFSearch = true } : nil,
                        onInsertImage: { showsImageImporter = true },
                        onInsertShape: insertShape,
                        hasActiveDocument: !activeDocumentID.isEmpty,
                        canClearPage: activeController != nil,
                        onDocumentAction: handleDocumentOutput,
                        onClearPage: requestClearCurrentPage,
                        allowsQuestionCapture: practice == nil
                    )
                } else {
                    ReadOnlyToolPaletteView(
                        showsThumbnails: thumbnailVisibility,
                        onSearch: practice == nil ? { showsPDFSearch = true } : nil,
                        hasActiveDocument: !activeDocumentID.isEmpty,
                        onDocumentAction: handleDocumentOutput
                    )
                }

                ZStack {
                    if let activeDocument = documentStore.document(withID: activeDocumentID) {
                        PDFDocumentReaderView(
                            documentStore: documentStore,
                            documentID: activeDocument.id,
                            showsThumbnails: thumbnailVisibility,
                            pageElementInsertionRequest: $pageElementInsertionRequest,
                            externalPageRequest: $requestedReaderPageIndex,
                            searchHighlight: $pdfSearchHighlight,
                            selectedTool: selectedTool,
                            selectedColor: selectedColor,
                            penWidth: penWidth,
                            markerWidth: markerWidth,
                            eraserSize: eraserSize,
                            eraserMode: eraserMode,
                            isScribbleEraseEnabled: isScribbleEraseEnabled,
                            isAnnotationEditingEnabled: annotationEditingEnabled,
                            practice: practice,
                            initialPageIndex: documentStore.lastViewedPage(for: activeDocument.id),
                            onOpenQuestionSession: { session in
                                guard practice == nil else { return }
                                questionSession = session
                            },
                            onSelectLassoTool: {
                                selectedTool = .lasso
                            },
                            onSelectTextTool: {
                                selectedTool = .text
                            },
                            onActiveCanvasChanged: { controller, pageIndex in
                                // Pencil-down reaffirms the active canvas. Avoid invalidating the
                                // complete workspace when it is still the same visible page.
                                if activeController !== controller {
                                    activeController = controller
                                }
                                if activePageIndex != pageIndex {
                                    activePageIndex = pageIndex
                                }
                                practice?.didView(pageIndex)
                            }
                        )
                        .id(activeDocument.id)

                        if annotationEditingEnabled && selectedTool != .question {
                            DockableToolPaletteView(
                                selectedTool: $selectedTool,
                                selectedPenVariant: selectedPenVariant,
                                selectedColor: $selectedColor,
                                penWidth: $penWidth,
                                markerWidth: $markerWidth,
                                eraserSize: $eraserSize,
                                dockEdge: $toolPaletteDockEdge,
                                dockProgress: $toolPaletteDockProgress,
                                leadingContentInset: thumbnailVisibility.wrappedValue ? 293 : 0
                            )
                            .zIndex(20)
                        }
                    } else {
                        EmptyPDFWorkspaceView(
                            canImportPDF: PlatformCapabilities.current.canImportPDF,
                            onImportPDF: { showsPDFImporter = true }
                        )
                    }
                }
            }
        }
        .accessibilityHidden(questionSession != nil)
        .fullScreenCover(item: $questionSession, onDismiss: {
            NotificationCenter.default.post(name: .documentQuestionDismissed, object: documentStore)
            closingQuestionSession?.discardWorkingCopy()
            closingQuestionSession = nil
        }) { session in
            TiyiPracticeEditor(workspace: session.workspace) {
                closingQuestionSession = session
                questionSession = nil
            }
            .interactiveDismissDisabled()
        }
        .onAppear(perform: prepareWorkspace)
        .onChange(of: practice?.requestedPageID) { _, id in
            if let id { requestedReaderPageIndex = documentStore.pageIndex(for: id, in: activeDocumentID) }
        }
        .onChange(of: documentStore.documents.map(\.id)) { _, _ in
            reconcileActiveDocument()
        }
        .onChange(of: selectedTool) { _, tool in
            if tool.isPenVariant {
                selectedPenVariant = tool
            }
            guard tool != .text,
                  let request = pageElementInsertionRequest,
                  case .text = request.payload else { return }
            // Aa and the destination tool can be tapped in the same render cycle.
            // Do not let that stale text request arrive after lasso has become active,
            // where it would look like a lasso object appeared from tapping Aa.
            pageElementInsertionRequest = nil
        }
        .onChange(of: scenePhase) { _, phase in
            // SwiftUI reports `.inactive` for short-lived system interruptions as well as the
            // beginning of a real background transition. The page editors deliberately wait for
            // `.background`; mirroring that rule here prevents a second synchronous journal/file
            // drain from blocking the first Pencil samples when the interruption disappears.
            guard phase == .background else { return }
            flushPendingAnnotations()
            if let practice { do { try practice.checkpoint() } catch { practice.errorMessage = error.localizedDescription } }
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
        if selectedPenVariant.isPenVariant {
            selectedTool = selectedPenVariant
        } else {
            selectedPenVariant = .pen
            selectedTool = .pen
        }
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

        if documentStore.openDocuments.isEmpty {
            activeDocumentID = ""
            activeController = nil
            activePageIndex = 0
            onShowLibrary()
            return
        }

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
        flushPendingAnnotations()
        isPreparingOutput = true
        defer { isPreparingOutput = false }
        do {
            switch action {
            case .flattenedPDF:
                sharePayload = DocumentSharePayload(
                    urls: [try documentStore.exportFlattenedPDF(documentID: document.id)]
                )
            case .printDocument:
                let url = try documentStore.exportFlattenedPDF(documentID: document.id)
                presentPrintPanel(for: url, title: document.title)
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
        (PlatformCapabilities.current.canEditAnnotations || (practice != nil && UIDevice.current.userInterfaceIdiom == .phone)) && canEditActiveDocument
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
