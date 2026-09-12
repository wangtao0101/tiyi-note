import SwiftUI
import UIKit
import PDFKit

public struct TiyiPracticeSection: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var pageIDs: [String]
    public var deletedPageIDs: [String]
    public init(id: String, label: String, pageIDs: [String] = [], deletedPageIDs: [String] = []) {
        self.id = id; self.label = label; self.pageIDs = pageIDs; self.deletedPageIDs = deletedPageIDs
    }

    private enum CodingKeys: String, CodingKey { case id, label, pageIDs, deletedPageIDs }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        label = try values.decode(String.self, forKey: .label)
        pageIDs = try values.decode([String].self, forKey: .pageIDs)
        deletedPageIDs = try values.decodeIfPresent([String].self, forKey: .deletedPageIDs) ?? []
    }
}

public struct TiyiPracticePageSeed {
    public var questionID: String
    public var image: UIImage
    public init(questionID: String, image: UIImage) { self.questionID = questionID; self.image = image }
}

extension Notification.Name { static let tiyiPracticeCheckpoint = Notification.Name("tiyi.practice.checkpoint") }

/// Reusable answer editor with an unbounded canvas per page. The caller owns persistence:
/// either the account practice service or the originating iCloud document attachment.
@MainActor public final class TiyiPracticeWorkspace: ObservableObject {
    let store: DrawingDocumentStore
    let defaults: UserDefaults
    public let documentID: String
    public let title: String
    @Published public private(set) var sections: [TiyiPracticeSection]
    @Published public private(set) var currentPageID: String?
    @Published var requestedPageID: String?
    @Published var showsPages = false
    @Published public var statusText = "已保存到本机"
    @Published public var errorMessage: String?
    public var onCheckpoint: ((Data, [TiyiPracticeSection], String?) throws -> Void)?
    public var assistantContext: (() -> TiyiAssistantContext)?
    public var onAnswer: ((String) -> Void)?
    @Published public var isCompleted = false
    public var onToggleCompleted: (() throws -> Void)?
    var packageExportDate: Date?
    private let layoutURL: URL

