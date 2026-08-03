import Combine
import Foundation

enum AutomaticBackupState: Equatable {
    case disabled
    case ready(lastBackupAt: Date?)
    case backingUp
    case failed(String)
}

/// Writes versioned native snapshots to a user-selected Files/iCloud Drive directory. This is a
/// real backup channel, deliberately independent from CloudKit's convergent current-state replica.
/// A document is written to a same-volume staging file and renamed into place before old versions
/// are pruned, so an interruption can lose at most the new version, never the previous good one.
@MainActor
final class AutomaticBackupCoordinator: ObservableObject {
    @Published private(set) var state: AutomaticBackupState = .disabled
    @Published private(set) var destinationURL: URL?
    @Published private(set) var retentionCount: Int

    private static let bookmarkKey = "automaticBackup.destinationBookmark"
    private static let retentionKey = "automaticBackup.retentionCount"
    private static let lastBackupKey = "automaticBackup.lastBackupAt"
    private static let backupRootName = "Tiyi Note Backups"

    private unowned let documentStore: DrawingDocumentStore
    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private let usesSecurityScopedBookmark: Bool
    private var pendingBackup: Task<Void, Never>?

    init(
        documentStore: DrawingDocumentStore,
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        destinationOverride: URL? = nil
    ) {
        self.documentStore = documentStore
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        retentionCount = min(max(userDefaults.integer(forKey: Self.retentionKey), 3), 30)
        if userDefaults.object(forKey: Self.retentionKey) == nil {
            retentionCount = 10
        }

        if let destinationOverride {
            usesSecurityScopedBookmark = false
            destinationURL = destinationOverride
            state = .ready(lastBackupAt: userDefaults.object(forKey: Self.lastBackupKey) as? Date)
        } else {
            usesSecurityScopedBookmark = true
            restoreDestinationBookmark()
        }
    }

    deinit {
        pendingBackup?.cancel()
    }

    var isEnabled: Bool { destinationURL != nil }

    var destinationDisplayName: String {
        destinationURL?.lastPathComponent ?? "未选择"
    }

