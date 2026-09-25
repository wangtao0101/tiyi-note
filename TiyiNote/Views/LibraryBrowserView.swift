import SwiftUI
import Observation
import UniformTypeIdentifiers
#if !targetEnvironment(macCatalyst)
import AVFoundation
import VisionKit
#endif

/// Own the provider's file before its callback returns; async import keeps this copy alive.
final class StagedDocumentDrop: @unchecked Sendable {
    let url: URL
    private let directory: URL

    init(copying source: URL, suggestedName: String? = nil) throws {
        guard source.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TiyiDocumentDrop-" + UUID().uuidString, isDirectory: true)
        let name = suggestedName.map { URL(fileURLWithPath: $0).lastPathComponent }
        let fileName = name.flatMap { $0.isEmpty ? nil : $0 } ?? source.lastPathComponent
        url = directory.appendingPathComponent(fileName)
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readableURL in
                do { try FileManager.default.copyItem(at: readableURL, to: url) }
                catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

/// Keep browsing context outside the mounted library, so entering the full-screen editor can
/// remove its complete view tree while returning to the same folder, filter, and scroll target.
@Observable
final class LibraryBrowserState {
    var scope = LibraryScope.documents
    var selectedFolderID: String? {
        didSet { if selectedFolderID != oldValue { scrollOffset = 0 } }
    }
    var searchText = "" {
        didSet { if searchText != oldValue { scrollOffset = 0 } }
    }
    var kindFilter = LibraryKindFilter.all {
        didSet { if kindFilter != oldValue { scrollOffset = 0 } }
    }
    @ObservationIgnored var scrollOffset: CGFloat = 0
}

struct LibraryBrowserView: View {
    @ObservedObject var documentStore: DrawingDocumentStore
    @Bindable var browsingState: LibraryBrowserState
    let onExit: (() -> Void)?
    let onSyncNow: () async -> Void
    let onOpenDocument: (String) -> Void
    let canEditDocument: (String) -> Bool
    var libraryPicker: AnyView? = nil

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var isSelecting = false
    @State private var selectedFolderIDs = Set<String>()
    @State private var selectedDocumentIDs = Set<String>()
    @State private var folderEditorRequest: FolderEditorRequest?
    @State private var canvasRequest: CanvasCreationRequest?
    @State private var nameAction: LibraryNameAction?
    @State private var draftName = ""
    @State private var moveRequest: LibraryMoveRequest?
    @State private var destructiveAction: LibraryDestructiveAction?
    @State private var showsPDFImporter = false
    @State private var importDestinationFolderID: String?
    @State private var showsDocumentScanner = false
    @State private var scanDestinationFolderID: String?
    @State private var errorMessage: String?
    @State private var showsCloudSyncStatus = false

    @AppStorage("library.layoutMode") private var layoutRawValue = LibraryLayoutMode.list.rawValue
    @AppStorage("library.sortOrder") private var sortRawValue = LibrarySortOrder.modifiedNewest.rawValue

    var body: some View {
        libraryPage(folderID: scope == .documents ? browsingState.selectedFolderID : nil)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("document-library")
        .accessibilityLabel("文稿")
        .fileImporter(
            isPresented: $showsPDFImporter,
            allowedContentTypes: [.pdf, .tiyiNoteDocument],
            allowsMultipleSelection: true,
            onCompletion: handlePDFImport
        )
#if !targetEnvironment(macCatalyst)
        .sheet(isPresented: $showsDocumentScanner) {
            DocumentScannerView(
                onScan: handleScannedPDF,
                onCancel: { showsDocumentScanner = false },
                onFailure: { error in
                    showsDocumentScanner = false
                    present(error)
                }
            )
            .ignoresSafeArea()
        }
#endif
        .sheet(item: $folderEditorRequest) { request in
            FolderEditorSheet(
                request: request,
                onSave: saveFolderEditor
            )
        }
        .sheet(item: $canvasRequest) { request in
            CanvasCreationSheet { title, style, color in
                _ = try documentStore.createCanvas(
                    named: title,
                    in: request.parentID,
                    backgroundStyle: style,
                    backgroundColor: color
                )
            }
        }
        .sheet(item: $moveRequest) { request in
            LibraryMoveSheet(
                documentStore: documentStore,
                request: request,
                onMove: { destinationID in
                    try documentStore.moveItems(
                        folderIDs: request.folderIDs,
                        documentIDs: request.documentIDs,
                        to: destinationID,
                        causalContext: request.collaborationContext
                    )
                    finishSelecting()
                }
            )
        }
        .sheet(isPresented: $showsCloudSyncStatus) {
            CloudSyncStatusSheet(
                documentStore: documentStore,
                onSyncNow: onSyncNow
            )
        }
        .alert(nameAction?.title ?? "名称", isPresented: nameActionIsPresented) {
            TextField("名称", text: $draftName)
            Button("取消", role: .cancel) { nameAction = nil }
            Button("保存") { commitNameAction() }
        } message: {
            Text(nameAction?.message ?? "")
        }
        .alert("操作失败", isPresented: errorIsPresented) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "请稍后重试。")
        }
        .confirmationDialog(
            destructiveAction?.title ?? "确认操作",
            isPresented: destructiveActionIsPresented,
            titleVisibility: .visible
        ) {
            if let action = destructiveAction {
                Button(action.confirmationTitle, role: .destructive) {
                    commitDestructiveAction(action)
                }
            }
            Button("取消", role: .cancel) { destructiveAction = nil }
        } message: {
            Text(destructiveAction?.message ?? "")
        }
        .onChange(of: scope) { _, _ in
            finishSelecting()
            browsingState.searchText = ""
            browsingState.selectedFolderID = nil
            browsingState.scrollOffset = 0
        }
    }

    private var scope: LibraryScope { browsingState.scope }