    public init(directory: URL, title: String, sections: [TiyiPracticeSection], packageData: Data? = nil,
                seeds: [TiyiPracticePageSeed] = [], lastPageID: String? = nil) throws {
        self.title = title
        defaults = UserDefaults(suiteName: "tiyi.practice.\(directory.lastPathComponent)")!
        store = DrawingDocumentStore(userDefaults: defaults, workspaceDirectoryOverride: directory, includesBundledSamples: false)
        layoutURL = directory.appendingPathComponent("practice-pages.json")
        var mapped = sections
        if let existing = store.documents.first {
            documentID = existing.id
            if let data = try? Data(contentsOf: layoutURL), let saved = try? JSONDecoder().decode([TiyiPracticeSection].self, from: data), saved.map(\.id) == sections.map(\.id) { mapped = saved }
        } else if let packageData {
            let temporary = directory.appendingPathComponent("restore.tiyinote")
            try packageData.write(to: temporary, options: .atomic)
            defer { try? FileManager.default.removeItem(at: temporary) }
            documentID = try store.importEditableDocumentPackage(from: temporary).id
        } else {
            guard !seeds.isEmpty, !sections.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            // PDF is only the immutable question background; writing and page objects use the
            // same unbounded world coordinates as Note's canvas.
            let bounds = CGRect(x: 0, y: 0, width: 768, height: 1086)
            let temporary = directory.appendingPathComponent("\(UUID().uuidString).pdf")
            try UIGraphicsPDFRenderer(bounds: bounds).writePDF(to: temporary) { context in
                for seed in seeds {
                    context.beginPage()
                    UIColor.white.setFill(); context.fill(bounds)
                    let scale = min(696 / max(seed.image.size.width, 1), 1014 / max(seed.image.size.height, 1))
                    seed.image.draw(in: CGRect(x: 36, y: 36, width: seed.image.size.width * scale, height: seed.image.size.height * scale))
                }
            }
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let document = try store.importPDFs(from: [temporary], into: nil).first else { throw CocoaError(.fileReadCorruptFile) }
            documentID = document.id
            let pages = store.pages(in: document.id)
            for index in mapped.indices { mapped[index].pageIDs = zip(seeds, pages).filter { $0.0.questionID == mapped[index].id }.map { $0.1.id } }
        }
        // Also migrate existing local workspaces and packages restored from older app versions.
        try store.enableUnboundedCanvas(for: documentID)
        self.sections = mapped
        store.allowsPracticeFingerDrawing = UIDevice.current.userInterfaceIdiom == .phone
        currentPageID = lastPageID ?? mapped.first?.pageIDs.first
        defaults.set(documentID, forKey: "pdfWorkspace.activeDocumentID")
        store.openDocument(documentID)
        if !seeds.isEmpty { try store.renameDocument(documentID, to: String(title.prefix(100)).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")) }
        if let currentPageID, let index = store.pageIndex(for: currentPageID, in: documentID) { store.setLastViewedPage(index, for: documentID) }
        try reconcilePages()
    }

    public var currentSection: TiyiPracticeSection? { sections.first { $0.pageIDs.contains(currentPageID ?? "") } ?? sections.first { !$0.pageIDs.isEmpty } }
    public var isWriting: Bool { store.hadRecentDrawingInteraction(within: 1.5) }
    public var pageCount: Int { sections.reduce(0) { $0 + $1.pageIDs.count } }

    public func checkpoint() throws {
        NotificationCenter.default.post(name: .tiyiPracticeCheckpoint, object: store)
        guard store.flushAllPendingSaves() else { throw CocoaError(.fileWriteUnknown) }
        try reconcilePages()
        let data = try store.editableDocumentPackageData(documentID: documentID, exportedAt: packageExportDate ?? Date())
        try onCheckpoint?(data, sections, currentPageID)
    }

    public func appendPage() throws {
        guard let section = currentSection else { return }
        try performPageMutation {
            let page = try store.insertTemplatePage(after: section.pageIDs.last, in: documentID, size: CGSize(width: 768, height: 1086))
            selectPage(page.id)
        }
    }

    /// The shared Note sidebar mutates the same store. Flush live editors before copying or
    /// archiving a page, then persist the page-to-question index together with its editable assets.
    func performPageMutation<Result>(_ mutation: () throws -> Result) throws -> Result {
        try checkpoint()
        let result = try mutation()
        try checkpoint()
        return result
    }

    public func selectPage(_ id: String) {
        guard let index = store.pageIndex(for: id, in: documentID) else { return }
        requestedPageID = id; currentPageID = id
        store.setLastViewedPage(index, for: documentID)
    }
    func didView(_ index: Int) {
        guard let id = store.pageID(at: index, in: documentID), id != currentPageID else { return }
        currentPageID = id
    }
    func step(_ delta: Int) {
        let available = sections.filter { !$0.pageIDs.isEmpty }
        guard let section = currentSection, let index = available.firstIndex(where: { $0.id == section.id }), available.indices.contains(index + delta), let id = available[index + delta].pageIDs.first else { return }
        selectPage(id)
    }
    private func persistSections() throws { try JSONEncoder().encode(sections).write(to: layoutURL, options: .atomic) }
    private func reconcilePages() throws {
        // Known pages keep their owner when reordered, deleted or restored. Recover an inserted
        // page from its active predecessor if Note's transaction preceded the host index write.
        let pages = store.pages(in: documentID).map(\.id)
        let deleted = store.deletedPages(in: documentID)
        let owners = Dictionary(sections.enumerated().flatMap { index, section in
            (section.pageIDs + section.deletedPageIDs).map { ($0, index) }
        }, uniquingKeysWith: { first, _ in first })
        var owner = 0
        var restored = sections.map { TiyiPracticeSection(id: $0.id, label: $0.label) }
        guard !restored.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        for id in pages {
            if let known = owners[id] { owner = known }
            restored[owner].pageIDs.append(id)
        }
        for page in deleted {
            guard let owner = owners[page.id] else { throw CocoaError(.fileReadCorruptFile) }
            restored[owner].deletedPageIDs.append(page.id)
        }
        if restored != sections { sections = restored }
        if !pages.contains(currentPageID ?? "") { currentPageID = pages.first }
        try persistSections()
    }

    public static func savePDFToSharedDocuments(_ data: Data, title: String) throws {
        guard PDFDocument(data: data) != nil else { throw CocoaError(.fileReadCorruptFile) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("\(safe.prefix(80))-\(UUID().uuidString.prefix(6)).pdf")
        try data.write(to: url)
        _ = try DrawingDocumentStore().importPDFs(from: [url], into: nil)
    }
}

public struct TiyiPracticeEditor: View {
    @ObservedObject private var workspace: TiyiPracticeWorkspace
    private let onExit: () -> Void
    private let navigation: TiyiWorkspaceNavigation?
    public init(workspace: TiyiPracticeWorkspace, onExit: @escaping () -> Void, navigation: TiyiWorkspaceNavigation? = nil) { self.workspace = workspace; self.onExit = onExit; self.navigation = navigation }
    public var body: some View {
        CanvasScreen(documentStore: workspace.store, onShowLibrary: {
            do { try workspace.checkpoint(); onExit() } catch { workspace.errorMessage = "保存失败：\(error.localizedDescription)" }
        }, practice: workspace, navigation: navigation)
        .defaultAppStorage(workspace.defaults)
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(12)) } catch { return }
                guard !workspace.isWriting else { continue }
                do { try workspace.checkpoint() } catch { workspace.errorMessage = "本机保存失败：\(error.localizedDescription)" }
            }
        }
        .alert("作答保存", isPresented: Binding(get: { workspace.errorMessage != nil }, set: { if !$0 { workspace.errorMessage = nil } })) {
            Button("好", role: .cancel) { workspace.errorMessage = nil }
        } message: { Text(workspace.errorMessage ?? "") }
    }
}

