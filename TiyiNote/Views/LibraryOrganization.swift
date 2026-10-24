import SwiftUI
import UniformTypeIdentifiers
import OSLog

@MainActor
struct LibraryMoveSelection {
    let folderIDs: Set<String>
    let documentIDs: Set<String>

    init(folderIDs: Set<String>, documentIDs: Set<String>, store: DrawingDocumentStore) {
        // Selecting a parent already includes its subtree; do not flatten selected children.
        let descendants = folderIDs.reduce(into: Set<String>()) {
            $0.formUnion(LibraryPath.descendantIDs(of: $1, folders: store.folders))
        }
        self.folderIDs = folderIDs.subtracting(descendants)
        self.documentIDs = documentIDs.filter { id in
            guard let parent = store.document(withID: id)?.parentID else { return true }
            return !folderIDs.union(descendants).contains(parent)
        }
    }

    var count: Int { folderIDs.count + documentIDs.count }

    func allows(_ destination: String?, in store: DrawingDocumentStore) -> Bool {
        guard store.libraryWriteAllowed, count > 0 else { return false }
        if let destination {
            guard store.folders.contains(where: { $0.id == destination && $0.trashedAt == nil }),
                  !folderIDs.contains(destination),
                  !folderIDs.contains(where: {
                      LibraryPath.isDescendant(destination, of: $0, folders: store.folders)
                  }) else { return false }
        }
        return folderIDs.contains { store.folder(withID: $0)?.parentID != destination }
            || documentIDs.contains { store.document(withID: $0)?.parentID != destination }
    }
}

@MainActor
final class LibraryOrganizationController: ObservableObject {
    struct Drag {
        let token: UUID
        let storeID: ObjectIdentifier
        let selection: LibraryMoveSelection
        let context: LibraryMoveCollaborationContext
    }
    struct Undo {
        let folders: [String: LibraryItemPlacement]
        let documents: [String: LibraryItemPlacement]
        let context: LibraryMoveCollaborationContext
    }
    struct Feedback {
        let destination: String?
        let title: String
        let count: Int
    }

    weak var store: DrawingDocumentStore?
    var onExternalDrop: ((Result<StagedDocumentDrop, Error>, String?) -> Void)?
    var onDidMove: (() -> Void)?
    // Drag callbacks must not invalidate the SwiftUI source: doing so recreates its provider.
    var drag: Drag?
    private var pendingDrags: [UUID: Drag] = [:]
    @Published var feedback: Feedback?
    @Published var errorMessage: String?
    private(set) var undoRecord: Undo?

    static let itemType = UTType(exportedAs: "com.tiyi.note.library-item", conformingTo: .data)

    func configure(store: DrawingDocumentStore) {
        let changed = self.store !== store
        self.store = store
        if changed { drag = nil; pendingDrags.removeAll(); feedback = nil; undoRecord = nil }
        objectWillChange.send()
    }