    func configure(destination: URL) throws {
        let accessed = destination.startAccessingSecurityScopedResource()
        defer { if accessed { destination.stopAccessingSecurityScopedResource() } }
        try verifyWritableDestination(destination)
        let bookmark = try destination.bookmarkData(
            options: Self.bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        userDefaults.set(bookmark, forKey: Self.bookmarkKey)
        destinationURL = destination
        state = .ready(lastBackupAt: userDefaults.object(forKey: Self.lastBackupKey) as? Date)
        scheduleBackup(delayNanoseconds: 100_000_000)
    }

    func disable() {
        pendingBackup?.cancel()
        pendingBackup = nil
        destinationURL = nil
        userDefaults.removeObject(forKey: Self.bookmarkKey)
        state = .disabled
    }

    func setRetentionCount(_ value: Int) {
        retentionCount = min(max(value, 3), 30)
        userDefaults.set(retentionCount, forKey: Self.retentionKey)
    }

    /// Debounces bursts of strokes/metadata edits. The Store only increments its generation after
    /// durable local writes, so the delayed snapshot never represents an uncommitted canvas frame.
    func scheduleBackup(delayNanoseconds: UInt64 = 2_000_000_000) {
        guard destinationURL != nil else { return }
        pendingBackup?.cancel()
        pendingBackup = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
                guard !Task.isCancelled else { return }
                self?.backupNow()
            } catch {
                // Cancellation is the expected debounce path.
            }
        }
    }

    func backupNow() {
        pendingBackup?.cancel()
        pendingBackup = nil
        do {
            _ = try performBackupNow()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Synchronous by design: DrawingDocumentStore is MainActor-isolated and first flushes any
    /// pending page saves. Tests call this directly to inspect the exact version files produced.
    @discardableResult
    func performBackupNow() throws -> [URL] {
        guard let destinationURL else {
            state = .disabled
            return []
        }

        state = .backingUp
        let accessed = usesSecurityScopedBookmark
            ? destinationURL.startAccessingSecurityScopedResource()
            : false
        defer { if accessed { destinationURL.stopAccessingSecurityScopedResource() } }

        try verifyWritableDestination(destinationURL)
        let backupRoot = destinationURL.appendingPathComponent(
            Self.backupRootName,
            isDirectory: true
        )
        let stagingRoot = backupRoot.appendingPathComponent(".staging", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        var writtenURLs: [URL] = []
        let activeDocuments = documentStore.documents
            .filter { $0.trashedAt == nil }
            .sorted { $0.id < $1.id }
        for document in activeDocuments {
            let data = try documentStore.editableDocumentPackageData(documentID: document.id)
            let documentDirectory = backupRoot.appendingPathComponent(
                document.id,
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: documentDirectory,
                withIntermediateDirectories: true
            )

            let fileName = "\(Self.timestamp())-\(safeFileName(document.title))-\(UUID().uuidString.prefix(8)).tiyinote"
            let stagingURL = stagingRoot.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("tiyinote")
            let finalURL = documentDirectory.appendingPathComponent(fileName)
            do {
                try data.write(to: stagingURL, options: .atomic)
                try fileManager.moveItem(at: stagingURL, to: finalURL)
                writtenURLs.append(finalURL)
                try pruneVersions(in: documentDirectory)
            } catch {
                try? fileManager.removeItem(at: stagingURL)
                throw error
            }
        }

        try? removeEmptyStagingDirectory(stagingRoot)
        let completedAt = Date()
        userDefaults.set(completedAt, forKey: Self.lastBackupKey)
        state = .ready(lastBackupAt: completedAt)
        return writtenURLs
    }

    private func restoreDestinationBookmark() {
        guard let bookmark = userDefaults.data(forKey: Self.bookmarkKey) else {
            state = .disabled
            return
        }
        do {
            var isStale = false
            let resolved = try URL(
                resolvingBookmarkData: bookmark,
                options: Self.bookmarkResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            destinationURL = resolved
            if isStale {
                let accessed = resolved.startAccessingSecurityScopedResource()
                defer { if accessed { resolved.stopAccessingSecurityScopedResource() } }
                let refreshed = try resolved.bookmarkData(
                    options: Self.bookmarkCreationOptions,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                userDefaults.set(refreshed, forKey: Self.bookmarkKey)
            }
            state = .ready(lastBackupAt: userDefaults.object(forKey: Self.lastBackupKey) as? Date)
        } catch {
            destinationURL = nil
            state = .failed("备份目录授权已失效，请重新选择目录。")
        }
    }

    private func verifyWritableDestination(_ destination: URL) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let backupRoot = destination.appendingPathComponent(Self.backupRootName, isDirectory: true)
        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let probe = backupRoot.appendingPathComponent(".write-test-\(UUID().uuidString)")
        do {
            try Data().write(to: probe, options: .atomic)
            try fileManager.removeItem(at: probe)
        } catch {
            try? fileManager.removeItem(at: probe)
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private func pruneVersions(in directory: URL) throws {
        let versions = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.caseInsensitiveCompare("tiyinote") == .orderedSame }
        .sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            if left != right { return left > right }
            return lhs.lastPathComponent > rhs.lastPathComponent
        }
        for expired in versions.dropFirst(retentionCount) {
            try fileManager.removeItem(at: expired)
        }
    }

    private func removeEmptyStagingDirectory(_ url: URL) throws {
        let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        if contents.isEmpty { try fileManager.removeItem(at: url) }
    }

    private func safeFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r")
        let sanitized = value.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((sanitized.isEmpty ? "未命名" : sanitized).prefix(80))
    }

    private static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }

    private static var bookmarkCreationOptions: URL.BookmarkCreationOptions {
#if targetEnvironment(macCatalyst)
        [.withSecurityScope]
#else
        []
#endif
    }

    private static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
#if targetEnvironment(macCatalyst)
        [.withSecurityScope, .withoutUI]
#else
        [.withoutUI]
#endif
    }
}