    private func libraryPage(folderID: String?) -> some View {
        LibraryContentPage(
            documentStore: documentStore,
            scope: scope,
            folderID: folderID,
            searchText: browsingState.searchText,
            kindFilter: browsingState.kindFilter,
            scrollState: browsingState,
            layoutMode: layoutMode,
            sortOrder: sortOrder,
            isSelecting: $isSelecting,
            selectedFolderIDs: $selectedFolderIDs,
            selectedDocumentIDs: $selectedDocumentIDs,
            onSetScope: {
                browsingState.scope = $0
                // Selecting a library location also returns to its root when that location
                // was already selected while browsing a nested folder.
                finishSelecting()
                browsingState.selectedFolderID = nil
                browsingState.scrollOffset = 0
            },
            onSetFilter: { browsingState.kindFilter = $0 },
            onSetLayout: { layoutRawValue = $0.rawValue },
            onSetSort: { sortRawValue = $0.rawValue },
            onNavigate: navigate(to:),
            onCommand: handleCommand,
            onNewFolder: {
                folderEditorRequest = FolderEditorRequest(parentID: folderID)
            },
            onNewCanvas: {
                canvasRequest = CanvasCreationRequest(parentID: folderID)
            },
            onImportPDF: {
                importDestinationFolderID = folderID
                showsPDFImporter = true
            },
            onScanDocument: {
                startDocumentScan(into: folderID)
            },
            onEmptyTrash: {
                destructiveAction = .emptyTrash
            },
            onDropPDFs: { result in
                switch result {
                case .success(let staged):
                    importDroppedPDFs(staged, into: folderID)
                case .failure(let error):
                    present(error)
                }
            },
            canEditDocument: canEditDocument,
            libraryPicker: libraryPicker
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            libraryNavigationBar
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting {
                LibrarySelectionBar(
                    scope: scope,
                    selectionCount: selectedFolderIDs.count + selectedDocumentIDs.count,
                    onMove: {
                        presentMovePicker(
                            folderIDs: selectedFolderIDs,
                            documentIDs: selectedDocumentIDs
                        )
                    },
                    onTrash: {
                        destructiveAction = .batchTrash(
                            folderIDs: selectedFolderIDs,
                            documentIDs: selectedDocumentIDs
                        )
                    },
                    onRestore: restoreSelection,
                    onDeletePermanently: {
                        destructiveAction = .batchPermanentDelete(
                            folderIDs: selectedFolderIDs,
                            documentIDs: selectedDocumentIDs
                        )
                    },
                    onCancel: finishSelecting
                )
            }
        }
    }

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    private var libraryNavigationBar: some View {
        HStack(spacing: 10) {
            LibraryInlineSearchField(text: $browsingState.searchText, fillsAvailableWidth: isCompact)

            Spacer(minLength: 0)

            if let onExit {
                Button(action: onExit) {
                    LibraryToolbarIcon(symbol: "house", fontSize: 16, frameSize: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回首页")
            }

            Button {
                showsCloudSyncStatus = true
            } label: {
                LibraryToolbarIcon(symbol: cloudStatusSymbol, fontSize: 16, frameSize: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("iCloud 同步状态")
            .accessibilityValue(cloudStatusLabel)
        }
        .padding(.horizontal, isCompact ? 16 : 20)
        .frame(height: TiyiWorkspaceLayout.headerHeight)
        .background(TiyiNoteTheme.chrome)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("document-library-header")
    }

    private var cloudStatusSymbol: String {
        switch documentStore.cloudSyncStatus {
        case .idle, .scheduled, .syncing: "icloud"
        case .succeeded: "checkmark.icloud.fill"
        case .waitingForAccount: "person.crop.circle.badge.exclamationmark"
        case .waitingForNetwork: "wifi.slash"
        case .failed: "exclamationmark.icloud.fill"
        }
    }

    private var cloudStatusLabel: String {
        switch documentStore.cloudSyncStatus {
        case .idle: "待同步"
        case .scheduled: "等待同步"
        case .syncing: "同步中"
        case .succeeded: "已同步"
        case .waitingForAccount: "请登录 iCloud"
        case .waitingForNetwork: "等待网络"
        case .failed: "同步失败"
        }
    }

    private var layoutMode: LibraryLayoutMode {
        LibraryLayoutMode(rawValue: layoutRawValue) ?? .list
    }

    private var sortOrder: LibrarySortOrder {
        LibrarySortOrder(rawValue: sortRawValue) ?? .modifiedNewest
    }

    private func navigate(to folderID: String?) {
        guard scope == .documents else {
            browsingState.scope = .documents
            DispatchQueue.main.async { navigate(to: folderID) }
            return
        }
        finishSelecting()
        browsingState.selectedFolderID = folderID
        browsingState.scrollOffset = 0
    }

    private func handleCommand(_ command: LibraryItemCommand) {
        do {
            switch command {
            case .openFolder(let id):
                navigate(to: id)
            case .openDocument(let id):
                onOpenDocument(id)
            case .editFolder(let id):
                guard let folder = documentStore.folder(withID: id),
                      let context = documentStore.folderEditorCollaborationContext(for: id) else {
                    return
                }
                folderEditorRequest = FolderEditorRequest(
                    folder: folder,
                    collaborationContext: context
                )
            case .renameDocument(let id):
                guard let document = documentStore.document(withID: id) else { return }
                draftName = document.title
                nameAction = .renameDocument(
                    id,
                    documentStore.documentMetadataCollaborationFrontier(for: id)
                )
            case .duplicateDocument(let id):
                Task {
                    do { _ = try await documentStore.duplicateDocumentInBackground(id) }
                    catch { present(error) }
                }
            case .moveFolder(let id):
                presentMovePicker(folderIDs: [id], documentIDs: [])
            case .moveDocument(let id):
                presentMovePicker(folderIDs: [], documentIDs: [id])
            case .toggleFolderFavorite(let id, let isFavorite):
                try documentStore.setFolderFavorite(id, isFavorite: isFavorite)
            case .toggleDocumentFavorite(let id, let isFavorite):
                try documentStore.setDocumentFavorite(id, isFavorite: isFavorite)
            case .trashFolder(let id):
                destructiveAction = .trashFolder(id)
            case .trashDocument(let id):
                destructiveAction = .trashDocument(id)
            case .restoreFolder(let id):
                try documentStore.restore(folderID: id)
            case .restoreDocument(let id):
                try documentStore.restore(documentID: id)
            case .permanentlyDeleteFolder(let id):
                destructiveAction = .permanentlyDeleteFolder(id)
            case .permanentlyDeleteDocument(let id):
                destructiveAction = .permanentlyDeleteDocument(id)
            }
        } catch {
            present(error)
        }
    }

    private func presentMovePicker(
        folderIDs: Set<String>,
        documentIDs: Set<String>
    ) {
        moveRequest = LibraryMoveRequest(
            folderIDs: folderIDs,
            documentIDs: documentIDs,
            collaborationContext: documentStore.libraryMoveCollaborationContext(
                folderIDs: folderIDs,
                documentIDs: documentIDs
            )
        )
    }

    private func saveFolderEditor(
        request: FolderEditorRequest,
        title: String,
        color: LibraryFolderColor,
        icon: LibraryFolderIcon
    ) throws {
        if let folderID = request.folderID {
            let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            try documentStore.updateFolderMetadata(
                folderID,
                title: normalizedTitle == request.originalTitle ? nil : normalizedTitle,
                color: color == request.originalColor ? nil : color,
                icon: icon == request.originalIcon ? nil : icon,
                causalContext: request.collaborationContext
            )
        } else {
            let folder = try documentStore.createFolder(
                named: title,
                in: request.parentID,
                color: color,
                icon: icon
            )
            if isCompact {
                navigate(to: folder.id)
            }
        }
    }

    private func commitNameAction() {
        guard let action = nameAction else { return }
        nameAction = nil
        do {
            switch action {
            case .renameDocument(let id, let context):
                try documentStore.renameDocument(
                    id,
                    to: draftName,
                    causalContext: context
                )
            }
        } catch {
            present(error)
        }
    }

    private func commitDestructiveAction(_ action: LibraryDestructiveAction) {
        destructiveAction = nil
        do {
            switch action {
            case .trashFolder(let id):
                try documentStore.moveToTrash(folderID: id)
            case .trashDocument(let id):
                try documentStore.moveToTrash(documentID: id)
            case .permanentlyDeleteFolder(let id):
                try documentStore.permanentlyDelete(folderID: id)
            case .permanentlyDeleteDocument(let id):
                try documentStore.permanentlyDelete(documentID: id)
            case .emptyTrash:
                try documentStore.emptyTrash()
            case .batchTrash(let folderIDs, let documentIDs):
                try documentStore.moveItemsToTrash(
                    folderIDs: folderIDs,
                    documentIDs: documentIDs
                )
                finishSelecting()
            case .batchPermanentDelete(let folderIDs, let documentIDs):
                try documentStore.permanentlyDeleteItems(
                    folderIDs: folderIDs,
                    documentIDs: documentIDs
                )
                finishSelecting()
            }
        } catch {
            present(error)
        }
    }

    private func restoreSelection() {
        do {
            let selectedFolders = documentStore.folders.filter {
                selectedFolderIDs.contains($0.id)
            }
            let rootSelectedFolders = selectedFolders.filter { folder in
                !selectedFolders.contains(where: { candidate in
                    candidate.id != folder.id
                        && LibraryPath.isDescendant(
                            folder.id,
                            of: candidate.id,
                            folders: documentStore.folders
                        )
                })
            }
            for folder in rootSelectedFolders {
                try documentStore.restore(folderID: folder.id)
            }
            for id in selectedDocumentIDs
            where documentStore.document(withID: id)?.trashedAt != nil {
                try documentStore.restore(documentID: id)
            }
            finishSelecting()
        } catch {
            present(error)
        }
    }

    private func handlePDFImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            importDocuments(urls, into: importDestinationFolderID)
        case .failure(let error):
            present(error)
        }
    }

    @discardableResult
    private func importDroppedPDFs(_ staged: StagedDocumentDrop, into folderID: String?) -> Bool {
        guard PlatformCapabilities.current.canImportPDF, scope == .documents else { return false }
        let fileExtension = staged.url.pathExtension
        let isPDF = fileExtension.caseInsensitiveCompare("pdf") == .orderedSame
        let isEditableDocument = fileExtension.caseInsensitiveCompare("tiyinote") == .orderedSame
        guard isPDF || isEditableDocument else { return false }
        importDocuments([staged.url], into: folderID, stagedDrop: staged)
        return true
    }

    private func importDocuments(_ urls: [URL], into folderID: String?, stagedDrop: StagedDocumentDrop? = nil) {
        let accessedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
        Task {
            defer {
                for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
                withExtendedLifetime(stagedDrop) {}
            }
            do {
                let pdfURLs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
                if !pdfURLs.isEmpty {
                    _ = try await documentStore.importPDFsInBackground(from: pdfURLs, into: folderID)
                }
                for url in urls where url.pathExtension.lowercased() == "tiyinote" {
                    _ = try documentStore.importEditableDocumentPackage(from: url, into: folderID)
                }
            } catch { present(error) }
        }
    }

    private func importPDFs(_ urls: [URL], into folderID: String?) {
        importDocuments(urls, into: folderID)
    }

    private func startDocumentScan(into folderID: String?) {
#if targetEnvironment(macCatalyst)
        errorMessage = "Mac 暂不支持相机扫描。"
#else
        guard VNDocumentCameraViewController.isSupported else {
            errorMessage = "当前设备不支持文档扫描。请在带相机的 iPad 上使用。"
            return
        }
        scanDestinationFolderID = folderID
        showsDocumentScanner = true
#endif
    }

    private func handleScannedPDF(_ data: Data) {
        showsDocumentScanner = false
        let fileName = "扫描-\(UUID().uuidString.prefix(8)).pdf"
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName)
        do {
            try data.write(to: temporaryURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            _ = try documentStore.importPDFs(
                from: [temporaryURL],
                into: scanDestinationFolderID
            )
        } catch {
            present(error)
        }
    }

    private func finishSelecting() {
        isSelecting = false
        selectedFolderIDs.removeAll()
        selectedDocumentIDs.removeAll()
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private var nameActionIsPresented: Binding<Bool> {
        Binding(
            get: { nameAction != nil },
            set: { if !$0 { nameAction = nil } }
        )
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var destructiveActionIsPresented: Binding<Bool> {
        Binding(
            get: { destructiveAction != nil },
            set: { if !$0 { destructiveAction = nil } }
        )
    }
}

private struct LibraryToolbarIcon: View {
    let symbol: String
    var isActive = false
    var tint: Color? = nil
    var fontSize: CGFloat = 14
    var frameSize: CGFloat = 34

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(
                isActive
                    ? TiyiNoteTheme.selectionBlue
                    : (tint ?? TiyiNoteTheme.textPrimary)
            )
            .frame(width: frameSize, height: frameSize)
            .contentShape(Rectangle())
    }
}

private struct LibraryInlineSearchField: View {
    @Binding var text: String
    let fillsAvailableWidth: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(TiyiNoteTheme.textPrimary)

            TextField("搜索文稿和文件夹", text: $text)
                .textFieldStyle(.plain)
                .font(TiyiWorkspaceLayout.headerSearchFont)
                .foregroundStyle(TiyiNoteTheme.textPrimary)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(TiyiNoteTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 0, idealWidth: 250, maxWidth: fillsAvailableWidth ? .infinity : 300)
        .frame(height: TiyiWorkspaceLayout.headerSearchHeight)
        .contentShape(Rectangle())
        .background(TiyiNoteTheme.textPrimary.opacity(0.045), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("搜索文稿和文件夹")
        .accessibilityIdentifier("library-search-field")
    }
}

/// A compact visible control with extra vertical hit space, without automatic glass padding
/// or a shadow that gets clipped by the phone's horizontal toolbar viewport.
struct LibraryCompactControlStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var isProminent = false
    var horizontalPadding: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, horizontalPadding)
            .frame(height: 28)
            .foregroundStyle(
                isProminent ? Color.white
                    : configuration.role == .destructive ? TiyiNoteTheme.danger : TiyiNoteTheme.textPrimary
            )
            .background(
                isProminent ? Color.black : TiyiNoteTheme.textPrimary.opacity(0.045),
                in: Capsule()
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.45)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
    }
}