    func beginDrag(folderIDs: Set<String>, documentIDs: Set<String>) -> NSItemProvider {
        guard let store else { return NSItemProvider() }
        let selection = LibraryMoveSelection(folderIDs: folderIDs, documentIDs: documentIDs, store: store)
        let drag = Drag(token: UUID(), storeID: ObjectIdentifier(store), selection: selection,
                        context: store.libraryMoveCollaborationContext(folderIDs: selection.folderIDs, documentIDs: selection.documentIDs))
        self.drag = drag
        if pendingDrags.count >= 32 { pendingDrags.removeAll() }
        pendingDrags[drag.token] = drag
#if DEBUG
        Logger(subsystem: "com.tiyi.note", category: "LibraryOrganization").notice("Begin library drag, items=\(selection.count)")
#endif
        let provider = NSItemProvider()
        let data = Data(drag.token.uuidString.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: Self.itemType.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        provider.suggestedName = selection.count == 1
            ? (selection.folderIDs.first.flatMap { store.folder(withID: $0)?.title }
                ?? selection.documentIDs.first.flatMap { store.document(withID: $0)?.title })
            : "\(selection.count) 个项目"
        return provider
    }

    func consumeDrag(_ data: Data?) -> Drag? {
        guard let data, let string = String(data: data, encoding: .utf8), let token = UUID(uuidString: string) else { return nil }
        return pendingDrags.removeValue(forKey: token)
    }

    func acceptsMove(to destination: String?) -> Bool {
        guard let store, let drag, drag.storeID == ObjectIdentifier(store) else { return false }
        return drag.selection.allows(destination, in: store)
    }

    func move(_ selection: LibraryMoveSelection, to destination: String?, context: LibraryMoveCollaborationContext) throws {
        guard let store else { throw OrganizationError.invalidDestination }
        try store.requireLibraryWriteAccess()
        guard selection.allows(destination, in: store) else { throw OrganizationError.invalidDestination }
        let folders = Dictionary(uniqueKeysWithValues: selection.folderIDs.compactMap { id -> (String, LibraryItemPlacement)? in
            guard let folder = store.folder(withID: id), folder.parentID != destination else { return nil }
            return (id, LibraryItemPlacement(parentID: folder.parentID))
        })
        let documents = Dictionary(uniqueKeysWithValues: selection.documentIDs.compactMap { id -> (String, LibraryItemPlacement)? in
            guard let document = store.document(withID: id), document.parentID != destination else { return nil }
            return (id, LibraryItemPlacement(parentID: document.parentID))
        })
        try store.moveItems(folderIDs: selection.folderIDs, documentIDs: selection.documentIDs, to: destination, causalContext: context)
        undoRecord = Undo(folders: folders, documents: documents,
                          context: store.libraryMoveCollaborationContext(folderIDs: Set(folders.keys), documentIDs: Set(documents.keys)))
        remember(destination, store: store)
        feedback = Feedback(destination: destination, title: LibraryPath.destinationTitle(destination, folders: store.folders), count: folders.count + documents.count)
        onDidMove?()
    }

    func undo() {
        guard let store, let undoRecord else { return }
        do {
            let current = store.libraryMoveCollaborationContext(folderIDs: Set(undoRecord.folders.keys), documentIDs: Set(undoRecord.documents.keys))
            guard current == undoRecord.context else {
                throw OrganizationError.changedSinceMove
            }
            try store.moveItemPlacements(folders: undoRecord.folders, documents: undoRecord.documents, causalContext: current)
            self.undoRecord = nil
            feedback = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private enum OrganizationError: LocalizedError {
        case changedSinceMove, invalidDestination
        var errorDescription: String? {
            switch self {
            case .changedSinceMove: "文件位置已发生变化，无法撤销这次移动。请重新选择目标目录。"
            case .invalidDestination: "无法移动到此目录，请重新选择目标位置。"
            }
        }
    }

    static func recentDestinations(store: DrawingDocumentStore) -> [LibraryItemPlacement] {
        Array((UserDefaults.standard.stringArray(forKey: "library.move.recent." + store.libraryOrganizationKey) ?? [])
            .compactMap { value in
                if value == "__root__" { return LibraryItemPlacement(parentID: nil) }
                guard store.folders.contains(where: { $0.id == value && $0.trashedAt == nil }) else { return nil }
                return LibraryItemPlacement(parentID: value)
            }.prefix(1))
    }

    private func remember(_ destination: String?, store: DrawingDocumentStore) {
        let key = "library.move.recent." + store.libraryOrganizationKey
        let value = destination ?? "__root__"
        UserDefaults.standard.set([value], forKey: key)
    }
}

extension LibraryPath {
    static func destinationTitle(_ id: String?, folders: [LibraryFolder]) -> String {
        id == nil ? "文稿根目录" : pathTitle(for: id!, folders: folders)
    }
}

/// One receiver is used by the page, folder cards, breadcrumbs, and directory tree.
enum LibraryFileDrop {
    static let types: [UTType] = [.fileURL, .pdf, .tiyiNoteDocument, .tiyiWordDoc, .tiyiWordDocx, .image]

    static func receive(_ providers: [NSItemProvider], onResult: @escaping (Result<StagedDocumentDrop, Error>) -> Void) -> Bool {
        let providers = providers.filter { provider in
            types.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
        }
        guard !providers.isEmpty else { return false }
        for provider in providers {
            let type = [UTType.tiyiNoteDocument, .pdf, .tiyiWordDocx, .tiyiWordDoc, .png, .jpeg, .heic, .tiff, .image].first {
                provider.hasItemConformingToTypeIdentifier($0.identifier)
            }
            if let type {
                provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                    let result = Result {
                        guard let url else { throw error ?? CocoaError(.fileReadUnknown) }
                        var name = provider.suggestedName ?? url.lastPathComponent
                        if URL(fileURLWithPath: name).pathExtension.isEmpty, let ext = type.preferredFilenameExtension { name += "." + ext }
                        return try StagedDocumentDrop(copying: url, suggestedName: name)
                    }
                    DispatchQueue.main.async { onResult(result) }
                }
            } else {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    let result = Result {
                        let url = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } ?? item as? URL
                        guard let url else { throw error ?? CocoaError(.fileReadUnknown) }
                        return try StagedDocumentDrop(copying: url)
                    }
                    DispatchQueue.main.async { onResult(result) }
                }
            }
        }
        return true
    }
}

