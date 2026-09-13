import SwiftUI
import PDFKit
import UIKit

struct PendingPDFImport: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let pageCount: Int
}

@MainActor final class DocumentImportCheckpoint {
    var error: Error?
}

extension Notification.Name {
    static let documentImportCheckpoint = Notification.Name("tiyi.document-import.checkpoint")
    static let documentImportCompleted = Notification.Name("tiyi.document-import.completed")
}

/// Owns durable incoming files across login and shares the live document store with the library.
@MainActor public final class TiyiPDFImportController: ObservableObject {
    @Published var pending: [PendingPDFImport] = []
    @Published var errorMessage: String?
    @Published var documentToOpen: String?
    private let stagingDirectory: URL
    let libraries: DocumentLibraryManager
    @Published var documentToOpenLibraryID = DocumentLibrary.personalID
    var store: DrawingDocumentStore { libraries.currentStore }

    public func maintainLibraries() async { await libraries.maintain() }

    public convenience init() {
        self.init(stagingDirectory: URL.applicationSupportDirectory.appendingPathComponent("TiyiIncomingPDFs", isDirectory: true))
    }

    init(stagingDirectory: URL, store: DrawingDocumentStore? = nil, libraries: DocumentLibraryManager? = nil) {
        self.stagingDirectory = stagingDirectory
        self.libraries = libraries ?? DocumentLibraryManager(
            directory: store == nil ? nil : stagingDirectory.deletingLastPathComponent()
                .appendingPathComponent(stagingDirectory.lastPathComponent + "-libraries"),
            defaults: store == nil ? .standard : UserDefaults(suiteName: UUID().uuidString)!, personalStore: store)
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            pending = try FileManager.default.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil)
                .compactMap { directory in
                    guard let data = try? Data(contentsOf: directory.appendingPathComponent("request.json")),
                          let request = try? JSONDecoder().decode(PendingPDFImport.self, from: data),
                          directory.lastPathComponent == request.id.uuidString,
                          FileManager.default.fileExists(atPath: directory.appendingPathComponent("source.pdf").path) else { return nil }
                    return request
                }.sorted { $0.id.uuidString < $1.id.uuidString }
        } catch { errorMessage = "无法准备 PDF 导入：\(error.localizedDescription)" }
    }

    public func receive(_ url: URL) async {
        do {
            let directory = stagingDirectory
            let request = try await Task.detached(priority: .userInitiated) {
                try Self.stage(url, in: directory)
            }.value
            pending.append(request)
        } catch { errorMessage = error.localizedDescription }
    }

    nonisolated private static func stage(_ url: URL, in root: URL) throws -> PendingPDFImport {
        guard url.isFileURL else { throw importError("请分享 PDF 文件，而不是网页链接。") }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let destination = root.appendingPathComponent(id.uuidString)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let file = destination.appendingPathComponent("source.pdf")
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
                do { try FileManager.default.copyItem(at: readableURL, to: file) }
                catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
            guard let pdf = PDFDocument(url: file) else { throw importError("无法读取这个 PDF，文件可能已损坏或格式不正确。") }
            guard !pdf.isLocked else { throw importError("这个 PDF 需要密码，请先在原软件中解锁并导出后再导入。") }
            guard pdf.pageCount > 0 else { throw importError("这个 PDF 没有可导入的页面。") }
            let name = url.deletingPathExtension().lastPathComponent
            let request = PendingPDFImport(id: id, name: name.isEmpty ? "导入文稿" : name, pageCount: pdf.pageCount)
            try JSONEncoder().encode(request).write(to: destination.appendingPathComponent("request.json"), options: .atomic)
            return request
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func cancel(_ request: PendingPDFImport) throws {
        try FileManager.default.removeItem(at: stagingDirectory.appendingPathComponent(request.id.uuidString))
        pending.removeAll { $0.id == request.id }
    }

    func suggestedName(_ proposed: String, folderID: String?, libraryID: String? = nil) throws -> String {
        let store = try libraries.requireImportLibrary(libraryID ?? libraries.selectedID)
        var base = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.lowercased().hasSuffix(".pdf") { base = String(base.dropLast(4)) }
        guard !base.isEmpty, !base.contains("/"), !base.contains(":"), !base.contains("\\"), base != ".", base != ".." else {
            throw Self.importError("请输入有效的文稿名称，不要包含 /、\\ 或 :。")
        }
        base = String(base.prefix(100))
        func key(_ name: String) -> String { name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
        let existing = Set((store.documents(in: folderID).map(\.title)
            + store.folders.filter { $0.parentID == folderID && $0.trashedAt == nil }.map(\.title)).map(key))
        var candidate = base, number = 2
        while existing.contains(key(candidate + ".pdf")) || existing.contains(key(candidate)) {
            candidate = "\(base) (\(number))"; number += 1
        }
        return candidate
    }

    func checkpoint(prepare: () throws -> Void) throws {
        try prepare()
        let checkpoint = DocumentImportCheckpoint()
        NotificationCenter.default.post(name: .documentImportCheckpoint, object: checkpoint)
        if let error = checkpoint.error { throw error }
    }

    @discardableResult func importPDF(_ request: PendingPDFImport, name: String, folderID: String?, libraryID: String? = nil, prepare: () throws -> Void) async throws -> String {
        let targetID = libraryID ?? libraries.selectedID
        let targetStore = try libraries.requireImportLibrary(targetID)
        // Complete all checkpoints before creating a document or dismissing the current answer.
        try checkpoint(prepare: prepare)
        let finalName = try suggestedName(name, folderID: folderID, libraryID: targetID)
        let directory = stagingDirectory.appendingPathComponent(request.id.uuidString)
        let namedDirectory = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: namedDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: namedDirectory) }
        let renamed = namedDirectory.appendingPathComponent(finalName + ".pdf")
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: directory.appendingPathComponent("source.pdf"), to: renamed)
        }.value
        guard try libraries.requireImportLibrary(targetID) === targetStore else {
            throw Self.importError("文稿库已改变，请重新选择导入位置。")
        }
        guard let document = try await targetStore.importPDFsInBackground(from: [renamed], into: folderID).first else {
            throw Self.importError("PDF 导入失败，请重试。")
        }
        pending.removeAll { $0.id == request.id }
        try? FileManager.default.removeItem(at: directory)
        libraries.select(targetID)
        if !libraries.isPresentingDocuments { libraries.pendingEntryLibraryID = targetID }
        documentToOpenLibraryID = targetID
        return document.id
    }

    nonisolated private static func importError(_ message: String) -> NSError {
        NSError(domain: "TiyiPDFImport", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private struct PDFImportConfirmation: View {
    let request: PendingPDFImport
    @ObservedObject var controller: TiyiPDFImportController
    @ObservedObject var libraries: DocumentLibraryManager
    @State var libraryID: String
    private var store: DrawingDocumentStore { libraries.store(for: libraries.library(libraryID) ?? .personal) }
    let prepare: () throws -> Void
    let initialError: String?
    let finish: (String?) -> Void
    @State private var name = ""
    @State private var folderID: String?
    @State private var error: String?
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("PDF · \(request.pageCount) 页", systemImage: "doc.richtext")
                        .foregroundStyle(.secondary)
                    TextField("文稿名称", text: $name).accessibilityIdentifier("pdf-import-name")
                }
                Section("导入位置") {
                    Picker("文稿库", selection: $libraryID) {
                        ForEach(libraries.libraries) { library in
                            Text(library.title).tag(library.id)
                        }
                    }.accessibilityIdentifier("pdf-import-library")
                    Picker("文件夹", selection: $folderID) {
                        Text("文稿根目录").tag(String?.none)
                        ForEach(store.folders.filter { $0.trashedAt == nil }.sorted { folderPath($0) < folderPath($1) }) { folder in
                            Text(folderPath(folder)).tag(Optional(folder.id))
                        }
                    }.accessibilityIdentifier("pdf-import-folder")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("导入文稿")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        do { try controller.cancel(request); finish(nil) }
                        catch { self.error = error.localizedDescription }
                    }.disabled(importing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        importing = true
                        Task { @MainActor in
                            await Task.yield()
                            do {
                                let id = try await controller.importPDF(request, name: name, folderID: folderID, libraryID: libraryID, prepare: prepare)
                                finish(id)
                            } catch { self.error = error.localizedDescription; importing = false }
                        }
                    }.disabled(importing || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("pdf-import-confirm")
                }
            }
            .overlay { if importing { ProgressView().padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .onAppear {
                name = (try? controller.suggestedName(request.name, folderID: nil, libraryID: libraryID)) ?? request.name
                error = initialError
            }
            .onChange(of: libraryID) { _, _ in folderID = nil }
            .onChange(of: folderID) { _, _ in
                if let suggested = try? controller.suggestedName(name, folderID: folderID, libraryID: libraryID) { name = suggested }
            }
        }.interactiveDismissDisabled()
    }

    private func folderPath(_ folder: LibraryFolder) -> String {
        var names = [folder.title], parent = folder.parentID, visited: Set<String> = [folder.id]
        while let id = parent, visited.insert(id).inserted, let ancestor = store.folder(withID: id) {
            names.insert(ancestor.title, at: 0); parent = ancestor.parentID
        }
        return names.joined(separator: " / ")
    }
}