private struct LibraryContentPage: View {
    @ObservedObject var documentStore: DrawingDocumentStore
    let scope: LibraryScope
    let folderID: String?
    let searchText: String
    let kindFilter: LibraryKindFilter
    let scrollState: LibraryBrowserState
    let layoutMode: LibraryLayoutMode
    let sortOrder: LibrarySortOrder
    @Binding var isSelecting: Bool
    @Binding var selectedFolderIDs: Set<String>
    @Binding var selectedDocumentIDs: Set<String>

    let onSetScope: (LibraryScope) -> Void
    let onSetFilter: (LibraryKindFilter) -> Void
    let onSetLayout: (LibraryLayoutMode) -> Void
    let onSetSort: (LibrarySortOrder) -> Void
    let onNavigate: (String?) -> Void
    let onCommand: (LibraryItemCommand) -> Void
    let onNewFolder: () -> Void
    let onNewCanvas: () -> Void
    let onImportPDF: () -> Void
    let onScanDocument: () -> Void
    let onEmptyTrash: () -> Void
    let onDropPDFs: (Result<StagedDocumentDrop, Error>) -> Void
    let canEditDocument: (String) -> Bool
    var libraryPicker: AnyView? = nil

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader
            if folders.isEmpty, documents.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .background(TiyiNoteTheme.chrome)
        .overlay {
            if isDropTargeted, PlatformCapabilities.current.canImportPDF {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(TiyiNoteTheme.selectionBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(
                                TiyiNoteTheme.selectionBorder,
                                style: StrokeStyle(lineWidth: 2, dash: [8, 5])
                            )
                    }
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(
            of: [
                UTType.fileURL.identifier,
                UTType.pdf.identifier,
                UTType.tiyiNoteDocument.identifier
            ],
            isTargeted: $isDropTargeted,
            perform: receiveDroppedFiles
        )
    }

    /// Copy provider-owned files inside the callback, before scheduling any asynchronous work.
    private func receiveDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        guard PlatformCapabilities.current.canImportPDF else { return false }
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.tiyiNoteDocument.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        let dropHandler = onDropPDFs
        for provider in fileProviders {
            let type: UTType? = provider.hasItemConformingToTypeIdentifier(UTType.tiyiNoteDocument.identifier)
                ? .tiyiNoteDocument : (provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) ? .pdf : nil)
            if let type {
                provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                    let result = Result {
                        guard let url else { throw error ?? CocoaError(.fileReadUnknown) }
                        var name = provider.suggestedName ?? url.lastPathComponent
                        if URL(fileURLWithPath: name).pathExtension.isEmpty, let ext = type.preferredFilenameExtension {
                            name += "." + ext
                        }
                        return try StagedDocumentDrop(copying: url, suggestedName: name)
                    }
                    DispatchQueue.main.async { dropHandler(result) }
                }
            } else {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    let result = Result {
                        let url: URL?
                        if let data = item as? Data {
                            url = URL(dataRepresentation: data, relativeTo: nil)
                        } else {
                            url = item as? URL
                        }
                        guard let url else { throw error ?? CocoaError(.fileReadUnknown) }
                        return try StagedDocumentDrop(copying: url)
                    }
                    DispatchQueue.main.async { dropHandler(result) }
                }
            }
        }
        return true
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isCompactLayout {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if let libraryPicker { libraryPicker }
                        filterControl
                        primaryAction
                        utilityControls
                    }
                }
                .frame(height: 36)
                if showsFolderPath {
                    LibraryBreadcrumbs(
                        folderID: folderID,
                        folders: documentStore.folders,
                        onNavigate: onNavigate
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 8) {
                    if let libraryPicker { libraryPicker }
                    filterControl
                        .fixedSize(horizontal: true, vertical: false)
                    if showsFolderPath {
                        Rectangle()
                            .fill(TiyiNoteTheme.hairline)
                            .frame(width: 1, height: 16)
                            .padding(.horizontal, 2)
                        LibraryBreadcrumbs(
                            folderID: folderID,
                            folders: documentStore.folders,
                            onNavigate: onNavigate
                        )
                        .frame(minWidth: 0, maxWidth: .infinity)
                    } else {
                        Spacer(minLength: 16)
                    }
                    primaryAction
                        .fixedSize(horizontal: true, vertical: false)
                    utilityControls
                        .fixedSize(horizontal: true, vertical: false)
                }
                .frame(height: 36)
            }
        }
        .padding(.horizontal, isCompactLayout ? 16 : 20)
        .padding(.vertical, 2)
        .background(TiyiNoteTheme.chrome)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-controls-bar")
    }

    private var showsFolderPath: Bool {
        scope == .documents && searchText.isEmpty && folderID != nil
    }

    private var filterControl: some View {
        Menu {
            Section("位置") {
                ForEach(LibraryScope.allCases) { item in
                    Button {
                        onSetScope(item)
                    } label: {
                        Label(
                            item == .documents ? "全部文稿" : item.title,
                            systemImage: item == scope ? "checkmark" : item.symbol
                        )
                    }
                    .accessibilityIdentifier("library-scope-\(item.rawValue)")
                }
            }
            Section("类型") {
                ForEach(LibraryKindFilter.allCases) { filter in
                    Button {
                        onSetFilter(filter)
                    } label: {
                        Label(
                            filter.title,
                            systemImage: filter == kindFilter ? "checkmark" : filter.symbol
                        )
                    }
                    .accessibilityIdentifier("library-kind-\(filter.rawValue)")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(scope == .documents ? "全部" : scope.title)
                if kindFilter != .all {
                    Text(kindFilter.title).foregroundStyle(TiyiNoteTheme.textSecondary)
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TiyiNoteTheme.textPrimary)
                .padding(.horizontal, 2)
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(LibraryCompactControlStyle())
        .accessibilityLabel("筛选：\(scope == .documents ? "全部" : scope.title)，\(kindFilter.title)")
        .accessibilityIdentifier("library-filter-menu")
    }

    @ViewBuilder
    private var primaryAction: some View {
        if PlatformCapabilities.current.canManageLibrary, scope == .documents {
            Menu {
                Button(action: onNewCanvas) {
                    Label("新建画板", systemImage: "rectangle.and.pencil.and.ellipsis")
                }
                Button(action: onNewFolder) {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }
                if PlatformCapabilities.current.canImportPDF {
                    Button(action: onImportPDF) {
                        Label("导入 PDF", systemImage: "square.and.arrow.down")
                    }
                }
                if PlatformCapabilities.current.canScanDocuments {
                    Button(action: onScanDocument) {
                        Label("扫描文稿", systemImage: "doc.viewfinder")
                    }
                }
            } label: {
                Label("新建", systemImage: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 2)
                    .frame(height: 28)
            }
            .buttonStyle(LibraryCompactControlStyle(isProminent: true))
            .tint(.black)
        } else if PlatformCapabilities.current.canManageLibrary,
                  scope == .trash,
                  !folders.isEmpty || !documents.isEmpty {
            Button("清空", role: .destructive, action: onEmptyTrash)
                .font(.system(size: 14, weight: .semibold))
                .buttonStyle(LibraryCompactControlStyle())
                .tint(TiyiNoteTheme.danger)
        }
    }

    private var utilityControls: some View {
        Group {
            HStack(spacing: 8) {
                Button {
                    onSetLayout(layoutMode == .list ? .grid : .list)
                } label: {
                    LibraryToolbarIcon(
                        symbol: layoutMode == .list ? "square.grid.2x2" : "list.bullet",
                        fontSize: 13,
                        frameSize: 28
                    )
                }
                .buttonStyle(LibraryCompactControlStyle(horizontalPadding: 4))
                .accessibilityLabel(layoutMode == .list ? "网格视图" : "列表视图")

                Menu {
                    ForEach(LibrarySortOrder.allCases) { order in
                        Button {
                            onSetSort(order)
                        } label: {
                            Label(
                                order.title,
                                systemImage: order == sortOrder ? "checkmark" : order.symbol
                            )
                        }
                    }
                } label: {
                    LibraryToolbarIcon(
                        symbol: "arrow.up.arrow.down",
                        fontSize: 13,
                        frameSize: 28
                    )
                }
                .buttonStyle(LibraryCompactControlStyle(horizontalPadding: 4))
                .accessibilityLabel("排序：\(sortOrder.title)")

                if PlatformCapabilities.current.canManageLibrary,
                   !folders.isEmpty || !documents.isEmpty {
                    Button {
                        isSelecting.toggle()
                        if !isSelecting {
                            selectedFolderIDs.removeAll()
                            selectedDocumentIDs.removeAll()
                        }
                    } label: {
                        LibraryToolbarIcon(
                            symbol: isSelecting ? "checkmark.circle.fill" : "checklist",
                            isActive: isSelecting,
                            fontSize: 13,
                            frameSize: 28
                        )
                    }
                    .buttonStyle(LibraryCompactControlStyle(horizontalPadding: 4))
                    .accessibilityLabel(isSelecting ? "完成选择" : "选择项目")
                }
            }
        }
    }

    private var isCompactLayout: Bool {
        horizontalSizeClass == .compact
    }

    @ViewBuilder
    private var content: some View {
        LibraryItemsScrollView(browsingState: scrollState) {
            if layoutMode == .list {
                LazyVStack(spacing: 0) {
                    ForEach(folders) { folder in
                        LibraryFolderListRow(
                            folder: folder,
                            detail: folderDetail(folder),
                            scope: scope,
                            isSelected: selectedFolderIDs.contains(folder.id),
                            isSelecting: isSelecting,
                            canManage: PlatformCapabilities.current.canManageLibrary,
                            onTap: { tapFolder(folder) },
                            onCommand: onCommand
                        )
                        .id(folder.id)
                    }
                    ForEach(documents) { document in
                        LibraryDocumentListRow(
                            document: document,
                            thumbnail: documentStore.thumbnail(
                                forPage: 0,
                                in: document.id,
                                size: CGSize(width: 150, height: 100)
                            ),
                            scope: scope,
                            isSelected: selectedDocumentIDs.contains(document.id),
                            isSelecting: isSelecting,
                            canManage: PlatformCapabilities.current.canManageLibrary,
                            canEditContent: canEditDocument(document.id),
                            onTap: { tapDocument(document) },
                            onCommand: onCommand
                        )
                        .id(document.id)
                    }
                }
                .padding(.horizontal, isCompactLayout ? 16 : 20)
                .padding(.top, 4)
                .padding(.bottom, 8)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 18)],
                    alignment: .leading,
                    spacing: 22
                ) {
                    ForEach(folders) { folder in
                        LibraryFolderGridCard(
                            folder: folder,
                            detail: folderDetail(folder),
                            scope: scope,
                            isSelected: selectedFolderIDs.contains(folder.id),
                            isSelecting: isSelecting,
                            canManage: PlatformCapabilities.current.canManageLibrary,
                            onTap: { tapFolder(folder) },
                            onCommand: onCommand
                        )
                        .id(folder.id)
                    }
                    ForEach(documents) { document in
                        LibraryDocumentGridCard(
                            document: document,
                            thumbnail: documentStore.thumbnail(
                                forPage: 0,
                                in: document.id,
                                size: CGSize(width: 300, height: 210)
                            ),
                            scope: scope,
                            isSelected: selectedDocumentIDs.contains(document.id),
                            isSelecting: isSelecting,
                            canManage: PlatformCapabilities.current.canManageLibrary,
                            canEditContent: canEditDocument(document.id),
                            onTap: { tapDocument(document) },
                            onCommand: onCommand
                        )
                        .id(document.id)
                    }
                }
                .padding(.horizontal, isCompactLayout ? 16 : 20)
                .padding(.vertical, 12)
            }
        }
        .id([scope.rawValue, folderID ?? "", searchText, kindFilter.rawValue])
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptySymbol)
        } description: {
            Text(emptyDescription)
        } actions: {
            if scope == .documents, PlatformCapabilities.current.canManageLibrary {
                Button("新建画板", action: onNewCanvas)
                    .font(.system(size: 14, weight: .semibold))
                    .buttonStyle(LibraryCompactControlStyle(isProminent: true))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(TiyiNoteTheme.textSecondary)
    }

    private var emptyTitle: String {
        if !searchText.isEmpty { return "没有找到结果" }
        return switch scope {
        case .documents: "这里还没有文稿"
        case .favorites: "还没有收藏"
        case .trash: "回收站是空的"
        }
    }

    private var emptyDescription: String {
        switch scope {
        case .documents: "新建画板、文件夹，或导入 PDF。"
        case .favorites: "收藏的文件夹和文稿会显示在这里。"
        case .trash: "删除的项目会保留在这里，直到永久删除。"
        }
    }

    private var emptySymbol: String {
        switch scope {
        case .documents: "doc.on.doc"
        case .favorites: "star"
        case .trash: "trash"
        }
    }

    private var folders: [LibraryFolder] {
        let query = normalizedQuery
        let candidates: [LibraryFolder]
        switch scope {
        case .documents:
            candidates = documentStore.folders.filter { folder in
                folder.trashedAt == nil
                    && (query.isEmpty ? folder.parentID == folderID : true)
            }
        case .favorites:
            candidates = documentStore.favoriteFolders
        case .trash:
            let trashIDs = Set(documentStore.trashedFolders.map(\.id))
            candidates = documentStore.trashedFolders.filter { folder in
                !query.isEmpty
                    || folder.parentID == nil
                    || !trashIDs.contains(folder.parentID ?? "")
            }
        }
        return sortFolders(candidates.filter { folder in
            query.isEmpty || normalized(folder.title).contains(query)
        })
    }

    private var documents: [PDFWorkspaceDocument] {
        let query = normalizedQuery
        let candidates: [PDFWorkspaceDocument]
        switch scope {
        case .documents:
            candidates = documentStore.documents.filter { document in
                document.trashedAt == nil
                    && (query.isEmpty ? document.parentID == folderID : true)
            }
        case .favorites:
            candidates = documentStore.favoriteDocuments
        case .trash:
            let trashFolderIDs = Set(documentStore.trashedFolders.map(\.id))
            candidates = documentStore.trashedDocuments.filter { document in
                !query.isEmpty
                    || document.parentID == nil
                    || !trashFolderIDs.contains(document.parentID ?? "")
            }
        }
        let kindFiltered = candidates.filter { document in
            switch kindFilter {
            case .all: true
            case .pdf: document.kind == .pdf
            case .canvas: document.kind == .canvas
            }
        }
        return sortDocuments(kindFiltered.filter { document in
            query.isEmpty || normalized(document.title).contains(query)
        })
    }

    private var normalizedQuery: String {
        normalized(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale.current
        )
    }

    private func sortFolders(_ folders: [LibraryFolder]) -> [LibraryFolder] {
        folders.sorted { lhs, rhs in
            switch sortOrder {
            case .modifiedNewest:
                lhs.modifiedAt == rhs.modifiedAt
                    ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                    : lhs.modifiedAt > rhs.modifiedAt
            case .createdNewest:
                lhs.createdAt == rhs.createdAt
                    ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                    : lhs.createdAt > rhs.createdAt
            case .titleAscending:
                lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            case .titleDescending:
                lhs.title.localizedStandardCompare(rhs.title) == .orderedDescending
            }
        }
    }

    private func sortDocuments(_ documents: [PDFWorkspaceDocument]) -> [PDFWorkspaceDocument] {
        documents.sorted { lhs, rhs in
            switch sortOrder {
            case .modifiedNewest:
                lhs.modifiedAt == rhs.modifiedAt
                    ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                    : lhs.modifiedAt > rhs.modifiedAt
            case .createdNewest:
                lhs.createdAt == rhs.createdAt
                    ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                    : lhs.createdAt > rhs.createdAt
            case .titleAscending:
                lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            case .titleDescending:
                lhs.title.localizedStandardCompare(rhs.title) == .orderedDescending
            }
        }
    }

    private func folderDetail(_ folder: LibraryFolder) -> String {
        if let trashedAt = folder.trashedAt {
            return "已删除 · \(trashedAt.formatted(date: .numeric, time: .omitted))"
        }
        let folderIDs = LibraryPath.descendantIDs(of: folder.id, folders: documentStore.folders)
            .union([folder.id])
        let folderCount = max(folderIDs.count - 1, 0)
        let documentCount = documentStore.documents.filter {
            $0.trashedAt == nil && $0.parentID.map(folderIDs.contains) == true
        }.count
        return "\(folderCount + documentCount) 个项目"
    }

    private func tapFolder(_ folder: LibraryFolder) {
        if scope == .trash, !PlatformCapabilities.current.canManageLibrary { return }
        if isSelecting || scope == .trash {
            if selectedFolderIDs.contains(folder.id) {
                selectedFolderIDs.remove(folder.id)
            } else {
                selectedFolderIDs.insert(folder.id)
                if scope == .trash { isSelecting = true }
            }
        } else {
            onCommand(.openFolder(folder.id))
        }
    }

    private func tapDocument(_ document: PDFWorkspaceDocument) {
        if scope == .trash, !PlatformCapabilities.current.canManageLibrary { return }
        if isSelecting || scope == .trash {
            if selectedDocumentIDs.contains(document.id) {
                selectedDocumentIDs.remove(document.id)
            } else {
                selectedDocumentIDs.insert(document.id)
                if scope == .trash { isSelecting = true }
            }
        } else {
            onCommand(.openDocument(document.id))
        }
    }
}