private struct LibraryItemDragModifier: ViewModifier {
    @EnvironmentObject private var organization: LibraryOrganizationController
    let folderIDs: Set<String>
    let documentIDs: Set<String>
    let enabled: Bool
    let title: String

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.onDrag {
                guard organization.store?.libraryWriteAllowed == true else { return NSItemProvider() }
                return organization.beginDrag(folderIDs: folderIDs, documentIDs: documentIDs)
            } preview: {
                Label(organization.drag.map { $0.selection.count > 1 ? "\($0.selection.count) 个项目" : title } ?? title,
                      systemImage: folderIDs.isEmpty ? "doc" : "folder")
                    .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
#if targetEnvironment(macCatalyst)
            .background(LibraryPointerDragConfiguration().allowsHitTesting(false))
#endif
        } else { content }
    }
}

private struct LibraryDropTargetModifier: ViewModifier {
    @EnvironmentObject private var organization: LibraryOrganizationController
    let destination: String?
    let enabled: Bool
    var onHover: (() -> Void)?
    @State private var targeted = false

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content
                .background(targeted ? TiyiNoteTheme.selectionBackground : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if targeted {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(TiyiNoteTheme.selectionBorder, lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if targeted {
                        Text((organization.drag == nil ? "导入到「" : "放入「")
                             + (organization.store.map { LibraryPath.destinationTitle(destination, folders: $0.folders) } ?? "目录") + "」")
                            .font(.caption2).padding(4).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                            .offset(y: 18).allowsHitTesting(false)
                    }
                }
                .onDrop(of: [LibraryOrganizationController.itemType] + LibraryFileDrop.types,
                        delegate: LibraryDirectoryDropDelegate(organization: organization, destination: destination,
                                                               targeted: $targeted))
                .task(id: targeted) {
                    guard targeted else { return }
                    try? await Task.sleep(for: .milliseconds(700))
                    guard !Task.isCancelled, targeted else { return }
                    onHover?()
                }
        } else { content }
    }
}