/// Presents above an existing answer sheet without navigating away or discarding its draft.
public struct TiyiPDFImportPresenter: UIViewControllerRepresentable {
    @ObservedObject private var controller: TiyiPDFImportController
    private let enabled: Bool
    private let prepare: () throws -> Void
    private let onImported: () -> Void
    public init(controller: TiyiPDFImportController, enabled: Bool, prepare: @escaping () throws -> Void, onImported: @escaping () -> Void) {
        self.controller = controller; self.enabled = enabled; self.prepare = prepare; self.onImported = onImported
    }
    public func makeUIViewController(context: Context) -> UIViewController { UIViewController() }
    public func makeCoordinator() -> Coordinator { Coordinator() }
    public func updateUIViewController(_ anchor: UIViewController, context: Context) {
        context.coordinator.latest = self
        context.coordinator.anchor = anchor
        context.coordinator.schedule()
    }
    public static func dismantleUIViewController(_ anchor: UIViewController, coordinator: Coordinator) {
        coordinator.shutdown()
    }
    @MainActor public final class Coordinator {
        var latest: TiyiPDFImportPresenter?
        weak var anchor: UIViewController?
        private var presented: UIViewController?
        private var scheduled = false
        func shutdown() {
            latest = nil
            anchor = nil
            presented?.dismiss(animated: false)
            presented = nil
        }
        func schedule() {
            guard !scheduled else { return }; scheduled = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self else { return }; self.scheduled = false; self.presentIfNeeded()
            }
        }
        private func presentIfNeeded() {
            guard let latest, latest.enabled, presented == nil,
                  latest.controller.pending.first != nil || latest.controller.errorMessage != nil else { return }
            guard var top = anchor?.view.window?.rootViewController else { schedule(); return }
            while let next = top.presentedViewController { top = next }
            guard !top.isBeingPresented, !top.isBeingDismissed else { schedule(); return }
            if let message = latest.controller.errorMessage {
                let alert = UIAlertController(title: "PDF 导入失败", message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in
                    latest.controller.errorMessage = nil; self?.presented = nil; self?.schedule()
                })
                presented = alert; top.present(alert, animated: true)
                return
            }
            guard let request = latest.controller.pending.first else { return }
            // Flush while the source editor is still visible and its live-canvas callbacks exist.
            // A failure remains retryable from the confirmation; importing rechecks it below.
            let checkpointError: String?
            do { try latest.controller.checkpoint(prepare: latest.prepare); checkpointError = nil }
            catch { checkpointError = error.localizedDescription }
            let host = UIHostingController(rootView: PDFImportConfirmation(request: request, controller: latest.controller,
                libraries: latest.controller.libraries,
                libraryID: latest.controller.libraries.isPresentingDocuments
                    ? latest.controller.libraries.selectedID : latest.controller.libraries.defaultID,
                prepare: latest.prepare, initialError: checkpointError, finish: { [weak self] documentID in
                    guard let self else { return }
                    self.presented?.dismiss(animated: true) {
                        self.presented = nil
                        if let documentID {
                            NotificationCenter.default.post(name: .documentImportCompleted, object: latest.controller)
                            latest.controller.documentToOpen = documentID
                            latest.onImported()
                        }
                        self.schedule()
                    }
                }))
            host.modalPresentationStyle = .formSheet
            host.isModalInPresentation = true
            host.preferredContentSize = CGSize(width: 480, height: 430)
            presented = host; top.present(host, animated: true)
        }
    }
}