/// User-driven offsets are saved independently of SwiftUI's transient scroll target binding.
/// Mounting/unmounting the library must not replace the saved position with its initial zero.
private struct LibraryItemsScrollView<Content: View>: View {
    let browsingState: LibraryBrowserState
    let content: Content
    @State private var position: ScrollPosition
    @State private var isUserScrolling = false

    init(browsingState: LibraryBrowserState, @ViewBuilder content: () -> Content) {
        self.browsingState = browsingState
        self.content = content()
        var restoredPosition = ScrollPosition(edge: .top)
        // Restore a viewport offset, not a row anchor. Registering the padded lazy rows as scroll
        // targets lets SwiftUI align their unpadded bounds and consume the page's leading gutter.
        restoredPosition.scrollTo(point: CGPoint(x: 0, y: browsingState.scrollOffset))
        _position = State(initialValue: restoredPosition)
    }

    var body: some View {
        ScrollView { content }
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .scrollPosition($position)
            .onScrollPhaseChange { _, phase in
                isUserScrolling = phase == .interacting || phase == .decelerating
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                if isUserScrolling {
                    browsingState.scrollOffset = max(0, offset)
                }
            }
            .accessibilityIdentifier("library-items")
    }
}

private struct LibraryFolderListRow: View {
    let folder: LibraryFolder
    let detail: String
    let scope: LibraryScope
    let isSelected: Bool
    let isSelecting: Bool
    let canManage: Bool
    let onTap: () -> Void
    let onCommand: (LibraryItemCommand) -> Void