private struct LibraryDirectoryDropDelegate: DropDelegate {
    let organization: LibraryOrganizationController
    let destination: String?
    @Binding var targeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        guard let store = organization.store, store.libraryWriteAllowed,
              destination == nil || store.folders.contains(where: { $0.id == destination && $0.trashedAt == nil }) else { return false }
        if info.hasItemsConforming(to: [LibraryOrganizationController.itemType]) {
            return organization.acceptsMove(to: destination)
        }
        return PlatformCapabilities.current.canImportPDF && info.hasItemsConforming(to: LibraryFileDrop.types)
    }
    func dropEntered(info: DropInfo) {
        if !info.hasItemsConforming(to: [LibraryOrganizationController.itemType]) { organization.drag = nil }
        targeted = validateDrop(info: info)
    }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        targeted = validateDrop(info: info)
        return DropProposal(operation: targeted ? (info.hasItemsConforming(to: [LibraryOrganizationController.itemType]) ? .move : .copy) : .forbidden)
    }
    func performDrop(info: DropInfo) -> Bool {
#if DEBUG
        Logger(subsystem: "com.tiyi.note", category: "LibraryOrganization").notice("Perform directory drop, valid=\(validateDrop(info: info))")
#endif
        targeted = false
        guard validateDrop(info: info), let store = organization.store else { return false }
        if let provider = info.itemProviders(for: [LibraryOrganizationController.itemType]).first {
            provider.loadDataRepresentation(forTypeIdentifier: LibraryOrganizationController.itemType.identifier) { data, error in
                DispatchQueue.main.async {
                    guard organization.store === store,
                          let drag = organization.consumeDrag(data),
                          drag.storeID == ObjectIdentifier(store) else { return }
                    do { try organization.move(drag.selection, to: destination, context: drag.context) }
                    catch { organization.errorMessage = error.localizedDescription }
                    organization.drag = nil
                }
            }
            return true
        }
        // Capture the destination and import handler before the asynchronous provider callback.
        guard let handler = organization.onExternalDrop else { return false }
        organization.drag = nil
        return LibraryFileDrop.receive(info.itemProviders(for: LibraryFileDrop.types)) { handler($0, destination) }
    }
}

extension View {
    func libraryDraggable(folderIDs: Set<String> = [], documentIDs: Set<String> = [], enabled: Bool, title: String) -> some View {
        modifier(LibraryItemDragModifier(folderIDs: folderIDs, documentIDs: documentIDs, enabled: enabled, title: title))
    }
    func libraryDropTarget(_ destination: String?, enabled: Bool = true, onHover: (() -> Void)? = nil) -> some View {
        modifier(LibraryDropTargetModifier(destination: destination, enabled: enabled, onHover: onHover))
    }
}

