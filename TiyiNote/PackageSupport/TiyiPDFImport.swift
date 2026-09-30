import SwiftUI
import PDFKit
import UIKit
import UniformTypeIdentifiers

struct PendingPDFImport: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let pageCount: Int
    var sourceExtension: String? = nil
    var libraryID: String? = nil
    var folderID: String? = nil
    var fileExtension: String { sourceExtension ?? "pdf" }
    var isWord: Bool { fileExtension == "doc" || fileExtension == "docx" }
    var isImage: Bool { UTType(filenameExtension: fileExtension)?.conforms(to: .image) == true }
    var outputExtension: String { isImage ? fileExtension : "pdf" }
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
    // Explicit navigation requests remain available; importing does not send one.
    @Published var documentToOpen: String?
    @Published var documentToOpenLibraryID = DocumentLibrary.personalID
    public typealias WordConverter = @MainActor (URL, UUID, @escaping @MainActor @Sendable (String) -> Void) async throws -> Data
    private var wordConverter: WordConverter?
    public func configureWordConverter(_ converter: @escaping WordConverter) { wordConverter = converter; supportsWordImport = true }
    @Published private(set) var supportsWordImport = false
    private let stagingDirectory: URL
    let libraries: DocumentLibraryManager
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
                          (["pdf", "doc", "docx"].contains(request.fileExtension) || request.isImage),
                          FileManager.default.fileExists(atPath: directory.appendingPathComponent("source." + request.fileExtension).path) else { return nil }
                    return request
                }.sorted { $0.id.uuidString < $1.id.uuidString }
        } catch { errorMessage = "无法准备文稿导入：\(error.localizedDescription)" }
    }

    public func receive(_ url: URL, libraryID: String? = nil, folderID: String? = nil) async {
        do {
            let directory = stagingDirectory
            let request = try await Task.detached(priority: .userInitiated) {
                try Self.stage(url, in: directory, libraryID: libraryID, folderID: folderID)
            }.value
            pending.append(request)
        } catch { errorMessage = error.localizedDescription }
    }

    nonisolated private static func stage(_ url: URL, in root: URL, libraryID: String?, folderID: String?) throws -> PendingPDFImport {
        guard url.isFileURL else { throw importError("请分享 PDF、Word 或图片文件，而不是网页链接。") }
        let incomingExtension = url.pathExtension.lowercased()
        // Existing PDF sharing also accepts provider URLs without a filename extension.
        var fileExtension = ["doc", "docx"].contains(incomingExtension) ? incomingExtension : "pdf"
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let destination = root.appendingPathComponent(id.uuidString)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            var file = destination.appendingPathComponent("source." + fileExtension)
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
                do {
                    if fileExtension != "pdf" {
                        let size = try readableURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size > 0, size <= 100 * 1024 * 1024 else { throw importError("请选择 100 MB 以内的非空 Word 文件。") }
                    }
                    try FileManager.default.copyItem(at: readableURL, to: file)
                }
                catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
            let pageCount: Int
            if ["doc", "docx"].contains(fileExtension) {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 100 * 1024 * 1024 else { throw importError("请选择 100 MB 以内的非空 Word 文件。") }
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let header = try handle.read(upToCount: 8) ?? Data()
                let valid = fileExtension == "doc" ? header == Data([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]) : header.starts(with: [0x50, 0x4b, 0x03, 0x04])
                guard valid else { throw importError("文件不是有效的 Word 文档。") }
                pageCount = 0
            } else if ImageDocumentSource.accepts(url) || (try? ImageDocumentSource.info(at: file)) != nil {
                let info = try ImageDocumentSource.info(at: file)
                fileExtension = UTType(filenameExtension: incomingExtension) == UTType(filenameExtension: info.fileExtension)
                    ? incomingExtension : info.fileExtension
                let imageFile = destination.appendingPathComponent("source." + fileExtension)
                try FileManager.default.moveItem(at: file, to: imageFile)
                file = imageFile
                pageCount = 1
            } else {
                pageCount = try validatedPDFPageCount(file)
            }
            let name = url.deletingPathExtension().lastPathComponent
            let request = PendingPDFImport(id: id, name: name.isEmpty ? "导入文稿" : name, pageCount: pageCount,
                sourceExtension: fileExtension, libraryID: libraryID, folderID: folderID)
            try JSONEncoder().encode(request).write(to: destination.appendingPathComponent("request.json"), options: .atomic)
            return request
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    nonisolated private static func validatedPDFPageCount(_ file: URL) throws -> Int {
        guard let pdf = PDFDocument(url: file) else { throw importError("无法读取这个 PDF，文件可能已损坏或格式不正确。") }
        guard !pdf.isLocked else { throw importError("这个 PDF 需要密码，请先在原软件中解锁并导出后再导入。") }
        guard pdf.pageCount > 0 else { throw importError("这个 PDF 没有可导入的页面。") }
        return pdf.pageCount
    }

    func cancel(_ request: PendingPDFImport) throws {
        try FileManager.default.removeItem(at: stagingDirectory.appendingPathComponent(request.id.uuidString))
        pending.removeAll { $0.id == request.id }
    }

    func suggestedName(_ proposed: String, folderID: String?, libraryID: String? = nil, fileExtension: String = "pdf") throws -> String {
        let store = try libraries.requireImportLibrary(libraryID ?? libraries.selectedID)
        var base = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.lowercased().hasSuffix("." + fileExtension) { base = String(base.dropLast(fileExtension.count + 1)) }
        guard !base.isEmpty, !base.contains("/"), !base.contains(":"), !base.contains("\\"), base != ".", base != ".." else {
            throw Self.importError("请输入有效的文稿名称，不要包含 /、\\ 或 :。")
        }
        base = String(base.prefix(100))
        func key(_ name: String) -> String { name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
        let existing = Set((store.documents(in: folderID).map(\.title)
            + store.folders.filter { $0.parentID == folderID && $0.trashedAt == nil }.map(\.title)).map(key))
        var candidate = base, number = 2
        while existing.contains(key(candidate + "." + fileExtension)) || existing.contains(key(candidate)) {
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

    @discardableResult func importPDF(_ request: PendingPDFImport, name: String, folderID: String?, libraryID: String? = nil, prepare: () throws -> Void, progress: @escaping @MainActor @Sendable (String) -> Void = { _ in }) async throws -> String {
        let targetID = libraryID ?? libraries.selectedID
        let targetStore = try libraries.requireImportLibrary(targetID)
        // Complete all checkpoints before creating a document or dismissing the current answer.
        try checkpoint(prepare: prepare)
        let finalName = try suggestedName(name, folderID: folderID, libraryID: targetID, fileExtension: request.outputExtension)
        let directory = stagingDirectory.appendingPathComponent(request.id.uuidString)
        let pdfFile = directory.appendingPathComponent("source.pdf")
        if request.isWord, (try? Self.validatedPDFPageCount(pdfFile)) == nil {
            guard let wordConverter else { throw Self.importError("Word 转换服务尚未准备好，请登录并联网后重试。") }
            let data = try await wordConverter(directory.appendingPathComponent("source." + request.fileExtension), request.id, progress)
            try Task.checkCancellation()
            try await Task.detached(priority: .userInitiated) {
                let temporary = directory.appendingPathComponent("converted.pdf")
                try data.write(to: temporary, options: .atomic)
                do {
                    _ = try Self.validatedPDFPageCount(temporary)
                    if FileManager.default.fileExists(atPath: pdfFile.path) { try FileManager.default.removeItem(at: pdfFile) }
                    try FileManager.default.moveItem(at: temporary, to: pdfFile)
                } catch { try? FileManager.default.removeItem(at: temporary); throw error }
            }.value
        }
        try checkpoint(prepare: prepare)
        progress("正在保存到文稿…")
        let namedDirectory = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: namedDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: namedDirectory) }
        let renamed = namedDirectory.appendingPathComponent(finalName + "." + request.outputExtension)
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: directory.appendingPathComponent("source." + request.outputExtension), to: renamed)
        }.value
        guard try libraries.requireImportLibrary(targetID) === targetStore else {
            throw Self.importError("文稿库已改变，请重新选择导入位置。")
        }
        let documents = request.isImage
            ? try await targetStore.importImagesInBackground(from: [renamed], into: folderID, openAfterImport: false)
            : try await targetStore.importPDFsInBackground(from: [renamed], into: folderID, openAfterImport: false)
        guard let document = documents.first else {
            throw Self.importError("文稿导入失败，请重试。")
        }
        pending.removeAll { $0.id == request.id }
        try? FileManager.default.removeItem(at: directory)
        libraries.browsingState(for: targetID).selectedFolderID = folderID
        libraries.select(targetID)
        if !libraries.isPresentingDocuments { libraries.pendingEntryLibraryID = targetID }
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
    @State private var progress = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(request.isWord ? "Word · 转换为 PDF 后导入" : (request.isImage ? "图片 · \(request.fileExtension.uppercased())" : "PDF · \(request.pageCount) 页"), systemImage: request.isImage ? "photo" : "doc.richtext")
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
            .disabled(importing)
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
                                let id = try await controller.importPDF(request, name: name, folderID: folderID, libraryID: libraryID, prepare: prepare, progress: { progress = $0 })
                                finish(id)
                            } catch { self.error = error.localizedDescription; importing = false }
                        }
                    }.disabled(importing || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("pdf-import-confirm")
                }
            }
            .overlay { if importing { ProgressView(progress.isEmpty ? "正在导入…" : progress).padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .onAppear {
                name = (try? controller.suggestedName(request.name, folderID: request.folderID, libraryID: libraryID, fileExtension: request.outputExtension)) ?? request.name
                folderID = request.folderID
                error = initialError
            }
            .onChange(of: libraryID) { _, _ in folderID = nil }
            .onChange(of: folderID) { _, _ in
                if let suggested = try? controller.suggestedName(name, folderID: folderID, libraryID: libraryID, fileExtension: request.outputExtension) { name = suggested }
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
                let alert = UIAlertController(title: "文稿导入失败", message: message, preferredStyle: .alert)
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
                libraryID: request.libraryID ?? (latest.controller.libraries.isPresentingDocuments
                    ? latest.controller.libraries.selectedID : latest.controller.libraries.defaultID),
                prepare: latest.prepare, initialError: checkpointError, finish: { [weak self] documentID in
                    guard let self else { return }
                    self.presented?.dismiss(animated: true) {
                        self.presented = nil
                        if documentID != nil {
                            NotificationCenter.default.post(name: .documentImportCompleted, object: latest.controller)
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
