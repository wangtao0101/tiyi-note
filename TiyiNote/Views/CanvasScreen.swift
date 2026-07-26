import SwiftUI
import UniformTypeIdentifiers

struct CanvasScreen: View {
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var documentStore = DrawingDocumentStore()

    @AppStorage("pdfWorkspace.activeDocumentID") private var activeDocumentID = "congruence"
    @AppStorage("canvas.tool") private var selectedTool = CanvasToolKind.pen
    @AppStorage("canvas.color") private var selectedColor = InkPaletteColor.graphite
    @AppStorage("canvas.penWidth") private var penWidth = 4.0
    @AppStorage("canvas.markerWidth") private var markerWidth = 16.0
    @AppStorage("canvas.fingerDrawing") private var fingerDrawingEnabled = false
    @AppStorage("pdfWorkspace.showsThumbnails") private var showsThumbnails = false

    @State private var activeController: CanvasController?
    @State private var activePageIndex = 0
    @State private var showsPDFImporter = false
    @State private var workspaceAlert: WorkspaceAlert?

    var body: some View {
        ZStack {
            TiyiNoteTheme.workspace
                .ignoresSafeArea()

            VStack(spacing: 0) {
                PDFDocumentTabBar(
                    openDocuments: documentStore.openDocuments,
                    libraryDocuments: documentStore.documents,
                    activeDocumentID: activeDocumentID,
                    saveState: documentStore.saveState,
                    onSelectDocument: selectDocument,
                    onCloseDocument: closeDocument,
                    onOpenDocument: selectDocument,
                    onImportPDF: { showsPDFImporter = true }
                )

                ToolPaletteView(
                    selectedTool: $selectedTool,
                    selectedColor: $selectedColor,
                    penWidth: $penWidth,
                    markerWidth: $markerWidth,
                    fingerDrawingEnabled: $fingerDrawingEnabled,
                    showsThumbnails: $showsThumbnails,
                    activeController: activeController,
                    onClear: requestClearCurrentPage
                )

                if let activeDocument = documentStore.document(withID: activeDocumentID) {
                    PDFDocumentReaderView(
                        documentStore: documentStore,
                        documentID: activeDocument.id,
                        showsThumbnails: $showsThumbnails,
                        selectedTool: selectedTool,
                        selectedColor: selectedColor,
                        penWidth: penWidth,
                        markerWidth: markerWidth,
                        fingerDrawingEnabled: fingerDrawingEnabled,
                        initialPageIndex: documentStore.lastViewedPage(for: activeDocument.id),
                        onActiveCanvasChanged: { controller, pageIndex in
                            activeController = controller
                            activePageIndex = pageIndex
                        }
                    )
                    .id(activeDocument.id)
                } else {
                    EmptyPDFWorkspaceView {
                        showsPDFImporter = true
                    }
                }
            }
        }
        .onAppear(perform: prepareWorkspace)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                flushActiveCanvas()
            }
        }
        .fileImporter(
            isPresented: $showsPDFImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true,
            onCompletion: handlePDFImport
        )
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
            }
        }
    }

    private func prepareWorkspace() {
#if targetEnvironment(simulator)
        fingerDrawingEnabled = true
#endif

        if !documentStore.openDocumentIDs.contains(activeDocumentID) {
            activeDocumentID = documentStore.openDocuments.first?.id ?? ""
        }
    }

    private func selectDocument(_ documentID: String) {
        guard documentID != activeDocumentID else {
            documentStore.openDocument(documentID)
            return
        }

        flushActiveCanvas()
        documentStore.openDocument(documentID)
        activeDocumentID = documentID
        activeController = nil
        activePageIndex = documentStore.lastViewedPage(for: documentID)
    }

    private func closeDocument(_ documentID: String) {
        let isClosingActiveDocument = documentID == activeDocumentID
        if isClosingActiveDocument {
            flushActiveCanvas()
        }

        documentStore.closeDocument(documentID)

        if isClosingActiveDocument, let nextDocument = documentStore.openDocuments.first {
            activeDocumentID = nextDocument.id
            activeController = nil
            activePageIndex = documentStore.lastViewedPage(for: nextDocument.id)
        }
    }

    private func requestClearCurrentPage() {
        guard activeController != nil else { return }
        workspaceAlert = .clearPage(activePageIndex + 1)
    }

    private func handlePDFImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            do {
                let importedDocuments = try documentStore.importPDFs(from: urls)
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

    private func flushActiveCanvas() {
        guard let activeController, !activeDocumentID.isEmpty else { return }
        documentStore.flush(
            activeController.drawing,
            forPage: activePageIndex,
            in: activeDocumentID
        )
    }
}

private enum WorkspaceAlert: Identifiable {
    case clearPage(Int)
    case importFailed(String)

    var id: String {
        switch self {
        case .clearPage(let page): "clear-\(page)"
        case .importFailed(let message): "import-\(message)"
        }
    }
}

private struct EmptyPDFWorkspaceView: View {
    let onImportPDF: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("没有打开的 PDF", systemImage: "doc.richtext")
        } description: {
            Text("从文件中导入一个 PDF 开始批注。")
        } actions: {
            Button("导入 PDF", action: onImportPDF)
                .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