struct LibraryFolderTree: View {
    struct Row: Identifiable {
        let folder: LibraryFolder
        let depth: Int
        var id: String { folder.id }
    }
    let folders: [LibraryFolder]
    let selectedID: String?
    @Binding var expanded: Set<String>
    @State private var visibleRows = Set<String>()
    var excluded: Set<String> = []
    var supportsDrop = false
    let onSelect: (String?) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    Button { onSelect(nil) } label: {
                        Label("文稿根目录", systemImage: "books.vertical")
                            .font(.system(size: 14, weight: selectedID == nil ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .contentShape(Rectangle())
                    }
                    .background(selectedID == nil ? TiyiNoteTheme.selectionBackground : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .libraryDropTarget(nil, enabled: supportsDrop)
                    .accessibilityIdentifier("library-tree-root")
                    ForEach(rows) { row in
                        treeRow(row).id(row.id)
                            .onScrollVisibilityChange(threshold: 0.1) { visible in
                                if visible { visibleRows.insert(row.id) } else { visibleRows.remove(row.id) }
                            }
                    }
                }
                .padding(8)
            }
            // Scroll to the adjacent visible row while a drag rests at an edge.
            .overlay(alignment: .top) { if supportsDrop { edgeScroller(rows: rows, proxy: proxy, direction: -1) } }
            .overlay(alignment: .bottom) { if supportsDrop { edgeScroller(rows: rows, proxy: proxy, direction: 1) } }
            .onChange(of: selectedID, initial: true) { _, id in
                expanded.formUnion(LibraryPath.ancestors(endingAt: id, folders: folders).map(\.id))
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(TiyiNoteTheme.textPrimary)
        .accessibilityIdentifier(supportsDrop ? "library-directory-tree" : "move-directory-tree")
    }

    private func treeRow(_ row: Row) -> some View {
        HStack(spacing: 4) {
            Button {
                if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
            } label: {
                Image(systemName: expanded.contains(row.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 36)
                    .opacity(folders.contains { $0.parentID == row.id && $0.trashedAt == nil } ? 1 : 0)
            }
            .accessibilityLabel((expanded.contains(row.id) ? "收起" : "展开") + row.folder.title)
            Button { onSelect(row.id) } label: {
                HStack(spacing: 8) {
                    Image(systemName: row.folder.icon.systemImageName).foregroundStyle(row.folder.color.swiftUIColor)
                    Text(row.folder.title).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 14)).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier((supportsDrop ? "library-tree-folder-" : "move-tree-folder-") + row.id)
        }
        .padding(.leading, CGFloat(row.depth) * 16).padding(.trailing, 8)
        .background(selectedID == row.id ? TiyiNoteTheme.selectionBackground : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .libraryDraggable(folderIDs: [row.id], enabled: supportsDrop, title: row.folder.title)
        .libraryDropTarget(row.id, enabled: supportsDrop) { expanded.insert(row.id) }
    }

    private var rows: [Row] {
        var result: [Row] = []
        func append(_ parent: String?, depth: Int, visited: Set<String>) {
            for folder in folders.filter({ $0.parentID == parent && $0.trashedAt == nil && !excluded.contains($0.id) && !visited.contains($0.id) })
                .sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) {
                result.append(Row(folder: folder, depth: depth))
                if expanded.contains(folder.id) { append(folder.id, depth: depth + 1, visited: visited.union([folder.id])) }
            }
        }
        append(nil, depth: 0, visited: [])
        return result
    }

    @ViewBuilder private func edgeScroller(rows: [Row], proxy: ScrollViewProxy, direction: Int) -> some View {
        LibraryTreeScrollEdge(rowIDs: rows.map(\.id), visibleIDs: visibleRows, direction: direction, scroll: { id, anchor in
            withAnimation(.linear(duration: 0.2)) { proxy.scrollTo(id, anchor: anchor) }
        })
    }
}

/// The nearest visible row is tracked by geometry, so edge scrolling does not jump to tree ends.
private struct LibraryTreeScrollEdge: View {
    let rowIDs: [String]
    let visibleIDs: Set<String>
    let direction: Int
    let scroll: (String, UnitPoint) -> Void
    @State private var targeted = false

    var body: some View {
        Color.clear.frame(height: 14).contentShape(Rectangle())
            .onDrop(of: [LibraryOrganizationController.itemType] + LibraryFileDrop.types, isTargeted: $targeted) { _ in false }
            .task(id: targeted ? rowIDs.filter { visibleIDs.contains($0) } : ["__inactive__"]) {
                guard targeted else { return }
                while !Task.isCancelled, targeted {
                    let visible = rowIDs.indices.filter { visibleIDs.contains(rowIDs[$0]) }
                    let index = direction < 0 ? (visible.first ?? 0) - 1 : (visible.last ?? -1) + 1
                    if rowIDs.indices.contains(index) { scroll(rowIDs[index], direction < 0 ? .top : .bottom) }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
    }
}

struct LibraryMoveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var documentStore: DrawingDocumentStore
    let request: LibraryMoveRequest
    let onMove: (String?) throws -> Void
    @State private var destinationID: String?
    @State private var errorMessage: String?
    @State private var newFolderName = ""
    @State private var showsNewFolder = false

    init(documentStore: DrawingDocumentStore, request: LibraryMoveRequest, onMove: @escaping (String?) throws -> Void) {
        self.documentStore = documentStore
        self.request = request
        self.onMove = onMove
        _destinationID = State(initialValue: request.initialFolderID)
    }

    private var selection: LibraryMoveSelection {
        LibraryMoveSelection(folderIDs: request.folderIDs, documentIDs: request.documentIDs, store: documentStore)
    }
    private var excluded: Set<String> {
        request.folderIDs.reduce(into: request.folderIDs) {
            $0.formUnion(LibraryPath.descendantIDs(of: $1, folders: documentStore.folders))
        }
    }
    private var destinationExists: Bool {
        documentStore.libraryWriteAllowed && (destinationID == nil || documentStore.folders.contains { $0.id == destinationID && $0.trashedAt == nil && !excluded.contains($0.id) })
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LibraryBreadcrumbs(folderID: destinationID, folders: documentStore.folders) {
                    destinationID = $0
                }
                .padding(.horizontal, 16)
                Divider()
                directoryList
                Divider()
                footer
            }
            .background(TiyiNoteTheme.chrome)
            .navigationTitle("移动到")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Text(request.itemTitle)
                            .font(.subheadline).foregroundStyle(TiyiNoteTheme.textSecondary)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 160)
                        Text("移动到").font(.headline).fixedSize()
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showsNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
                        .disabled(!destinationExists).accessibilityLabel("新建目标文件夹")
                }
            }
            .alert("新建文件夹", isPresented: $showsNewFolder) {
                TextField("文件夹名称", text: $newFolderName)
                Button("取消", role: .cancel) { newFolderName = "" }
                Button("创建") {
                    do {
                        let folder = try documentStore.createFolder(named: newFolderName, in: destinationID)
                        destinationID = folder.id
                        newFolderName = ""
                    } catch { errorMessage = error.localizedDescription }
                }
            }
        }
        .presentationDetents([.large])
        .presentationSizing(.form)
        .frame(idealWidth: 440, idealHeight: 480)
