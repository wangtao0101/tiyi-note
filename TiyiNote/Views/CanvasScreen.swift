import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

struct CanvasScreen: View {
    @Environment(\.tiyiAssistant) private var assistantIntegration
    @State private var showsAssistant = false
    @State private var assistantPageID: String?
    @State private var assistantQuestionID: String?
    @State private var assistantSelections: [TiyiAssistantSelectionEvent] = []
    @Environment(\.scenePhase) private var scenePhase

    @ObservedObject var documentStore: DrawingDocumentStore
    let canEditActiveDocument: Bool
    let onShowLibrary: () -> Void
    var practice: TiyiPracticeWorkspace?
    var handout: TiyiHandoutWorkspace?
    var navigation: TiyiWorkspaceNavigation?

    @AppStorage("pdfWorkspace.activeDocumentID") private var activeDocumentID = "congruence"
    @State private var interactionSession = CanvasInteractionSession()
    @State private var pendingReadOnly = false
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
        practice: TiyiPracticeWorkspace? = nil,
        handout: TiyiHandoutWorkspace? = nil,
        navigation: TiyiWorkspaceNavigation? = nil
    ) {
        self.documentStore = documentStore
        self.canEditActiveDocument = canEditActiveDocument
        self.onShowLibrary = onShowLibrary
        self.practice = practice
        self.handout = handout
        self.navigation = navigation
        if let handout {
            _activeDocumentID = AppStorage(wrappedValue: handout.documentID, "pdfWorkspace.activeDocumentID", store: handout.defaults)
        }
        if let practice {
            _activeDocumentID = AppStorage(wrappedValue: practice.documentID, "pdfWorkspace.activeDocumentID", store: practice.defaults)
        }
        _pageElementInsertionRequest = State(
            initialValue: initialPageElementInsertionRequest
        )
    }

    private var assistantContext: TiyiAssistantContext {
        _ = assistantPageID
        if var context = practice?.assistantContext?() {
            context.selections += assistantSelections.map(\.image)
            return context
        }
        let documentID = activeDocumentID
        let pageIndex = activePageIndex
        return TiyiAssistantContext(scope: .init(kind: "document", sourceId: documentID),
            title: documentStore.document(withID: documentID)?.title ?? "文稿",
            prompt: "当前文稿第 \(pageIndex + 1) 页。用户可在同一文稿讨论不同题目；当前问题以本轮附图为准，不要将历史题目的条件当作当前题目。",
            selections: assistantSelections.map(\.image),
            captureQuestion: {
                if !assistantSelections.isEmpty {
                    return try assistantSelections.map { selection in
                        guard let index = documentStore.pageIndex(for: selection.pageID, in: documentID) else { throw CocoaError(.fileNoSuchFile) }
                        return .init(id: selection.image.id, label: "题面",
                            data: try documentStore.assistantImage(documentID: documentID, pageIndex: index, crop: selection.bounds, includesAnswer: false, preservesPageElements: true))
                    }
                }
                return [.init(id: "page-\(pageIndex)", label: "题面", data: try documentStore.assistantImage(documentID: documentID, pageIndex: pageIndex, includesAnswer: false, preservesPageElements: true))]
            },
            capture: {
                NotificationCenter.default.post(name: .tiyiPracticeCheckpoint, object: documentStore)
                if !assistantSelections.isEmpty {
                    return try assistantSelections.map { selection in
                        guard let index = documentStore.pageIndex(for: selection.pageID, in: documentID) else { throw CocoaError(.fileNoSuchFile) }
                        return .init(id: selection.image.id, label: selection.image.label,
                            data: try documentStore.assistantImage(documentID: documentID, pageIndex: index, crop: selection.bounds))
                    }
                }
                return [.init(id: "page-\(pageIndex)", label: "第 \(pageIndex + 1) 页", data: try documentStore.assistantImage(documentID: documentID, pageIndex: pageIndex))]
            })
    }

    private var onAssistant: (() -> Void)? {
        guard assistantIntegration != nil else { return nil }
        return { showsAssistant.toggle() }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                workspaceHeader
                workspaceToolbar
                AssistantSplitView(
                    maximumWidth: min(480, geometry.size.width * 0.48),
                    assistant: showsAssistant && geometry.size.width >= 900 ? assistantPanel : nil,
                    canvas: canvasContent
                )
            }
            .sheet(isPresented: Binding(get: { showsAssistant && geometry.size.width < 900 }, set: { if !$0 { showsAssistant = false } })) {
                if let integration = assistantIntegration {
                    integration.panel(assistantContext, { showsAssistant = false }).id(assistantContext.scope.key)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .onReceive(practice?.$currentPageID.eraseToAnyPublisher() ?? Just(nil).eraseToAnyPublisher()) { pageID in
            let questionID = practice?.sections.first { $0.pageIDs.contains(pageID ?? "") }?.id
            if assistantQuestionID != questionID { assistantSelections = []; assistantQuestionID = questionID }
            assistantPageID = pageID
        }
        .onChange(of: activeDocumentID) { _, _ in assistantSelections = []; showsAssistant = false }
        .onChange(of: interactionContentID, initial: true) { _, id in
            pendingReadOnly = false
            interactionSession.enter(id)
        }
        .task(id: pendingReadOnly) {
            guard pendingReadOnly else { return }
            let contentID = interactionContentID
            // A second hand can tap the toolbar before the Pencil has lifted. Let that
            // transaction finish, including its final sample, before closing the editor.
            while activeController?.isUsingTool == true {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
            guard !Task.isCancelled, pendingReadOnly,
                  contentID == interactionContentID, annotationEditingEnabled else { return }
            NotificationCenter.default.post(name: .tiyiPracticeCheckpoint, object: documentStore)
            pageElementInsertionRequest = nil
            showsImageImporter = false
            interactionSession.toggle(contentID: contentID, hasPermission: canToggleEditing)
            pendingReadOnly = false
        }
        .onDisappear { pendingReadOnly = false }
        .onReceive(NotificationCenter.default.publisher(for: .tiyiAssistantSelection)) { notification in
            guard let value = notification.object as? TiyiAssistantSelectionEvent,
                  value.documentID == activeDocumentID else { return }
            assistantSelections.append(value)
            assistantSelections = Array(assistantSelections.suffix(6))
            showsAssistant = true
        }
    }

    private var assistantPanel: AnyView? {
        guard let integration = assistantIntegration else { return nil }
        let context = assistantContext
        return AnyView(integration.panel(context, { showsAssistant = false }).id(context.scope.key))
    }

    @ViewBuilder private var workspaceHeader: some View {
        if let navigation {
            PDFDocumentTabBar(openDocuments: navigation.tabs, activeDocumentID: navigation.selectedID,
                onSelectDocument: navigation.onSelect, onCloseDocument: navigation.onClose,
                onMoveDocument: navigation.onMove, onShowLibrary: onShowLibrary, libraryLabel: "返回讲义库",
                onInteract: handout.map { workspace in { workspace.interact(at: activePageIndex) } },
                actions: AnyView(HStack(spacing: 0) {
                    navigation.actions
                    if let practice { TiyiPracticeActions(workspace: practice) }
                }))
        } else if let practice {
            PracticeEditorHeader(workspace: practice, onExit: onShowLibrary)
        } else {
            PDFDocumentTabBar(
                openDocuments: documentStore.openDocuments.map { TiyiWorkspaceTab(id: $0.id, title: $0.title) },
                activeDocumentID: activeDocumentID,
                onSelectDocument: selectDocument,
                onCloseDocument: closeDocument,
                onMoveDocument: { sourceDocumentID, destinationDocumentID in
                    documentStore.moveOpenDocument(sourceDocumentID, relativeTo: destinationDocumentID)
                },
                onShowLibrary: onShowLibrary,
                libraryLabel: handout == nil ? "返回文稿" : "返回讲义库",
                onInteract: handout.map { workspace in { workspace.interact(at: activePageIndex) } }
            )
        }
    }

    @ViewBuilder private var workspaceToolbar: some View {
        if annotationEditingEnabled {
            ToolPaletteView(
                activeController: activeController,
                selectedTool: $selectedTool,
                selectedPenVariant: $selectedPenVariant,
                eraserMode: $eraserMode,
                isScribbleEraseEnabled: $isScribbleEraseEnabled,
                showsThumbnails: thumbnailVisibility,
                onSearch: practice == nil && handout == nil ? { showsPDFSearch = true } : nil,
                onInsertImage: { showsImageImporter = true },
                onInsertShape: insertShape,
                hasActiveDocument: !activeDocumentID.isEmpty,
                canClearPage: activeController != nil,
                onDocumentAction: handleDocumentOutput,
                onClearPage: requestClearCurrentPage,
                allowsQuestionCapture: practice == nil && handout == nil,
                onAssistant: onAssistant,
                isAssistantOpen: showsAssistant,
                onToggleEditing: canToggleEditing ? toggleEditing : nil
            )
        } else {
            ReadOnlyToolPaletteView(
                showsThumbnails: thumbnailVisibility,
                onSearch: practice == nil && handout == nil ? { showsPDFSearch = true } : nil,
                hasActiveDocument: !activeDocumentID.isEmpty,
                onDocumentAction: handleDocumentOutput,
                onAssistant: onAssistant,
                isAssistantOpen: showsAssistant,
                onToggleEditing: canToggleEditing ? toggleEditing : nil
            )
        }
    }

    private var canvasContent: some View {
        ZStack {
            TiyiNoteTheme.documentWorkspace
                .ignoresSafeArea()

            VStack(spacing: 0) {
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
        .onChange(of: handout?.requestedPageID) { _, id in
            if let id { requestedReaderPageIndex = documentStore.pageIndex(for: id, in: activeDocumentID) }
        }
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
        guard annotationEditingEnabled else { return }
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
        guard annotationEditingEnabled else { return }
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
        if handout != nil {
            workspaceAlert = .outputFailed("这份讲义包含可互动网页，暂不支持 PDF 导出与打印。正文和批注已保存在本机。")
            return
        }
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

    private var interactionContentID: String {
        "\(ObjectIdentifier(documentStore))-\(activeDocumentID)"
    }

    private var canToggleEditing: Bool {
        PlatformCapabilities.current.canEditAnnotations && canEditActiveDocument && !activeDocumentID.isEmpty
    }

    private var annotationEditingEnabled: Bool {
        interactionSession.canWrite(contentID: interactionContentID, hasPermission: canToggleEditing)
    }

    private func toggleEditing() {
        guard canToggleEditing else { return }
        if annotationEditingEnabled {
            pendingReadOnly = true
        } else {
            interactionSession.toggle(contentID: interactionContentID, hasPermission: canToggleEditing)
        }
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

/// Resize state stays here so pointer samples do not rebuild the document toolbar or resolve chat context.
private struct AssistantSplitView<Canvas: View>: View {
    let maximumWidth: CGFloat
    let assistant: AnyView?
    let canvas: Canvas
    @State private var width: CGFloat = 390
    @GestureState private var dragTranslation: CGFloat = 0
    @Namespace private var coordinateSpace

    private func clampedWidth(_ proposed: CGFloat) -> CGFloat {
        min(maximumWidth, max(320, proposed))
    }

    var body: some View {
        HStack(spacing: 0) {
            canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let assistant {
                divider.zIndex(1)
                assistant.frame(width: clampedWidth(clampedWidth(width) - dragTranslation))
            }
        }
        .coordinateSpace(name: coordinateSpace)
        // The divider tracks the finger immediately, including when inherited UI animations are active.
        .transaction(value: dragTranslation) { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(TiyiNoteTheme.textTertiary.opacity(0.18))
            .frame(width: 0.5)
            .overlay {
                Capsule()
                    .fill(TiyiNoteTheme.documentWorkspace)
                    .frame(width: 12, height: 44)
                    .overlay {
                        Capsule().fill(TiyiNoteTheme.textTertiary.opacity(0.55))
                            .frame(width: 3, height: 22)
                    }
                    .overlay { Capsule().strokeBorder(TiyiNoteTheme.textTertiary.opacity(0.2), lineWidth: 0.5) }
            }
            .overlay {
                Color.clear.frame(width: 28).contentShape(Rectangle())
                    // The divider moves during resize; measuring in its local coordinates creates feedback jitter.
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(coordinateSpace))
                        .updating($dragTranslation) { value, translation, transaction in
                            transaction.animation = nil
                            translation = value.translation.width
                        }
                        .onEnded { value in
                            width = clampedWidth(clampedWidth(width) - value.translation.width)
                        })
                    .accessibilityLabel("调整对话宽度")
                    .accessibilityValue("\(Int(clampedWidth(clampedWidth(width) - dragTranslation)))")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: width = clampedWidth(width + 20)
                        case .decrement: width = clampedWidth(width - 20)
                        @unknown default: break
                        }
                    }
                    .accessibilityIdentifier("tiyi-assistant-resize")
            }
    }
}