    var body: some View {
        HStack(spacing: 12) {
            FolderListArtwork(folder: folder)

            VStack(alignment: .leading, spacing: 3) {
                Text(folder.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TiyiNoteTheme.textPrimary)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(TiyiNoteTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isSelecting {
                SelectionIndicator(isSelected: isSelected)
            } else if scope != .trash {
                Image(systemName: "chevron.right")
                    .foregroundStyle(TiyiNoteTheme.textTertiary)
                Button {
                    guard canManage else { return }
                    onCommand(.toggleFolderFavorite(folder.id, !folder.isFavorite))
                } label: {
                    Image(systemName: folder.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(folder.isFavorite ? Color.orange : TiyiNoteTheme.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .disabled(!canManage)
            }
        }
        .frame(height: 60)
        .background(isSelected ? TiyiNoteTheme.selectionBackground : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TiyiNoteTheme.hairline)
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu { itemMenu }
    }

    @ViewBuilder
    private var itemMenu: some View {
        if scope == .trash, canManage {
            Button { onCommand(.restoreFolder(folder.id)) } label: {
                Label("恢复", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) { onCommand(.permanentlyDeleteFolder(folder.id)) } label: {
                Label("永久删除", systemImage: "trash.slash")
            }
        } else if canManage {
            Button { onCommand(.toggleFolderFavorite(folder.id, !folder.isFavorite)) } label: {
                Label(folder.isFavorite ? "取消收藏" : "收藏", systemImage: folder.isFavorite ? "star.slash" : "star")
            }
            Button { onCommand(.editFolder(folder.id)) } label: {
                Label("名称、颜色与图标", systemImage: "paintpalette")
            }
            Button { onCommand(.moveFolder(folder.id)) } label: {
                Label("移动到", systemImage: "folder.badge.arrow.forward")
            }
            Divider()
            Button(role: .destructive) { onCommand(.trashFolder(folder.id)) } label: {
                Label("移到回收站", systemImage: "trash")
            }
        }
    }
}

private struct LibraryDocumentListRow: View {
    let document: PDFWorkspaceDocument
    let thumbnail: UIImage?
    let scope: LibraryScope
    let isSelected: Bool
    let isSelecting: Bool
    let canManage: Bool
    let canEditContent: Bool
    let onTap: () -> Void
    let onCommand: (LibraryItemCommand) -> Void

    var body: some View {
        HStack(spacing: 12) {
            DocumentListArtwork(document: document, thumbnail: thumbnail)

            VStack(alignment: .leading, spacing: 3) {
                Text(document.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TiyiNoteTheme.textPrimary)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(TiyiNoteTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isSelecting {
                SelectionIndicator(isSelected: isSelected)
            } else if scope != .trash {
                Button {
                    guard canManage else { return }
                    onCommand(.toggleDocumentFavorite(document.id, !document.isFavorite))
                } label: {
                    Image(systemName: document.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(document.isFavorite ? Color.orange : TiyiNoteTheme.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .disabled(!canManage)
            }
        }
        .frame(height: 60)
        .background(isSelected ? TiyiNoteTheme.selectionBackground : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TiyiNoteTheme.hairline)
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu { itemMenu }
    }

    private var detail: String {
        if let trashedAt = document.trashedAt {
            return "已删除 · \(trashedAt.formatted(date: .numeric, time: .omitted))"
        }
        let kind = document.kind == .canvas ? "画板" : "PDF"
        return "\(kind) · \(document.modifiedAt.formatted(date: .numeric, time: .omitted))"
    }

    @ViewBuilder
    private var itemMenu: some View {
        if scope == .trash, canManage {
            Button { onCommand(.restoreDocument(document.id)) } label: {
                Label("恢复", systemImage: "arrow.uturn.backward")
            }
            if canEditContent {
                Button(role: .destructive) { onCommand(.permanentlyDeleteDocument(document.id)) } label: {
                    Label("永久删除", systemImage: "trash.slash")
                }
            }
        } else {
            if canManage {
                Button { onCommand(.toggleDocumentFavorite(document.id, !document.isFavorite)) } label: {
                    Label(document.isFavorite ? "取消收藏" : "收藏", systemImage: document.isFavorite ? "star.slash" : "star")
                }
                if canEditContent {
                    Button { onCommand(.renameDocument(document.id)) } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                }
                Button { onCommand(.moveDocument(document.id)) } label: {
                    Label("移动到", systemImage: "folder.badge.arrow.forward")
                }
                Button { onCommand(.duplicateDocument(document.id)) } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                Divider()
                Button(role: .destructive) { onCommand(.trashDocument(document.id)) } label: {
                    Label("移到回收站", systemImage: "trash")
                }
            }
        }
    }
}

private struct LibraryFolderGridCard: View {
    let folder: LibraryFolder
    let detail: String
    let scope: LibraryScope
    let isSelected: Bool
    let isSelecting: Bool
    let canManage: Bool
    let onTap: () -> Void
    let onCommand: (LibraryItemCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FolderArtwork(folder: folder)
                .frame(maxWidth: .infinity)
                .aspectRatio(1.45, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    if isSelecting {
                        SelectionIndicator(isSelected: isSelected).padding(10)
                    }
                }
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(folder.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(TiyiNoteTheme.textPrimary)
                        .lineLimit(2)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(TiyiNoteTheme.textSecondary)
                }
                Spacer(minLength: 2)
                if !isSelecting, scope != .trash {
                    Image(systemName: folder.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(folder.isFavorite ? Color.yellow : TiyiNoteTheme.textSecondary)
                        .onTapGesture {
                            guard canManage else { return }
                            onCommand(.toggleFolderFavorite(folder.id, !folder.isFavorite))
                        }
                }
            }
        }
        .padding(6)
        .background(
            isSelected ? TiyiNoteTheme.selectionBackground : Color.clear,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu {
            if scope == .trash, canManage {
                Button { onCommand(.restoreFolder(folder.id)) } label: {
                    Label("恢复", systemImage: "arrow.uturn.backward")
                }
                Button(role: .destructive) { onCommand(.permanentlyDeleteFolder(folder.id)) } label: {
                    Label("永久删除", systemImage: "trash.slash")
                }
            } else if canManage {
                Button { onCommand(.toggleFolderFavorite(folder.id, !folder.isFavorite)) } label: {
                    Label(folder.isFavorite ? "取消收藏" : "收藏", systemImage: "star")
                }
                Button { onCommand(.editFolder(folder.id)) } label: {
                    Label("名称、颜色与图标", systemImage: "paintpalette")
                }
                Button { onCommand(.moveFolder(folder.id)) } label: {
                    Label("移动到", systemImage: "folder.badge.arrow.forward")
                }
                Button(role: .destructive) { onCommand(.trashFolder(folder.id)) } label: {
                    Label("移到回收站", systemImage: "trash")
                }
            }
        }
    }
}

private struct LibraryDocumentGridCard: View {
    let document: PDFWorkspaceDocument
    let thumbnail: UIImage?
    let scope: LibraryScope
    let isSelected: Bool
    let isSelecting: Bool
    let canManage: Bool
    let canEditContent: Bool
    let onTap: () -> Void
    let onCommand: (LibraryItemCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DocumentArtwork(document: document, thumbnail: thumbnail)
                .frame(maxWidth: .infinity)
                .aspectRatio(1.45, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    if isSelecting {
                        SelectionIndicator(isSelected: isSelected).padding(10)
                    }
                }
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(document.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(TiyiNoteTheme.textPrimary)
                        .lineLimit(2)
                    Text(document.kind == .canvas ? "画板" : "PDF")
                        .font(.caption)
                        .foregroundStyle(TiyiNoteTheme.textSecondary)
                }
                Spacer(minLength: 2)
                if !isSelecting, scope != .trash {
                    Image(systemName: document.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(document.isFavorite ? Color.yellow : TiyiNoteTheme.textSecondary)
                        .onTapGesture {
                            guard canManage else { return }
                            onCommand(.toggleDocumentFavorite(document.id, !document.isFavorite))
                        }
                }
            }
        }
        .padding(6)
        .background(
            isSelected ? TiyiNoteTheme.selectionBackground : Color.clear,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu {
            if scope == .trash, canManage {
                Button { onCommand(.restoreDocument(document.id)) } label: {
                    Label("恢复", systemImage: "arrow.uturn.backward")
                }
                if canEditContent {
                    Button(role: .destructive) { onCommand(.permanentlyDeleteDocument(document.id)) } label: {
                        Label("永久删除", systemImage: "trash.slash")
                    }
                }
            } else {
                if canManage {
                    Button { onCommand(.toggleDocumentFavorite(document.id, !document.isFavorite)) } label: {
                        Label(document.isFavorite ? "取消收藏" : "收藏", systemImage: "star")
                    }
                    if canEditContent {
                        Button { onCommand(.renameDocument(document.id)) } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                    }
                    Button { onCommand(.moveDocument(document.id)) } label: {
                        Label("移动到", systemImage: "folder.badge.arrow.forward")
                    }
                    Button { onCommand(.duplicateDocument(document.id)) } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) { onCommand(.trashDocument(document.id)) } label: {
                        Label("移到回收站", systemImage: "trash")
                    }
                }
            }
        }
    }
}

/// Use one visible preview size as well as one column size. Fitting each page to a differently
/// proportioned image box makes portrait PDFs narrower than canvases and folder icons.
private struct LibraryListArtwork<Content: View>: View {
    var isDocument = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: 40, height: 40)
            .background(isDocument ? Color.white : Color.clear)
            .clipped()
            .overlay {
                if isDocument {
                    Rectangle()
                        .strokeBorder(TiyiNoteTheme.hairline, lineWidth: 0.5)
                }
            }
            .frame(width: 48, height: 48, alignment: .leading)
    }
}

private struct FolderListArtwork: View {
    let folder: LibraryFolder

    var body: some View {
        LibraryListArtwork {
            Image(systemName: folder.icon.systemImageName)
                .resizable()
                .scaledToFit()
                .foregroundStyle(folder.color.swiftUIColor.gradient)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(folder.title)文件夹外观")
        .accessibilityValue("颜色 \(folder.color.title)；图标 \(folder.icon.title)")
    }
}

private struct DocumentListArtwork: View {
    let document: PDFWorkspaceDocument
    let thumbnail: UIImage?

    var body: some View {
        LibraryListArtwork(isDocument: true) {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: document.kind == .canvas
                    ? "rectangle.and.pencil.and.ellipsis"
                    : "doc.richtext.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(TiyiNoteTheme.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(document.title)缩略图")
    }
}

private struct FolderArtwork: View {
    let folder: LibraryFolder

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(folder.color.swiftUIColor.gradient)
            Image(systemName: folder.icon.systemImageName)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: folder.color.swiftUIColor.opacity(0.18), radius: 8, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(folder.title)文件夹外观")
        .accessibilityValue("颜色 \(folder.color.title)；图标 \(folder.icon.title)")
    }
}

private struct DocumentArtwork: View {
    let document: PDFWorkspaceDocument
    let thumbnail: UIImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: document.kind == .canvas ? "rectangle.and.pencil.and.ellipsis" : "doc.richtext.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(TiyiNoteTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SelectionIndicator: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(isSelected ? TiyiNoteTheme.selectionBlue : TiyiNoteTheme.textSecondary)
            .background(Circle().fill(TiyiNoteTheme.workspace.opacity(0.75)))
            .frame(width: 32, height: 32)
    }
}

private struct LibraryBreadcrumbs: View {
    let folderID: String?
    let folders: [LibraryFolder]
    let onNavigate: (String?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button("文稿") { onNavigate(nil) }
                    .foregroundStyle(TiyiNoteTheme.textSecondary)
                    .frame(height: 36)
                ForEach(LibraryPath.ancestors(endingAt: folderID, folders: folders)) { folder in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(TiyiNoteTheme.textTertiary)
                    Button(folder.title) { onNavigate(folder.id) }
                        .fontWeight(folder.id == folderID ? .semibold : .regular)
                        .foregroundStyle(folder.id == folderID ? TiyiNoteTheme.textPrimary : TiyiNoteTheme.textSecondary)
                        .frame(height: 36)
                }
            }
            .font(.system(size: 14))
            .buttonStyle(.plain)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .defaultScrollAnchor(.trailing)
        .defaultScrollAnchor(.leading, for: .alignment)
        .frame(height: 36)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-breadcrumbs")
    }
}

private struct LibrarySelectionBar: View {
    let scope: LibraryScope
    let selectionCount: Int
    let onMove: () -> Void
    let onTrash: () -> Void
    let onRestore: () -> Void
    let onDeletePermanently: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("已选 \(selectionCount) 项")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(TiyiNoteTheme.textPrimary)
            Spacer()
            if scope == .trash {
                Button("恢复", action: onRestore)
                    .disabled(selectionCount == 0)
                Button("永久删除", role: .destructive, action: onDeletePermanently)
                    .disabled(selectionCount == 0)
            } else {
                Button("移动", action: onMove)
                    .disabled(selectionCount == 0)
                Button("删除", role: .destructive, action: onTrash)
                    .disabled(selectionCount == 0)
            }
            Button("取消", action: onCancel)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .frame(minHeight: 64)
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }
}

private struct FolderEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let request: FolderEditorRequest
    let onSave: (FolderEditorRequest, String, LibraryFolderColor, LibraryFolderIcon) throws -> Void

    @State private var title: String
    @State private var color: LibraryFolderColor
    @State private var icon: LibraryFolderIcon
    @State private var errorMessage: String?

    init(
        request: FolderEditorRequest,
        onSave: @escaping (FolderEditorRequest, String, LibraryFolderColor, LibraryFolderIcon) throws -> Void
    ) {
        self.request = request
        self.onSave = onSave
        _title = State(initialValue: request.originalTitle)
        _color = State(initialValue: request.originalColor)
        _icon = State(initialValue: request.originalIcon)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("文件夹名称", text: $title)
                }
                Section("预览") {
                    HStack {
                        Spacer()
                        FolderArtwork(
                            folder: LibraryFolder(
                                title: title.isEmpty ? "文件夹" : title,
                                parentID: nil,
                                color: color,
                                icon: icon
                            )
                        )
                        .frame(width: 150, height: 100)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Section("颜色") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
                        ForEach(LibraryFolderColor.allCases) { item in
                            Button {
                                color = item
                            } label: {
                                Circle()
                                    .fill(item.swiftUIColor)
                                    .frame(width: 38, height: 38)
                                    .overlay {
                                        if color == item {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 15, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.title)
                        }
                    }
                    .padding(.vertical, 5)
                }
                Section("图标") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 14) {
                        ForEach(LibraryFolderIcon.allCases) { item in
                            Button {
                                icon = item
                            } label: {
                                Image(systemName: item.systemImageName)
                                    .font(.system(size: 21))
                                    .foregroundStyle(icon == item ? .white : TiyiNoteTheme.textSecondary)
                                    .frame(width: 48, height: 42)
                                    .background(
                                        icon == item ? color.swiftUIColor : TiyiNoteTheme.surface,
                                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.title)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
            .navigationTitle(request.folderID == nil ? "新建文件夹" : "编辑文件夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            try onSave(request, title, color, icon)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .alert("无法保存文件夹", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "请检查名称后重试。")
        }
    }
}

private struct CanvasCreationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (String, CanvasBackgroundStyle, CanvasBackgroundColor) throws -> Void

    @State private var title = "未命名画板"
    @State private var style = CanvasBackgroundStyle.dotted
    @State private var color = CanvasBackgroundColor.ivory
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("画板名称", text: $title)
                }
                Section("预览") {
                    CanvasBackgroundPreview(style: style, color: color)
                        .aspectRatio(4 / 3, contentMode: .fit)
                        .frame(maxWidth: 360)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
                Section("背景样式") {
                    Picker("背景样式", selection: $style) {
                        ForEach(CanvasBackgroundStyle.allCases) { item in
                            Label(item.title, systemImage: item.systemImageName).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("背景颜色") {
                    HStack {
                        ForEach(CanvasBackgroundColor.allCases) { item in
                            Button {
                                color = item
                            } label: {
                                Circle()
                                    .fill(item.swiftUIColor)
                                    .frame(width: 38, height: 38)
                                    .overlay {
                                        Circle().stroke(
                                            color == item ? TiyiNoteTheme.selectionBlue : TiyiNoteTheme.strongHairline,
                                            lineWidth: color == item ? 3 : 1
                                        )
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.title)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(TiyiNoteTheme.danger)
                }
            }
            .navigationTitle("新建画板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        do {
                            try onCreate(title, style, color)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }
}

private struct CanvasBackgroundPreview: View {
    let style: CanvasBackgroundStyle
    let color: CanvasBackgroundColor

    var body: some View {
        Canvas { context, size in
            let guide = color == .dark ? Color.white.opacity(0.25) : Color.blue.opacity(0.18)
            let spacing: CGFloat = max(min(size.width, size.height) / 12, 14)
            switch style {
            case .blank:
                break
            case .ruled:
                var path = Path()
                for y in stride(from: spacing, through: size.height - spacing, by: spacing) {
                    path.move(to: CGPoint(x: spacing, y: y))
                    path.addLine(to: CGPoint(x: size.width - spacing, y: y))
                }
                context.stroke(path, with: .color(guide), lineWidth: 1)
            case .grid:
                var path = Path()
                for x in stride(from: spacing, through: size.width - spacing, by: spacing) {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: spacing, through: size.height - spacing, by: spacing) {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(path, with: .color(guide), lineWidth: 1)
            case .dotted:
                for x in stride(from: spacing, through: size.width - spacing, by: spacing) {
                    for y in stride(from: spacing, through: size.height - spacing, by: spacing) {
                        context.fill(
                            Path(ellipseIn: CGRect(x: x - 1.2, y: y - 1.2, width: 2.4, height: 2.4)),
                            with: .color(guide)
                        )
                    }
                }
            }
        }
        .background(color.swiftUIColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(TiyiNoteTheme.strongHairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 10, y: 5)
    }
}

private struct LibraryMoveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var documentStore: DrawingDocumentStore
    let request: LibraryMoveRequest
    let onMove: (String?) throws -> Void

    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Button {
                    move(to: nil)
                } label: {
                    Label("文稿根目录", systemImage: "books.vertical.fill")
                }
                ForEach(destinations) { folder in
                    Button {
                        move(to: folder.id)
                    } label: {
                        Label {
                            Text(LibraryPath.pathTitle(for: folder.id, folders: documentStore.folders))
                                .lineLimit(2)
                        } icon: {
                            Image(systemName: folder.icon.systemImageName)
                                .foregroundStyle(folder.color.swiftUIColor)
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(TiyiNoteTheme.danger)
                }
            }
            .navigationTitle("移动到")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var destinations: [LibraryFolder] {
        documentStore.folders
            .filter { folder in
                guard folder.trashedAt == nil,
                      !request.folderIDs.contains(folder.id) else { return false }
                return !request.folderIDs.contains(where: { movingID in
                    LibraryPath.isDescendant(
                        folder.id,
                        of: movingID,
                        folders: documentStore.folders
                    )
                })
            }
            .sorted {
                LibraryPath.pathTitle(for: $0.id, folders: documentStore.folders)
                    .localizedStandardCompare(
                        LibraryPath.pathTitle(for: $1.id, folders: documentStore.folders)
                    ) == .orderedAscending
            }
    }

    private func move(to destinationID: String?) {
        do {
            try onMove(destinationID)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CloudSyncStatusSheet: View {
    @ObservedObject var documentStore: DrawingDocumentStore
    let onSyncNow: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isManualSyncRunning = false

    var body: some View {
        NavigationStack {
            Form {
                Section("云同步") {
                    HStack(alignment: .center, spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(statusColor.opacity(0.12))
                                .frame(width: 42, height: 42)

                            if isSyncing {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(statusColor)
                            } else {
                                Image(systemName: statusSymbol)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(statusColor)
                            }
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(statusTitle)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(TiyiNoteTheme.textPrimary)
                            Text(statusDetail)
                                .font(.system(size: 13))
                                .foregroundStyle(TiyiNoteTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    Button(action: requestSyncNow) {
                        HStack(spacing: 9) {
                            if isSyncing {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text(isSyncing ? "正在同步…" : "现在同步")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(TiyiNoteTheme.selectionBlue)
                    .disabled(isSyncing || !canSync)
                } footer: {
                    Text("Tiyi 会在文稿变化、应用打开以及收到 iCloud 更新时自动同步。")
                }
            }
            .scrollContentBackground(.hidden)
            .background(TiyiNoteTheme.chrome)
            .navigationTitle("iCloud 同步状态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var isSyncing: Bool {
        if isManualSyncRunning { return true }
        if case .syncing = documentStore.cloudSyncStatus { return true }
        return false
    }

    private var canSync: Bool {
        if case .waitingForAccount = documentStore.cloudSyncStatus { return false }
        return true
    }

    private var statusSymbol: String {
        switch documentStore.cloudSyncStatus {
        case .idle where documentStore.lastCloudSyncAt != nil: "checkmark.icloud.fill"
        case .idle, .scheduled, .syncing: "icloud"
        case .succeeded: "checkmark.icloud.fill"
        case .waitingForAccount: "person.crop.circle.badge.exclamationmark"
        case .waitingForNetwork: "wifi.slash"
        case .failed: "exclamationmark.icloud.fill"
        }
    }

    private var statusTitle: String {
        switch documentStore.cloudSyncStatus {
        case .idle where documentStore.lastCloudSyncAt != nil: "资料库已同步至 iCloud"
        case .idle: "资料库等待首次同步"
        case .scheduled: "资料库已加入同步队列"
        case .syncing: "正在同步资料库"
        case .succeeded: "资料库已同步至 iCloud"
        case .waitingForAccount: "需要登录 iCloud"
        case .waitingForNetwork: "等待网络连接"
        case .failed: "iCloud 同步失败"
        }
    }

    private var statusDetail: String {
        switch documentStore.cloudSyncStatus {
        case .idle:
            return lastSyncDescription
        case .scheduled:
            return "更改已保存，将在稍后自动同步。\(lastSyncSuffix)"
        case .syncing:
            return "正在上传和下载最新更改。\(lastSyncSuffix)"
        case .succeeded(let date):
            return formattedLastSync(date)
        case .waitingForAccount:
            return "请先在系统设置中登录 iCloud。"
        case .waitingForNetwork:
            return "恢复网络后会自动继续同步。\(lastSyncSuffix)"
        case .failed(let message):
            return message
        }
    }

    private var statusColor: Color {
        TiyiNoteTheme.textPrimary
    }

    private var lastSyncDescription: String {
        guard let date = documentStore.lastCloudSyncAt else {
            return "尚未完成首次同步。"
        }
        return formattedLastSync(date)
    }

    private var lastSyncSuffix: String {
        guard let date = documentStore.lastCloudSyncAt else { return "" }
        return " \(formattedLastSync(date))"
    }

    private func formattedLastSync(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) {
            return "上次同步：今天 \(time)"
        }
        return "上次同步：\(date.formatted(date: .abbreviated, time: .omitted)) \(time)"
    }

    private func requestSyncNow() {
        guard !isSyncing, canSync else { return }
        isManualSyncRunning = true
        Task {
            await onSyncNow()
            isManualSyncRunning = false
        }
    }
}

enum LibraryScope: String, CaseIterable, Identifiable {
    case documents
    case favorites
    case trash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .documents: "文稿"
        case .favorites: "收藏夹"
        case .trash: "回收站"
        }
    }

    var symbol: String {
        switch self {
        case .documents: "folder.fill"
        case .favorites: "bookmark.fill"
        case .trash: "trash.fill"
        }
    }
}

private enum LibraryLayoutMode: String {
    case list
    case grid
}

enum LibraryKindFilter: String, CaseIterable, Identifiable {
    case all
    case pdf
    case canvas

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "全部"
        case .pdf: "PDF"
        case .canvas: "画板"
        }
    }
    var symbol: String {
        switch self {
        case .all: "square.stack.3d.up"
        case .pdf: "doc.richtext"
        case .canvas: "rectangle.and.pencil.and.ellipsis"
        }
    }
}

private enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case modifiedNewest
    case createdNewest
    case titleAscending
    case titleDescending

    var id: String { rawValue }
    var title: String {
        switch self {
        case .modifiedNewest: "最近修改"
        case .createdNewest: "最近创建"
        case .titleAscending: "名称 A–Z"
        case .titleDescending: "名称 Z–A"
        }
    }
    var symbol: String {
        switch self {
        case .modifiedNewest: "clock.arrow.circlepath"
        case .createdNewest: "calendar"
        case .titleAscending: "textformat.abc"
        case .titleDescending: "textformat.abc.dottedunderline"
        }
    }
}

private enum LibraryItemCommand {
    case openFolder(String)
    case openDocument(String)
    case editFolder(String)
    case renameDocument(String)
    case duplicateDocument(String)
    case moveFolder(String)
    case moveDocument(String)
    case toggleFolderFavorite(String, Bool)
    case toggleDocumentFavorite(String, Bool)
    case trashFolder(String)
    case trashDocument(String)
    case restoreFolder(String)
    case restoreDocument(String)
    case permanentlyDeleteFolder(String)
    case permanentlyDeleteDocument(String)
}

private struct FolderEditorRequest: Identifiable {
    let id = UUID()
    let folderID: String?
    let parentID: String?
    let originalTitle: String
    let originalColor: LibraryFolderColor
    let originalIcon: LibraryFolderIcon
    let collaborationContext: FolderEditorCollaborationContext?

    init(parentID: String? = nil) {
        folderID = nil
        self.parentID = parentID
        originalTitle = "新建文件夹"
        originalColor = .blue
        originalIcon = .folder
        collaborationContext = nil
    }

    init(folder: LibraryFolder, collaborationContext: FolderEditorCollaborationContext) {
        folderID = folder.id
        parentID = folder.parentID
        originalTitle = folder.title
        originalColor = folder.color
        originalIcon = folder.icon
        self.collaborationContext = collaborationContext
    }
}

private struct CanvasCreationRequest: Identifiable {
    let id = UUID()
    let parentID: String?
}

private struct LibraryMoveRequest: Identifiable {
    let id = UUID()
    let folderIDs: Set<String>
    let documentIDs: Set<String>
    let collaborationContext: LibraryMoveCollaborationContext
}

private enum LibraryNameAction {
    case renameDocument(String, CollaborationVersionVector)

    var title: String { "重命名文稿" }
    var message: String { "输入文稿的新名称。" }
}

private enum LibraryDestructiveAction {
    case trashFolder(String)
    case trashDocument(String)
    case permanentlyDeleteFolder(String)
    case permanentlyDeleteDocument(String)
    case emptyTrash
    case batchTrash(folderIDs: Set<String>, documentIDs: Set<String>)
    case batchPermanentDelete(folderIDs: Set<String>, documentIDs: Set<String>)

    var title: String {
        switch self {
        case .trashFolder, .trashDocument, .batchTrash: "移到回收站？"
        case .permanentlyDeleteFolder, .permanentlyDeleteDocument, .batchPermanentDelete:
            "永久删除？"
        case .emptyTrash: "清空回收站？"
        }
    }
    var message: String {
        switch self {
        case .trashFolder:
            "文件夹及其中的文稿会移到回收站，可以稍后恢复。"
        case .trashDocument, .batchTrash:
            "所选项目会移到回收站，可以稍后恢复。"
        case .permanentlyDeleteFolder, .permanentlyDeleteDocument, .batchPermanentDelete, .emptyTrash:
            "这会同时删除 PDF 和批注，且无法恢复。"
        }
    }
    var confirmationTitle: String {
        switch self {
        case .trashFolder, .trashDocument, .batchTrash: "移到回收站"
        case .permanentlyDeleteFolder, .permanentlyDeleteDocument, .batchPermanentDelete:
            "永久删除"
        case .emptyTrash: "清空"
        }
    }
}

private struct LibraryFolderNode: Identifiable {
    let folder: LibraryFolder
    let children: [LibraryFolderNode]?
    var id: String { folder.id }
}

private enum LibraryPath {
    static func tree(from folders: [LibraryFolder]) -> [LibraryFolderNode] {
        buildNodes(parentID: nil, folders: folders, visited: [])
    }

    private static func buildNodes(
        parentID: String?,
        folders: [LibraryFolder],
        visited: Set<String>
    ) -> [LibraryFolderNode] {
        folders
            .filter { $0.parentID == parentID && !visited.contains($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { folder in
                var nextVisited = visited
                nextVisited.insert(folder.id)
                let children = buildNodes(
                    parentID: folder.id,
                    folders: folders,
                    visited: nextVisited
                )
                return LibraryFolderNode(
                    folder: folder,
                    children: children.isEmpty ? nil : children
                )
            }
    }

    static func ancestors(endingAt folderID: String?, folders: [LibraryFolder]) -> [LibraryFolder] {
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var result: [LibraryFolder] = []
        var cursor = folderID
        var visited = Set<String>()
        while let id = cursor, visited.insert(id).inserted, let folder = byID[id] {
            result.append(folder)
            cursor = folder.parentID
        }
        return result.reversed()
    }

    static func pathIDs(to folderID: String?, folders: [LibraryFolder]) -> [String] {
        ancestors(endingAt: folderID, folders: folders).map(\.id)
    }

    static func pathTitle(for folderID: String, folders: [LibraryFolder]) -> String {
        ancestors(endingAt: folderID, folders: folders).map(\.title).joined(separator: " / ")
    }

    static func descendantIDs(of folderID: String, folders: [LibraryFolder]) -> Set<String> {
        var result = Set<String>()
        var pending = [folderID]
        while let parent = pending.popLast() {
            for folder in folders where folder.parentID == parent {
                if result.insert(folder.id).inserted { pending.append(folder.id) }
            }
        }
        return result
    }

    static func isDescendant(_ candidateID: String, of ancestorID: String, folders: [LibraryFolder]) -> Bool {
        descendantIDs(of: ancestorID, folders: folders).contains(candidateID)
    }
}

private extension LibraryFolderColor {
    var swiftUIColor: Color {
        switch self {
        case .blue: Color(red: 0.20, green: 0.58, blue: 0.96)
        case .purple: Color(red: 0.55, green: 0.37, blue: 0.92)
        case .pink: Color(red: 0.93, green: 0.38, blue: 0.67)
        case .red: Color(red: 0.91, green: 0.32, blue: 0.33)
        case .orange: Color(red: 0.96, green: 0.53, blue: 0.22)
        case .yellow: Color(red: 0.91, green: 0.72, blue: 0.20)
        case .green: Color(red: 0.28, green: 0.70, blue: 0.43)
        case .teal: Color(red: 0.20, green: 0.68, blue: 0.68)
        case .gray: Color(red: 0.46, green: 0.49, blue: 0.55)
        }
    }
}

private extension CanvasBackgroundColor {
    var swiftUIColor: Color {
        switch self {
        case .white: Color(white: 0.985)
        case .ivory: Color(red: 0.965, green: 0.945, blue: 0.88)
        case .yellow: Color(red: 0.99, green: 0.95, blue: 0.68)
        case .blue: Color(red: 0.86, green: 0.94, blue: 0.99)
        case .green: Color(red: 0.87, green: 0.96, blue: 0.88)
        case .dark: Color(red: 0.12, green: 0.14, blue: 0.18)
        }
    }
}

enum DocumentScanPDFRenderer {
    private static let portraitPageSize = CGSize(width: 595, height: 842)

    static func makePDFData(images: [UIImage]) -> Data {
        guard !images.isEmpty else { return Data() }
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: portraitPageSize)
        )
        return renderer.pdfData { context in
            for image in images {
                let pageSize = image.size.width > image.size.height
                    ? CGSize(width: portraitPageSize.height, height: portraitPageSize.width)
                    : portraitPageSize
                context.beginPage(
                    withBounds: CGRect(origin: .zero, size: pageSize),
                    pageInfo: [:]
                )
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: pageSize))
                image.draw(in: aspectFitRect(for: image.size, in: pageSize))
            }
        }
    }

    static func aspectFitRect(for imageSize: CGSize, in pageSize: CGSize) -> CGRect {
        let scale = min(
            pageSize.width / max(imageSize.width, 1),
            pageSize.height / max(imageSize.height, 1)
        )
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (pageSize.width - size.width) / 2,
            y: (pageSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

#if !targetEnvironment(macCatalyst)
private struct DocumentScannerView: UIViewControllerRepresentable {
    let onScan: (Data) -> Void
    let onCancel: () -> Void
    let onFailure: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onCancel: onCancel, onFailure: onFailure)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(
        _ uiViewController: VNDocumentCameraViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScan: (Data) -> Void
        let onCancel: () -> Void
        let onFailure: (Error) -> Void

        init(
            onScan: @escaping (Data) -> Void,
            onCancel: @escaping () -> Void,
            onFailure: @escaping (Error) -> Void
        ) {
            self.onScan = onScan
            self.onCancel = onCancel
            self.onFailure = onFailure
        }

        func documentCameraViewControllerDidCancel(
            _ controller: VNDocumentCameraViewController
        ) {
            onCancel()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
#if targetEnvironment(simulator)
            let scannerError = error as NSError
            if scannerError.domain == AVFoundationErrorDomain,
               scannerError.code == AVError.unknown.rawValue {
                // VisionKit already presents its own camera-unavailable alert in
                // Simulator. Reporting the same AVFoundation failure again after the
                // scanner closes leaves a second, misleading app alert over the
                // library and makes the cancellation path look stuck.
                onCancel()
                return
            }
#endif
            onFailure(error)
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            guard scan.pageCount > 0 else {
                onFailure(
                    NSError(
                        domain: "TiyiNote.DocumentScanner",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "扫描结果没有页面。"]
                    )
                )
                return
            }
            let data = DocumentScanPDFRenderer.makePDFData(
                images: (0..<scan.pageCount).map(scan.imageOfPage(at:))
            )
            onScan(data)
        }
    }
}
#endif