#if targetEnvironment(macCatalyst)
        .frame(minWidth: 400, minHeight: 400)
#endif
    }

    private var directoryList: some View {
        List {
            if let placement = LibraryOrganizationController.recentDestinations(store: documentStore).first,
               placement.parentID.map({ !excluded.contains($0) }) ?? true {
                Button { destinationID = placement.parentID } label: {
                    HStack {
                        Image(systemName: "clock").foregroundStyle(TiyiNoteTheme.textSecondary)
                        Text(LibraryPath.destinationTitle(placement.parentID, folders: documentStore.folders))
                            .foregroundStyle(TiyiNoteTheme.textPrimary).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text("最近移动到").font(.caption).foregroundStyle(TiyiNoteTheme.textSecondary)
                            .fixedSize()
                    }
                    .frame(minHeight: 28).contentShape(Rectangle())
                }
                .accessibilityIdentifier("move-recent-destination")
            }
            ForEach(documentStore.childFolders(in: destinationID).filter { !excluded.contains($0.id) }) { folder in
                Button { destinationID = folder.id } label: {
                    HStack {
                        Image(systemName: folder.icon.systemImageName).foregroundStyle(folder.color.swiftUIColor)
                        Text(folder.title).foregroundStyle(TiyiNoteTheme.textPrimary).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(TiyiNoteTheme.textTertiary)
                    }.frame(minHeight: 28).contentShape(Rectangle())
                }
                .accessibilityIdentifier("move-destination-" + folder.id)
            }
            if documentStore.childFolders(in: destinationID).filter({ !excluded.contains($0.id) }).isEmpty {
                Text("没有子文件夹，可移动到当前目录").foregroundStyle(TiyiNoteTheme.textSecondary)
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 44)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(TiyiNoteTheme.danger) }
            if !destinationExists { Text("目标目录已不可用，请重新选择").font(.footnote).foregroundStyle(TiyiNoteTheme.danger) }
            HStack {
                Spacer()
                Button("移动到此处") {
                    do { try onMove(destinationID); dismiss() }
                    catch { errorMessage = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!selection.allows(destinationID, in: documentStore))
                .accessibilityIdentifier("move-confirm")
            }
        }.padding(12)
    }
}