struct PracticeEditorHeader: View {
    @ObservedObject var workspace: TiyiPracticeWorkspace
    var onExit: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button(action: onExit) { Image(systemName: "chevron.left").frame(width: 36, height: 44) }.accessibilityLabel("保存并返回").accessibilityIdentifier("practice-exit")
            if workspace.sections.count == 1 {
                Text(workspace.currentSection?.label ?? "作答").font(.system(size: 15, weight: .semibold))
            } else {
            Menu {
                ForEach(workspace.sections) { section in
                    Button(section.label) { if let id = section.pageIDs.first { workspace.selectPage(id) } }
                        .disabled(section.pageIDs.isEmpty)
                }
            } label: { HStack(spacing: 4) { Text(workspace.currentSection?.label ?? "作答").font(.system(size: 15, weight: .semibold)); Image(systemName: "chevron.down").font(.caption2) } }.accessibilityIdentifier("practice-question-menu")
            }
            Spacer(minLength: 0)
            if workspace.sections.count > 1 {
            Button { workspace.step(-1) } label: { Image(systemName: "chevron.up").frame(width: 28, height: 44) }.accessibilityLabel("上一题")
            Button { workspace.step(1) } label: { Image(systemName: "chevron.down").frame(width: 28, height: 44) }.accessibilityLabel("下一题")
            }
            TiyiPracticeActions(workspace: workspace)
        }.padding(.horizontal, 6).frame(height: 44).background(TiyiNoteTheme.chrome)
    }
}

/// The same answer/add-page/completion actions in standalone and tabbed editors.
public struct TiyiPracticeActions: View {
    @ObservedObject private var workspace: TiyiPracticeWorkspace
    public init(workspace: TiyiPracticeWorkspace) { self.workspace = workspace }
    public var body: some View {
            Menu {
                Button("插入作答页", systemImage: "doc.badge.plus") { do { try workspace.appendPage() } catch { workspace.errorMessage = error.localizedDescription } }.accessibilityIdentifier("practice-add-page")
                if workspace.onAnswer != nil {
                    Button("答案与解析", systemImage: "text.book.closed") { if let id = workspace.currentSection?.id { workspace.onAnswer?(id) } }
                }
                Button(workspace.isCompleted ? "标记为未完成" : "标记完成", systemImage: "checkmark.circle") { do { try workspace.onToggleCompleted?() } catch { workspace.errorMessage = error.localizedDescription } }
            } label: { Image(systemName: "ellipsis").frame(width: 36, height: 44) }.accessibilityLabel("作答操作")
    }
}