#if targetEnvironment(macCatalyst)
struct LibraryMacDirectoryPane: View {
    @ObservedObject var documentStore: DrawingDocumentStore
    let selectedID: String?
    let availableWidth: CGFloat
    let onSelect: (String?) -> Void
    @AppStorage("library.directoryTree.width") private var savedWidth = 240.0
    @State private var expanded = Set<String>()
    @State private var dragStartWidth: Double?

    private var expansionKey: String { "library.directoryTree.expanded." + documentStore.libraryOrganizationKey }
    private var maximumWidth: CGFloat { max(180, min(360, availableWidth * 0.4)) }
    private var width: CGFloat { min(max(180, savedWidth), maximumWidth) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("文件夹").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TiyiNoteTheme.textSecondary)
                    .padding(.horizontal, 16).frame(height: TiyiWorkspaceLayout.headerHeight)
                Divider()
                LibraryFolderTree(folders: documentStore.folders, selectedID: selectedID,
                                  expanded: $expanded, supportsDrop: true, onSelect: onSelect)
            }.frame(width: width)
            Rectangle().fill(TiyiNoteTheme.hairline).frame(width: 1).frame(width: 8)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    if dragStartWidth == nil { dragStartWidth = savedWidth }
                    savedWidth = min(max(180, (dragStartWidth ?? savedWidth) + value.translation.width), maximumWidth)
                }.onEnded { _ in dragStartWidth = nil })
                .accessibilityLabel("调整目录树宽度")
        }
        .background(TiyiNoteTheme.chrome)
        .onAppear { restoreExpansion() }
        .onChange(of: documentStore.libraryOrganizationKey) { _, _ in restoreExpansion() }
        .onChange(of: expanded) { _, value in UserDefaults.standard.set(value.sorted(), forKey: expansionKey) }
    }

    private func restoreExpansion() {
        expanded = Set(UserDefaults.standard.stringArray(forKey: expansionKey) ?? [])
            .union(LibraryPath.ancestors(endingAt: selectedID, folders: documentStore.folders).map(\.id))
    }
}
#endif

#if targetEnvironment(macCatalyst)
/// UIKit 27 defaults Mac pointer drags to a touch-style lift delay. Library rows should begin
/// dragging once the mouse moves, while UITextInput retains its normal selection behavior.
private struct LibraryPointerDragConfiguration: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        // This view only configures existing drag interactions. It must never become
        // the mouse target instead of a folder button or a document row.
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: Probe, context: Context) { view.schedule() }

    final class Probe: UIView {
        private static var pendingWindows = Set<ObjectIdentifier>()
        override func didMoveToWindow() { super.didMoveToWindow(); schedule() }
        func schedule() {
            guard #available(iOS 27.0, *), let window else { return }
            let id = ObjectIdentifier(window)
            guard Self.pendingWindows.insert(id).inserted else { return }
            DispatchQueue.main.async { [weak window] in
                Self.pendingWindows.remove(id)
                guard let window else { return }
                func configure(_ view: UIView) {
                    guard !(view is UITextField), !(view is UITextView) else { return }
                    for interaction in view.interactions {
                        if let drag = interaction as? UIDragInteraction {
                            // A stationary mouse press must still reach SwiftUI's folder
                            // buttons; a recognized click cancels the pending lift.
                            drag.allowsSimultaneousRecognitionDuringLift = true
                            drag.allowsPointerDragBeforeLiftDelay = true
                        }
                    }
                    for child in view.subviews { configure(child) }
                }
                configure(window)
            }
        }
    }
}
#endif
