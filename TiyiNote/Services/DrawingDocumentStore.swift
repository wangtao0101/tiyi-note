import CryptoKit
import Foundation
import PDFKit
import PencilKit
import Security
import UIKit

extension Notification.Name {
    static let tiyiDrawingInteractionActivityChanged = Notification.Name(
        "TiyiNote.DrawingInteractionActivityChanged"
    )
}

enum LocalSaveState {
    case saved(Date?)
    case saving
    case failed(String)
}

struct CanvasImageAnnotation: Identifiable {
    let id: UUID
    let image: UIImage
    var logicalBounds: CGRect
    var rotationRadians: CGFloat

    init(
        id: UUID,
        image: UIImage,
        logicalBounds: CGRect,
        rotationRadians: CGFloat
    ) {
        self.id = id
        self.image = image
        self.logicalBounds = logicalBounds
        self.rotationRadians = rotationRadians
    }

    init?(pageElement: CanvasPageElement) {
        guard case .image(let payload) = pageElement.payload,
              let image = UIImage(data: payload.pngData) else { return nil }
        id = pageElement.id
        self.image = image
        logicalBounds = pageElement.logicalBounds
        rotationRadians = CGFloat(pageElement.rotationRadians)
    }

    var pageElement: CanvasPageElement? {
        guard let pngData = image.pngData() else { return nil }
        return CanvasPageElement(
            id: id,
            logicalBounds: logicalBounds,
            rotationRadians: Double(rotationRadians),
            payload: .image(PageImagePayload(pngData: pngData))
        )
    }
}

private struct StoredCanvasImageAnnotation: Codable {
    let id: UUID
    let pngData: Data
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let rotationRadians: Double

    init?(_ annotation: CanvasImageAnnotation) {
        guard let pngData = annotation.image.pngData() else { return nil }
        id = annotation.id
        self.pngData = pngData
        x = Double(annotation.logicalBounds.minX)
        y = Double(annotation.logicalBounds.minY)
        width = Double(annotation.logicalBounds.width)
        height = Double(annotation.logicalBounds.height)
        rotationRadians = Double(annotation.rotationRadians)
    }

    var annotation: CanvasImageAnnotation? {
        guard let image = UIImage(data: pngData) else { return nil }
        return CanvasImageAnnotation(
            id: id,
            image: image,
            logicalBounds: CGRect(
                x: CGFloat(x),
                y: CGFloat(y),
                width: CGFloat(width),
                height: CGFloat(height)
            ),
            rotationRadians: CGFloat(rotationRadians)
        )
    }
}

private struct LegacyImportedPDFRecord: Codable {
    let id: String
    let title: String
    let fileName: String
}

private struct LibraryRegistry: Codable {
    let schemaVersion: Int
    var folders: [LibraryFolder]
    var documents: [LibraryDocumentMetadata]
    var pages: [LibraryPage]

    init(
        schemaVersion: Int,
        folders: [LibraryFolder],
        documents: [LibraryDocumentMetadata],
        pages: [LibraryPage]
    ) {
        self.schemaVersion = schemaVersion
        self.folders = folders
        self.documents = documents
        self.pages = pages
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, folders, documents, pages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        folders = try container.decode([LibraryFolder].self, forKey: .folders)
        documents = try container.decode([LibraryDocumentMetadata].self, forKey: .documents)
        pages = try container.decodeIfPresent([LibraryPage].self, forKey: .pages) ?? []
    }
}

private struct PendingAssetSave {
    let token: UUID
    var data: Data
    let targetURL: URL
    let reference: LibraryAssetReference
}

struct PreparedDrawingStrokePersistence: Sendable {
    let data: Data
    let exactFingerprint: String
    let stableFingerprint: String
}

/// Immutable PencilKit serialization prepared away from MainActor after handwriting has been idle.
/// The append-only path intentionally encodes only new strokes; erase/lasso edits prepare complete
/// identities because those operations need a real diff.
struct PreparedDrawingPersistence: Sendable {
    /// A full-page snapshot is intentionally absent for ordinary appended ink. The immutable
    /// collaboration journal is enough to recover those strokes, while the compact snapshot is
    /// refreshed when the page closes or the scene leaves the foreground. This keeps PencilKit's
    /// non-cancellable whole-page encoder out of a live writing session.
    let drawingData: Data?
    let appendedStrokeData: [Data]?
    let drawingStrokes: [PreparedDrawingStrokePersistence]?
    let baseStrokes: [PreparedDrawingStrokePersistence]?
}

private enum PreparedDrawingCollaborationMutation: Sendable {
    case upsert(id: String, data: Data, zIndex: Int)
    case delete(strokeID: String)
}

private enum PreparedDrawingCollaborationPath: Sendable {
    case appendOnly
    case fullDiff
}

/// CPU-only result of comparing a PencilKit snapshot with its collaboration history. The costly
/// materialization, stroke matching, and fingerprint work is performed on a background task;
/// MainActor only assigns causal stamps and installs this immutable result.
private struct PreparedDrawingCollaborationPlan: Sendable {
    let page: LibraryPage
    let baseOperations: [CollaborationOperation]
    let preexistingOperationCount: Int
    let mutations: [PreparedDrawingCollaborationMutation]
    let initialContext: CollaborationVersionVector
    let observedFrontier: CollaborationVersionVector
    let maximumLamport: UInt64
    let path: PreparedDrawingCollaborationPath
}

private struct CollaborationOperationsFileSignature: Equatable {
    let byteCount: UInt64
    let modifiedAt: Date?
}

private struct CollaborationOperationsCacheEntry {
    let signature: CollaborationOperationsFileSignature
    let operations: [CollaborationOperation]
}

private struct PendingCollaborationOperationsSave {
    let token: UUID
    let operations: [CollaborationOperation]
    let targetURL: URL
    let documentID: String
    let pageID: String
}

private enum WorkspaceTransactionPhase: String, Codable {
    case prepared
    case committed
}

private struct WorkspaceTransactionEntry: Codable {
    let relativePath: String
    let backupFileName: String
    let existedBefore: Bool
}

private struct WorkspaceTransactionJournal: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: String
    let kind: String
    let createdAt: Date
    var phase: WorkspaceTransactionPhase
    let entries: [WorkspaceTransactionEntry]
}

private struct ActiveWorkspaceTransaction {
    let directory: URL
    var journal: WorkspaceTransactionJournal
    let snapshotBefore: LibrarySnapshot
    let clockBefore: CollaborationReplicaClock
}

private struct SanitizedLibraryRegistry {
    var folders: [LibraryFolder]
    var documents: [LibraryDocumentMetadata]
    var didChange: Bool
}

enum PDFWorkspaceError: LocalizedError {
    case cannotAccess(String)
    case invalidPDF(String)

    var errorDescription: String? {
        switch self {
        case .cannotAccess(let name): "无法读取文件：\(name)"
        case .invalidPDF(let name): "不是有效的 PDF：\(name)"
        }
    }
}

@MainActor
final class DrawingDocumentStore: ObservableObject {
    @Published private(set) var saveState: LocalSaveState = .saved(nil)
    @Published private(set) var folders: [LibraryFolder] = []
    @Published private(set) var documents: [PDFWorkspaceDocument] = []
    @Published private(set) var pages: [LibraryPage] = []
    @Published private(set) var openDocumentIDs: [String] = []
    @Published private(set) var pageAssetGeneration: UInt64 = 0
    @Published private(set) var pageAssetRevisions: [LibraryPageReference: UInt64] = [:]
    @Published private(set) var cloudSyncStatus: CloudLibrarySyncStatus = .idle
    @Published private(set) var lastCloudSyncAt: Date?
    @Published private(set) var cloudSyncGeneration = 0

    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private let includesBundledSamples: Bool
    private let workspaceDirectory: URL
    private let importsDirectory: URL
    private let drawingsDirectory: URL
    private let transactionsDirectory: URL
    private let registryURL: URL
    private let collaborationClockURL: URL
    private let pendingDocumentReferencesURL: URL
    private let collaborationAcknowledgementsURL: URL
    private let deletionTombstonesURL: URL

    private var documentMetadata: [LibraryDocumentMetadata] = []
    private var pdfCache: [String: PDFDocument] = [:]
    private var thumbnailCache: [String: UIImage] = [:]
    private var pendingSaves: [String: Task<Void, Never>] = [:]
    private var pendingAssetSaves: [String: PendingAssetSave] = [:]
    /// Operation archives are immutable between edits but used repeatedly by drawing load,
    /// autosave, asset refresh, and CloudKit export. Keeping decoded values here prevents every
    /// quiet pause from decoding the complete history again on MainActor.
    private var collaborationOperationsCache: [String: CollaborationOperationsCacheEntry] = [:]
    private var pendingCollaborationOperationsSaves: [String: PendingCollaborationOperationsSave] = [:]
    private var pendingCollaborationOperationsTasks: [String: Task<Void, Never>] = [:]
    /// Invalidates an off-main drawing diff if CloudKit or another editor changes that page while
    /// the diff is being prepared. The worker simply retries from the latest immutable snapshot.
    private var collaborationOperationsRevisions: [String: UInt64] = [:]
    private var collaborationOperationsRevisionSeed: UInt64 = 0
    private var collaborationClock: CollaborationReplicaClock
    private var readOnlySharedDocumentIDs: Set<String> = []
    private var activeDrawingInteractionIDs: Set<UUID> = []
    /// A page sets this as soon as PencilKit reports a real mutation and clears it only after the
    /// immutable result has been handed to the durable writers. CloudKit must not race that handoff.
    private var pendingEditorDrawingPersistenceIDs: Set<UUID> = []
    private(set) var lastDrawingInteractionAt: Date?
    var allowsPracticeFingerDrawing = false
#if DEBUG
    private(set) var debugAppendOnlyDrawingSaveCount = 0
    private(set) var debugFullDrawingDiffSaveCount = 0
#endif
    /// A private-zone reference can arrive before the corresponding CKShare zone is mounted.
    /// Keeping it on disk prevents a committed change token from discarding that placement.
    private var pendingDocumentReferences: [String: LibraryDocumentReference] = [:]
    private var collaborationAcknowledgements: [String: CollaborationAcknowledgement] = [:]
    private var deletionTombstones: [String: LibraryEntityDeletionTombstone] = [:]

    init(
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        workspaceDirectoryOverride: URL? = nil,
        includesBundledSamples: Bool = true
    ) {
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        self.includesBundledSamples = includesBundledSamples
        lastCloudSyncAt = userDefaults.object(forKey: Self.lastCloudSyncAtKey) as? Date

        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let resolvedWorkspaceDirectory = workspaceDirectoryOverride ?? applicationSupport
            .appendingPathComponent("TiyiNote", isDirectory: true)
            .appendingPathComponent("Workspace", isDirectory: true)
        workspaceDirectory = resolvedWorkspaceDirectory
        importsDirectory = resolvedWorkspaceDirectory.appendingPathComponent("PDFs", isDirectory: true)
        drawingsDirectory = resolvedWorkspaceDirectory.appendingPathComponent("Drawings", isDirectory: true)
        let resolvedTransactionsDirectory = resolvedWorkspaceDirectory
            .appendingPathComponent("Transactions", isDirectory: true)
        transactionsDirectory = resolvedTransactionsDirectory
        registryURL = resolvedWorkspaceDirectory.appendingPathComponent("documents.json")
        let resolvedCollaborationClockURL = resolvedWorkspaceDirectory
            .appendingPathComponent("collaboration-clock.json")
        collaborationClockURL = resolvedCollaborationClockURL
        pendingDocumentReferencesURL = resolvedWorkspaceDirectory
            .appendingPathComponent("pending-document-references.json")
        collaborationAcknowledgementsURL = resolvedWorkspaceDirectory
            .appendingPathComponent("collaboration-acknowledgements.json")
        deletionTombstonesURL = resolvedWorkspaceDirectory
            .appendingPathComponent("deletion-tombstones.json")

        try? fileManager.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: drawingsDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(
            at: resolvedTransactionsDirectory,
            withIntermediateDirectories: true
        )
        Self.recoverInterruptedWorkspaceTransactions(
            fileManager: fileManager,
            workspaceDirectory: resolvedWorkspaceDirectory,
            transactionsDirectory: resolvedTransactionsDirectory
        )

        let savedClock: CollaborationReplicaClock? = {
            guard let data = try? Data(contentsOf: resolvedCollaborationClockURL) else { return nil }
            return try? JSONDecoder().decode(CollaborationReplicaClock.self, from: data)
        }()
        let localActorID: String
        if workspaceDirectoryOverride != nil {
            let actorDefaultsKey = "collaboration.localActorID"
            if let existing = userDefaults.string(forKey: actorDefaultsKey), !existing.isEmpty {
                localActorID = existing
            } else {
                localActorID = UUID().uuidString.lowercased()
                userDefaults.set(localActorID, forKey: actorDefaultsKey)
            }
        } else {
            // A missing local clock means a fresh/reinstalled replica even if Keychain survived
            // app deletion. Rotate the actor so counters can never collide with old CloudKit dots.
            localActorID = savedClock == nil
                ? UUID().uuidString.lowercased()
                : (Self.replicaActorIDFromKeychain() ?? UUID().uuidString.lowercased())
            Self.storeReplicaActorIDInKeychain(localActorID)
        }
        if let savedClock, savedClock.actorID == localActorID {
            collaborationClock = savedClock
        } else if let savedClock {
            // Identity rotation preserves causal knowledge but never reuses the old actor's next
            // counter. Existing operation logs remain valid under their original actor.
            collaborationClock = CollaborationReplicaClock(
                actorID: localActorID,
                version: savedClock.version,
                lamport: savedClock.lamport
            )
        } else {
            collaborationClock = CollaborationReplicaClock(actorID: localActorID)
        }

        if savedClock == nil || savedClock?.actorID != localActorID {
            try? persistCollaborationClock()
        }

        if let data = try? Data(contentsOf: pendingDocumentReferencesURL),
           let references = try? JSONDecoder().decode(
               [String: LibraryDocumentReference].self,
               from: data
           ) {
            pendingDocumentReferences = references
        }
        if let data = try? Data(contentsOf: collaborationAcknowledgementsURL),
           let acknowledgements = try? JSONDecoder().decode(
               [String: CollaborationAcknowledgement].self,
               from: data
           ) {
            collaborationAcknowledgements = acknowledgements
        }
        if let data = try? Data(contentsOf: deletionTombstonesURL),
           let tombstones = try? JSONDecoder().decode(
               [LibraryEntityDeletionTombstone].self,
               from: data
           ) {
            for tombstone in tombstones {
                let key = Self.deletionLedgerKey(tombstone.reference)
                if let current = deletionTombstones[key] {
                    deletionTombstones[key] = current.merged(with: tombstone)
                } else {
                    deletionTombstones[key] = tombstone
                }
                for stamp in tombstone.stamps { collaborationClock.observe(stamp) }
            }
        }

        if workspaceDirectoryOverride == nil {
            migrateLegacyCongruenceDrawings(from: applicationSupport)
        }
        loadWorkspace()
    }

    deinit {
        pendingSaves.values.forEach { $0.cancel() }
        pendingCollaborationOperationsTasks.values.forEach { $0.cancel() }
    }

    private static let replicaActorKeychainService = "com.tiyi.note.collaboration-replica"
    private static let replicaActorKeychainAccount = "actor-id"
    private static let lastCloudSyncAtKey = "cloudSync.lastSucceededAt"
    private static var drawingPersistenceQuietWindow: TimeInterval {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let argumentIndex = arguments.firstIndex(of: "--drawing-persistence-idle-delay"),
           arguments.indices.contains(argumentIndex + 1),
           let override = TimeInterval(arguments[argumentIndex + 1]) {
            return max(0.1, override)
        }
#endif
        // JSON journal encoding and atomic replacement remain outside an active handwriting burst.
        // The page-level scheduler uses the same window, and every new Pencil contact cancels any
        // staged writer before it may replace the live file.
        return 10.0
    }

    private static func replicaActorIDFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: replicaActorKeychainService,
            kSecAttrAccount as String: replicaActorKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    private static func storeReplicaActorIDInKeychain(_ actorID: String) {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: replicaActorKeychainService,
            kSecAttrAccount as String: replicaActorKeychainAccount
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(actorID.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = key
            insertion.merge(attributes) { _, new in new }
            SecItemAdd(insertion as CFDictionary, nil)
        }
    }

    var openDocuments: [PDFWorkspaceDocument] {
        openDocumentIDs.compactMap { id in
            documents.first(where: { $0.id == id && $0.trashedAt == nil })
        }
    }

    var isDrawingInteractionActive: Bool {
        !activeDrawingInteractionIDs.isEmpty
    }

    /// Automatic CloudKit export is eligible only after every editor snapshot, collaboration
    /// journal, and asset write from the current local checkpoint has completed.
    var hasPendingLocalDrawingPersistence: Bool {
        !pendingEditorDrawingPersistenceIDs.isEmpty
            || !pendingAssetSaves.isEmpty
            || !pendingCollaborationOperationsSaves.isEmpty
    }

    func setEditorDrawingPersistencePending(_ isPending: Bool, id: UUID) {
        if isPending {
            pendingEditorDrawingPersistenceIDs.insert(id)
        } else {
            pendingEditorDrawingPersistenceIDs.remove(id)
        }
    }

    func setDrawingInteractionActive(_ isActive: Bool, id: UUID) {
        let wasActive = isDrawingInteractionActive
        let membershipChanged: Bool
        if isActive {
            membershipChanged = activeDrawingInteractionIDs.insert(id).inserted
        } else {
            membershipChanged = activeDrawingInteractionIDs.remove(id) != nil
        }
        guard membershipChanged else { return }
        lastDrawingInteractionAt = Date()
        if isDrawingInteractionActive {
            // A delayed disk commit must never steal the main thread from a new Pencil contact.
            // Keep its immutable payload and restart the timer after the next sustained quiet span.
            pendingSaves.values.forEach { $0.cancel() }
            pendingSaves.removeAll()
            pendingCollaborationOperationsTasks.values.forEach { $0.cancel() }
            pendingCollaborationOperationsTasks.removeAll()
        } else if wasActive {
            schedulePendingAssetSaves()
            schedulePendingCollaborationOperationsSaves()
        }
        guard wasActive != isDrawingInteractionActive else { return }
        NotificationCenter.default.post(
            name: .tiyiDrawingInteractionActivityChanged,
            object: self
        )
    }

    func hadRecentDrawingInteraction(within interval: TimeInterval) -> Bool {
        guard !isDrawingInteractionActive,
              let lastDrawingInteractionAt else { return isDrawingInteractionActive }
        return Date().timeIntervalSince(lastDrawingInteractionAt) < interval
    }

    func drawingInteractionQuietTimeRemaining(within interval: TimeInterval) -> TimeInterval {
        if isDrawingInteractionActive { return max(0, interval) }
        guard let lastDrawingInteractionAt else { return 0 }
        return max(0, interval - Date().timeIntervalSince(lastDrawingInteractionAt))
    }

    func document(withID documentID: String) -> PDFWorkspaceDocument? {
        documents.first(where: { $0.id == documentID })
    }

    func folder(withID folderID: String) -> LibraryFolder? {
        folders.first(where: { $0.id == folderID })
    }

    func folderEditorCollaborationContext(
        for folderID: String
    ) -> FolderEditorCollaborationContext? {
        guard let folder = folder(withID: folderID) else { return nil }
        return FolderEditorCollaborationContext(frontier: folder.causalFrontier)
    }

    func libraryMoveCollaborationContext(
        folderIDs: Set<String>,
        documentIDs: Set<String>
    ) -> LibraryMoveCollaborationContext {
        let folderPairs: [(String, CollaborationVersionVector)] = folders.compactMap { folder in
            guard folderIDs.contains(folder.id) else { return nil }
            return (
                folder.id,
                folder.parentRevision?.inclusiveFrontier ?? CollaborationVersionVector()
            )
        }
        let documentPairs: [(String, CollaborationVersionVector)] = documentMetadata.compactMap {
            document in
            guard documentIDs.contains(document.id) else { return nil }
            return (
                document.id,
                document.parentRevision?.inclusiveFrontier ?? CollaborationVersionVector()
            )
        }
        return LibraryMoveCollaborationContext(
            folderParents: Dictionary(uniqueKeysWithValues: folderPairs),
            documentParents: Dictionary(uniqueKeysWithValues: documentPairs)
        )
    }

    func pages(in documentID: String) -> [LibraryPage] {
        pages
            .filter { $0.documentID == documentID }
            .sorted {
                if $0.position != $1.position { return $0.position < $1.position }
                return $0.id < $1.id
            }
    }

    func pageMetadata(at pageIndex: Int, in documentID: String) -> LibraryPage? {
        let documentPages = pages(in: documentID)
        guard documentPages.indices.contains(pageIndex) else { return nil }
        return documentPages[pageIndex]
    }

    func pageID(at pageIndex: Int, in documentID: String) -> String? {
        pageMetadata(at: pageIndex, in: documentID)?.id
    }

    func pageIndex(for pageID: String, in documentID: String) -> Int? {
        pages(in: documentID).firstIndex(where: { $0.id == pageID })
    }

    @discardableResult
    func insertTemplatePage(
        after pageID: String?,
        in documentID: String,
        style: CanvasBackgroundStyle = .blank,
        color: CanvasBackgroundColor = .white,
        size: CGSize = CGSize(width: 1024, height: 768)
    ) throws -> LibraryPage {
        try requireEditableSharedDocument(documentID)
        try prepareDocumentForPageEditing(documentID)
        let ordered = pages(in: documentID)
        let insertionIndex: Int
        if let pageID {
            guard let index = ordered.firstIndex(where: { $0.id == pageID }) else {
                throw LibraryStoreError.pageNotFound(pageID)
            }
            insertionIndex = index + 1
        } else {
            insertionIndex = ordered.count
        }

        let stamp = collaborationClock.nextStamp()
        let position = CollaborativePosition.between(
            insertionIndex > 0 ? ordered[insertionIndex - 1].position : nil,
            insertionIndex < ordered.count ? ordered[insertionIndex].position : nil,
            actorID: stamp.dot.actorID,
            sequence: stamp.dot.counter
        )
        let page = LibraryPage(
            documentID: documentID,
            orderIndex: insertionIndex,
            position: position,
            createdAt: stamp.createdAt,
            modifiedAt: stamp.createdAt,
            width: Double(size.width),
            height: Double(size.height),
            sourceKind: .template,
            backgroundStyle: style,
            backgroundColor: color
        )
        let backgroundURL = pageBackgroundURL(forPageID: page.id, in: documentID)
        var affectedURLs = [
            registryURL,
            collaborationClockURL,
            backgroundURL,
            collaborationOperationsURL(forPageID: page.id, in: documentID)
        ]
        if let metadata = documentMetadata.first(where: { $0.id == documentID }),
           let documentURL = fileURL(for: metadata) {
            affectedURLs.append(documentURL)
        }
        let transaction = try beginWorkspaceTransaction(
            kind: "insert-page",
            affectedURLs: affectedURLs
        )
        do {
            try templatePagePDFData(size: size, style: style, color: color)
                .write(to: backgroundURL, options: .atomic)
            var updated = ordered
            updated.insert(page, at: insertionIndex)
            try commitPageMutation(updated, in: documentID)
            try appendCollaborationOperation(
                CollaborationOperation(
                    workspaceID: "personal-library",
                    documentID: documentID,
                    pageID: page.id,
                    stamp: stamp,
                    payload: .pagePosition(position)
                )
            )
            try commitWorkspaceTransaction(transaction)
            signalLocalCloudChange()
            return page
        } catch {
            rollbackWorkspaceTransaction(transaction)
            throw error
        }
    }

    @discardableResult
    func duplicatePage(_ pageID: String, in documentID: String) throws -> LibraryPage {
        try requireEditableSharedDocument(documentID)
        try prepareDocumentForPageEditing(documentID)
        let ordered = pages(in: documentID)
        guard let sourceIndex = ordered.firstIndex(where: { $0.id == pageID }) else {
            throw LibraryStoreError.pageNotFound(pageID)
        }
        let insertionIndex = sourceIndex + 1
        let stamp = collaborationClock.nextStamp()
        let position = CollaborativePosition.between(
            ordered[sourceIndex].position,
            insertionIndex < ordered.count ? ordered[insertionIndex].position : nil,
            actorID: stamp.dot.actorID,
            sequence: stamp.dot.counter
        )
        let source = ordered[sourceIndex]
        let duplicate = LibraryPage(
            documentID: documentID,
            orderIndex: insertionIndex,
            position: position,
            createdAt: stamp.createdAt,
            modifiedAt: stamp.createdAt,
            width: source.width,
            height: source.height,
            rotation: source.rotation,
            sourceKind: source.sourceKind,
            backgroundStyle: source.backgroundStyle,
            backgroundColor: source.backgroundColor,
            isBookmarked: source.isBookmarked
        )
        var affectedURLs = [
            registryURL,
            collaborationClockURL,
            pageBackgroundURL(forPageID: duplicate.id, in: documentID),
            drawingURL(forPageID: duplicate.id, in: documentID),
            imageAnnotationsURL(forPageID: duplicate.id, in: documentID),
            collaborationOperationsURL(forPageID: duplicate.id, in: documentID)
        ]
        if let metadata = documentMetadata.first(where: { $0.id == documentID }),
           let documentURL = fileURL(for: metadata) {
            affectedURLs.append(documentURL)
        }
        let transaction = try beginWorkspaceTransaction(
            kind: "duplicate-page",
            affectedURLs: affectedURLs
        )
        do {
            _ = try copyPageAssets(
                from: source.id,
                to: duplicate.id,
                in: documentID
            )
            var updated = ordered
            updated.insert(duplicate, at: insertionIndex)
            try commitPageMutation(updated, in: documentID)
            try appendCollaborationOperation(
                CollaborationOperation(
                    workspaceID: "personal-library",
                    documentID: documentID,
                    pageID: duplicate.id,
                    stamp: stamp,
                    payload: .pagePosition(position)
                )
            )
            try commitWorkspaceTransaction(transaction)
            signalLocalCloudChange()
            return duplicate
        } catch {
            rollbackWorkspaceTransaction(transaction)
            throw error
        }
    }

    func movePage(_ pageID: String, to destinationIndex: Int, in documentID: String) throws {
        try requireEditableSharedDocument(documentID)
        try prepareDocumentForPageEditing(documentID)
        var ordered = pages(in: documentID)
        guard let sourceIndex = ordered.firstIndex(where: { $0.id == pageID }) else {
            throw LibraryStoreError.pageNotFound(pageID)
        }
        let page = ordered.remove(at: sourceIndex)
        let target = min(max(destinationIndex, 0), ordered.count)
        let stamp = collaborationClock.nextStamp()
        var moved = page
        moved.position = .between(
            target > 0 ? ordered[target - 1].position : nil,
            target < ordered.count ? ordered[target].position : nil,
            actorID: stamp.dot.actorID,
            sequence: stamp.dot.counter
        )
        moved.modifiedAt = stamp.createdAt
        ordered.insert(moved, at: target)
        var affectedURLs = [
            registryURL,
            collaborationClockURL,
            collaborationOperationsURL(forPageID: pageID, in: documentID)
        ]
        if let metadata = documentMetadata.first(where: { $0.id == documentID }),
           let documentURL = fileURL(for: metadata) {
            affectedURLs.append(documentURL)
        }
        let transaction = try beginWorkspaceTransaction(
            kind: "move-page",
            affectedURLs: affectedURLs
        )
        do {
            try commitPageMutation(ordered, in: documentID)
            try appendCollaborationOperation(
                CollaborationOperation(
                    workspaceID: "personal-library",
                    documentID: documentID,
                    pageID: pageID,
                    stamp: stamp,
                    payload: .pagePosition(moved.position)
                )
            )
            try commitWorkspaceTransaction(transaction)
            signalLocalCloudChange()
        } catch {
            rollbackWorkspaceTransaction(transaction)
            throw error
        }
    }

    func deletePages(_ pageIDs: Set<String>, in documentID: String) throws {
        try requireEditableSharedDocument(documentID)
        guard !pageIDs.isEmpty else { return }
        try prepareDocumentForPageEditing(documentID)
        let ordered = pages(in: documentID)
        guard pageIDs.allSatisfy({ id in ordered.contains(where: { $0.id == id }) }) else {
            throw LibraryStoreError.pageNotFound(pageIDs.sorted().first ?? "")
        }
        let remaining = ordered.filter { !pageIDs.contains($0.id) }
        guard !remaining.isEmpty else { throw LibraryStoreError.cannotDeleteLastPage }
        let pageByID = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
        let operations = try pageIDs.sorted().flatMap { pageID -> [CollaborationOperation] in
            guard let page = pageByID[pageID] else { return [] }
            return [
                CollaborationOperation(
                    workspaceID: "personal-library",
                    documentID: documentID,
                    pageID: pageID,
                    stamp: collaborationClock.nextStamp(),
                    payload: .metadataSet(
                        field: "pageArchive",
                        value: try encodedCollaborationValue(page)
                    )
                ),
                CollaborationOperation(
                    workspaceID: "personal-library",
                    documentID: documentID,
                    pageID: pageID,
                    stamp: collaborationClock.nextStamp(),
                    payload: .pageDelete
                )
            ]
        }
        var affectedURLs = [registryURL, collaborationClockURL]
        affectedURLs.append(contentsOf: pageIDs.map {
            collaborationOperationsURL(forPageID: $0, in: documentID)
        })
        if let metadata = documentMetadata.first(where: { $0.id == documentID }),
           let documentURL = fileURL(for: metadata) {
            affectedURLs.append(documentURL)
        }
        let transaction = try beginWorkspaceTransaction(
            kind: "delete-pages",
            affectedURLs: affectedURLs
        )
        do {
            try commitPageMutation(remaining, in: documentID)
            for operation in operations { try appendCollaborationOperation(operation) }
            try commitWorkspaceTransaction(transaction)
            signalLocalCloudChange()
        } catch {
            rollbackWorkspaceTransaction(transaction)
            throw error
        }
    }

    func deletedPages(in documentID: String) -> [LibraryPage] {
        let activePageIDs = Set(pages(in: documentID).map(\.id))
        let grouped = Dictionary(
            grouping: exportCollaborationOperations().filter {
                $0.documentID == documentID
                    && $0.pageID != CollaborationReservedID.documentMetadata
                    && !activePageIDs.contains($0.pageID)
            },
            by: \.pageID
        )
        return grouped.compactMap { pageID, operations -> LibraryPage? in
            let state = CollaborationMergeEngine.materialize(operations)
            guard state.isDeleted,
                  let archivedData = state.metadata["pageArchive"],
                  var archived = try? JSONDecoder().decode(
                      LibraryPage.self,
                      from: archivedData
                  ),
                  archived.documentID == documentID,
                  archived.id == pageID else { return nil }
            if let position = state.position { archived.position = position }
            return archived
        }.sorted {
            if $0.position != $1.position { return $0.position < $1.position }
            return $0.id < $1.id
        }
    }

    func restoreDeletedPages(_ pageIDs: Set<String>, in documentID: String) throws {
        try requireEditableSharedDocument(documentID)
        guard !pageIDs.isEmpty else { return }
        let archivedByID = Dictionary(
            uniqueKeysWithValues: deletedPages(in: documentID).map { ($0.id, $0) }
        )
        guard pageIDs.allSatisfy({ archivedByID[$0] != nil }) else {
            throw LibraryStoreError.pageNotFound(pageIDs.sorted().first ?? "")
        }

        var restoreOperations: [CollaborationOperation] = []
        for pageID in pageIDs.sorted() {
            let current = loadCollaborationOperations(forPageID: pageID, in: documentID)
            let state = CollaborationMergeEngine.materialize(current)
            let stamp = collaborationClock.nextStamp(observedContext: state.frontier)
            restoreOperations.append(
                CollaborationOperation(
                    workspaceID: "personal-library",
                    documentID: documentID,
                    pageID: pageID,
                    stamp: stamp,
                    payload: .pageRestore
                )
            )
        }

        var affectedURLs = [registryURL, collaborationClockURL]
        affectedURLs.append(contentsOf: pageIDs.map {
            collaborationOperationsURL(forPageID: $0, in: documentID)
        })
        if let metadata = documentMetadata.first(where: { $0.id == documentID }),
           let pdfURL = fileURL(for: metadata) {
            affectedURLs.append(pdfURL)
        }
        let transaction = try beginWorkspaceTransaction(
            kind: "restore-deleted-pages",
            affectedURLs: affectedURLs
        )
        do {
            for operation in restoreOperations { try appendCollaborationOperation(operation) }
            try persistCollaborationClock()
            try applyRemoteCollaborationOperations(restoreOperations)
            try finalizeRemotePageChanges(for: [documentID])
            try commitWorkspaceTransaction(transaction)
            signalLocalCloudChange()
        } catch {
            rollbackWorkspaceTransaction(transaction)
            throw error
        }
    }

    func rotatePage(_ pageID: String, clockwise: Bool, in documentID: String) throws {
        try requireEditableSharedDocument(documentID)
        try prepareDocumentForPageEditing(documentID)
        var ordered = pages(in: documentID)
        guard let index = ordered.firstIndex(where: { $0.id == pageID }) else {
            throw LibraryStoreError.pageNotFound(pageID)
        }
        let backgroundURL = pageBackgroundURL(forPageID: pageID, in: documentID)
        guard let pageDocument = PDFDocument(url: backgroundURL),
              let pdfPage = pageDocument.page(at: 0) else {
            throw PDFWorkspaceError.invalidPDF(documentID)
        }
        let delta = clockwise ? 90 : -90
        let rotation = normalizedPageRotation(pdfPage.rotation + delta)
        pdfPage.rotation = rotation
        guard let data = pageDocument.dataRepresentation() else {
            throw PDFWorkspaceError.invalidPDF(documentID)
        }
        var affectedURLs = [
            registryURL,
            collaborationClockURL,
            backgroundURL,
            collaborationOperationsURL(forPageID: pageID, in: documentID)
        ]
        if let metadata = documentMetadata.first(where: { $0.id == documentID }),
           let documentURL = fileURL(for: metadata) {
            affectedURLs.append(documentURL)
        }
        let transaction = try beginWorkspaceTransaction(
            kind: "rotate-page",
            affectedURLs: affectedURLs
        )
        do {
            try data.write(to: backgroundURL, options: .atomic)
            let stamp = collaborationClock.nextStamp()
            ordered[index].rotation = rotation
            ordered[index].modifiedAt = stamp.createdAt
            try commitPageMutation(ordered, in: documentID)
            try appendCollaborationOperation(
                CollaborationOperation(
                    workspaceID: "personal-library",
                    documentID: documentID,
                    pageID: pageID,
                    stamp: stamp,
                    payload: .metadataSet(
                        field: "rotation",
                        value: try encodedCollaborationValue(rotation)
                    )
                )
            )
            try commitWorkspaceTransaction(transaction)
            signalLocalCloudChange()
        } catch {
            rollbackWorkspaceTransaction(transaction)
            throw error
        }
    }

    func setPageBookmark(_ pageID: String, isBookmarked: Bool, in documentID: String) throws {
        try requireEditableSharedDocument(documentID)
        var updated = pages
        guard let index = updated.firstIndex(where: {
            $0.id == pageID && $0.documentID == documentID
        }) else { throw LibraryStoreError.pageNotFound(pageID) }
        let stamp = collaborationClock.nextStamp()
        updated[index].isBookmarked = isBookmarked
        updated[index].modifiedAt = stamp.createdAt
        let transaction = try beginWorkspaceTransaction(
            kind: "bookmark-page",
            affectedURLs: [
                registryURL,
                collaborationClockURL,
                collaborationOperationsURL(forPageID: pageID, in: documentID)
            ]
        )
        do {
            try persistRegistry(folders: folders, documents: documentMetadata, pages: updated)
            pages = updated
            try appendCollaborationOperation(
                CollaborationOperation(
                    workspaceID: "personal-library",
                    documentID: documentID,
                    pageID: pageID,
                    stamp: stamp,
                    payload: .metadataSet(
                        field: "isBookmarked",
                        value: try encodedCollaborationValue(isBookmarked)
                    )
                )
            )
            try commitWorkspaceTransaction(transaction)
            signalLocalCloudChange()
        } catch {
            rollbackWorkspaceTransaction(transaction)
            throw error
        }
    }

#if DEBUG
    /// Test-only crash simulation. It intentionally leaves a valid `prepared` journal behind after
    /// one of the multi-file rotation stages; constructing a new Store must restore the old state.
    func debugLeaveInterruptedRotationTransaction(
        pageID: String,
        in documentID: String,
        completedStage: Int
    ) throws {
        precondition((1...3).contains(completedStage))
        try prepareDocumentForPageEditing(documentID)
        var ordered = pages(in: documentID)
        guard let index = ordered.firstIndex(where: { $0.id == pageID }) else {
            throw LibraryStoreError.pageNotFound(pageID)
        }
        let backgroundURL = pageBackgroundURL(forPageID: pageID, in: documentID)
        guard let pageDocument = PDFDocument(url: backgroundURL),
              let pdfPage = pageDocument.page(at: 0) else {
            throw PDFWorkspaceError.invalidPDF(documentID)
        }
        let rotation = normalizedPageRotation(pdfPage.rotation + 90)
        pdfPage.rotation = rotation
        guard let data = pageDocument.dataRepresentation() else {
            throw PDFWorkspaceError.invalidPDF(documentID)
        }
        var affectedURLs = [
            registryURL,
            collaborationClockURL,
            backgroundURL,
            collaborationOperationsURL(forPageID: pageID, in: documentID)
        ]
        if let metadata = documentMetadata.first(where: { $0.id == documentID }),
           let documentURL = fileURL(for: metadata) {
            affectedURLs.append(documentURL)
        }
        let transaction = try beginWorkspaceTransaction(
            kind: "debug-interrupted-rotation-stage-\(completedStage)",
            affectedURLs: affectedURLs
        )
        try data.write(to: backgroundURL, options: .atomic)
        if completedStage >= 2 {
            let stamp = collaborationClock.nextStamp()
            ordered[index].rotation = rotation
            ordered[index].modifiedAt = stamp.createdAt
            try commitPageMutation(ordered, in: documentID)
            if completedStage >= 3 {
                try appendCollaborationOperation(
                    CollaborationOperation(
                        workspaceID: "personal-library",
                        documentID: documentID,
                        pageID: pageID,
                        stamp: stamp,
                        payload: .metadataSet(
                            field: "rotation",
                            value: try encodedCollaborationValue(rotation)
                        )
                    )
                )
            }
        }
        _ = transaction
    }
#endif

    func childFolders(in parentID: String?) -> [LibraryFolder] {
        folders
            .filter { $0.parentID == parentID && $0.trashedAt == nil }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func documents(in parentID: String?) -> [PDFWorkspaceDocument] {
        documents
            .filter { $0.parentID == parentID && $0.trashedAt == nil }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var favoriteFolders: [LibraryFolder] {
        folders.filter { $0.isFavorite && $0.trashedAt == nil }
    }

    var favoriteDocuments: [PDFWorkspaceDocument] {
        documents.filter { $0.isFavorite && $0.trashedAt == nil }
    }

    var trashedFolders: [LibraryFolder] {
        folders.filter { $0.trashedAt != nil }
    }

    var trashedDocuments: [PDFWorkspaceDocument] {
        documents.filter { $0.trashedAt != nil }
    }

    @discardableResult
    func createFolder(
        named proposedTitle: String,
        in parentID: String?,
        color: LibraryFolderColor = .blue,
        icon: LibraryFolderIcon = .folder
    ) throws -> LibraryFolder {
        try validateParentFolder(parentID)
        let title = try normalizedTitle(proposedTitle)
        try validateUniqueTitle(title, in: parentID)

        let stamp = collaborationClock.nextStamp()
        let folder = LibraryFolder(
            title: title,
            parentID: parentID,
            createdAt: stamp.createdAt,
            modifiedAt: stamp.createdAt,
            color: color,
            icon: icon,
            titleRevision: stamp,
            parentRevision: stamp,
            colorRevision: stamp,
            iconRevision: stamp,
            favoriteRevision: stamp,
            trashRevision: stamp
        )
        var updatedFolders = folders
        updatedFolders.append(folder)
        try persistRegistry(folders: updatedFolders, documents: documentMetadata)
        try persistCollaborationClock()
        folders = updatedFolders
        signalLocalCloudChange()
        return folder
    }

    func renameFolder(
        _ folderID: String,
        to proposedTitle: String,
        causalContext: CollaborationVersionVector? = nil
    ) throws {
        try updateFolderMetadata(
            folderID,
            title: proposedTitle,
            causalContext: causalContext.map {
                FolderEditorCollaborationContext(title: $0, color: $0, icon: $0)
            }
        )
    }

    /// Commits all fields changed by one folder editor as a single recoverable transaction.
    /// `nil` means the user did not edit that field, which is different from writing the value
    /// currently visible in the store: a remote update may have arrived behind the open sheet.
    func updateFolderMetadata(
        _ folderID: String,
        title proposedTitle: String? = nil,
        color proposedColor: LibraryFolderColor? = nil,
        icon proposedIcon: LibraryFolderIcon? = nil,
        causalContext: FolderEditorCollaborationContext? = nil
    ) throws {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else {
            throw LibraryStoreError.folderNotFound(folderID)
        }
        guard folders[index].trashedAt == nil else { throw LibraryStoreError.itemIsInTrash }
        let title = try proposedTitle.map(normalizedTitle)
        if let title, title != folders[index].title {
            try validateUniqueTitle(title, in: folders[index].parentID, excludingID: folderID)
        }

        let changesTitle = title.map { $0 != folders[index].title } ?? false
        let changesColor = proposedColor.map { $0 != folders[index].color } ?? false
        let changesIcon = proposedIcon.map { $0 != folders[index].icon } ?? false
        guard changesTitle || changesColor || changesIcon else { return }

        let transaction = try beginWorkspaceTransaction(
            kind: "update-folder-metadata",
            affectedURLs: [registryURL, collaborationClockURL]
        )
        var updatedFolders = folders
        var emittedFrontier = CollaborationVersionVector()

        func nextFieldStamp(
            observedContext: CollaborationVersionVector?
        ) -> CollaborationStamp {
            let stamp: CollaborationStamp
            if var observedContext {
                // Fields changed by the same Save action form one local causal chain, while remote
                // events received after the sheet opened remain intentionally excluded.
                observedContext.formUnion(emittedFrontier)
                stamp = collaborationClock.nextStamp(observedContext: observedContext)
            } else {
                stamp = collaborationClock.nextStamp()
            }
            emittedFrontier.formUnion(stamp.context)
            emittedFrontier.observe(stamp.dot)
            return stamp
        }

        do {
            if changesTitle, let title {
                let stamp = nextFieldStamp(observedContext: causalContext?.title)
                updatedFolders[index].title = title
                updatedFolders[index].titleRevision = stamp
                updatedFolders[index].modifiedAt = max(
                    updatedFolders[index].modifiedAt,
                    stamp.createdAt
                )
            }
            if changesColor, let proposedColor {
                let stamp = nextFieldStamp(observedContext: causalContext?.color)
                updatedFolders[index].color = proposedColor
                updatedFolders[index].colorRevision = stamp
                updatedFolders[index].modifiedAt = max(
                    updatedFolders[index].modifiedAt,
                    stamp.createdAt
                )
            }
            if changesIcon, let proposedIcon {
                let stamp = nextFieldStamp(observedContext: causalContext?.icon)
                updatedFolders[index].icon = proposedIcon
                updatedFolders[index].iconRevision = stamp
                updatedFolders[index].modifiedAt = max(
                    updatedFolders[index].modifiedAt,
                    stamp.createdAt
                )
            }
            try persistRegistry(folders: updatedFolders, documents: documentMetadata)
            try persistCollaborationClock()
            try commitWorkspaceTransaction(transaction)
            folders = updatedFolders
            signalLocalCloudChange()
        } catch {
            rollbackWorkspaceTransaction(transaction)
            throw error
        }
    }

    func moveFolder(_ folderID: String, to parentID: String?) throws {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else {
            throw LibraryStoreError.folderNotFound(folderID)
        }
        guard folders[index].trashedAt == nil else { throw LibraryStoreError.itemIsInTrash }
        try validateParentFolder(parentID)
        guard parentID != folderID, !descendantFolderIDs(of: folderID).contains(parentID ?? "") else {
            throw LibraryStoreError.folderCycle
        }
        try validateUniqueTitle(
            folders[index].title,
            in: parentID,
            excludingID: folderID
        )

        let stamp = collaborationClock.nextStamp()
        var updatedFolders = folders
        updatedFolders[index].parentID = parentID
        updatedFolders[index].parentRevision = stamp
        updatedFolders[index].modifiedAt = stamp.createdAt
        try persistRegistry(folders: updatedFolders, documents: documentMetadata)
        try persistCollaborationClock()
        folders = updatedFolders
        signalLocalCloudChange()
    }

    func renameDocument(
        _ documentID: String,
        to proposedTitle: String,
        causalContext: CollaborationVersionVector? = nil
    ) throws {
        try requireEditableSharedDocument(documentID)
        guard let index = documentMetadata.firstIndex(where: { $0.id == documentID }) else {
            throw LibraryStoreError.documentNotFound(documentID)
        }
        guard documentMetadata[index].trashedAt == nil else { throw LibraryStoreError.itemIsInTrash }
        let title = try normalizedTitle(proposedTitle)
        try validateUniqueTitle(
            title,
            in: documentMetadata[index].parentID,
            excludingID: documentID
        )

        var updatedMetadata = documentMetadata
        updatedMetadata[index].title = title
        let previousOperations = loadCollaborationOperations(
            forPageID: CollaborationReservedID.documentMetadata,
            in: documentID
        )
        let titleData = try collaborationJSONEncoder().encode(title)
        let titleOperation = CollaborationOperation(
            workspaceID: "personal-library",
            documentID: documentID,
            pageID: CollaborationReservedID.documentMetadata,
            stamp: causalContext.map {
                collaborationClock.nextStamp(observedContext: $0)
            } ?? collaborationClock.nextStamp(),
            payload: .metadataSet(field: "document.title", value: titleData)
        )
        updatedMetadata[index].modifiedAt = titleOperation.stamp.createdAt
        updatedMetadata[index].contentModifiedAt = titleOperation.stamp.createdAt
        try appendCollaborationOperation(titleOperation)
        do {
            try persistRegistry(folders: folders, documents: updatedMetadata)
        } catch {
            // The registry and its causal event are one logical mutation. A failed registry write
            // must not later rename the document through CloudKit.
            try? saveCollaborationOperations(
                previousOperations,
                forPageID: CollaborationReservedID.documentMetadata,
                in: documentID
            )
            throw error
        }
        documentMetadata = updatedMetadata
        rebuildWorkspaceDocuments()
        signalLocalCloudChange()
    }

    func moveDocument(_ documentID: String, to parentID: String?) throws {
        guard let index = documentMetadata.firstIndex(where: { $0.id == documentID }) else {
            throw LibraryStoreError.documentNotFound(documentID)
        }
        guard documentMetadata[index].trashedAt == nil else { throw LibraryStoreError.itemIsInTrash }
        try validateParentFolder(parentID)
        try validateUniqueTitle(
            documentMetadata[index].title,
            in: parentID,
            excludingID: documentID
        )

        let stamp = collaborationClock.nextStamp()
        var updatedMetadata = documentMetadata
        updatedMetadata[index].parentID = parentID
        updatedMetadata[index].parentRevision = stamp
        updatedMetadata[index].modifiedAt = stamp.createdAt
        try persistRegistry(folders: folders, documents: updatedMetadata)
        try persistCollaborationClock()
        documentMetadata = updatedMetadata
        rebuildWorkspaceDocuments()
        signalLocalCloudChange()
    }

    func updateFolderAppearance(
        _ folderID: String,
        color: LibraryFolderColor,
        icon: LibraryFolderIcon,
        colorCausalContext: CollaborationVersionVector? = nil,
        iconCausalContext: CollaborationVersionVector? = nil
    ) throws {
        let context: FolderEditorCollaborationContext?
        if colorCausalContext != nil || iconCausalContext != nil {
            let fallback = colorCausalContext ?? iconCausalContext ?? CollaborationVersionVector()
            context = FolderEditorCollaborationContext(
                title: fallback,
                color: colorCausalContext ?? fallback,
                icon: iconCausalContext ?? fallback
            )
        } else {
            context = nil
        }
        try updateFolderMetadata(
            folderID,
            color: color,
            icon: icon,
            causalContext: context
        )
    }

    func setFolderFavorite(_ folderID: String, isFavorite: Bool) throws {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else {
            throw LibraryStoreError.folderNotFound(folderID)
        }
        guard folders[index].trashedAt == nil else { throw LibraryStoreError.itemIsInTrash }
        guard folders[index].isFavorite != isFavorite else { return }
        let stamp = collaborationClock.nextStamp()
        var updatedFolders = folders
        updatedFolders[index].isFavorite = isFavorite
        updatedFolders[index].favoriteRevision = stamp
        updatedFolders[index].modifiedAt = stamp.createdAt
        try persistRegistry(folders: updatedFolders, documents: documentMetadata)
        try persistCollaborationClock()
        folders = updatedFolders
        signalLocalCloudChange()
    }

    func setDocumentFavorite(_ documentID: String, isFavorite: Bool) throws {
        guard let index = documentMetadata.firstIndex(where: { $0.id == documentID }) else {
            throw LibraryStoreError.documentNotFound(documentID)
        }
        guard documentMetadata[index].trashedAt == nil else { throw LibraryStoreError.itemIsInTrash }
        guard documentMetadata[index].isFavorite != isFavorite else { return }
        let stamp = collaborationClock.nextStamp()
        var updatedMetadata = documentMetadata
        updatedMetadata[index].isFavorite = isFavorite
        updatedMetadata[index].favoriteRevision = stamp
        updatedMetadata[index].modifiedAt = stamp.createdAt
        try persistRegistry(folders: folders, documents: updatedMetadata)
        try persistCollaborationClock()
        documentMetadata = updatedMetadata
        rebuildWorkspaceDocuments()
        signalLocalCloudChange()
    }

    /// Moves all selected items as one registry transaction. No partial move is persisted.
    func moveItems(
        folderIDs: Set<String>,
        documentIDs: Set<String>,
        to parentID: String?,
        causalContext: LibraryMoveCollaborationContext? = nil
    ) throws {
        guard !folderIDs.isEmpty || !documentIDs.isEmpty else { return }
        try validateParentFolder(parentID)

        let movingFolders = try folderIDs.map { folderID -> LibraryFolder in
            guard let folder = folders.first(where: { $0.id == folderID }) else {
                throw LibraryStoreError.folderNotFound(folderID)
            }
            guard folder.trashedAt == nil else { throw LibraryStoreError.itemIsInTrash }
            return folder
        }
        let movingDocuments = try documentIDs.map { documentID -> LibraryDocumentMetadata in
            guard let document = documentMetadata.first(where: { $0.id == documentID }) else {
                throw LibraryStoreError.documentNotFound(documentID)
            }
            guard document.trashedAt == nil else { throw LibraryStoreError.itemIsInTrash }
            return document
        }

        if let parentID {
            for folderID in folderIDs {
                guard parentID != folderID,
                      !descendantFolderIDs(of: folderID).contains(parentID) else {
                    throw LibraryStoreError.folderCycle
                }
            }
        }

        var occupied = Set<String>()
        for folder in folders where folder.parentID == parentID
            && folder.trashedAt == nil
            && !folderIDs.contains(folder.id) {
            occupied.insert(normalizedComparisonKey(folder.title))
        }
        for document in documentMetadata where document.parentID == parentID
            && document.trashedAt == nil
            && !documentIDs.contains(document.id) {
            occupied.insert(normalizedComparisonKey(document.title))
        }
        for title in (movingFolders.map(\.title) + movingDocuments.map(\.title)).sorted() {
            guard occupied.insert(normalizedComparisonKey(title)).inserted else {
                throw LibraryStoreError.nameConflict(title)
            }
        }

        let changedFolderIDs = Set(movingFolders.compactMap {
            $0.parentID != parentID ? $0.id : nil
        })
        let changedDocumentIDs = Set(movingDocuments.compactMap {
            $0.parentID != parentID ? $0.id : nil
        })
        guard !changedFolderIDs.isEmpty || !changedDocumentIDs.isEmpty else { return }

        let transaction = try beginWorkspaceTransaction(
            kind: "move-library-items",
            affectedURLs: [registryURL, collaborationClockURL]
        )
        var updatedFolders = folders
        var updatedMetadata = documentMetadata
        var emittedFrontier = CollaborationVersionVector()

        func nextMoveStamp(
            observedContext: CollaborationVersionVector?
        ) -> CollaborationStamp {
            let stamp: CollaborationStamp
            if var observedContext {
                observedContext.formUnion(emittedFrontier)
                stamp = collaborationClock.nextStamp(observedContext: observedContext)
            } else {
                stamp = collaborationClock.nextStamp()
            }
            emittedFrontier.formUnion(stamp.context)
            emittedFrontier.observe(stamp.dot)
            return stamp
        }

        do {
            for folderID in changedFolderIDs.sorted() {
                guard let index = updatedFolders.firstIndex(where: { $0.id == folderID }) else {
                    continue
                }
                let stamp = nextMoveStamp(
                    observedContext: causalContext?.folderParents[folderID]
                )
                updatedFolders[index].parentID = parentID
                updatedFolders[index].parentRevision = stamp
                updatedFolders[index].modifiedAt = stamp.createdAt
            }
            for documentID in changedDocumentIDs.sorted() {
                guard let index = updatedMetadata.firstIndex(where: { $0.id == documentID }) else {
                    continue
                }
                let stamp = nextMoveStamp(
                    observedContext: causalContext?.documentParents[documentID]
                )
                updatedMetadata[index].parentID = parentID
                updatedMetadata[index].parentRevision = stamp
                updatedMetadata[index].modifiedAt = stamp.createdAt
            }
            try persistRegistry(folders: updatedFolders, documents: updatedMetadata)
            try persistCollaborationClock()
            try commitWorkspaceTransaction(transaction)
            folders = updatedFolders
            documentMetadata = updatedMetadata
            rebuildWorkspaceDocuments()
            signalLocalCloudChange()
        } catch {
            rollbackWorkspaceTransaction(transaction)
            throw error
        }
    }

    func moveToTrash(folderID: String) throws {
        guard let folder = folders.first(where: { $0.id == folderID }) else {
            throw LibraryStoreError.folderNotFound(folderID)
        }
        guard folder.trashedAt == nil else { return }

        let folderIDs = descendantFolderIDs(of: folderID).union([folderID])
        let now = Date()
        let referenceStamp = collaborationClock.nextStamp(createdAt: now)
        var updatedFolders = folders
        var updatedMetadata = documentMetadata
        for index in updatedFolders.indices where folderIDs.contains(updatedFolders[index].id) {
            updatedFolders[index].trashedAt = now
            updatedFolders[index].isFavorite = false
            updatedFolders[index].trashRevision = referenceStamp
            updatedFolders[index].favoriteRevision = referenceStamp
            updatedFolders[index].modifiedAt = now
        }
        let trashedDocumentIDs = Set(updatedMetadata.compactMap { metadata in
            metadata.parentID.map(folderIDs.contains) == true ? metadata.id : nil
        })
        for index in updatedMetadata.indices where trashedDocumentIDs.contains(updatedMetadata[index].id) {
            updatedMetadata[index].trashedAt = now
            updatedMetadata[index].isFavorite = false
            updatedMetadata[index].trashRevision = referenceStamp
            updatedMetadata[index].favoriteRevision = referenceStamp
            updatedMetadata[index].modifiedAt = now
        }
        try persistRegistry(folders: updatedFolders, documents: updatedMetadata)
        try persistCollaborationClock()
        folders = updatedFolders
        documentMetadata = updatedMetadata
        openDocumentIDs.removeAll(where: trashedDocumentIDs.contains)
        rebuildWorkspaceDocuments()
        persistOpenDocuments()
        signalLocalCloudChange()
    }

    func moveToTrash(documentID: String) throws {
        guard let index = documentMetadata.firstIndex(where: { $0.id == documentID }) else {
            throw LibraryStoreError.documentNotFound(documentID)
        }
        guard documentMetadata[index].trashedAt == nil else { return }
        let now = Date()
        let referenceStamp = collaborationClock.nextStamp(createdAt: now)
        var updatedMetadata = documentMetadata
        updatedMetadata[index].trashedAt = now
        updatedMetadata[index].isFavorite = false
        updatedMetadata[index].trashRevision = referenceStamp
        updatedMetadata[index].favoriteRevision = referenceStamp
        updatedMetadata[index].modifiedAt = now
        try persistRegistry(folders: folders, documents: updatedMetadata)
        try persistCollaborationClock()
        documentMetadata = updatedMetadata
        openDocumentIDs.removeAll(where: { $0 == documentID })
        rebuildWorkspaceDocuments()
        persistOpenDocuments()
        signalLocalCloudChange()
    }

    func moveItemsToTrash(
        folderIDs requestedFolderIDs: Set<String>,
        documentIDs requestedDocumentIDs: Set<String>
    ) throws {
        var expandedFolderIDs = requestedFolderIDs
        for folderID in requestedFolderIDs {
            guard folders.contains(where: { $0.id == folderID && $0.trashedAt == nil }) else {
                throw LibraryStoreError.folderNotFound(folderID)
            }
            expandedFolderIDs.formUnion(descendantFolderIDs(of: folderID))
        }
        var expandedDocumentIDs = requestedDocumentIDs
        for documentID in requestedDocumentIDs {
            guard documentMetadata.contains(where: { $0.id == documentID && $0.trashedAt == nil }) else {
                throw LibraryStoreError.documentNotFound(documentID)
            }
        }
        for document in documentMetadata
        where document.parentID.map(expandedFolderIDs.contains) == true {
            expandedDocumentIDs.insert(document.id)
        }
        guard !expandedFolderIDs.isEmpty || !expandedDocumentIDs.isEmpty else { return }
        let now = Date()
        let referenceStamp = collaborationClock.nextStamp(createdAt: now)
        var updatedFolders = folders
        var updatedMetadata = documentMetadata
        for index in updatedFolders.indices where expandedFolderIDs.contains(updatedFolders[index].id) {
            updatedFolders[index].trashedAt = now
            updatedFolders[index].isFavorite = false
            updatedFolders[index].trashRevision = referenceStamp
            updatedFolders[index].favoriteRevision = referenceStamp
            updatedFolders[index].modifiedAt = now
        }
        for index in updatedMetadata.indices where expandedDocumentIDs.contains(updatedMetadata[index].id) {
            updatedMetadata[index].trashedAt = now
            updatedMetadata[index].isFavorite = false
            updatedMetadata[index].trashRevision = referenceStamp
            updatedMetadata[index].favoriteRevision = referenceStamp
            updatedMetadata[index].modifiedAt = now
        }
        try persistRegistry(folders: updatedFolders, documents: updatedMetadata)
        try persistCollaborationClock()
        folders = updatedFolders
        documentMetadata = updatedMetadata
        openDocumentIDs.removeAll(where: expandedDocumentIDs.contains)
        rebuildWorkspaceDocuments()
        persistOpenDocuments()
        signalLocalCloudChange()
    }

    func restore(folderID: String) throws {
        guard let rootIndex = folders.firstIndex(where: { $0.id == folderID }) else {
            throw LibraryStoreError.folderNotFound(folderID)
        }
        guard folders[rootIndex].trashedAt != nil else { return }

        let restoringFolderIDs = descendantFolderIDs(of: folderID).union([folderID])
        let now = Date()
        let referenceStamp = collaborationClock.nextStamp(createdAt: now)
        var updatedFolders = folders
        var updatedMetadata = documentMetadata
        let proposedParentID = updatedFolders[rootIndex].parentID
        if let proposedParentID,
           !updatedFolders.contains(where: { $0.id == proposedParentID && $0.trashedAt == nil }) {
            updatedFolders[rootIndex].parentID = nil
            updatedFolders[rootIndex].parentRevision = referenceStamp
        }

        let orderedFolderIDs = restoringFolderIDs.sorted {
            folderDepth($0, in: updatedFolders) < folderDepth($1, in: updatedFolders)
        }
        for restoringID in orderedFolderIDs {
            guard let index = updatedFolders.firstIndex(where: { $0.id == restoringID }) else { continue }
            let restoredTitle = uniqueRestoredTitle(
                updatedFolders[index].title,
                parentID: updatedFolders[index].parentID,
                excludingID: restoringID,
                folders: updatedFolders,
                documents: updatedMetadata,
                isDocument: false
            )
            if updatedFolders[index].title != restoredTitle {
                updatedFolders[index].title = restoredTitle
                updatedFolders[index].titleRevision = referenceStamp
            }
            updatedFolders[index].trashedAt = nil
            updatedFolders[index].trashRevision = referenceStamp
            updatedFolders[index].modifiedAt = now
        }

        for index in updatedMetadata.indices
        where updatedMetadata[index].parentID.map(restoringFolderIDs.contains) == true {
            updatedMetadata[index].title = uniqueRestoredTitle(
                updatedMetadata[index].title,
                parentID: updatedMetadata[index].parentID,
                excludingID: updatedMetadata[index].id,
                folders: updatedFolders,
                documents: updatedMetadata,
                isDocument: true
            )
            updatedMetadata[index].trashedAt = nil
            updatedMetadata[index].trashRevision = referenceStamp
            updatedMetadata[index].contentModifiedAt = now
            updatedMetadata[index].modifiedAt = now
        }

        try persistRegistry(folders: updatedFolders, documents: updatedMetadata)
        try persistCollaborationClock()
        folders = updatedFolders
        documentMetadata = updatedMetadata
        rebuildWorkspaceDocuments()
        signalLocalCloudChange()
    }

    func restore(documentID: String) throws {
        guard let index = documentMetadata.firstIndex(where: { $0.id == documentID }) else {
            throw LibraryStoreError.documentNotFound(documentID)
        }
        guard documentMetadata[index].trashedAt != nil else { return }
        let now = Date()
        let referenceStamp = collaborationClock.nextStamp(createdAt: now)
        var updatedMetadata = documentMetadata
        if let parentID = updatedMetadata[index].parentID,
           !folders.contains(where: { $0.id == parentID && $0.trashedAt == nil }) {
            updatedMetadata[index].parentID = nil
            updatedMetadata[index].parentRevision = referenceStamp
        }
        updatedMetadata[index].title = uniqueRestoredTitle(
            updatedMetadata[index].title,
            parentID: updatedMetadata[index].parentID,
            excludingID: documentID,
            folders: folders,
            documents: updatedMetadata,
            isDocument: true
        )
        updatedMetadata[index].trashedAt = nil
        updatedMetadata[index].trashRevision = referenceStamp
        updatedMetadata[index].contentModifiedAt = now
        updatedMetadata[index].modifiedAt = now
        try persistRegistry(folders: folders, documents: updatedMetadata)
        try persistCollaborationClock()
        documentMetadata = updatedMetadata
        rebuildWorkspaceDocuments()
        signalLocalCloudChange()
    }

    func permanentlyDelete(folderID: String) throws {
        guard folders.contains(where: { $0.id == folderID }) else {
            throw LibraryStoreError.folderNotFound(folderID)
        }
        let folderIDs = descendantFolderIDs(of: folderID).union([folderID])
        let documentIDs = Set(documentMetadata.compactMap { metadata in
            metadata.parentID.map(folderIDs.contains) == true ? metadata.id : nil
        })
        try deleteItemsPermanently(folderIDs: folderIDs, documentIDs: documentIDs)
    }

    func permanentlyDelete(documentID: String) throws {
        try requireEditableSharedDocument(documentID)
        guard documentMetadata.contains(where: { $0.id == documentID }) else {
            throw LibraryStoreError.documentNotFound(documentID)
        }
        try deleteItemsPermanently(folderIDs: [], documentIDs: [documentID])
    }

    func emptyTrash() throws {
        let folderIDs = Set(folders.filter { $0.trashedAt != nil }.map(\.id))
        let documentIDs = Set(documentMetadata.filter { $0.trashedAt != nil }.map(\.id))
        guard !folderIDs.isEmpty || !documentIDs.isEmpty else { return }
        try deleteItemsPermanently(folderIDs: folderIDs, documentIDs: documentIDs)
    }

    func permanentlyDeleteItems(
        folderIDs requestedFolderIDs: Set<String>,
        documentIDs requestedDocumentIDs: Set<String>
    ) throws {
        var expandedFolderIDs = requestedFolderIDs
        for folderID in requestedFolderIDs {
            expandedFolderIDs.formUnion(descendantFolderIDs(of: folderID))
        }
        var expandedDocumentIDs = requestedDocumentIDs
        for document in documentMetadata
        where document.parentID.map(expandedFolderIDs.contains) == true {
            expandedDocumentIDs.insert(document.id)
        }
        guard !expandedFolderIDs.isEmpty || !expandedDocumentIDs.isEmpty else { return }
        try deleteItemsPermanently(
            folderIDs: expandedFolderIDs,
            documentIDs: expandedDocumentIDs
        )
    }

    @discardableResult
    func createCanvas(
        named proposedTitle: String,
        in parentID: String?,
        backgroundStyle: CanvasBackgroundStyle,
        backgroundColor: CanvasBackgroundColor
    ) throws -> PDFWorkspaceDocument {
        try validateParentFolder(parentID)
        let title = try normalizedTitle(proposedTitle)
        try validateUniqueTitle(title, in: parentID)

        let documentID = UUID().uuidString.lowercased()
        let fileName = "\(documentID).pdf"
        let targetURL = importsDirectory.appendingPathComponent(fileName)
        let pageBounds = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: title,
            kCGPDFContextCreator as String: "Tiyi Note"
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds, format: format)

        do {
            try renderer.writePDF(to: targetURL) { context in
                context.beginPage()
                drawCanvasBackground(
                    in: context.cgContext,
                    bounds: pageBounds,
                    style: backgroundStyle,
                    color: backgroundColor
                )
            }
            guard let pdf = PDFDocument(url: targetURL), pdf.pageCount == 1 else {
                throw PDFWorkspaceError.invalidPDF(title)
            }

            let now = Date()
            let metadata = LibraryDocumentMetadata(
                id: documentID,
                title: title,
                parentID: parentID,
                fileName: fileName,
                isBundled: false,
                createdAt: now,
                modifiedAt: now,
                kind: .canvas,
                canvasBackgroundStyle: backgroundStyle,
                canvasBackgroundColor: backgroundColor
            )
            let updatedMetadata = documentMetadata + [metadata]
            let createdPages = makePageMetadata(for: metadata, pdf: pdf)
            let updatedPages = pages + createdPages
            try persistPageBackgroundAssets(
                pages: createdPages,
                from: pdf,
                documentID: documentID
            )
            try persistRegistry(
                folders: folders,
                documents: updatedMetadata,
                pages: updatedPages
            )
            documentMetadata = updatedMetadata
            pages = updatedPages
            pdfCache[documentID] = pdf
            rebuildWorkspaceDocuments()
            openDocumentIDs.append(documentID)
            persistOpenDocuments()
            signalLocalCloudChange()
            guard let document = document(withID: documentID) else {
                throw LibraryStoreError.documentNotFound(documentID)
            }
            return document
        } catch {
            try? fileManager.removeItem(at: targetURL)
            throw error
        }
    }

    func openDocument(_ documentID: String) {
        guard document(withID: documentID)?.trashedAt == nil else { return }
        if !openDocumentIDs.contains(documentID) {
            openDocumentIDs.append(documentID)
            persistOpenDocuments()
        }
    }

    func closeDocument(_ documentID: String) {
        guard openDocumentIDs.count > 1 else { return }
        openDocumentIDs.removeAll(where: { $0 == documentID })
        persistOpenDocuments()
    }

    func moveOpenDocument(_ documentID: String, relativeTo targetDocumentID: String) {
        guard documentID != targetDocumentID,
              let sourceIndex = openDocumentIDs.firstIndex(of: documentID),
              let targetIndex = openDocumentIDs.firstIndex(of: targetDocumentID) else {
            return
        }

        var reorderedDocumentIDs = openDocumentIDs
        let movedDocumentID = reorderedDocumentIDs.remove(at: sourceIndex)
        let insertionIndex = min(targetIndex, reorderedDocumentIDs.endIndex)
        reorderedDocumentIDs.insert(movedDocumentID, at: insertionIndex)

        guard reorderedDocumentIDs != openDocumentIDs else { return }
        openDocumentIDs = reorderedDocumentIDs
        persistOpenDocuments()
    }

    @discardableResult
    func importPDFs(from urls: [URL]) throws -> [PDFWorkspaceDocument] {
        try importPDFs(from: urls, into: nil)
    }

    @discardableResult
    func importPDFs(
        from urls: [URL],
        into parentID: String?
    ) throws -> [PDFWorkspaceDocument] {
        try validateParentFolder(parentID)
        var reservedTitles = Set<String>()
        for url in urls {
            let title = try normalizedTitle(url.lastPathComponent)
            let comparisonKey = normalizedComparisonKey(title)
            guard !reservedTitles.contains(comparisonKey) else {
                throw LibraryStoreError.nameConflict(title)
            }
            try validateUniqueTitle(title, in: parentID)
            reservedTitles.insert(comparisonKey)
        }

        var newMetadata: [LibraryDocumentMetadata] = []
        var loadedPDFs: [String: PDFDocument] = [:]
        var createdURLs: [URL] = []

        do {
            for sourceURL in urls {
                let hasSecurityAccess = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if hasSecurityAccess {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }

                let documentID = UUID().uuidString.lowercased()
                let targetFileName = "\(documentID).pdf"
                let targetURL = importsDirectory.appendingPathComponent(targetFileName)

                do {
                    try fileManager.copyItem(at: sourceURL, to: targetURL)
                    createdURLs.append(targetURL)
                } catch {
                    throw PDFWorkspaceError.cannotAccess(sourceURL.lastPathComponent)
                }

                guard let pdfDocument = PDFDocument(url: targetURL), pdfDocument.pageCount > 0 else {
                    throw PDFWorkspaceError.invalidPDF(sourceURL.lastPathComponent)
                }

                let now = Date()
                newMetadata.append(
                    LibraryDocumentMetadata(
                        id: documentID,
                        title: try normalizedTitle(sourceURL.lastPathComponent),
                        parentID: parentID,
                        fileName: targetFileName,
                        isBundled: false,
                        createdAt: now,
                        modifiedAt: now
                    )
                )
                loadedPDFs[documentID] = pdfDocument
            }

            let updatedMetadata = documentMetadata + newMetadata
            let newPages = newMetadata.flatMap { metadata in
                loadedPDFs[metadata.id].map { makePageMetadata(for: metadata, pdf: $0) } ?? []
            }
            for metadata in newMetadata {
                guard let pdf = loadedPDFs[metadata.id] else { continue }
                try persistPageBackgroundAssets(
                    pages: newPages.filter { $0.documentID == metadata.id },
                    from: pdf,
                    documentID: metadata.id
                )
            }
            let updatedPages = pages + newPages
            try persistRegistry(
                folders: folders,
                documents: updatedMetadata,
                pages: updatedPages
            )
            documentMetadata = updatedMetadata
            pages = updatedPages
            pdfCache.merge(loadedPDFs) { _, new in new }
            openDocumentIDs.append(contentsOf: newMetadata.map(\.id))
            rebuildWorkspaceDocuments()
            persistOpenDocuments()
            signalLocalCloudChange()
            return newMetadata.compactMap { document(withID: $0.id) }
        } catch {
            for url in createdURLs {
                try? fileManager.removeItem(at: url)
            }
            throw error
        }
    }

    func pdfDocument(for documentID: String) -> PDFDocument? {
        if let cachedDocument = pdfCache[documentID] {
            return cachedDocument
        }
        guard let workspaceDocument = document(withID: documentID) else { return nil }
        let pdfDocument = PDFDocument(url: workspaceDocument.fileURL)
        pdfCache[documentID] = pdfDocument
        return pdfDocument
    }

    func pageCount(for documentID: String) -> Int {
        pdfDocument(for: documentID)?.pageCount ?? 0
    }

    func page(at index: Int, in documentID: String) -> PDFPage? {
        guard index >= 0, index < pageCount(for: documentID) else { return nil }
        return pdfDocument(for: documentID)?.page(at: index)
    }

    func searchPDF(
        _ query: String,
        in documentID: String,
        limit: Int = 250
    ) -> [PDFTextSearchResult] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty,
              let document = pdfDocument(for: documentID) else { return [] }
        return document.findString(normalizedQuery, withOptions: [.caseInsensitive])
            .prefix(max(limit, 1))
            .enumerated()
            .compactMap { offset, selection in
                guard let page = selection.pages.first else { return nil }
                let pageIndex = document.index(for: page)
                let lineSelection = selection.copy() as? PDFSelection
                lineSelection?.extendForLineBoundaries()
                let excerpt = (lineSelection?.string ?? selection.string ?? normalizedQuery)
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return PDFTextSearchResult(
                    id: "\(pageIndex)-\(offset)",
                    pageIndex: pageIndex,
                    excerpt: excerpt,
                    pageBounds: selection.bounds(for: page)
                )
            }
    }

    func exportFlattenedPDF(documentID: String) throws -> URL {
        guard let document = document(withID: documentID) else {
            throw LibraryStoreError.documentNotFound(documentID)
        }
        guard flushAllPendingSaves() else {
            throw PDFWorkspaceError.cannotAccess("仍有批注未能保存")
        }
        let documentPages = pages(in: documentID)
        guard !documentPages.isEmpty else { throw PDFWorkspaceError.invalidPDF(document.title) }

        let firstSize = exportBounds(forPage: 0, in: documentID).size
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: firstSize))
        let data = renderer.pdfData { rendererContext in
            for pageIndex in documentPages.indices {
                let bounds = exportBounds(forPage: pageIndex, in: documentID)
                rendererContext.beginPage(
                    withBounds: CGRect(origin: .zero, size: bounds.size),
                    pageInfo: [:]
                )
                renderFlattenedPage(
                    documentID: documentID,
                    pageIndex: pageIndex,
                    bounds: bounds,
                    context: rendererContext.cgContext
                )
            }
        }
        let url = try makeExportURL(title: document.title, suffix: "批注", extension: "pdf")
        try data.write(to: url, options: .atomic)
        return url
    }

    func exportPageImages(documentID: String) throws -> [URL] {
        guard let document = document(withID: documentID) else {
            throw LibraryStoreError.documentNotFound(documentID)
        }
        guard flushAllPendingSaves() else {
            throw PDFWorkspaceError.cannotAccess("仍有批注未能保存")
        }
        let documentPages = pages(in: documentID)
        guard !documentPages.isEmpty else { throw PDFWorkspaceError.invalidPDF(document.title) }

        return try documentPages.indices.map { pageIndex in
            let bounds = exportBounds(forPage: pageIndex, in: documentID)
            let format = UIGraphicsImageRendererFormat()
            format.scale = document.kind == .canvas ? min(2, 4096 / max(bounds.width, bounds.height)) : 2
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
            let image = renderer.image { rendererContext in
                renderFlattenedPage(
                    documentID: documentID,
                    pageIndex: pageIndex,
                    bounds: bounds,
                    context: rendererContext.cgContext
                )
            }
            guard let data = image.pngData() else {
                throw PDFWorkspaceError.cannotAccess("第 \(pageIndex + 1) 页图片")
            }
            let url = try makeExportURL(
                title: document.title,
                suffix: String(format: "第%03d页", pageIndex + 1),
                extension: "png"
            )
            try data.write(to: url, options: .atomic)
            return url
        }
    }

    func exportEditableDocumentPackage(documentID: String) throws -> URL {
        guard let document = document(withID: documentID) else {
            throw LibraryStoreError.documentNotFound(documentID)
        }
        let data = try editableDocumentPackageData(documentID: documentID)
        let url = try makeExportURL(title: document.title, suffix: "可编辑", extension: "tiyinote")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Produces one self-contained native document snapshot without leaving a temporary export
    /// behind. Automatic backup uses this entry point so a long-running library does not slowly
    /// fill its private Exports directory.
    func editableDocumentPackageData(documentID: String) throws -> Data {
        guard document(withID: documentID) != nil,
              let metadata = documentMetadata.first(where: { $0.id == documentID }),
              let sourceURL = fileURL(for: metadata) else {
            throw LibraryStoreError.documentNotFound(documentID)
        }
        guard flushAllPendingSaves() else {
            throw PDFWorkspaceError.cannotAccess("仍有批注未能保存")
        }
        let documentPages = pages(in: documentID)
        let archivedPages = deletedPages(in: documentID)
        let assets = (documentPages + archivedPages).map { page in
            EditableDocumentPageAssets(
                pageID: page.id,
                backgroundPDFData: try? Data(
                    contentsOf: pageBackgroundURL(forPageID: page.id, in: documentID)
                ),
                drawingData: try? Data(
                    contentsOf: drawingURL(forPageID: page.id, in: documentID)
                ),
                elementsData: try? Data(
                    contentsOf: imageAnnotationsURL(forPageID: page.id, in: documentID)
                ),
                operations: loadCollaborationOperations(forPageID: page.id, in: documentID)
            )
        }
        let package = EditableDocumentPackage(
            document: metadata,
            pages: documentPages,
            deletedPages: archivedPages,
            sourcePDFData: try Data(contentsOf: sourceURL),
            pageAssets: assets,
            documentOperations: loadCollaborationOperations(
                forPageID: CollaborationReservedID.documentMetadata,
                in: documentID
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(package)
    }

    @discardableResult
    func importEditableDocumentPackage(
        from sourceURL: URL,
        into parentID: String? = nil
    ) throws -> PDFWorkspaceDocument {
        try validateParentFolder(parentID)
        let hasSecurityAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if hasSecurityAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        let resourceValues = try? sourceURL.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = resourceValues?.fileSize, fileSize > 2_000_000_000 {
            throw LibraryStoreError.invalidSnapshot("可编辑包超过 2 GB")
        }
        let packageData: Data
        do {
            packageData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        } catch {
            throw PDFWorkspaceError.cannotAccess(sourceURL.lastPathComponent)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let package: EditableDocumentPackage
        do {
            package = try decoder.decode(EditableDocumentPackage.self, from: packageData)
        } catch {
            throw LibraryStoreError.invalidSnapshot("无法解析 .tiyinote 可编辑包")
        }
        try validateEditableDocumentPackage(package)

        let oldDocumentID = package.document.id
        let occupiedEntityIDs = Set(folders.map(\.id))
            .union(documentMetadata.map(\.id))
            .union(pages.map(\.id))
            .union(deletionTombstones.values.map(\.reference.entityID))
        let newDocumentID = occupiedEntityIDs.contains(oldDocumentID)
            ? UUID().uuidString.lowercased()
            : oldDocumentID
        let existingPageIDs = Set(pages.map(\.id))
        var pageIDMap: [String: String] = [:]
        let allPackagePages = package.pages + package.deletedPages
        for page in allPackagePages {
            pageIDMap[page.id] = newDocumentID != oldDocumentID || existingPageIDs.contains(page.id)
                ? UUID().uuidString.lowercased()
                : page.id
        }

        let importedOperations = package.documentOperations
            + package.pageAssets.flatMap(\.operations)
        let existingOperationIDs = Set(exportCollaborationOperations().map(\.id))
        let rewritesHistory = newDocumentID != oldDocumentID
            || pageIDMap.contains(where: { $0.key != $0.value })
            || !existingOperationIDs.isDisjoint(with: importedOperations.map(\.id))
        let actorMap = importedActorMap(
            operations: importedOperations,
            newDocumentID: newDocumentID,
            rewritesHistory: rewritesHistory
        )
        let operationIDMap = rewritesHistory
            ? Dictionary(uniqueKeysWithValues: importedOperations.map {
                ($0.id, UUID().uuidString.lowercased())
            })
            : [:]
        let transformedOperations = try importedOperations.map {
            try transformedImportedOperation(
                $0,
                documentID: newDocumentID,
                pageIDMap: pageIDMap,
                actorMap: actorMap,
                operationIDMap: operationIDMap,
                rewritesHistory: rewritesHistory
            )
        }
        let transformedPageOperations = Dictionary(
            grouping: transformedOperations.filter {
                $0.pageID != CollaborationReservedID.documentMetadata
            },
            by: \.pageID
        )
        var transformedDocumentOperations = transformedOperations.filter {
            $0.pageID == CollaborationReservedID.documentMetadata
        }

        let orderedPackagePages = package.pages.sorted {
            if $0.position != $1.position { return $0.position < $1.position }
            return $0.id < $1.id
        }
        let importedPages = orderedPackagePages.enumerated().map { index, page in
            LibraryPage(
                id: pageIDMap[page.id]!,
                documentID: newDocumentID,
                orderIndex: index,
                position: page.position,
                createdAt: page.createdAt,
                modifiedAt: page.modifiedAt,
                width: page.width,
                height: page.height,
                rotation: normalizedPageRotation(page.rotation),
                sourceKind: page.sourceKind,
                backgroundStyle: page.backgroundStyle,
                backgroundColor: page.backgroundColor,
                isBookmarked: page.isBookmarked
            )
        }
        let assetsByOldPageID = Dictionary(
            uniqueKeysWithValues: package.pageAssets.map { ($0.pageID, $0) }
        )
        let targetFileName = "\(newDocumentID).pdf"
        let targetPDFURL = importsDirectory.appendingPathComponent(targetFileName)
        var affectedURLs = [registryURL, collaborationClockURL, targetPDFURL]
        for page in allPackagePages {
            let pageID = pageIDMap[page.id]!
            affectedURLs.append(pageBackgroundURL(forPageID: pageID, in: newDocumentID))
            affectedURLs.append(drawingURL(forPageID: pageID, in: newDocumentID))
            affectedURLs.append(imageAnnotationsURL(forPageID: pageID, in: newDocumentID))
            affectedURLs.append(
                collaborationOperationsURL(forPageID: pageID, in: newDocumentID)
            )
        }
        affectedURLs.append(
            collaborationOperationsURL(
                forPageID: CollaborationReservedID.documentMetadata,
                in: newDocumentID
            )
        )
        let transaction = try beginWorkspaceTransaction(
            kind: "import-editable-document",
            affectedURLs: affectedURLs
        )

        do {
            for operation in transformedOperations { collaborationClock.observe(operation.stamp) }
            let placementStamp = collaborationClock.nextStamp()
            let title = uniqueRestoredTitle(
                try normalizedTitle(package.document.title),
                parentID: parentID,
                excludingID: newDocumentID,
                folders: folders,
                documents: documentMetadata,
                isDocument: true
            )
            let titleStamp = collaborationClock.nextStamp()
            transformedDocumentOperations.append(
                CollaborationOperation(
                    workspaceID: "personal-library",
                    documentID: newDocumentID,
                    pageID: CollaborationReservedID.documentMetadata,
                    stamp: titleStamp,
                    payload: .metadataSet(
                        field: "document.title",
                        value: try encodedCollaborationValue(title)
                    )
                )
            )
            let importedMetadata = LibraryDocumentMetadata(
                id: newDocumentID,
                title: title,
                parentID: parentID,
                fileName: targetFileName,
                isBundled: false,
                createdAt: package.document.createdAt,
                modifiedAt: max(titleStamp.createdAt, placementStamp.createdAt),
                contentModifiedAt: titleStamp.createdAt,
                kind: package.document.kind,
                canvasBackgroundStyle: package.document.canvasBackgroundStyle,
                canvasBackgroundColor: package.document.canvasBackgroundColor,
                isFavorite: package.document.isFavorite,
                trashedAt: nil,
                parentRevision: placementStamp,
                favoriteRevision: placementStamp,
                trashRevision: placementStamp
            )

            try package.sourcePDFData.write(to: targetPDFURL, options: .atomic)
            for oldPage in allPackagePages {
                let importedPageID = pageIDMap[oldPage.id]!
                guard let assets = assetsByOldPageID[oldPage.id],
                      let backgroundData = assets.backgroundPDFData else {
                    throw LibraryStoreError.invalidSnapshot("页面背景资产缺失")
                }
                try backgroundData.write(
                    to: pageBackgroundURL(
                        forPageID: importedPageID,
                        in: newDocumentID
                    ),
                    options: .atomic
                )
                if let drawingData = assets.drawingData {
                    try drawingData.write(
                        to: drawingURL(forPageID: importedPageID, in: newDocumentID),
                        options: .atomic
                    )
                }
                if let elementsData = assets.elementsData {
                    try elementsData.write(
                        to: imageAnnotationsURL(
                            forPageID: importedPageID,
                            in: newDocumentID
                        ),
                        options: .atomic
                    )
                }
                try saveCollaborationOperations(
                    transformedPageOperations[importedPageID] ?? [],
                    forPageID: importedPageID,
                    in: newDocumentID
                )
            }
            try saveCollaborationOperations(
                transformedDocumentOperations,
                forPageID: CollaborationReservedID.documentMetadata,
                in: newDocumentID
            )

            documentMetadata.append(importedMetadata)
            pages.append(contentsOf: importedPages)
            try rebuildPDFDocumentFromPageBackgrounds(documentID: newDocumentID)
            try persistRegistry(
                folders: folders,
                documents: documentMetadata,
                pages: pages
            )
            try persistCollaborationClock()
            try commitWorkspaceTransaction(transaction)
            rebuildWorkspaceDocuments()
            openDocumentIDs.append(newDocumentID)
            persistOpenDocuments()
            signalLocalCloudChange()
            guard let result = document(withID: newDocumentID) else {
                throw LibraryStoreError.documentNotFound(newDocumentID)
            }
            return result
        } catch {
            rollbackWorkspaceTransaction(transaction)
            throw error
        }
    }

    private func validateEditableDocumentPackage(_ package: EditableDocumentPackage) throws {
        guard package.schemaVersion > 0,
              package.schemaVersion <= EditableDocumentPackage.currentSchemaVersion else {
            throw LibraryStoreError.invalidSnapshot(
                "不支持的 .tiyinote 版本 \(package.schemaVersion)"
            )
        }
        guard isSafePathComponent(package.document.id),
              isSafePathComponent(package.document.fileName),
              !package.pages.isEmpty,
              package.pages.count + package.deletedPages.count <= 10_000,
              let sourcePDF = PDFDocument(data: package.sourcePDFData),
              sourcePDF.pageCount == package.pages.count else {
            throw LibraryStoreError.invalidSnapshot("文稿身份、PDF 或页数无效")
        }
        _ = try normalizedTitle(package.document.title)

        let allPackagePages = package.pages + package.deletedPages
        let deletedPageIDs = Set(package.deletedPages.map(\.id))
        let pageIDs = allPackagePages.map(\.id)
        guard Set(pageIDs).count == pageIDs.count else {
            throw LibraryStoreError.invalidSnapshot("可编辑包包含重复页面 ID")
        }
        for page in allPackagePages {
            guard page.documentID == package.document.id,
                  isSafePathComponent(page.id),
                  page.orderIndex >= 0,
                  page.width.isFinite,
                  page.height.isFinite,
                  page.width > 0,
                  page.height > 0,
                  page.width <= 100_000,
                  page.height <= 100_000,
                  !page.position.components.isEmpty,
                  page.rotation % 90 == 0 else {
                throw LibraryStoreError.invalidSnapshot("页面元数据无效")
            }
        }

        let assetPageIDs = package.pageAssets.map(\.pageID)
        guard Set(assetPageIDs).count == assetPageIDs.count,
              Set(assetPageIDs) == Set(pageIDs) else {
            throw LibraryStoreError.invalidSnapshot("页面资产索引不完整或重复")
        }
        for assets in package.pageAssets {
            guard let backgroundData = assets.backgroundPDFData,
                  let background = PDFDocument(data: backgroundData),
                  background.pageCount == 1 else {
                throw LibraryStoreError.invalidSnapshot("页面 \(assets.pageID) 背景无效")
            }
            if let drawingData = assets.drawingData,
               (try? PKDrawing(data: drawingData)) == nil {
                throw LibraryStoreError.invalidSnapshot("页面 \(assets.pageID) 笔迹无效")
            }
            if let elementsData = assets.elementsData {
                guard let archive = try? JSONDecoder().decode(
                    CanvasPageElementsArchive.self,
                    from: elementsData
                ),
                archive.schemaVersion > 0,
                archive.schemaVersion <= CanvasPageElementsArchive.currentSchemaVersion,
                Set(archive.elements.map(\.id)).count == archive.elements.count,
                archive.elements.allSatisfy(isValidImportedElement) else {
                    throw LibraryStoreError.invalidSnapshot("页面 \(assets.pageID) 对象数据无效")
                }
            }
            guard assets.operations.allSatisfy({
                $0.documentID == package.document.id && $0.pageID == assets.pageID
            }) else {
                throw LibraryStoreError.invalidSnapshot("页面 operation 引用了其他文稿或页面")
            }
            if deletedPageIDs.contains(assets.pageID) {
                let state = CollaborationMergeEngine.materialize(assets.operations)
                guard state.isDeleted,
                      let data = state.metadata["pageArchive"],
                      let archive = try? JSONDecoder().decode(LibraryPage.self, from: data),
                      archive.id == assets.pageID,
                      archive.documentID == package.document.id else {
                    throw LibraryStoreError.invalidSnapshot("回收站页面的恢复数据不完整")
                }
            }
        }
        guard package.documentOperations.allSatisfy({
            $0.documentID == package.document.id
                && $0.pageID == CollaborationReservedID.documentMetadata
        }) else {
            throw LibraryStoreError.invalidSnapshot("文稿 operation 的作用域无效")
        }

        let operations = package.documentOperations + package.pageAssets.flatMap(\.operations)
        guard Set(operations.map(\.id)).count == operations.count else {
            throw LibraryStoreError.invalidSnapshot("operation ID 重复")
        }
        for operation in operations {
            guard !operation.id.isEmpty,
                  !operation.stamp.dot.actorID.isEmpty,
                  operation.stamp.dot.counter > 0 else {
                throw LibraryStoreError.invalidSnapshot("operation 因果身份无效")
            }
            try validateImportedOperationPayload(operation.payload, operation: operation)
        }
    }

    private func isValidImportedElement(_ element: CanvasPageElement) -> Bool {
        let bounds = element.logicalBounds
        guard bounds.minX.isFinite,
              bounds.minY.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width > 0,
              bounds.height > 0,
              element.rotationRadians.isFinite else { return false }
        switch element.payload {
        case .text(let text):
            return text.fontSize.isFinite && text.fontSize > 0 && text.fontSize <= 1_000
        case .image(let image):
            return image.opacity.isFinite
                && (0...1).contains(image.opacity)
                && UIImage(data: image.pngData) != nil
        case .shape(let shape):
            return shape.lineWidth.isFinite && shape.lineWidth > 0 && shape.lineWidth <= 1_000
        }
    }

    private func validateImportedOperationPayload(
        _ payload: CollaborationOperationPayload,
        operation: CollaborationOperation
    ) throws {
        switch payload {
        case .strokeUpsert(let stroke):
            guard !stroke.id.isEmpty, (try? PKDrawing(data: stroke.drawingData)) != nil else {
                throw LibraryStoreError.invalidSnapshot("operation 笔迹数据无效")
            }
        case .elementUpsert(let element):
            guard isValidImportedElement(element) else {
                throw LibraryStoreError.invalidSnapshot("operation 对象数据无效")
            }
        case .elementPatch(let element, let fields):
            guard !fields.isEmpty, isValidImportedElement(element) else {
                throw LibraryStoreError.invalidSnapshot("operation 对象补丁无效")
            }
        case .metadataSet(let field, let value) where field == "pageArchive":
            guard let value,
                  let page = try? JSONDecoder().decode(LibraryPage.self, from: value),
                  page.documentID == operation.documentID,
                  page.id == operation.pageID else {
                throw LibraryStoreError.invalidSnapshot("operation 页面归档无效")
            }
        case .pagePosition,
             .pageDelete,
             .pageRestore,
             .metadataSet,
             .strokeDelete,
             .elementDelete:
            break
        }
    }

    private func importedActorMap(
        operations: [CollaborationOperation],
        newDocumentID: String,
        rewritesHistory: Bool
    ) -> [String: String] {
        guard rewritesHistory else { return [:] }
        var actorIDs = Set<String>()
        for operation in operations {
            actorIDs.insert(operation.stamp.dot.actorID)
            actorIDs.formUnion(operation.stamp.context.counters.keys)
        }
        let prefix = String(newDocumentID.prefix(12))
        return Dictionary(uniqueKeysWithValues: actorIDs.sorted().enumerated().map {
            ($0.element, "import:\(prefix):\($0.offset)")
        })
    }

    private func transformedImportedOperation(
        _ operation: CollaborationOperation,
        documentID: String,
        pageIDMap: [String: String],
        actorMap: [String: String],
        operationIDMap: [String: String],
        rewritesHistory: Bool
    ) throws -> CollaborationOperation {
        guard rewritesHistory else { return operation }
        let pageID = operation.pageID == CollaborationReservedID.documentMetadata
            ? CollaborationReservedID.documentMetadata
            : (pageIDMap[operation.pageID] ?? operation.pageID)
        let mappedContext = CollaborationVersionVector(
            counters: Dictionary(
                uniqueKeysWithValues: operation.stamp.context.counters.map { actorID, counter in
                    (actorMap[actorID] ?? actorID, counter)
                }
            )
        )
        let stamp = CollaborationStamp(
            dot: CollaborationDot(
                actorID: actorMap[operation.stamp.dot.actorID]
                    ?? operation.stamp.dot.actorID,
                counter: operation.stamp.dot.counter
            ),
            context: mappedContext,
            lamport: operation.stamp.lamport,
            operationID: operationIDMap[operation.id] ?? UUID().uuidString.lowercased(),
            createdAt: operation.stamp.createdAt
        )
        let payload: CollaborationOperationPayload
        if case .metadataSet(let field, let value) = operation.payload,
           field == "pageArchive",
           let value,
           let archived = try? JSONDecoder().decode(LibraryPage.self, from: value) {
            let transformedPage = LibraryPage(
                id: pageIDMap[archived.id] ?? archived.id,
                documentID: documentID,
                orderIndex: archived.orderIndex,
                position: archived.position,
                createdAt: archived.createdAt,
                modifiedAt: archived.modifiedAt,
                width: archived.width,
                height: archived.height,
                rotation: normalizedPageRotation(archived.rotation),
                sourceKind: archived.sourceKind,
                backgroundStyle: archived.backgroundStyle,
                backgroundColor: archived.backgroundColor,
                isBookmarked: archived.isBookmarked
            )
            payload = .metadataSet(
                field: field,
                value: try encodedCollaborationValue(transformedPage)
            )
        } else {
            payload = operation.payload
        }
        return CollaborationOperation(
            workspaceID: operation.workspaceID,
            documentID: documentID,
            pageID: pageID,
            stamp: stamp,
            payload: payload
        )
    }

    func collaborationConflicts(in documentID: String) -> [CollaborationConflictItem] {
        let directory = documentDrawingsDirectory(for: documentID, createIfNeeded: false)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .filter { $0.lastPathComponent.hasSuffix(".operations.json") }
            .flatMap { url -> [CollaborationConflictItem] in
                let operations = loadCollaborationOperations(at: url)
                guard let first = operations.first,
                      first.documentID == documentID else { return [] }
                let state = CollaborationMergeEngine.materialize(operations)
                return state.conflicts.compactMap { conflict in
                    guard state.metadata["resolvedConflict:\(conflict.id)"] == nil else { return nil }
                    return CollaborationConflictItem(
                        documentID: documentID,
                        pageID: first.pageID,
                        pageIndex: pageIndex(for: first.pageID, in: documentID),
                        conflict: conflict
                    )
                }
            }
            .sorted {
                if $0.pageIndex != $1.pageIndex {
                    return ($0.pageIndex ?? .max) < ($1.pageIndex ?? .max)
                }
                if $0.pageID != $1.pageID { return $0.pageID < $1.pageID }
                return $0.conflict.id < $1.conflict.id
            }
    }

    func restoreCollaborationConflict(_ item: CollaborationConflictItem) throws {
        try resolveCollaborationConflict(item, restoresCopy: true)
    }

    func dismissCollaborationConflict(_ item: CollaborationConflictItem) throws {
        try resolveCollaborationConflict(item, restoresCopy: false)
    }

    private func resolveCollaborationConflict(
        _ item: CollaborationConflictItem,
        restoresCopy: Bool
    ) throws {
        var operations = loadCollaborationOperations(
            forPageID: item.pageID,
            in: item.documentID
        )
        let state = CollaborationMergeEngine.materialize(operations)
        guard let conflict = state.conflicts.first(where: { $0.id == item.conflict.id }),
              state.metadata["resolvedConflict:\(conflict.id)"] == nil else { return }
        for operation in operations { collaborationClock.observe(operation.stamp) }

        if restoresCopy {
            let restoredPayload: CollaborationOperationPayload?
            switch conflict.payload {
            case .strokeUpsert(let stroke):
                restoredPayload = .strokeUpsert(
                    CollaborationInkStroke(
                        id: UUID().uuidString.lowercased(),
                        drawingData: stroke.drawingData,
                        zIndex: stroke.zIndex
                    )
                )
            case .elementUpsert(let element), .elementPatch(let element, _):
                restoredPayload = .elementUpsert(
                    CanvasPageElement(
                        id: UUID(),
                        logicalBounds: element.logicalBounds,
                        rotationRadians: element.rotationRadians,
                        zIndex: element.zIndex,
                        isLocked: element.isLocked,
                        groupID: element.groupID,
                        payload: element.payload
                    )
                )
            case .metadataSet(let field, let value):
                restoredPayload = .metadataSet(field: field, value: value)
            case .pagePosition(let position):
                restoredPayload = .pagePosition(position)
            case .pageDelete, .pageRestore:
                restoredPayload = .pageRestore
            case .strokeDelete, .elementDelete:
                restoredPayload = nil
            }
            if let restoredPayload {
                operations.append(
                    CollaborationOperation(
                        workspaceID: "personal-library",
                        documentID: item.documentID,
                        pageID: item.pageID,
                        stamp: collaborationClock.nextStamp(),
                        payload: restoredPayload
                    )
                )
            }
        }

        operations.append(
            CollaborationOperation(
                workspaceID: "personal-library",
                documentID: item.documentID,
                pageID: item.pageID,
                stamp: collaborationClock.nextStamp(),
                payload: .metadataSet(
                    field: "resolvedConflict:\(conflict.id)",
                    value: Data([1])
                )
            )
        )
        try saveCollaborationOperations(
            operations,
            forPageID: item.pageID,
            in: item.documentID
        )
        try persistCollaborationClock()

        let resolvedState = CollaborationMergeEngine.materialize(operations)
        if item.pageID == CollaborationReservedID.documentMetadata {
            if let titleData = resolvedState.metadata["document.title"],
               let title = try? JSONDecoder().decode(String.self, from: titleData),
               let index = documentMetadata.firstIndex(where: { $0.id == item.documentID }) {
                let resolvedAt = operations.map(\.stamp.createdAt).max() ?? Date()
                documentMetadata[index].title = title
                documentMetadata[index].contentModifiedAt = max(
                    documentMetadata[index].contentModifiedAt,
                    resolvedAt
                )
                documentMetadata[index].modifiedAt = max(
                    documentMetadata[index].modifiedAt,
                    resolvedAt
                )
                try persistRegistry(folders: folders, documents: documentMetadata, pages: pages)
                rebuildWorkspaceDocuments()
            }
            signalLocalCloudChange()
            return
        }
        if !resolvedState.isDeleted,
           !pages.contains(where: { $0.id == item.pageID && $0.documentID == item.documentID }),
           let pageData = resolvedState.metadata["pageArchive"],
           var page = try? JSONDecoder().decode(LibraryPage.self, from: pageData) {
            if let position = resolvedState.position { page.position = position }
            try ensureRecoveryBackground(for: page)
            pages.append(page)
            try persistRegistry(folders: folders, documents: documentMetadata, pages: pages)
        }
        if !resolvedState.isDeleted {
            try materializeCollaborationDrawing(
                from: operations,
                forPageID: item.pageID,
                in: item.documentID
            )
            guard let elementsData = encodedPageElements(Array(resolvedState.elements.values)) else {
                throw LibraryStoreError.cannotApplyAsset(item.pageID)
            }
            try elementsData.write(
                to: imageAnnotationsURL(forPageID: item.pageID, in: item.documentID),
                options: .atomic
            )
        }
        bumpPageAssetRevision(forPageID: item.pageID, in: item.documentID)
        signalLocalCloudChange()
    }

    /// Practice keeps its original question PDFs as backgrounds while adopting the same camera,
    /// thumbnails and uncropped exports as a canvas. Existing page IDs, ink and objects stay valid.
    func enableUnboundedCanvas(for documentID: String) throws {
        try requireEditableSharedDocument(documentID)
        guard let index = documentMetadata.firstIndex(where: { $0.id == documentID }) else {
            throw LibraryStoreError.documentNotFound(documentID)
        }
        guard documentMetadata[index].kind != .canvas else { return }
        var updatedMetadata = documentMetadata
        updatedMetadata[index].kind = .canvas
        updatedMetadata[index].canvasBackgroundStyle = .blank
        updatedMetadata[index].canvasBackgroundColor = .white
        updatedMetadata[index].modifiedAt = Date()
        updatedMetadata[index].contentModifiedAt = updatedMetadata[index].modifiedAt
        try persistRegistry(folders: folders, documents: updatedMetadata)
        documentMetadata = updatedMetadata
        rebuildWorkspaceDocuments()
        thumbnailCache.removeAll()
        signalLocalCloudChange()
    }

    func canvasViewport(forPageID pageID: String, in documentID: String, referenceSize: CGSize) -> CanvasViewport {
        let fallback = CanvasViewport(referenceSize: referenceSize)
        guard let data = userDefaults.data(forKey: "canvas.viewport.v1.\(documentID).\(pageID)"),
              var viewport = try? JSONDecoder().decode(CanvasViewport.self, from: data),
              viewport.center.x.isFinite, viewport.center.y.isFinite,
              viewport.zoomScale.isFinite else { return fallback }
        viewport.zoomScale = min(max(viewport.zoomScale, CanvasViewport.minimumZoomScale), CanvasViewport.maximumZoomScale)
        return viewport
    }

    func saveCanvasViewport(_ viewport: CanvasViewport, forPageID pageID: String, in documentID: String) {
        guard let data = try? JSONEncoder().encode(viewport) else { return }
        userDefaults.set(data, forKey: "canvas.viewport.v1.\(documentID).\(pageID)")
    }

    func pageSize(at index: Int, in documentID: String) -> CGSize {
        guard let page = page(at: index, in: documentID) else {
            return CGSize(width: 595, height: 842)
        }
        let bounds = page.bounds(for: .mediaBox)
        let rotation = abs(page.rotation) % 180
        return rotation == 90
            ? CGSize(width: bounds.height, height: bounds.width)
            : bounds.size
    }

    func thumbnail(
        forPage index: Int,
        in documentID: String,
        size: CGSize
    ) -> UIImage? {
        let cacheKey = "\(documentID)#\(index)#\(Int(size.width))x\(Int(size.height))"
        if let cachedImage = thumbnailCache[cacheKey] {
            return cachedImage
        }
        guard let page = page(at: index, in: documentID) else { return nil }
        let image: UIImage
        if document(withID: documentID)?.kind == .canvas {
            let bounds = exportBounds(forPage: index, in: documentID)
            let scale = min(size.width / bounds.width, size.height / bounds.height)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            format.opaque = true
            image = UIGraphicsImageRenderer(
                size: CGSize(width: bounds.width * scale, height: bounds.height * scale),
                format: format
            ).image { rendererContext in
                rendererContext.cgContext.scaleBy(x: scale, y: scale)
                renderFlattenedPage(
                    documentID: documentID, pageIndex: index,
                    bounds: bounds, context: rendererContext.cgContext
                )
            }
        } else {
            image = page.thumbnail(of: size, for: .mediaBox)
        }
        thumbnailCache[cacheKey] = image
        return image
    }

    func thumbnail(forDeletedPage page: LibraryPage, size: CGSize) -> UIImage? {
        let cacheKey = "deleted#\(page.documentID)#\(page.id)#\(Int(size.width))x\(Int(size.height))"
        if let cachedImage = thumbnailCache[cacheKey] { return cachedImage }
        let url = pageBackgroundURL(forPageID: page.id, in: page.documentID)
        guard let pdfPage = PDFDocument(url: url)?.page(at: 0) else { return nil }
        let image = pdfPage.thumbnail(of: size, for: .mediaBox)
        thumbnailCache[cacheKey] = image
        return image
    }

    func loadDrawing(forPage pageIndex: Int, in documentID: String) -> PKDrawing {
        let drawingURL = drawingURL(forPage: pageIndex, in: documentID)
        let storedDrawing: PKDrawing
        if let data = try? Data(contentsOf: drawingURL),
           let drawing = try? PKDrawing(data: data) {
            storedDrawing = drawing
        } else {
            storedDrawing = PKDrawing()
        }

        guard let pageID = pageID(at: pageIndex, in: documentID) else {
            return storedDrawing
        }
        let operations = loadCollaborationOperations(forPageID: pageID, in: documentID)
        let hasDrawingHistory = operations.contains { operation in
            switch operation.payload {
            case .strokeUpsert, .strokeDelete: true
            default: false
            }
        }
        guard hasDrawingHistory else { return storedDrawing }

        // Once a deep-idle save has committed its collaboration events, replaying them keeps the
        // page recoverable even if the process exits before the materialized drawing asset lands.
        return (try? PKDrawing(data: collaborationDrawingData(from: operations)))
            ?? storedDrawing
    }

    func loadImageAnnotations(
        forPage pageIndex: Int,
        in documentID: String
    ) -> [CanvasImageAnnotation] {
        loadPageElements(forPage: pageIndex, in: documentID)
            .compactMap(CanvasImageAnnotation.init(pageElement:))
    }

    func loadPageElements(
        forPage pageIndex: Int,
        in documentID: String
    ) -> [CanvasPageElement] {
        if let pageID = pageID(at: pageIndex, in: documentID) {
            let operations = loadCollaborationOperations(forPageID: pageID, in: documentID)
            let hasElementHistory = operations.contains { operation in
                switch operation.payload {
                case .elementUpsert, .elementPatch, .elementDelete: true
                default: false
                }
            }
            if hasElementHistory {
                return Array(CollaborationMergeEngine.materialize(operations).elements.values)
                    .sorted(by: pageElementSort)
            }
        }

        let url = imageAnnotationsURL(forPage: pageIndex, in: documentID)
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let archive = try? JSONDecoder().decode(CanvasPageElementsArchive.self, from: data),
           archive.schemaVersion > 0,
           archive.schemaVersion <= CanvasPageElementsArchive.currentSchemaVersion {
            return archive.elements.sorted(by: pageElementSort)
        }

        // v1 stored only images as a bare JSON array. Decode it lazily and rewrite it as the
        // object archive on the next edit, preserving existing users' annotations.
        guard let legacy = try? JSONDecoder().decode(
            [StoredCanvasImageAnnotation].self,
            from: data
        ) else { return [] }
        return legacy.compactMap(\.annotation).compactMap(\.pageElement)
    }

    nonisolated static func prepareDrawingPersistence(
        drawing: PKDrawing,
        baseDrawing: PKDrawing,
        assumesOnlyAppendedStrokes: Bool
    ) -> PreparedDrawingPersistence? {
        guard !Task.isCancelled else { return nil }
        if assumesOnlyAppendedStrokes,
           drawing.strokes.count >= baseDrawing.strokes.count {
            // The hot autosave path serializes only the newly appended strokes. Calling
            // `drawing.dataRepresentation()` here used to encode every old stroke again and that
            // monolithic call cannot be cancelled when the Pencil returns to the screen.
            var appendedStrokeData: [Data] = []
            appendedStrokeData.reserveCapacity(drawing.strokes.count - baseDrawing.strokes.count)
            for stroke in drawing.strokes.dropFirst(baseDrawing.strokes.count) {
                guard !Task.isCancelled else { return nil }
                appendedStrokeData.append(PKDrawing(strokes: [stroke]).dataRepresentation())
            }
            return PreparedDrawingPersistence(
                drawingData: nil,
                appendedStrokeData: appendedStrokeData,
                drawingStrokes: nil,
                baseStrokes: nil
            )
        }

        let drawingData = drawing.dataRepresentation()
        guard !Task.isCancelled else { return nil }
        func prepareStroke(_ stroke: PKStroke) -> PreparedDrawingStrokePersistence {
            let data = PKDrawing(strokes: [stroke]).dataRepresentation()
            return PreparedDrawingStrokePersistence(
                data: data,
                exactFingerprint: Self.collaborationStrokeFingerprint(data),
                stableFingerprint: Self.collaborationStableStrokeFingerprint(data)
            )
        }
        var drawingStrokes: [PreparedDrawingStrokePersistence] = []
        drawingStrokes.reserveCapacity(drawing.strokes.count)
        for stroke in drawing.strokes {
            guard !Task.isCancelled else { return nil }
            drawingStrokes.append(prepareStroke(stroke))
        }
        var baseStrokes: [PreparedDrawingStrokePersistence] = []
        baseStrokes.reserveCapacity(baseDrawing.strokes.count)
        for stroke in baseDrawing.strokes {
            guard !Task.isCancelled else { return nil }
            baseStrokes.append(prepareStroke(stroke))
        }
        return PreparedDrawingPersistence(
            drawingData: drawingData,
            appendedStrokeData: nil,
            drawingStrokes: drawingStrokes,
            baseStrokes: baseStrokes
        )
    }

    /// Performs the expensive collaboration diff off MainActor. If a remote operation lands while
    /// the worker is running, the immutable snapshot is discarded and rebuilt. Pencil-down cancels
    /// the caller before any result is installed, so resuming handwriting never waits for this work.
    func schedulePreparedDrawingSaveAfterIdle(
        _ drawing: PKDrawing,
        replacing baseDrawing: PKDrawing,
        causalContext: CollaborationVersionVector,
        assumesOnlyAppendedStrokes: Bool,
        preparedPersistence: PreparedDrawingPersistence,
        forPage pageIndex: Int,
        in documentID: String
    ) async -> CollaborationVersionVector? {
        guard !readOnlySharedDocumentIDs.contains(documentID) else {
            saveState = .failed(LibraryStoreError.readOnlySharedDocument.errorDescription ?? "只读")
            return causalContext
        }

        while !Task.isCancelled, !isDrawingInteractionActive {
            let quietTimeRemaining = drawingPersistenceQuietTimeRemaining()
            if quietTimeRemaining > 0 {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(quietTimeRemaining * 1_000_000_000)
                    )
                } catch {
                    return nil
                }
                continue
            }
            guard let page = pageMetadata(at: pageIndex, in: documentID) else {
                return causalContext
            }
            let operationsURL = collaborationOperationsURL(
                forPageID: page.id,
                in: documentID
            )
            let cacheKey = operationsURL.standardizedFileURL.path
            let revision = collaborationOperationsRevisions[cacheKey, default: 0]
            let operations = loadCollaborationOperations(
                forPageID: page.id,
                in: documentID
            )
            let existingDrawingURL = drawingURL(forPageID: page.id, in: documentID)

            let preparationTask = Task.detached(priority: .background) {
                Self.prepareDrawingCollaborationPlan(
                    drawing: drawing,
                    baseDrawing: baseDrawing,
                    causalContext: causalContext,
                    assumesOnlyAppendedStrokes: assumesOnlyAppendedStrokes,
                    preparedPersistence: preparedPersistence,
                    page: page,
                    sourceOperations: operations,
                    existingDrawingURL: existingDrawingURL
                )
            }
            let plan = await withTaskCancellationHandler {
                await preparationTask.value
            } onCancel: {
                preparationTask.cancel()
            }
            guard let plan,
                  !Task.isCancelled,
                  !isDrawingInteractionActive else { return nil }

            // CloudKit can merge this page while the detached comparison is running. Never install
            // a result based on an older operation set; retry without blocking PencilKit.
            guard collaborationOperationsRevisions[cacheKey, default: 0] == revision else {
                continue
            }

            let updatedContext: CollaborationVersionVector
            do {
                updatedContext = try commitPreparedDrawingCollaborationPlan(plan)
            } catch {
                saveState = .failed("协作操作无法保存：\(error.localizedDescription)")
                return causalContext
            }

            let scheduledOperations = plan.preexistingOperationCount < plan.baseOperations.count
                || !plan.mutations.isEmpty
            if let drawingData = preparedPersistence.drawingData {
                let saveKey = drawingKey(documentID: documentID, pageIndex: pageIndex)
                pendingSaves[saveKey]?.cancel()
                saveState = .saving
                let pendingSave = PendingAssetSave(
                    token: UUID(),
                    data: drawingData,
                    targetURL: drawingURL(forPage: pageIndex, in: documentID),
                    reference: LibraryAssetReference(
                        documentID: documentID,
                        kind: .drawing(pageIndex: pageIndex)
                    )
                )
                pendingAssetSaves[saveKey] = pendingSave
                schedulePendingAssetSave(pendingSave, saveKey: saveKey)
            } else {
                // Appended ink is already recoverable from the immutable operation journal. Do
                // not manufacture a redundant full PKDrawing snapshot while its editor is open.
                saveState = scheduledOperations ? .saving : .saved(Date())
            }
            return updatedContext
        }
        return nil
    }

    @discardableResult
    func scheduleSave(
        _ drawing: PKDrawing,
        replacing baseDrawing: PKDrawing? = nil,
        causalContext: CollaborationVersionVector? = nil,
        assumesOnlyAppendedStrokes: Bool = false,
        preparedPersistence: PreparedDrawingPersistence? = nil,
        forPage pageIndex: Int,
        in documentID: String
    ) -> CollaborationVersionVector {
        guard !readOnlySharedDocumentIDs.contains(documentID) else {
            saveState = .failed(LibraryStoreError.readOnlySharedDocument.errorDescription ?? "只读")
            return causalContext ?? collaborationFrontier(forPage: pageIndex, in: documentID)
        }
        let updatedContext: CollaborationVersionVector
        do {
            updatedContext = try recordDrawingCollaborationOperations(
                drawing,
                replacing: baseDrawing,
                causalContext: causalContext,
                assumesOnlyAppendedStrokes: assumesOnlyAppendedStrokes,
                preparedPersistence: preparedPersistence,
                forPage: pageIndex,
                in: documentID
            )
        } catch {
            saveState = .failed("协作操作无法保存：\(error.localizedDescription)")
            return causalContext ?? collaborationFrontier(forPage: pageIndex, in: documentID)
        }
        let saveKey = drawingKey(documentID: documentID, pageIndex: pageIndex)
        pendingSaves[saveKey]?.cancel()
        saveState = .saving

        let data: Data
        if hasUnseenDrawingCollaborationOperations(
            outside: updatedContext,
            forPage: pageIndex,
            in: documentID
        ) {
            // A remote operation landed behind this editor's causal base. Materialize only in
            // that exceptional merge case so the snapshot contains both replicas.
            data = collaborationDrawingData(forPage: pageIndex, in: documentID)
        } else {
            // The live PencilKit value is already the authoritative local snapshot. Reusing it
            // avoids replaying the entire operation history and decoding every stored stroke.
            data = preparedPersistence?.drawingData ?? drawing.dataRepresentation()
        }
        let targetURL = drawingURL(forPage: pageIndex, in: documentID)
        let pendingSave = PendingAssetSave(
            token: UUID(),
            data: data,
            targetURL: targetURL,
            reference: LibraryAssetReference(
                documentID: documentID,
                kind: .drawing(pageIndex: pageIndex)
            )
        )
        pendingAssetSaves[saveKey] = pendingSave
        schedulePendingAssetSave(pendingSave, saveKey: saveKey)
        return updatedContext
    }

    /// Refreshes the compact drawing asset from the already-committed operation journal without
    /// recording another logical edit. Ordinary handwriting uses this only as the page is closing
    /// or the app is leaving the foreground, never while Pencil input is available.
    func scheduleDrawingSnapshotCompaction(
        _ drawing: PKDrawing,
        causalContext: CollaborationVersionVector,
        forPage pageIndex: Int,
        in documentID: String
    ) {
        guard !readOnlySharedDocumentIDs.contains(documentID) else { return }
        let saveKey = drawingKey(documentID: documentID, pageIndex: pageIndex)
        pendingSaves[saveKey]?.cancel()
        let data = hasUnseenDrawingCollaborationOperations(
            outside: causalContext,
            forPage: pageIndex,
            in: documentID
        )
            ? collaborationDrawingData(forPage: pageIndex, in: documentID)
            : drawing.dataRepresentation()
        let pendingSave = PendingAssetSave(
            token: UUID(),
            data: data,
            targetURL: drawingURL(forPage: pageIndex, in: documentID),
            reference: LibraryAssetReference(
                documentID: documentID,
                kind: .drawing(pageIndex: pageIndex)
            )
        )
        saveState = .saving
        pendingAssetSaves[saveKey] = pendingSave
        schedulePendingAssetSave(pendingSave, saveKey: saveKey)
    }

    private func drawingPersistenceQuietTimeRemaining() -> TimeInterval {
        guard let lastDrawingInteractionAt else { return 0 }
        return max(
            0,
            Self.drawingPersistenceQuietWindow
                - Date().timeIntervalSince(lastDrawingInteractionAt)
        )
    }

    private func schedulePendingAssetSaves() {
        guard !isDrawingInteractionActive else { return }
        for (saveKey, pendingSave) in pendingAssetSaves {
            schedulePendingAssetSave(pendingSave, saveKey: saveKey)
        }
    }

    private func schedulePendingAssetSave(
        _ pendingSave: PendingAssetSave,
        saveKey: String
    ) {
        pendingSaves[saveKey]?.cancel()
        guard !isDrawingInteractionActive else {
            pendingSaves[saveKey] = nil
            return
        }
        let delay = drawingPersistenceQuietTimeRemaining()
        pendingSaves[saveKey] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  !self.isDrawingInteractionActive,
                  let latestSave = self.pendingAssetSaves[saveKey],
                  latestSave.token == pendingSave.token else { return }
            if self.drawingPersistenceQuietTimeRemaining() > 0 {
                self.pendingSaves[saveKey] = nil
                self.schedulePendingAssetSave(latestSave, saveKey: saveKey)
                return
            }

            let stagingURL = latestSave.targetURL
                .deletingLastPathComponent()
                .appendingPathComponent(
                    ".\(latestSave.targetURL.lastPathComponent)."
                        + "\(latestSave.token.uuidString.lowercased()).pending"
                )
            let writeTask = Task.detached(priority: .background) {
                try Task.checkCancellation()
                try latestSave.data.write(to: stagingURL, options: .atomic)
            }
            do {
                try await withTaskCancellationHandler {
                    try await writeTask.value
                } onCancel: {
                    writeTask.cancel()
                }
                guard !Task.isCancelled,
                      !self.isDrawingInteractionActive,
                      self.drawingPersistenceQuietTimeRemaining() == 0,
                      self.pendingAssetSaves[saveKey]?.token == pendingSave.token else {
                    try? FileManager.default.removeItem(at: stagingURL)
                    return
                }

                // Only the tiny same-volume rename remains on MainActor. A cancelled/stale writer
                // never touches the live asset and therefore cannot overwrite a later flush.
                try Self.installStagedFile(stagingURL, at: latestSave.targetURL)
                self.pendingSaves[saveKey] = nil
                self.pendingAssetSaves[saveKey] = nil
                self.saveState = self.pendingAssetSaves.isEmpty ? .saved(Date()) : .saving
                self.bumpPageAssetRevision(for: latestSave.reference)
                self.signalLocalCloudChange()
            } catch {
                try? FileManager.default.removeItem(at: stagingURL)
                if self.pendingAssetSaves[saveKey]?.token == pendingSave.token {
                    self.pendingSaves[saveKey] = nil
                    if !Task.isCancelled {
                        self.saveState = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    nonisolated private static func installStagedFile(
        _ stagingURL: URL,
        at targetURL: URL
    ) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: targetURL.path) {
            _ = try fileManager.replaceItemAt(
                targetURL,
                withItemAt: stagingURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: stagingURL, to: targetURL)
        }
    }

    private func bumpPageAssetRevision(for reference: LibraryAssetReference) {
        switch reference.kind {
        case .pageDrawing(let pageID), .pageElements(let pageID):
            bumpPageAssetRevision(forPageID: pageID, in: reference.documentID)
        case .drawing(let pageIndex), .imageAnnotations(let pageIndex):
            bumpPageAssetRevision(forPage: pageIndex, in: reference.documentID)
        case .pdf, .pageBackground:
            break
        }
    }

    func scheduleSave(
        _ imageAnnotations: [CanvasImageAnnotation],
        forPage pageIndex: Int,
        in documentID: String
    ) {
        let preserved = loadPageElements(forPage: pageIndex, in: documentID).filter {
            if case .image = $0.payload { return false }
            return true
        }
        scheduleSave(
            preserved + imageAnnotations.compactMap(\.pageElement),
            forPage: pageIndex,
            in: documentID
        )
    }

    @discardableResult
    func scheduleSave(
        _ pageElements: [CanvasPageElement],
        replacing baseElements: [CanvasPageElement]? = nil,
        causalContext: CollaborationVersionVector? = nil,
        forPage pageIndex: Int,
        in documentID: String
    ) -> CollaborationVersionVector {
        guard !readOnlySharedDocumentIDs.contains(documentID) else {
            saveState = .failed(LibraryStoreError.readOnlySharedDocument.errorDescription ?? "只读")
            return causalContext ?? collaborationFrontier(forPage: pageIndex, in: documentID)
        }
        let updatedContext: CollaborationVersionVector
        do {
            updatedContext = try recordElementCollaborationOperations(
                pageElements,
                replacing: baseElements,
                causalContext: causalContext,
                forPage: pageIndex,
                in: documentID
            )
        } catch {
            saveState = .failed("对象协作操作无法保存：\(error.localizedDescription)")
            return causalContext ?? collaborationFrontier(forPage: pageIndex, in: documentID)
        }
        let saveKey = "\(drawingKey(documentID: documentID, pageIndex: pageIndex))#elements"
        pendingSaves[saveKey]?.cancel()
        guard let data = collaborationElementsData(forPage: pageIndex, in: documentID) else {
            saveState = .failed("页面对象无法保存")
            return updatedContext
        }
        saveState = .saving
        let targetURL = imageAnnotationsURL(forPage: pageIndex, in: documentID)
        let pendingSave = PendingAssetSave(
            token: UUID(),
            data: data,
            targetURL: targetURL,
            reference: LibraryAssetReference(
                documentID: documentID,
                kind: pageID(at: pageIndex, in: documentID).map {
                    .pageElements(pageID: $0)
                } ?? .imageAnnotations(pageIndex: pageIndex)
            )
        )
        pendingAssetSaves[saveKey] = pendingSave
        schedulePendingAssetSave(pendingSave, saveKey: saveKey)
        return updatedContext
    }

    func flush(
        _ drawing: PKDrawing,
        forPage pageIndex: Int,
        in documentID: String
    ) {
        guard !readOnlySharedDocumentIDs.contains(documentID) else {
            saveState = .failed(LibraryStoreError.readOnlySharedDocument.errorDescription ?? "只读")
            return
        }
        do {
            _ = try recordDrawingCollaborationOperations(
                drawing,
                forPage: pageIndex,
                in: documentID
            )
        } catch {
            saveState = .failed("协作操作无法保存：\(error.localizedDescription)")
            return
        }
        let saveKey = drawingKey(documentID: documentID, pageIndex: pageIndex)
        pendingSaves[saveKey]?.cancel()
        pendingSaves[saveKey] = nil
        let pendingSave = PendingAssetSave(
            token: UUID(),
            data: collaborationDrawingData(forPage: pageIndex, in: documentID),
            targetURL: drawingURL(forPage: pageIndex, in: documentID),
            reference: LibraryAssetReference(
                documentID: documentID,
                kind: .drawing(pageIndex: pageIndex)
            )
        )
        pendingAssetSaves[saveKey] = pendingSave

        do {
            try pendingSave.data.write(to: pendingSave.targetURL, options: .atomic)
            pendingAssetSaves[saveKey] = nil
            saveState = pendingAssetSaves.isEmpty ? .saved(Date()) : .saving
            signalLocalCloudChange()
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    func flush(
        _ imageAnnotations: [CanvasImageAnnotation],
        forPage pageIndex: Int,
        in documentID: String
    ) {
        let preserved = loadPageElements(forPage: pageIndex, in: documentID).filter {
            if case .image = $0.payload { return false }
            return true
        }
        flush(
            preserved + imageAnnotations.compactMap(\.pageElement),
            forPage: pageIndex,
            in: documentID
        )
    }

    func flush(
        _ pageElements: [CanvasPageElement],
        forPage pageIndex: Int,
        in documentID: String
    ) {
        guard !readOnlySharedDocumentIDs.contains(documentID) else {
            saveState = .failed(LibraryStoreError.readOnlySharedDocument.errorDescription ?? "只读")
            return
        }
        do {
            _ = try recordElementCollaborationOperations(
                pageElements,
                forPage: pageIndex,
                in: documentID
            )
        } catch {
            saveState = .failed("对象协作操作无法保存：\(error.localizedDescription)")
            return
        }
        let saveKey = "\(drawingKey(documentID: documentID, pageIndex: pageIndex))#elements"
        pendingSaves[saveKey]?.cancel()
        pendingSaves[saveKey] = nil
        guard let data = collaborationElementsData(forPage: pageIndex, in: documentID) else {
            saveState = .failed("页面对象无法保存")
            return
        }
        let pendingSave = PendingAssetSave(
            token: UUID(),
            data: data,
            targetURL: imageAnnotationsURL(forPage: pageIndex, in: documentID),
            reference: LibraryAssetReference(
                documentID: documentID,
                kind: pageID(at: pageIndex, in: documentID).map {
                    .pageElements(pageID: $0)
                } ?? .imageAnnotations(pageIndex: pageIndex)
            )
        )
        pendingAssetSaves[saveKey] = pendingSave
        do {
            try pendingSave.data.write(to: pendingSave.targetURL, options: .atomic)
            pendingAssetSaves[saveKey] = nil
            saveState = pendingAssetSaves.isEmpty ? .saved(Date()) : .saving
            signalLocalCloudChange()
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    func pageAssetRevision(forPage pageIndex: Int, in documentID: String) -> UInt64 {
        let stablePageID = pageID(at: pageIndex, in: documentID) ?? "index-\(pageIndex)"
        return pageAssetRevisions[
            LibraryPageReference(documentID: documentID, pageID: stablePageID),
            default: 0
        ]
    }

    func collaborationFrontier(
        forPage pageIndex: Int,
        in documentID: String
    ) -> CollaborationVersionVector {
        guard let pageID = pageID(at: pageIndex, in: documentID) else {
            return CollaborationVersionVector()
        }
        return collaborationFrontier(
            from: loadCollaborationOperations(forPageID: pageID, in: documentID)
        )
    }

    /// Returns whether the operation log contains a drawing edit the visible canvas has not
    /// observed. Page-asset revisions also advance for local autosaves and CloudKit snapshot
    /// echoes; those revisions must not cause a live PKCanvasView to reinstall its own drawing.
    func hasUnseenDrawingCollaborationOperations(
        outside context: CollaborationVersionVector,
        forPage pageIndex: Int,
        in documentID: String
    ) -> Bool {
        guard let pageID = pageID(at: pageIndex, in: documentID) else { return false }
        return loadCollaborationOperations(forPageID: pageID, in: documentID).contains {
            operation in
            guard !context.contains(operation.stamp.dot) else { return false }
            switch operation.payload {
            case .strokeUpsert, .strokeDelete:
                return true
            default:
                return false
            }
        }
    }

    func documentMetadataCollaborationFrontier(
        for documentID: String
    ) -> CollaborationVersionVector {
        collaborationFrontier(
            from: loadCollaborationOperations(
                forPageID: CollaborationReservedID.documentMetadata,
                in: documentID
            )
        )
    }

    func hasPendingDrawingSave(forPage pageIndex: Int, in documentID: String) -> Bool {
        pendingAssetSaves[drawingKey(documentID: documentID, pageIndex: pageIndex)] != nil
    }

    func hasPendingImageAnnotationsSave(forPage pageIndex: Int, in documentID: String) -> Bool {
        pendingAssetSaves["\(drawingKey(documentID: documentID, pageIndex: pageIndex))#elements"] != nil
    }

    /// Synchronously writes the captured drawing and image payloads for one page.
    @discardableResult
    func flushPendingSaves(forPage pageIndex: Int, in documentID: String) -> Bool {
        let collaborationSaved: Bool
        if let pageID = pageID(at: pageIndex, in: documentID) {
            let operationsKey = collaborationOperationsURL(
                forPageID: pageID,
                in: documentID
            ).standardizedFileURL.path
            collaborationSaved = flushPendingCollaborationOperationsSaves(
                withKeys: [operationsKey]
            )
        } else {
            collaborationSaved = true
        }
        let assetsSaved = flushPendingSaves(withKeys: [
            drawingKey(documentID: documentID, pageIndex: pageIndex),
            "\(drawingKey(documentID: documentID, pageIndex: pageIndex))#elements"
        ])
        return collaborationSaved && assetsSaved
    }

    /// Synchronously drains every debounce payload before the app enters the background.
    @discardableResult
    func flushAllPendingSaves() -> Bool {
        let collaborationSaved = flushPendingCollaborationOperationsSaves(
            withKeys: Array(pendingCollaborationOperationsSaves.keys)
        )
        let assetsSaved = flushPendingSaves(withKeys: Array(pendingAssetSaves.keys))
        return collaborationSaved && assetsSaved
    }

    private func flushPendingSaves(withKeys keys: [String]) -> Bool {
        var firstError: Error?
        var didWriteAsset = false

        for key in keys {
            pendingSaves[key]?.cancel()
            pendingSaves[key] = nil
            guard let pendingSave = pendingAssetSaves[key] else { continue }
            do {
                try pendingSave.data.write(to: pendingSave.targetURL, options: .atomic)
                if pendingAssetSaves[key]?.token == pendingSave.token {
                    pendingAssetSaves[key] = nil
                }
                didWriteAsset = true
            } catch {
                firstError = firstError ?? error
            }
        }

        if didWriteAsset {
            signalLocalCloudChange()
        }
        if let firstError {
            saveState = .failed(firstError.localizedDescription)
            return false
        }
        saveState = pendingAssetSaves.isEmpty ? .saved(Date()) : .saving
        return true
    }

    func lastViewedPage(for documentID: String) -> Int {
        let storedPage = userDefaults.integer(forKey: lastPageKey(documentID))
        return min(max(storedPage, 0), max(pageCount(for: documentID) - 1, 0))
    }

    func setLastViewedPage(_ pageIndex: Int, for documentID: String) {
        userDefaults.set(pageIndex, forKey: lastPageKey(documentID))
    }

    func cloudSyncDidUpdateStatus(_ status: CloudLibrarySyncStatus) {
        cloudSyncStatus = status
        if case .succeeded(let date) = status {
            lastCloudSyncAt = date
            userDefaults.set(date, forKey: Self.lastCloudSyncAtKey)
        }
    }

    func setReadOnlySharedDocumentIDs(_ documentIDs: Set<String>) {
        readOnlySharedDocumentIDs = documentIDs
    }

    var librarySnapshot: LibrarySnapshot {
        LibrarySnapshot(folders: folders, documents: documentMetadata, pages: pages)
    }

    func exportLibrarySnapshot() -> LibrarySnapshot {
        if ensureFolderCausalRevisions(&folders) {
            try? persistRegistry(folders: folders, documents: documentMetadata, pages: pages)
            try? persistCollaborationClock()
        }
        return librarySnapshot
    }

    func exportDeletionTombstones() -> [LibraryEntityDeletionTombstone] {
        deletionTombstones.values.sorted {
            if $0.reference.kind.rawValue != $1.reference.kind.rawValue {
                return $0.reference.kind.rawValue < $1.reference.kind.rawValue
            }
            return $0.reference.entityID < $1.reference.entityID
        }
    }

    func applyRemoteDeletionTombstones(
        _ incomingTombstones: [LibraryEntityDeletionTombstone]
    ) throws {
        let incomingTombstones = incomingTombstones.filter {
            $0.reference.kind == .folder || $0.reference.kind == .document
        }
        guard !incomingTombstones.isEmpty else { return }

        var updatedTombstones = deletionTombstones
        for tombstone in incomingTombstones {
            for stamp in tombstone.stamps { collaborationClock.observe(stamp) }
            mergeDeletionTombstone(tombstone, into: &updatedTombstones)
        }

        // A folder tombstone semantically covers its whole observed-or-concurrent subtree. Copying
        // the same deletion event onto newly discovered descendant IDs prevents an offline child
        // from becoming an orphan root and lets every replica learn the inherited removal.
        var deletedFolderIDs = Set<String>()
        var folderDeletionByID: [String: LibraryEntityDeletionTombstone] = [:]
        for tombstone in updatedTombstones.values where tombstone.reference.kind == .folder {
            let folderID = tombstone.reference.entityID
            deletedFolderIDs.insert(folderID)
            folderDeletionByID[folderID] = tombstone
        }
        var pendingFolderIDs = Array(deletedFolderIDs)
        while let parentID = pendingFolderIDs.popLast(),
              let parentTombstone = folderDeletionByID[parentID] {
            for child in folders
            where child.parentID == parentID && deletedFolderIDs.insert(child.id).inserted {
                let inherited = LibraryEntityDeletionTombstone(
                    reference: CloudLibraryEntityReference(kind: .folder, entityID: child.id),
                    stamps: parentTombstone.stamps
                )
                mergeDeletionTombstone(inherited, into: &updatedTombstones)
                folderDeletionByID[child.id] = inherited
                pendingFolderIDs.append(child.id)
            }
        }

        var deletedDocumentIDs = Set(updatedTombstones.values.compactMap { tombstone in
            tombstone.reference.kind == .document ? tombstone.reference.entityID : nil
        })
        for metadata in documentMetadata {
            guard let parentID = metadata.parentID,
                  deletedFolderIDs.contains(parentID),
                  let folderTombstone = folderDeletionByID[parentID] else { continue }
            deletedDocumentIDs.insert(metadata.id)
            mergeDeletionTombstone(
                LibraryEntityDeletionTombstone(
                    reference: CloudLibraryEntityReference(
                        kind: .document,
                        entityID: metadata.id
                    ),
                    ownerDocumentID: metadata.id,
                    stamps: folderTombstone.stamps
                ),
                into: &updatedTombstones
            )
        }

        let deletedMetadata = documentMetadata.filter { deletedDocumentIDs.contains($0.id) }
        let updatedFolders = folders.filter { !deletedFolderIDs.contains($0.id) }
        let updatedMetadata = documentMetadata.filter { !deletedDocumentIDs.contains($0.id) }
        let updatedPages = pages.filter { !deletedDocumentIDs.contains($0.documentID) }
        let transaction = try beginWorkspaceTransaction(
            kind: "apply-remote-permanent-delete",
            affectedURLs: [registryURL, collaborationClockURL, deletionTombstonesURL]
        )
        do {
            try persistDeletionTombstones(updatedTombstones)
            try persistCollaborationClock()
            try persistRegistry(
                folders: updatedFolders,
                documents: updatedMetadata,
                pages: updatedPages
            )
            try commitWorkspaceTransaction(transaction)
        } catch {
            rollbackWorkspaceTransaction(transaction)
            throw error
        }

        deletionTombstones = updatedTombstones
        folders = updatedFolders
        documentMetadata = updatedMetadata
        pages = updatedPages
        for documentID in deletedDocumentIDs { pendingDocumentReferences[documentID] = nil }
        try? persistPendingDocumentReferences()
        openDocumentIDs.removeAll(where: deletedDocumentIDs.contains)
        cancelPendingSaves(forDocumentsNotIn: Set(updatedMetadata.map(\.id)))
        cleanupDeletedDocumentAssets(deletedMetadata)
        rebuildWorkspaceDocuments()
        persistOpenDocuments()
        signalLocalCloudChange()
    }

    func exportCollaborationOperations() -> [CollaborationOperation] {
        guard let enumerator = fileManager.enumerator(
            at: drawingsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var operationsByID: [String: CollaborationOperation] = [:]
        for case let url as URL in enumerator
        where url.lastPathComponent.hasSuffix(".operations.json") {
            for operation in loadCollaborationOperations(at: url) {
                operationsByID[operation.id] = operation
            }
        }
        for pendingSave in pendingCollaborationOperationsSaves.values {
            for operation in pendingSave.operations {
                operationsByID[operation.id] = operation
            }
        }
        return operationsByID.values.sorted {
            $0.deterministicallyPrecedes($1)
        }
    }

    func exportDocumentReferences(
        for documentIDs: Set<String>
    ) throws -> [LibraryDocumentReference] {
        var registryChanged = false
        var clockChanged = false
        for index in documentMetadata.indices where documentIDs.contains(documentMetadata[index].id) {
            guard documentMetadata[index].parentRevision == nil
                    || documentMetadata[index].favoriteRevision == nil
                    || documentMetadata[index].trashRevision == nil else { continue }
            let stamp = collaborationClock.nextStamp()
            if documentMetadata[index].parentRevision == nil {
                documentMetadata[index].parentRevision = stamp
            }
            if documentMetadata[index].favoriteRevision == nil {
                documentMetadata[index].favoriteRevision = stamp
            }
            if documentMetadata[index].trashRevision == nil {
                documentMetadata[index].trashRevision = stamp
            }
            registryChanged = true
            clockChanged = true
        }
        if registryChanged {
            try persistRegistry(folders: folders, documents: documentMetadata, pages: pages)
        }
        if clockChanged { try persistCollaborationClock() }

        var result: [LibraryDocumentReference] = documentMetadata.compactMap {
            metadata -> LibraryDocumentReference? in
            guard documentIDs.contains(metadata.id),
                  let parentRevision = metadata.parentRevision,
                  let favoriteRevision = metadata.favoriteRevision,
                  let trashRevision = metadata.trashRevision else { return nil }
            return LibraryDocumentReference(
                documentID: metadata.id,
                parent: LibraryDocumentReferenceRegister(
                    value: metadata.parentID,
                    stamp: parentRevision
                ),
                favorite: LibraryDocumentReferenceRegister(
                    value: metadata.isFavorite,
                    stamp: favoriteRevision
                ),
                trash: LibraryDocumentReferenceRegister(
                    value: metadata.trashedAt,
                    stamp: trashRevision
                )
            )
        }
        let materializedIDs = Set(result.map(\.documentID))
        result.append(contentsOf: pendingDocumentReferences.values.filter {
            documentIDs.contains($0.documentID) && !materializedIDs.contains($0.documentID)
        })
        return result.sorted { $0.documentID < $1.documentID }
    }

    func applyRemoteDocumentReferences(
        _ references: [LibraryDocumentReference]
    ) throws {
        guard !references.isEmpty else { return }
        for incoming in references {
            guard !hasDeletionTombstone(
                kind: .document,
                entityID: incoming.documentID
            ) else { continue }
            if let current = pendingDocumentReferences[incoming.documentID] {
                pendingDocumentReferences[incoming.documentID] = current.merged(with: incoming)
            } else {
                pendingDocumentReferences[incoming.documentID] = incoming
            }
            for stamp in [incoming.parent.stamp, incoming.favorite.stamp, incoming.trash.stamp] {
                collaborationClock.observe(stamp)
            }
        }
        pendingDocumentReferences = pendingDocumentReferences.filter { documentID, _ in
            !hasDeletionTombstone(kind: .document, entityID: documentID)
        }

        var metadataChanged = false
        for index in documentMetadata.indices {
            let documentID = documentMetadata[index].id
            guard var incoming = pendingDocumentReferences[documentID] else { continue }

            if let local = documentReference(for: documentMetadata[index]) {
                incoming = local.merged(with: incoming)
            }

            // A concurrently deleted/missing personal folder must never make the shared content
            // invalid. Repair the reference with a causally newer root placement.
            if let parentID = incoming.parent.value,
               !folders.contains(where: { $0.id == parentID && $0.trashedAt == nil }) {
                let repairStamp = collaborationClock.nextStamp()
                incoming.parent = LibraryDocumentReferenceRegister(
                    value: nil,
                    stamp: repairStamp
                )
            }

            documentMetadata[index].parentID = incoming.parent.value
            documentMetadata[index].isFavorite = incoming.favorite.value
            documentMetadata[index].trashedAt = incoming.trash.value
            documentMetadata[index].parentRevision = incoming.parent.stamp
            documentMetadata[index].favoriteRevision = incoming.favorite.stamp
            documentMetadata[index].trashRevision = incoming.trash.stamp
            documentMetadata[index].modifiedAt = max(
                documentMetadata[index].contentModifiedAt,
                incoming.parent.stamp.createdAt,
                incoming.favorite.stamp.createdAt,
                incoming.trash.stamp.createdAt
            )
            pendingDocumentReferences[documentID] = nil
            metadataChanged = true
        }

        if metadataChanged {
            let sanitized = sanitizeRegistry(folders: folders, documents: documentMetadata)
            documentMetadata = sanitized.documents
            try persistRegistry(folders: sanitized.folders, documents: documentMetadata, pages: pages)
            folders = sanitized.folders
            rebuildWorkspaceDocuments()
        }
        try persistPendingDocumentReferences()
        try persistCollaborationClock()
    }

    func exportCollaborationAcknowledgements(
        for documentID: String
    ) -> [CollaborationAcknowledgement] {
        collaborationAcknowledgements.values
            .filter { $0.documentID == documentID }
            .sorted { $0.participantID < $1.participantID }
    }

    func applyRemoteCollaborationAcknowledgements(
        _ acknowledgements: [CollaborationAcknowledgement]
    ) throws {
        guard !acknowledgements.isEmpty else { return }
        for incoming in acknowledgements {
            let key = incoming.id
            if let current = collaborationAcknowledgements[key] {
                collaborationAcknowledgements[key] = current.merged(with: incoming)
            } else {
                collaborationAcknowledgements[key] = incoming
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(collaborationAcknowledgements).write(
            to: collaborationAcknowledgementsURL,
            options: .atomic
        )
    }

    func applyRemoteCollaborationOperations(_ operations: [CollaborationOperation]) throws {
        let grouped = Dictionary(grouping: operations) {
            LibraryPageReference(documentID: $0.documentID, pageID: $0.pageID)
        }
        var clockChanged = false
        var pageMetadataChanged = false
        var documentMetadataChanged = false
        var affectedDocumentIDs: Set<String> = []

        for (reference, remoteOperations) in grouped {
            guard !hasDeletionTombstone(
                kind: .document,
                entityID: reference.documentID
            ) else { continue }
            let localOperations = loadCollaborationOperations(
                forPageID: reference.pageID,
                in: reference.documentID
            )
            var operationsByID: [String: CollaborationOperation] = [:]
            for operation in localOperations + remoteOperations {
                if let current = operationsByID[operation.id] {
                    operationsByID[operation.id] = .preferred(current, operation)
                } else {
                    operationsByID[operation.id] = operation
                }
                collaborationClock.observe(operation.stamp)
                clockChanged = true
            }

            let mergedOperations = operationsByID.values.sorted {
                $0.deterministicallyPrecedes($1)
            }
            let operationsChanged = Set(mergedOperations) != Set(localOperations)
            if operationsChanged {
                try saveCollaborationOperations(
                    mergedOperations,
                    forPageID: reference.pageID,
                    in: reference.documentID
                )
            }
            if reference.pageID == CollaborationReservedID.documentMetadata {
                let state = CollaborationMergeEngine.materialize(mergedOperations)
                if let titleData = state.metadata["document.title"],
                   let title = try? JSONDecoder().decode(String.self, from: titleData),
                   !title.isEmpty,
                   let index = documentMetadata.firstIndex(where: {
                       $0.id == reference.documentID
                   }),
                   documentMetadata[index].title != title {
                    let remoteContentDate = mergedOperations.map(\.stamp.createdAt).max()
                        ?? .distantPast
                    documentMetadata[index].title = title
                    documentMetadata[index].contentModifiedAt = max(
                        documentMetadata[index].contentModifiedAt,
                        remoteContentDate
                    )
                    documentMetadata[index].modifiedAt = max(
                        documentMetadata[index].modifiedAt,
                        remoteContentDate
                    )
                    documentMetadataChanged = true
                }
                affectedDocumentIDs.insert(reference.documentID)
                continue
            }
            let state = CollaborationMergeEngine.materialize(mergedOperations)
            if !state.isDeleted,
               !pages.contains(where: {
                   $0.id == reference.pageID && $0.documentID == reference.documentID
               }),
               let archivedData = state.metadata["pageArchive"],
               var archivedPage = try? JSONDecoder().decode(LibraryPage.self, from: archivedData),
               archivedPage.documentID == reference.documentID,
               archivedPage.id == reference.pageID {
                if let position = state.position { archivedPage.position = position }
                try ensureRecoveryBackground(for: archivedPage)
                pages.append(archivedPage)
                pageMetadataChanged = true
            }
            if !state.isDeleted,
               operationsChanged,
               mergedOperations.contains(where: { operation in
                switch operation.payload {
                case .strokeUpsert, .strokeDelete: true
                default: false
                }
            }) {
                try materializeCollaborationDrawing(
                    from: mergedOperations,
                    forPageID: reference.pageID,
                    in: reference.documentID
                )
            }
            if !state.isDeleted,
               operationsChanged,
               mergedOperations.contains(where: { operation in
                switch operation.payload {
                case .elementUpsert, .elementPatch, .elementDelete: true
                default: false
                }
            }) {
                guard let data = encodedPageElements(Array(state.elements.values)) else {
                    throw LibraryStoreError.cannotApplyAsset(reference.pageID)
                }
                try data.write(
                    to: imageAnnotationsURL(
                        forPageID: reference.pageID,
                        in: reference.documentID
                    ),
                    options: .atomic
                )
            }
            if let index = pages.firstIndex(where: {
                $0.id == reference.pageID && $0.documentID == reference.documentID
            }) {
                if state.isDeleted {
                    pages.remove(at: index)
                    pageMetadataChanged = true
                } else {
                    if let position = state.position, pages[index].position != position {
                        pages[index].position = position
                        pageMetadataChanged = true
                    }
                    if let data = state.metadata["rotation"],
                       let rotation = try? JSONDecoder().decode(Int.self, from: data),
                       pages[index].rotation != rotation {
                        pages[index].rotation = normalizedPageRotation(rotation)
                        pageMetadataChanged = true
                    }
                    if let data = state.metadata["isBookmarked"],
                       let isBookmarked = try? JSONDecoder().decode(Bool.self, from: data),
                       pages[index].isBookmarked != isBookmarked {
                        pages[index].isBookmarked = isBookmarked
                        pageMetadataChanged = true
                    }
                }
                affectedDocumentIDs.insert(reference.documentID)
            }
            affectedDocumentIDs.insert(reference.documentID)
            refreshPendingCollaborationSaves(
                forPageID: reference.pageID,
                in: reference.documentID,
                operations: mergedOperations
            )
            bumpPageAssetRevision(
                forPageID: reference.pageID,
                in: reference.documentID
            )
        }

        for documentID in affectedDocumentIDs
        where documentMetadata.contains(where: { $0.id == documentID && $0.trashedAt == nil })
            && pages(in: documentID).isEmpty {
            pages.append(try recoverPageForEmptyDocument(documentID))
            pageMetadataChanged = true
        }

        if pageMetadataChanged || documentMetadataChanged {
            if pageMetadataChanged {
            for documentID in affectedDocumentIDs {
                let orderedIDs = pages(in: documentID).map(\.id)
                let orderByID = Dictionary(
                    uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) }
                )
                for index in pages.indices where pages[index].documentID == documentID {
                    pages[index].orderIndex = orderByID[pages[index].id] ?? pages[index].orderIndex
                }
            }
            }
            try persistRegistry(folders: folders, documents: documentMetadata, pages: pages)
            if documentMetadataChanged { rebuildWorkspaceDocuments() }
        }
        if clockChanged { try persistCollaborationClock() }
    }

    func finalizeRemotePageChanges(for documentIDs: Set<String>) throws {
        for documentID in documentIDs {
            // Page CKAssets are snapshots used for fast bootstrap, never the causal source of
            // truth. A newer snapshot can arrive after operations in the same or a later batch;
            // replaying the immutable log here prevents it from resurrecting deleted strokes or
            // hiding concurrent objects merely because of delivery order.
            try rematerializeCollaborationAssets(for: documentID)
            try rebuildPDFDocumentFromPageBackgrounds(documentID: documentID)
        }
    }

    private func rematerializeCollaborationAssets(for documentID: String) throws {
        let grouped = Dictionary(
            grouping: exportCollaborationOperations().filter { $0.documentID == documentID },
            by: \.pageID
        )
        var didChangeDocumentMetadata = false
        var didChangePageMetadata = false
        for (pageID, operations) in grouped {
            let state = CollaborationMergeEngine.materialize(operations)
            if pageID == CollaborationReservedID.documentMetadata {
                if let titleData = state.metadata["document.title"],
                   let title = try? JSONDecoder().decode(String.self, from: titleData),
                   let index = documentMetadata.firstIndex(where: { $0.id == documentID }),
                   documentMetadata[index].title != title {
                    let remoteContentDate = operations.map(\.stamp.createdAt).max() ?? .distantPast
                    documentMetadata[index].title = title
                    documentMetadata[index].contentModifiedAt = max(
                        documentMetadata[index].contentModifiedAt,
                        remoteContentDate
                    )
                    documentMetadata[index].modifiedAt = max(
                        documentMetadata[index].modifiedAt,
                        remoteContentDate
                    )
                    didChangeDocumentMetadata = true
                }
                continue
            }

            if state.isDeleted {
                let previousCount = pages.count
                pages.removeAll { $0.id == pageID && $0.documentID == documentID }
                if pages.count != previousCount {
                    didChangePageMetadata = true
                    bumpPageAssetRevision(forPageID: pageID, in: documentID)
                }
                continue
            }

            if !pages.contains(where: { $0.id == pageID && $0.documentID == documentID }),
               let archivedData = state.metadata["pageArchive"],
               var archivedPage = try? JSONDecoder().decode(LibraryPage.self, from: archivedData),
               archivedPage.documentID == documentID,
               archivedPage.id == pageID {
                if let position = state.position { archivedPage.position = position }
                try ensureRecoveryBackground(for: archivedPage)
                pages.append(archivedPage)
                didChangePageMetadata = true
            }

            guard let pageIndex = pages.firstIndex(where: {
                $0.id == pageID && $0.documentID == documentID
            }) else { continue }
            if let position = state.position, pages[pageIndex].position != position {
                pages[pageIndex].position = position
                didChangePageMetadata = true
            }
            if let data = state.metadata["rotation"],
               let rotation = try? JSONDecoder().decode(Int.self, from: data) {
                let normalized = normalizedPageRotation(rotation)
                if pages[pageIndex].rotation != normalized {
                    pages[pageIndex].rotation = normalized
                    didChangePageMetadata = true
                }
                try materializeCollaborationBackgroundRotation(
                    normalized,
                    forPageID: pageID,
                    in: documentID
                )
            }
            if let data = state.metadata["isBookmarked"],
               let isBookmarked = try? JSONDecoder().decode(Bool.self, from: data),
               pages[pageIndex].isBookmarked != isBookmarked {
                pages[pageIndex].isBookmarked = isBookmarked
                didChangePageMetadata = true
            }

            if operations.contains(where: {
                switch $0.payload {
                case .strokeUpsert, .strokeDelete: true
                default: false
                }
            }) {
                try materializeCollaborationDrawing(
                    from: operations,
                    forPageID: pageID,
                    in: documentID
                )
            }
            if operations.contains(where: {
                switch $0.payload {
                case .elementUpsert, .elementPatch, .elementDelete: true
                default: false
                }
            }) {
                guard let data = encodedPageElements(Array(state.elements.values)) else {
                    throw LibraryStoreError.cannotApplyAsset(pageID)
                }
                try data.write(
                    to: imageAnnotationsURL(forPageID: pageID, in: documentID),
                    options: .atomic
                )
            }
            bumpPageAssetRevision(forPageID: pageID, in: documentID)
        }

        if documentMetadata.contains(where: { $0.id == documentID && $0.trashedAt == nil }),
           pages(in: documentID).isEmpty {
            pages.append(try recoverPageForEmptyDocument(documentID))
            didChangePageMetadata = true
        }
        if didChangePageMetadata {
            let orderedIDs = pages(in: documentID).map(\.id)
            let orderByID = Dictionary(
                uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) }
            )
            for index in pages.indices where pages[index].documentID == documentID {
                pages[index].orderIndex = orderByID[pages[index].id] ?? pages[index].orderIndex
            }
        }
        if didChangeDocumentMetadata || didChangePageMetadata {
            try persistRegistry(folders: folders, documents: documentMetadata, pages: pages)
            if didChangeDocumentMetadata { rebuildWorkspaceDocuments() }
        }
    }

    /// Page records/CKAssets are bootstrap snapshots. Rotation is selected by the causal metadata
    /// register, so normalize whichever background asset won the CloudKit record race before the
    /// document PDF is rebuilt.
    private func materializeCollaborationBackgroundRotation(
        _ rotation: Int,
        forPageID pageID: String,
        in documentID: String
    ) throws {
        let url = pageBackgroundURL(forPageID: pageID, in: documentID)
        guard let document = PDFDocument(url: url),
              let page = document.page(at: 0),
              normalizedPageRotation(page.rotation) != rotation else { return }
        page.rotation = rotation
        guard let data = document.dataRepresentation() else {
            throw PDFWorkspaceError.invalidPDF(documentID)
        }
        try data.write(to: url, options: .atomic)
    }

    /// Applies a complete remote metadata snapshot. Assets can arrive before or after this call.
    func applyRemoteSnapshot(_ snapshot: LibrarySnapshot) throws {
        guard snapshot.schemaVersion > 0,
              snapshot.schemaVersion <= LibrarySnapshot.currentSchemaVersion else {
            throw LibraryStoreError.invalidSnapshot("不支持的版本 \(snapshot.schemaVersion)")
        }
        let snapshot = snapshotRemovingTombstonedEntities(snapshot)
        let sanitized = sanitizeRegistry(
            folders: snapshot.folders,
            documents: snapshot.documents
        )
        for folder in sanitized.folders {
            for stamp in folder.causalStamps { collaborationClock.observe(stamp) }
        }
        for metadata in sanitized.documents {
            for stamp in [
                metadata.parentRevision,
                metadata.favoriteRevision,
                metadata.trashRevision
            ].compactMap({ $0 }) {
                collaborationClock.observe(stamp)
            }
        }
        var normalizedFolders = sanitized.folders
        _ = ensureFolderCausalRevisions(&normalizedFolders)
        var normalizedPages = snapshot.pages
        for documentID in Set(snapshot.documents.map(\.id)) {
            if normalizedPages.allSatisfy({ $0.documentID != documentID }),
               snapshot.documents.contains(where: { $0.id == documentID && $0.trashedAt == nil }) {
                normalizedPages.append(try recoverPageForEmptyDocument(documentID))
            }
            let orderedIDs = normalizedPages
                .filter { $0.documentID == documentID }
                .sorted {
                    if $0.position != $1.position { return $0.position < $1.position }
                    return $0.id < $1.id
                }
                .map(\.id)
            let orderByID = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) })
            for index in normalizedPages.indices
            where normalizedPages[index].documentID == documentID {
                normalizedPages[index].orderIndex = orderByID[normalizedPages[index].id] ?? 0
            }
        }
        let normalizedSnapshot = LibrarySnapshot(
            schemaVersion: snapshot.schemaVersion,
            folders: normalizedFolders,
            documents: sanitized.documents,
            pages: normalizedPages,
            generatedAt: snapshot.generatedAt
        )
        try validate(snapshot: normalizedSnapshot)
        try persistRegistry(
            folders: normalizedSnapshot.folders,
            documents: normalizedSnapshot.documents,
            pages: normalizedSnapshot.pages
        )
        try persistCollaborationClock()

        folders = normalizedSnapshot.folders
        documentMetadata = normalizedSnapshot.documents
        pages = normalizedSnapshot.pages
        rebuildWorkspaceDocuments()
        if !pendingDocumentReferences.isEmpty {
            try applyRemoteDocumentReferences(Array(pendingDocumentReferences.values))
        }

        let availableIDs = Set(documentMetadata.filter { $0.trashedAt == nil }.map(\.id))
        cancelPendingSaves(forDocumentsNotIn: availableIDs)
        openDocumentIDs = uniqueAvailableDocumentIDs(openDocumentIDs, availableIDs: availableIDs)
        if openDocumentIDs.isEmpty, let firstDocumentID = documents.first?.id {
            openDocumentIDs = [firstDocumentID]
        }
        pdfCache = pdfCache.filter { availableIDs.contains($0.key) }
        thumbnailCache.removeAll()
        persistOpenDocuments()
    }

    /// Resolves the canonical on-disk location used by CloudKit for an asset.
    func assetURL(for reference: LibraryAssetReference) -> URL? {
        guard let metadata = documentMetadata.first(where: { $0.id == reference.documentID }) else {
            return nil
        }
        switch reference.kind {
        case .pdf:
            // Resolve from metadata rather than the visible document array. A freshly downloaded
            // Cloud record needs a canonical destination before its PDF asset exists locally.
            return fileURL(for: metadata)
        case .pageBackground(let pageID):
            guard pages.contains(where: { $0.id == pageID && $0.documentID == reference.documentID })
            else { return nil }
            return pageBackgroundURL(forPageID: pageID, in: reference.documentID)
        case .pageDrawing(let pageID):
            guard pages.contains(where: { $0.id == pageID && $0.documentID == reference.documentID })
            else { return nil }
            return drawingURL(forPageID: pageID, in: reference.documentID)
        case .pageElements(let pageID):
            guard pages.contains(where: { $0.id == pageID && $0.documentID == reference.documentID })
            else { return nil }
            return imageAnnotationsURL(forPageID: pageID, in: reference.documentID)
        case .drawing(let pageIndex):
            guard pageIndex >= 0 else { return nil }
            return drawingURL(forPage: pageIndex, in: reference.documentID)
        case .imageAnnotations(let pageIndex):
            guard pageIndex >= 0 else { return nil }
            return imageAnnotationsURL(forPage: pageIndex, in: reference.documentID)
        }
    }

    /// Enumerates locally materialized assets without opening the PDF or PencilKit data.
    func availableAssetReferences(for documentID: String) -> [LibraryAssetReference] {
        guard let metadata = documentMetadata.first(where: { $0.id == documentID }) else {
            return []
        }
        var references: [LibraryAssetReference] = []
        if let pdfURL = fileURL(for: metadata), fileManager.fileExists(atPath: pdfURL.path) {
            references.append(LibraryAssetReference(documentID: documentID, kind: .pdf))
        }

        for page in pages(in: documentID) {
            let background = pageBackgroundURL(forPageID: page.id, in: documentID)
            if fileManager.fileExists(atPath: background.path) {
                references.append(
                    LibraryAssetReference(
                        documentID: documentID,
                        kind: .pageBackground(pageID: page.id)
                    )
                )
            }
            let drawing = drawingURL(forPageID: page.id, in: documentID)
            if fileManager.fileExists(atPath: drawing.path) {
                references.append(
                    LibraryAssetReference(documentID: documentID, kind: .pageDrawing(pageID: page.id))
                )
            }
            let elements = imageAnnotationsURL(forPageID: page.id, in: documentID)
            if fileManager.fileExists(atPath: elements.path) {
                references.append(
                    LibraryAssetReference(documentID: documentID, kind: .pageElements(pageID: page.id))
                )
            }
        }
        return references
    }

    /// Atomically installs a downloaded CloudKit asset at its canonical local location.
    func applyRemoteAsset(from sourceURL: URL, for reference: LibraryAssetReference) throws {
        guard let metadata = documentMetadata.first(where: { $0.id == reference.documentID }) else {
            throw LibraryStoreError.documentNotFound(reference.documentID)
        }
        if case .pdf = reference.kind, metadata.isBundled {
            // Bundled sample PDFs are identical on every installation and the app bundle is
            // read-only. Metadata (including a renamed title) has already been applied above.
            return
        }
        // Local in-memory edits win over a remote page asset. Drain the captured debounce payload
        // so CloudKit sees its fresh mtime, then skip this remote channel without a UI revision.
        if try preservePendingLocalEditIfNeeded(for: reference) {
            return
        }
        guard let targetURL = assetURL(for: reference) else {
            throw LibraryStoreError.cannotApplyAsset(sourceURL.lastPathComponent)
        }
        if sourceURL.standardizedFileURL == targetURL.standardizedFileURL {
            return
        }

        let hasSecurityAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let temporaryURL = targetURL.deletingLastPathComponent().appendingPathComponent(
            ".sync-\(UUID().uuidString)"
        )
        do {
            try fileManager.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: sourceURL, to: temporaryURL)
            if fileManager.fileExists(atPath: targetURL.path) {
                _ = try fileManager.replaceItemAt(targetURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: targetURL)
            }
            switch reference.kind {
            case .pdf:
                pdfCache[reference.documentID] = nil
                thumbnailCache = thumbnailCache.filter {
                    !$0.key.hasPrefix("\(reference.documentID)#")
                }
                rebuildWorkspaceDocuments()
            case .pageBackground(let pageID):
                bumpPageAssetRevision(forPageID: pageID, in: reference.documentID)
            case .pageDrawing(let pageID), .pageElements(let pageID):
                bumpPageAssetRevision(forPageID: pageID, in: reference.documentID)
            case .drawing(let pageIndex), .imageAnnotations(let pageIndex):
                bumpPageAssetRevision(forPage: pageIndex, in: reference.documentID)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw LibraryStoreError.cannotApplyAsset(sourceURL.lastPathComponent)
        }
    }

    /// Removes an asset selected by remote conflict/deletion handling without creating a local
    /// CloudKit change. Annotation removals still invalidate the exact visible page.
    func removeRemoteAsset(for reference: LibraryAssetReference) throws {
        guard let metadata = documentMetadata.first(where: { $0.id == reference.documentID }) else {
            throw LibraryStoreError.documentNotFound(reference.documentID)
        }
        if case .pdf = reference.kind, metadata.isBundled {
            return
        }
        if try preservePendingLocalEditIfNeeded(for: reference) {
            return
        }
        guard let targetURL = assetURL(for: reference) else {
            throw LibraryStoreError.cannotApplyAsset(reference.documentID)
        }

        do {
            if fileManager.fileExists(atPath: targetURL.path) {
                try fileManager.removeItem(at: targetURL)
            }
            switch reference.kind {
            case .pdf:
                pdfCache[reference.documentID] = nil
                thumbnailCache = thumbnailCache.filter {
                    !$0.key.hasPrefix("\(reference.documentID)#")
                }
                rebuildWorkspaceDocuments()
            case .pageBackground(let pageID):
                bumpPageAssetRevision(forPageID: pageID, in: reference.documentID)
            case .pageDrawing(let pageID), .pageElements(let pageID):
                bumpPageAssetRevision(forPageID: pageID, in: reference.documentID)
            case .drawing(let pageIndex), .imageAnnotations(let pageIndex):
                bumpPageAssetRevision(forPage: pageIndex, in: reference.documentID)
            }
        } catch {
            throw LibraryStoreError.cannotApplyAsset(targetURL.lastPathComponent)
        }
    }

    private func loadWorkspace() {
        let bundledMetadata = defaultBundledMetadata()
        var needsRegistryUpgrade = false

        if let registryData = try? Data(contentsOf: registryURL) {
            if let registry = try? JSONDecoder().decode(LibraryRegistry.self, from: registryData) {
                folders = registry.folders
                documentMetadata = registry.documents
                pages = registry.pages
            } else if let legacyRecords = try? JSONDecoder().decode(
                [LegacyImportedPDFRecord].self,
                from: registryData
            ) {
                folders = []
                pages = []
                documentMetadata = bundledMetadata + legacyRecords.map { record in
                    let fileURL = importsDirectory.appendingPathComponent(record.fileName)
                    let dates = fileDates(for: fileURL)
                    return LibraryDocumentMetadata(
                        id: record.id,
                        title: record.title,
                        parentID: nil,
                        fileName: record.fileName,
                        isBundled: false,
                        createdAt: dates.createdAt,
                        modifiedAt: dates.modifiedAt
                    )
                }
                needsRegistryUpgrade = true
            } else {
                folders = []
                pages = []
                documentMetadata = bundledMetadata
                needsRegistryUpgrade = true
            }
        } else {
            folders = []
            pages = []
            documentMetadata = bundledMetadata
            needsRegistryUpgrade = true
        }

        // A committed deletion ledger is authoritative even if the process stopped before the
        // registry/asset cleanup completed. Folder deletion is subtree-wide and remove-wins, so a
        // concurrently created offline descendant cannot survive merely because it has a new ID.
        var deletedFolderIDs = Set(folders.compactMap { folder in
            hasDeletionTombstone(kind: .folder, entityID: folder.id) ? folder.id : nil
        })
        for folderID in Array(deletedFolderIDs) {
            deletedFolderIDs.formUnion(descendantFolderIDs(of: folderID))
        }
        let deletedDocumentIDs = Set(documentMetadata.compactMap { metadata -> String? in
            if hasDeletionTombstone(kind: .document, entityID: metadata.id) { return metadata.id }
            if metadata.parentID.map(deletedFolderIDs.contains) == true { return metadata.id }
            return nil
        })
        if !deletedFolderIDs.isEmpty || !deletedDocumentIDs.isEmpty {
            folders.removeAll { deletedFolderIDs.contains($0.id) }
            documentMetadata.removeAll { deletedDocumentIDs.contains($0.id) }
            pages.removeAll {
                deletedDocumentIDs.contains($0.documentID)
                    || hasDeletionTombstone(kind: .page, entityID: $0.id)
            }
            needsRegistryUpgrade = true
        } else {
            let pageCountBefore = pages.count
            pages.removeAll { hasDeletionTombstone(kind: .page, entityID: $0.id) }
            needsRegistryUpgrade = needsRegistryUpgrade || pages.count != pageCountBefore
        }

        let sanitized = sanitizeRegistry(folders: folders, documents: documentMetadata)
        folders = sanitized.folders
        documentMetadata = sanitized.documents
        needsRegistryUpgrade = needsRegistryUpgrade || sanitized.didChange
        for folder in folders {
            for stamp in folder.causalStamps { collaborationClock.observe(stamp) }
        }
        for metadata in documentMetadata {
            for stamp in [
                metadata.parentRevision,
                metadata.favoriteRevision,
                metadata.trashRevision
            ].compactMap({ $0 }) {
                collaborationClock.observe(stamp)
            }
        }
        if ensureFolderCausalRevisions(&folders) {
            needsRegistryUpgrade = true
        }
        try? persistCollaborationClock()

        rebuildWorkspaceDocuments()
        needsRegistryUpgrade = reconcilePageMetadata() || needsRegistryUpgrade
        for metadata in documentMetadata where !metadata.isBundled {
            guard let pdf = pdfDocument(for: metadata.id) else { continue }
            let documentPages = pages(in: metadata.id)
            let needsBackgrounds = documentPages.contains {
                !fileManager.fileExists(
                    atPath: pageBackgroundURL(forPageID: $0.id, in: metadata.id).path
                )
            }
            if needsBackgrounds {
                try? persistPageBackgroundAssets(
                    pages: documentPages,
                    from: pdf,
                    documentID: metadata.id
                )
            }
        }
        if needsRegistryUpgrade {
            try? persistRegistry(folders: folders, documents: documentMetadata, pages: pages)
        }

        if !pendingDocumentReferences.isEmpty {
            // Best effort during startup; the same references remain pending if their shared
            // content has not been mounted yet.
            try? applyRemoteDocumentReferences(Array(pendingDocumentReferences.values))
        }

        let savedOpenIDs = userDefaults.stringArray(forKey: "pdfWorkspace.openDocumentIDs") ?? []
        let availableIDs = Set(documents.filter { $0.trashedAt == nil }.map(\.id))
        openDocumentIDs = uniqueAvailableDocumentIDs(savedOpenIDs, availableIDs: availableIDs)
        if openDocumentIDs.isEmpty {
            openDocumentIDs = documents.map(\.id)
        } else {
            for bundledDocument in documents where bundledDocument.isBundled {
                if !openDocumentIDs.contains(bundledDocument.id) {
                    openDocumentIDs.append(bundledDocument.id)
                }
            }
        }
        persistOpenDocuments()
    }

    private func persistRegistry(
        folders: [LibraryFolder],
        documents: [LibraryDocumentMetadata],
        pages persistedPages: [LibraryPage]? = nil
    ) throws {
        let registry = LibraryRegistry(
            schemaVersion: LibrarySnapshot.currentSchemaVersion,
            folders: folders,
            documents: documents,
            pages: persistedPages ?? pages
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(registry)
        try data.write(to: registryURL, options: .atomic)
    }

    private func beginWorkspaceTransaction(
        kind: String,
        affectedURLs: [URL]
    ) throws -> ActiveWorkspaceTransaction {
        let pendingOperationKeys = affectedURLs
            .filter { $0.lastPathComponent.hasSuffix(".operations.json") }
            .map { $0.standardizedFileURL.path }
        guard flushPendingCollaborationOperationsSaves(withKeys: pendingOperationKeys) else {
            throw LibraryStoreError.cannotApplyAsset(kind)
        }
        let transactionID = UUID().uuidString.lowercased()
        let directory = transactionsDirectory.appendingPathComponent(
            transactionID,
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)

        do {
            let uniqueURLs = Dictionary(
                affectedURLs.map { ($0.standardizedFileURL.path, $0.standardizedFileURL) },
                uniquingKeysWith: { first, _ in first }
            ).values.sorted { $0.path < $1.path }
            var entries: [WorkspaceTransactionEntry] = []
            entries.reserveCapacity(uniqueURLs.count)
            for (index, url) in uniqueURLs.enumerated() {
                let relativePath = try workspaceRelativePath(for: url)
                let backupFileName = "backup-\(index)"
                let existed = fileManager.fileExists(atPath: url.path)
                if existed {
                    try fileManager.copyItem(
                        at: url,
                        to: directory.appendingPathComponent(backupFileName)
                    )
                }
                entries.append(
                    WorkspaceTransactionEntry(
                        relativePath: relativePath,
                        backupFileName: backupFileName,
                        existedBefore: existed
                    )
                )
            }
            let journal = WorkspaceTransactionJournal(
                schemaVersion: WorkspaceTransactionJournal.currentSchemaVersion,
                id: transactionID,
                kind: kind,
                createdAt: Date(),
                phase: .prepared,
                entries: entries
            )
            try Self.writeWorkspaceTransactionJournal(journal, in: directory)
            return ActiveWorkspaceTransaction(
                directory: directory,
                journal: journal,
                snapshotBefore: librarySnapshot,
                clockBefore: collaborationClock
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    private func commitWorkspaceTransaction(_ transaction: ActiveWorkspaceTransaction) throws {
        var committed = transaction.journal
        committed.phase = .committed
        try Self.writeWorkspaceTransactionJournal(committed, in: transaction.directory)
        // Once the committed marker is durable, cleanup is best-effort. Startup will remove a
        // leftover committed directory without rolling the successful mutation back.
        try? fileManager.removeItem(at: transaction.directory)
    }

    private func rollbackWorkspaceTransaction(_ transaction: ActiveWorkspaceTransaction) {
        do {
            try Self.restoreWorkspaceTransaction(
                transaction.journal,
                from: transaction.directory,
                fileManager: fileManager,
                workspaceDirectory: workspaceDirectory
            )
            try fileManager.removeItem(at: transaction.directory)
        } catch {
            // Keep the journal and backups for the next launch if immediate recovery is interrupted.
        }
        folders = transaction.snapshotBefore.folders
        documentMetadata = transaction.snapshotBefore.documents
        pages = transaction.snapshotBefore.pages
        collaborationClock = transaction.clockBefore
        pdfCache.removeAll()
        thumbnailCache.removeAll()
        collaborationOperationsCache.removeAll()
        rebuildWorkspaceDocuments()
        pageAssetGeneration &+= 1
    }

    private func workspaceRelativePath(for url: URL) throws -> String {
        let rootPath = workspaceDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else {
            throw LibraryStoreError.invalidSnapshot("事务文件超出工作区")
        }
        let relative = String(path.dropFirst(prefix.count))
        guard !relative.isEmpty, !relative.split(separator: "/").contains("..") else {
            throw LibraryStoreError.invalidSnapshot("事务文件路径无效")
        }
        return relative
    }

    private static func writeWorkspaceTransactionJournal(
        _ journal: WorkspaceTransactionJournal,
        in directory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(journal).write(
            to: directory.appendingPathComponent("journal.json"),
            options: .atomic
        )
    }

    private static func recoverInterruptedWorkspaceTransactions(
        fileManager: FileManager,
        workspaceDirectory: URL,
        transactionsDirectory: URL
    ) {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: transactionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let journalURL = directory.appendingPathComponent("journal.json")
            guard let data = try? Data(contentsOf: journalURL),
                  let journal = try? JSONDecoder().decode(
                      WorkspaceTransactionJournal.self,
                      from: data
                  ),
                  journal.schemaVersion == WorkspaceTransactionJournal.currentSchemaVersion,
                  journal.id == directory.lastPathComponent else {
                // beginWorkspaceTransaction never exposes the transaction before its journal is
                // durable, so a directory without a readable journal contains only unused backups.
                try? fileManager.removeItem(at: directory)
                continue
            }
            do {
                if journal.phase == .prepared {
                    try restoreWorkspaceTransaction(
                        journal,
                        from: directory,
                        fileManager: fileManager,
                        workspaceDirectory: workspaceDirectory
                    )
                }
                try fileManager.removeItem(at: directory)
            } catch {
                // Retain the transaction for a later retry instead of accepting a partial restore.
                continue
            }
        }
    }

    private static func restoreWorkspaceTransaction(
        _ journal: WorkspaceTransactionJournal,
        from directory: URL,
        fileManager: FileManager,
        workspaceDirectory: URL
    ) throws {
        let rootPath = workspaceDirectory.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        for entry in journal.entries {
            let destination = workspaceDirectory
                .appendingPathComponent(entry.relativePath)
                .standardizedFileURL
            guard destination.path.hasPrefix(prefix) else {
                throw LibraryStoreError.invalidSnapshot("事务恢复路径无效")
            }
            if !entry.existedBefore {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                continue
            }

            let backup = directory.appendingPathComponent(entry.backupFileName)
            guard fileManager.fileExists(atPath: backup.path) else {
                throw LibraryStoreError.invalidSnapshot("事务备份缺失")
            }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(
                ".tiyi-restore-\(UUID().uuidString.lowercased())"
            )
            try fileManager.copyItem(at: backup, to: temporary)
            if fileManager.fileExists(atPath: destination.path) {
                do {
                    _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
                } catch {
                    try? fileManager.removeItem(at: destination)
                    try fileManager.moveItem(at: temporary, to: destination)
                }
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        }
    }

    private func documentReference(
        for metadata: LibraryDocumentMetadata
    ) -> LibraryDocumentReference? {
        metadata.personalReference
    }

    /// Assigns causal identities to legacy/repaired fields before they can be uploaded. A single
    /// migration event may initialize several unchanged fields; later edits advance only the field
    /// they actually modify.
    @discardableResult
    private func ensureFolderCausalRevisions(_ values: inout [LibraryFolder]) -> Bool {
        var changed = false
        for index in values.indices where !values[index].hasCompleteCausalMetadata {
            let stamp = collaborationClock.nextStamp()
            if values[index].titleRevision == nil { values[index].titleRevision = stamp }
            if values[index].parentRevision == nil { values[index].parentRevision = stamp }
            if values[index].colorRevision == nil { values[index].colorRevision = stamp }
            if values[index].iconRevision == nil { values[index].iconRevision = stamp }
            if values[index].favoriteRevision == nil { values[index].favoriteRevision = stamp }
            if values[index].trashRevision == nil { values[index].trashRevision = stamp }
            values[index].modifiedAt = max(values[index].modifiedAt, stamp.createdAt)
            changed = true
        }
        return changed
    }

    private func persistPendingDocumentReferences() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(pendingDocumentReferences).write(
            to: pendingDocumentReferencesURL,
            options: .atomic
        )
    }

    private static func deletionLedgerKey(
        _ reference: CloudLibraryEntityReference
    ) -> String {
        "\(reference.kind.rawValue)|\(reference.entityID)"
    }

    private func mergeDeletionTombstone(
        _ tombstone: LibraryEntityDeletionTombstone,
        into values: inout [String: LibraryEntityDeletionTombstone]
    ) {
        let key = Self.deletionLedgerKey(tombstone.reference)
        if let current = values[key] {
            values[key] = current.merged(with: tombstone)
        } else {
            values[key] = tombstone
        }
    }

    private func persistDeletionTombstones(
        _ values: [String: LibraryEntityDeletionTombstone]
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let ordered = values.values.sorted {
            if $0.reference.kind.rawValue != $1.reference.kind.rawValue {
                return $0.reference.kind.rawValue < $1.reference.kind.rawValue
            }
            return $0.reference.entityID < $1.reference.entityID
        }
        try encoder.encode(ordered).write(to: deletionTombstonesURL, options: .atomic)
    }

    private func hasDeletionTombstone(
        kind: CloudLibraryEntityKind,
        entityID: String
    ) -> Bool {
        deletionTombstones[
            Self.deletionLedgerKey(
                CloudLibraryEntityReference(kind: kind, entityID: entityID)
            )
        ] != nil
    }

    private func snapshotRemovingTombstonedEntities(
        _ snapshot: LibrarySnapshot
    ) -> LibrarySnapshot {
        var deletedFolderIDs = Set(snapshot.folders.compactMap { folder in
            hasDeletionTombstone(kind: .folder, entityID: folder.id) ? folder.id : nil
        })
        var pending = Array(deletedFolderIDs)
        while let parentID = pending.popLast() {
            for folder in snapshot.folders
            where folder.parentID == parentID && deletedFolderIDs.insert(folder.id).inserted {
                pending.append(folder.id)
            }
        }
        let deletedDocumentIDs = Set(snapshot.documents.compactMap { metadata -> String? in
            if hasDeletionTombstone(kind: .document, entityID: metadata.id) { return metadata.id }
            if metadata.parentID.map(deletedFolderIDs.contains) == true { return metadata.id }
            return nil
        })
        return LibrarySnapshot(
            schemaVersion: snapshot.schemaVersion,
            folders: snapshot.folders.filter { !deletedFolderIDs.contains($0.id) },
            documents: snapshot.documents.filter { !deletedDocumentIDs.contains($0.id) },
            pages: snapshot.pages.filter {
                !deletedDocumentIDs.contains($0.documentID)
                    && !hasDeletionTombstone(kind: .page, entityID: $0.id)
            },
            generatedAt: snapshot.generatedAt
        )
    }

    private func rebuildWorkspaceDocuments() {
        documents = documentMetadata.compactMap { metadata in
            guard let fileURL = fileURL(for: metadata) else { return nil }
            return PDFWorkspaceDocument(
                id: metadata.id,
                title: metadata.title,
                fileURL: fileURL,
                isBundled: metadata.isBundled,
                parentID: metadata.parentID,
                createdAt: metadata.createdAt,
                modifiedAt: metadata.modifiedAt,
                kind: metadata.kind,
                canvasBackgroundStyle: metadata.canvasBackgroundStyle,
                canvasBackgroundColor: metadata.canvasBackgroundColor,
                isFavorite: metadata.isFavorite,
                trashedAt: metadata.trashedAt
            )
        }
    }

    private func makePageMetadata(
        for metadata: LibraryDocumentMetadata,
        pdf: PDFDocument
    ) -> [LibraryPage] {
        (0..<pdf.pageCount).compactMap { pageIndex in
            guard let pdfPage = pdf.page(at: pageIndex) else { return nil }
            let bounds = pdfPage.bounds(for: .mediaBox)
            return LibraryPage(
                documentID: metadata.id,
                orderIndex: pageIndex,
                createdAt: metadata.createdAt,
                modifiedAt: metadata.modifiedAt,
                width: Double(max(bounds.width, 1)),
                height: Double(max(bounds.height, 1)),
                rotation: pdfPage.rotation,
                sourceKind: metadata.kind == .canvas ? .template : .pdf,
                backgroundStyle: metadata.kind == .canvas
                    ? metadata.canvasBackgroundStyle
                    : nil,
                backgroundColor: metadata.kind == .canvas
                    ? metadata.canvasBackgroundColor
                    : nil
            )
        }
    }

    private func persistPageBackgroundAssets(
        pages: [LibraryPage],
        from pdf: PDFDocument,
        documentID: String
    ) throws {
        for page in pages.sorted(by: { $0.orderIndex < $1.orderIndex }) {
            guard let sourcePage = pdf.page(at: page.orderIndex),
                  let copiedPage = sourcePage.copy() as? PDFPage else {
                throw PDFWorkspaceError.invalidPDF(documentID)
            }
            let pageDocument = PDFDocument()
            pageDocument.insert(copiedPage, at: 0)
            guard let data = pageDocument.dataRepresentation() else {
                throw PDFWorkspaceError.invalidPDF(documentID)
            }
            try data.write(
                to: pageBackgroundURL(forPageID: page.id, in: documentID),
                options: .atomic
            )
        }
    }

    private func rebuildPDFDocumentFromPageBackgrounds(documentID: String) throws {
        guard let metadata = documentMetadata.first(where: { $0.id == documentID }),
              !metadata.isBundled else { return }
        let orderedPages = pages(in: documentID)
        guard !orderedPages.isEmpty else { return }
        let sourceDocuments = orderedPages.map {
            PDFDocument(url: pageBackgroundURL(forPageID: $0.id, in: documentID))
        }
        guard sourceDocuments.allSatisfy({ $0?.pageCount == 1 }) else { return }

        let rebuilt = PDFDocument()
        for sourceDocument in sourceDocuments {
            guard let page = sourceDocument?.page(at: 0)?.copy() as? PDFPage else {
                throw PDFWorkspaceError.invalidPDF(metadata.title)
            }
            rebuilt.insert(page, at: rebuilt.pageCount)
        }
        guard let data = rebuilt.dataRepresentation(), let targetURL = fileURL(for: metadata) else {
            throw PDFWorkspaceError.invalidPDF(metadata.title)
        }
        try data.write(to: targetURL, options: .atomic)
        pdfCache[documentID] = rebuilt
        thumbnailCache = thumbnailCache.filter { !$0.key.hasPrefix("\(documentID)#") }
        rebuildWorkspaceDocuments()
    }

    /// Creates stable page identities for v1/v2 registries and repairs interrupted page edits.
    /// Legacy page-number asset files are moved once to their stable page-ID destinations.
    @discardableResult
    private func reconcilePageMetadata() -> Bool {
        let availableDocumentIDs = Set(documentMetadata.map(\.id))
        var didChange = false
        var pagesByID: [String: LibraryPage] = [:]

        for page in pages.sorted(by: { $0.modifiedAt > $1.modifiedAt }) {
            guard
                availableDocumentIDs.contains(page.documentID),
                isSafePathComponent(page.id),
                pagesByID[page.id] == nil
            else {
                didChange = true
                continue
            }
            pagesByID[page.id] = page
        }

        var reconciledPages: [LibraryPage] = []
        for metadata in documentMetadata.sorted(by: { $0.id < $1.id }) {
            guard let pdf = pdfDocument(for: metadata.id) else { continue }
            let existing = pagesByID.values
                .filter { $0.documentID == metadata.id }
                .sorted {
                    if $0.position != $1.position { return $0.position < $1.position }
                    return $0.id < $1.id
                }

            if existing.count != pdf.pageCount { didChange = true }
            for pageIndex in 0..<pdf.pageCount {
                guard let pdfPage = pdf.page(at: pageIndex) else { continue }
                let pageBounds = pdfPage.bounds(for: .mediaBox)
                var page: LibraryPage
                if existing.indices.contains(pageIndex) {
                    page = existing[pageIndex]
                    if page.orderIndex != pageIndex {
                        page.orderIndex = pageIndex
                        didChange = true
                    }
                    if page.width <= 0 || page.height <= 0 {
                        page.width = Double(max(pageBounds.width, 1))
                        page.height = Double(max(pageBounds.height, 1))
                        didChange = true
                    }
                } else {
                    page = LibraryPage(
                        id: deterministicLegacyPageID(
                            documentID: metadata.id,
                            pageIndex: pageIndex
                        ),
                        documentID: metadata.id,
                        orderIndex: pageIndex,
                        createdAt: metadata.createdAt,
                        modifiedAt: metadata.modifiedAt,
                        width: Double(max(pageBounds.width, 1)),
                        height: Double(max(pageBounds.height, 1)),
                        rotation: pdfPage.rotation,
                        sourceKind: metadata.kind == .canvas ? .template : .pdf,
                        backgroundStyle: metadata.kind == .canvas
                            ? metadata.canvasBackgroundStyle
                            : nil,
                        backgroundColor: metadata.kind == .canvas
                            ? metadata.canvasBackgroundColor
                            : nil
                    )
                    didChange = true
                }
                reconciledPages.append(page)
                if migrateLegacyPageAssets(
                    documentID: metadata.id,
                    pageIndex: pageIndex,
                    pageID: page.id
                ) {
                    didChange = true
                }
            }
        }

        let sortedPages = reconciledPages.sorted {
            if $0.documentID != $1.documentID { return $0.documentID < $1.documentID }
            if $0.position != $1.position { return $0.position < $1.position }
            return $0.id < $1.id
        }
        if sortedPages != pages { didChange = true }
        pages = sortedPages
        return didChange
    }

    private func deterministicLegacyPageID(documentID: String, pageIndex: Int) -> String {
        "legacy-\(documentID)-page-\(pageIndex + 1)"
    }

    private func migrateLegacyPageAssets(
        documentID: String,
        pageIndex: Int,
        pageID: String
    ) -> Bool {
        let directory = documentDrawingsDirectory(for: documentID, createIfNeeded: false)
        let legacyDrawing = directory.appendingPathComponent(
            String(format: "page-%04d.drawing", pageIndex + 1)
        )
        let legacyImages = legacyDrawing.appendingPathExtension("images.json")
        let stableDrawing = drawingURL(forPageID: pageID, in: documentID)
        let stableImages = imageAnnotationsURL(forPageID: pageID, in: documentID)
        var didChange = false

        if fileManager.fileExists(atPath: legacyDrawing.path),
           !fileManager.fileExists(atPath: stableDrawing.path) {
            try? fileManager.moveItem(at: legacyDrawing, to: stableDrawing)
            didChange = true
        }
        if fileManager.fileExists(atPath: legacyImages.path),
           !fileManager.fileExists(atPath: stableImages.path) {
            try? fileManager.moveItem(at: legacyImages, to: stableImages)
            didChange = true
        }
        return didChange
    }

    private func fileURL(for metadata: LibraryDocumentMetadata) -> URL? {
        if metadata.isBundled {
            let fileURL = URL(fileURLWithPath: metadata.fileName)
            return Bundle.main.url(
                forResource: fileURL.deletingPathExtension().lastPathComponent,
                withExtension: fileURL.pathExtension
            )
        }
        return importsDirectory.appendingPathComponent(metadata.fileName)
    }

    private func defaultBundledMetadata() -> [LibraryDocumentMetadata] {
        let hostIncludesBundledSamples = Bundle.main.object(
            forInfoDictionaryKey: "TiyiDocumentsIncludesBundledSamples"
        ) as? Bool ?? true
        guard includesBundledSamples && hostIncludesBundledSamples else { return [] }

        // A fixed old timestamp lets a genuinely renamed/moved CloudKit sample always win over a
        // pristine sample installed for the first time on another device.
        let pristineDate = Date(timeIntervalSince1970: 0)
        return [
            LibraryDocumentMetadata(
                id: "congruence",
                title: "初中数学竞赛中的数论初步-同余.pdf",
                parentID: nil,
                fileName: "Congruence.pdf",
                isBundled: true,
                createdAt: pristineDate,
                modifiedAt: pristineDate
            ),
            LibraryDocumentMetadata(
                id: "geometry",
                title: "2026马哥各地中考几何压轴-学生卷.pdf",
                parentID: nil,
                fileName: "Geometry.pdf",
                isBundled: true,
                createdAt: pristineDate,
                modifiedAt: pristineDate
            )
        ]
    }

    /// Repairs registries created by pre-library builds or interrupted syncs before publishing
    /// them to SwiftUI. The result is deterministic for a given set of records.
    private func sanitizeRegistry(
        folders inputFolders: [LibraryFolder],
        documents inputDocuments: [LibraryDocumentMetadata]
    ) -> SanitizedLibraryRegistry {
        let repairDate = Date()
        var didChange = false
        var candidateDocuments = inputDocuments
        let bundledDefaults = defaultBundledMetadata()

        // Normalize only untouched samples. Renamed or moved samples retain their real timestamp.
        for bundledDefault in bundledDefaults {
            var foundMatchingID = false
            for index in candidateDocuments.indices
            where candidateDocuments[index].id == bundledDefault.id {
                foundMatchingID = true
                let candidate = candidateDocuments[index]
                let isPristineSample = candidate.title == bundledDefault.title
                    && candidate.parentID == nil
                    && candidate.fileName == bundledDefault.fileName
                    && candidate.trashedAt == nil
                    && !candidate.isFavorite
                    && candidate.kind == .pdf
                if isPristineSample {
                    // Normalize bundled content dates/shape without discarding the private causal
                    // registers. Dropping those stamps here would make every fresh device invent a
                    // new reference event and fight CloudKit forever on otherwise pristine samples.
                    var normalized = bundledDefault
                    normalized.parentRevision = candidate.parentRevision
                    normalized.favoriteRevision = candidate.favoriteRevision
                    normalized.trashRevision = candidate.trashRevision
                    normalized.modifiedAt = max(
                        normalized.contentModifiedAt,
                        candidate.parentRevision?.createdAt ?? .distantPast,
                        candidate.favoriteRevision?.createdAt ?? .distantPast,
                        candidate.trashRevision?.createdAt ?? .distantPast
                    )
                    if candidate != normalized {
                        candidateDocuments[index] = normalized
                        didChange = true
                    }
                }
            }
            // A missing sample is intentional after permanent deletion. Bundled defaults are
            // installed only when the registry is first created, never reintroduced here.
            _ = foundMatchingID
        }

        var documentsByID: [String: LibraryDocumentMetadata] = [:]
        for document in candidateDocuments {
            guard isSafePathComponent(document.id), isSafePathComponent(document.fileName) else {
                didChange = true
                continue
            }
            if let existing = documentsByID[document.id] {
                documentsByID[document.id] = preferredDocument(existing, document)
                didChange = true
            } else {
                documentsByID[document.id] = document
            }
        }
        var sanitizedDocuments = documentsByID.values.sorted { $0.id < $1.id }

        // Distinct records pointing at one imported PDF would overwrite each other's asset.
        var seenImportedFileNames = Set<String>()
        sanitizedDocuments = sanitizedDocuments.filter { document in
            guard !document.isBundled else { return true }
            let inserted = seenImportedFileNames.insert(document.fileName).inserted
            if !inserted { didChange = true }
            return inserted
        }

        let documentIDs = Set(sanitizedDocuments.map(\.id))
        var foldersByID: [String: LibraryFolder] = [:]
        for folder in inputFolders {
            guard isSafePathComponent(folder.id), !documentIDs.contains(folder.id) else {
                didChange = true
                continue
            }
            if let existing = foldersByID[folder.id] {
                foldersByID[folder.id] = preferredFolder(existing, folder)
                didChange = true
            } else {
                foldersByID[folder.id] = folder
            }
        }
        var sanitizedFolders = foldersByID.values.sorted { $0.id < $1.id }
        let folderIDs = Set(sanitizedFolders.map(\.id))

        let trashedFolderIDs = Set(
            sanitizedFolders.filter { $0.trashedAt != nil }.map(\.id)
        )
        for index in sanitizedFolders.indices {
            if let parentID = sanitizedFolders[index].parentID,
               (parentID == sanitizedFolders[index].id
                    || !folderIDs.contains(parentID)
                    || (sanitizedFolders[index].trashedAt == nil
                        && trashedFolderIDs.contains(parentID))) {
                sanitizedFolders[index].parentID = nil
                sanitizedFolders[index].parentRevision = nil
                sanitizedFolders[index].modifiedAt = repairDate
                didChange = true
            }
        }

        // Break one deterministic edge per pass until every parent chain terminates.
        while let cycle = firstFolderCycle(in: sanitizedFolders),
              let folderIDToDetach = cycle.max(),
              let index = sanitizedFolders.firstIndex(where: { $0.id == folderIDToDetach }) {
            sanitizedFolders[index].parentID = nil
            sanitizedFolders[index].parentRevision = nil
            sanitizedFolders[index].modifiedAt = repairDate
            didChange = true
        }

        for index in sanitizedDocuments.indices {
            if let parentID = sanitizedDocuments[index].parentID,
               (!folderIDs.contains(parentID)
                    || (sanitizedDocuments[index].trashedAt == nil
                        && trashedFolderIDs.contains(parentID))) {
                sanitizedDocuments[index].parentID = nil
                sanitizedDocuments[index].modifiedAt = repairDate
                didChange = true
            }
        }

        // Folders claim a sibling title first, then documents. Each group is ordered by stable ID,
        // so registry array order or CloudKit delivery order cannot change the chosen suffix.
        var occupiedNamesByScope: [String: Set<String>] = [:]
        for index in sanitizedFolders.indices {
            let baseTitle = canonicalRegistryTitle(
                sanitizedFolders[index].title,
                fallback: "未命名文件夹"
            )
            let uniqueTitle: String
            if sanitizedFolders[index].trashedAt == nil {
                let scope = registryScopeKey(sanitizedFolders[index].parentID)
                uniqueTitle = uniqueRegistryTitle(
                    baseTitle,
                    isDocument: false,
                    occupied: &occupiedNamesByScope[scope, default: []]
                )
            } else {
                uniqueTitle = baseTitle
            }
            if uniqueTitle != sanitizedFolders[index].title {
                sanitizedFolders[index].title = uniqueTitle
                sanitizedFolders[index].titleRevision = nil
                sanitizedFolders[index].modifiedAt = repairDate
                didChange = true
            }
        }
        for index in sanitizedDocuments.indices {
            let baseTitle = canonicalRegistryTitle(
                sanitizedDocuments[index].title,
                fallback: "未命名.pdf"
            )
            let uniqueTitle: String
            if sanitizedDocuments[index].trashedAt == nil {
                let scope = registryScopeKey(sanitizedDocuments[index].parentID)
                uniqueTitle = uniqueRegistryTitle(
                    baseTitle,
                    isDocument: true,
                    occupied: &occupiedNamesByScope[scope, default: []]
                )
            } else {
                uniqueTitle = baseTitle
            }
            if uniqueTitle != sanitizedDocuments[index].title {
                sanitizedDocuments[index].title = uniqueTitle
                sanitizedDocuments[index].modifiedAt = repairDate
                didChange = true
            }
        }

        return SanitizedLibraryRegistry(
            folders: sanitizedFolders,
            documents: sanitizedDocuments,
            didChange: didChange
        )
    }

    private func preferredDocument(
        _ first: LibraryDocumentMetadata,
        _ second: LibraryDocumentMetadata
    ) -> LibraryDocumentMetadata {
        if first.modifiedAt != second.modifiedAt {
            return first.modifiedAt > second.modifiedAt ? first : second
        }
        if first.isBundled != second.isBundled {
            return first.isBundled ? first : second
        }
        if first.createdAt != second.createdAt {
            return first.createdAt < second.createdAt ? first : second
        }
        if first.title != second.title {
            return first.title < second.title ? first : second
        }
        return first.fileName <= second.fileName ? first : second
    }

    private func preferredFolder(_ first: LibraryFolder, _ second: LibraryFolder) -> LibraryFolder {
        first.merged(with: second)
    }

    private func firstFolderCycle(in folders: [LibraryFolder]) -> [String]? {
        let foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        for startID in folders.map(\.id).sorted() {
            var path: [String] = []
            var positions: [String: Int] = [:]
            var cursor: String? = startID
            while let folderID = cursor, let folder = foldersByID[folderID] {
                if let cycleStart = positions[folderID] {
                    return Array(path[cycleStart...])
                }
                positions[folderID] = path.count
                path.append(folderID)
                cursor = folder.parentID
            }
        }
        return nil
    }

    private func registryScopeKey(_ parentID: String?) -> String {
        parentID.map { "folder:\($0)" } ?? "root"
    }

    private func canonicalRegistryTitle(_ title: String, fallback: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func uniqueRegistryTitle(
        _ baseTitle: String,
        isDocument: Bool,
        occupied: inout Set<String>
    ) -> String {
        var candidate = baseTitle
        var copyNumber = 2
        while !occupied.insert(normalizedComparisonKey(candidate)).inserted {
            candidate = registryTitle(
                baseTitle,
                appendingCopyNumber: copyNumber,
                preservesPathExtension: isDocument
            )
            copyNumber += 1
        }
        return candidate
    }

    private func registryTitle(
        _ title: String,
        appendingCopyNumber copyNumber: Int,
        preservesPathExtension: Bool
    ) -> String {
        guard preservesPathExtension else { return "\(title) \(copyNumber)" }
        let pathExtension = (title as NSString).pathExtension
        let baseName = (title as NSString).deletingPathExtension
        guard !pathExtension.isEmpty, !baseName.isEmpty else {
            return "\(title) \(copyNumber)"
        }
        return "\(baseName) \(copyNumber).\(pathExtension)"
    }

    private func uniqueAvailableDocumentIDs(
        _ candidates: [String],
        availableIDs: Set<String>
    ) -> [String] {
        var seen = Set<String>()
        return candidates.filter {
            availableIDs.contains($0) && seen.insert($0).inserted
        }
    }

    private func folderDepth(_ folderID: String, in folders: [LibraryFolder]) -> Int {
        let foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var depth = 0
        var cursor = foldersByID[folderID]?.parentID
        var visited = Set<String>()
        while let id = cursor, visited.insert(id).inserted {
            depth += 1
            cursor = foldersByID[id]?.parentID
        }
        return depth
    }

    private func uniqueRestoredTitle(
        _ proposedTitle: String,
        parentID: String?,
        excludingID: String,
        folders: [LibraryFolder],
        documents: [LibraryDocumentMetadata],
        isDocument: Bool
    ) -> String {
        var occupied = Set<String>()
        for folder in folders where folder.parentID == parentID
            && folder.id != excludingID
            && folder.trashedAt == nil {
            occupied.insert(normalizedComparisonKey(folder.title))
        }
        for document in documents where document.parentID == parentID
            && document.id != excludingID
            && document.trashedAt == nil {
            occupied.insert(normalizedComparisonKey(document.title))
        }
        guard occupied.contains(normalizedComparisonKey(proposedTitle)) else {
            return proposedTitle
        }
        var copyNumber = 2
        while true {
            let candidate = registryTitle(
                proposedTitle,
                appendingCopyNumber: copyNumber,
                preservesPathExtension: isDocument
            )
            if !occupied.contains(normalizedComparisonKey(candidate)) {
                return candidate
            }
            copyNumber += 1
        }
    }

    private func deleteItemsPermanently(
        folderIDs: Set<String>,
        documentIDs: Set<String>
    ) throws {
        for documentID in documentIDs { try requireEditableSharedDocument(documentID) }
        let deletedMetadata = documentMetadata.filter { documentIDs.contains($0.id) }
        let updatedFolders = folders.filter { !folderIDs.contains($0.id) }
        let updatedMetadata = documentMetadata.filter { !documentIDs.contains($0.id) }
        let updatedPages = pages.filter { !documentIDs.contains($0.documentID) }
        let deletionStamp = collaborationClock.nextStamp()
        var updatedTombstones = deletionTombstones
        for folderID in folderIDs {
            mergeDeletionTombstone(
                LibraryEntityDeletionTombstone(
                    reference: CloudLibraryEntityReference(kind: .folder, entityID: folderID),
                    stamp: deletionStamp
                ),
                into: &updatedTombstones
            )
        }
        for documentID in documentIDs {
            mergeDeletionTombstone(
                LibraryEntityDeletionTombstone(
                    reference: CloudLibraryEntityReference(kind: .document, entityID: documentID),
                    ownerDocumentID: documentID,
                    stamp: deletionStamp
                ),
                into: &updatedTombstones
            )
        }
        let transaction = try beginWorkspaceTransaction(
            kind: "permanent-delete",
            affectedURLs: [registryURL, collaborationClockURL, deletionTombstonesURL]
        )
        do {
            try persistDeletionTombstones(updatedTombstones)
            try persistCollaborationClock()
            try persistRegistry(
                folders: updatedFolders,
                documents: updatedMetadata,
                pages: updatedPages
            )
            try commitWorkspaceTransaction(transaction)
        } catch {
            rollbackWorkspaceTransaction(transaction)
            throw error
        }

        deletionTombstones = updatedTombstones
        folders = updatedFolders
        documentMetadata = updatedMetadata
        pages = updatedPages
        for documentID in documentIDs { pendingDocumentReferences[documentID] = nil }
        try? persistPendingDocumentReferences()
        openDocumentIDs.removeAll(where: documentIDs.contains)
        cancelPendingSaves(forDocumentsNotIn: Set(updatedMetadata.map(\.id)))

        cleanupDeletedDocumentAssets(deletedMetadata)

        rebuildWorkspaceDocuments()
        persistOpenDocuments()
        signalLocalCloudChange()
    }

    private func cleanupDeletedDocumentAssets(_ deletedMetadata: [LibraryDocumentMetadata]) {
        for metadata in deletedMetadata {
            if !metadata.isBundled, let url = fileURL(for: metadata) {
                try? fileManager.removeItem(at: url)
            }
            let drawingsURL = documentDrawingsDirectory(
                for: metadata.id,
                createIfNeeded: false
            )
            try? fileManager.removeItem(at: drawingsURL)
            pdfCache[metadata.id] = nil
            thumbnailCache = thumbnailCache.filter {
                !$0.key.hasPrefix("\(metadata.id)#")
            }
            userDefaults.removeObject(forKey: lastPageKey(metadata.id))
        }
    }

    private func drawCanvasBackground(
        in context: CGContext,
        bounds: CGRect,
        style: CanvasBackgroundStyle,
        color: CanvasBackgroundColor
    ) {
        let background = canvasUIColor(color)
        context.setFillColor(background.cgColor)
        context.fill(bounds)
        guard style != .blank else { return }

        let guideColor: UIColor = color == .dark
            ? UIColor.white.withAlphaComponent(0.22)
            : UIColor(red: 0.35, green: 0.45, blue: 0.58, alpha: 0.22)
        let spacing: CGFloat = 32
        context.setStrokeColor(guideColor.cgColor)
        context.setFillColor(guideColor.cgColor)
        context.setLineWidth(1)

        switch style {
        case .blank:
            break
        case .ruled:
            for y in stride(from: spacing, through: bounds.height - spacing, by: spacing) {
                context.move(to: CGPoint(x: 40, y: y))
                context.addLine(to: CGPoint(x: bounds.width - 40, y: y))
            }
            context.strokePath()
        case .grid:
            for x in stride(from: spacing, through: bounds.width - spacing, by: spacing) {
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x, y: bounds.height))
            }
            for y in stride(from: spacing, through: bounds.height - spacing, by: spacing) {
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: bounds.width, y: y))
            }
            context.strokePath()
        case .dotted:
            for x in stride(from: spacing, through: bounds.width - spacing, by: spacing) {
                for y in stride(from: spacing, through: bounds.height - spacing, by: spacing) {
                    context.fillEllipse(in: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3))
                }
            }
        }
    }

    private func canvasUIColor(_ color: CanvasBackgroundColor) -> UIColor {
        switch color {
        case .white: UIColor(white: 0.985, alpha: 1)
        case .ivory: UIColor(red: 0.965, green: 0.945, blue: 0.88, alpha: 1)
        case .yellow: UIColor(red: 0.99, green: 0.95, blue: 0.68, alpha: 1)
        case .blue: UIColor(red: 0.86, green: 0.94, blue: 0.99, alpha: 1)
        case .green: UIColor(red: 0.87, green: 0.96, blue: 0.88, alpha: 1)
        case .dark: UIColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1)
        }
    }

    private func fileDates(for url: URL) -> (createdAt: Date, modifiedAt: Date) {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let modifiedAt = attributes?[.modificationDate] as? Date ?? Date()
        let createdAt = attributes?[.creationDate] as? Date ?? modifiedAt
        return (createdAt, modifiedAt)
    }

    private func normalizedTitle(_ proposedTitle: String) throws -> String {
        let title = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw LibraryStoreError.invalidName }
        return title
    }

    private func normalizedComparisonKey(_ title: String) -> String {
        title.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private func validateParentFolder(_ parentID: String?) throws {
        guard let parentID else { return }
        guard folders.contains(where: { $0.id == parentID && $0.trashedAt == nil }) else {
            throw LibraryStoreError.folderNotFound(parentID)
        }
    }

    private func validateUniqueTitle(
        _ title: String,
        in parentID: String?,
        excludingID: String? = nil
    ) throws {
        let comparisonKey = normalizedComparisonKey(title)
        let folderConflict = folders.contains {
            $0.parentID == parentID
                && $0.id != excludingID
                && $0.trashedAt == nil
                && normalizedComparisonKey($0.title) == comparisonKey
        }
        let documentConflict = documentMetadata.contains {
            $0.parentID == parentID
                && $0.id != excludingID
                && $0.trashedAt == nil
                && normalizedComparisonKey($0.title) == comparisonKey
        }
        guard !folderConflict, !documentConflict else {
            throw LibraryStoreError.nameConflict(title)
        }
    }

    private func descendantFolderIDs(of folderID: String) -> Set<String> {
        var result = Set<String>()
        var pending = [folderID]
        while let nextParentID = pending.popLast() {
            for folder in folders where folder.parentID == nextParentID {
                if result.insert(folder.id).inserted {
                    pending.append(folder.id)
                }
            }
        }
        return result
    }

    private func validate(snapshot: LibrarySnapshot) throws {
        guard snapshot.schemaVersion > 0,
              snapshot.schemaVersion <= LibrarySnapshot.currentSchemaVersion else {
            throw LibraryStoreError.invalidSnapshot("不支持的版本 \(snapshot.schemaVersion)")
        }

        let folderIDs = snapshot.folders.map(\.id)
        let documentIDs = snapshot.documents.map(\.id)
        let pageIDs = snapshot.pages.map(\.id)
        guard Set(folderIDs).count == folderIDs.count,
              Set(documentIDs).count == documentIDs.count,
              Set(pageIDs).count == pageIDs.count,
              Set(folderIDs).isDisjoint(with: Set(documentIDs)),
              Set(folderIDs).isDisjoint(with: Set(pageIDs)),
              Set(documentIDs).isDisjoint(with: Set(pageIDs)) else {
            throw LibraryStoreError.invalidSnapshot("存在重复 ID")
        }
        let availableFolderIDs = Set(folderIDs)
        var siblingNames: [String: Set<String>] = [:]

        func validateName(_ title: String, parentID: String?, checksUniqueness: Bool) throws {
            let canonicalTitle = try normalizedTitle(title)
            guard canonicalTitle == title else {
                throw LibraryStoreError.invalidSnapshot("名称包含首尾空格")
            }
            guard checksUniqueness else { return }
            let scope = parentID.map { "folder:\($0)" } ?? "root"
            let key = normalizedComparisonKey(title)
            guard siblingNames[scope, default: []].insert(key).inserted else {
                throw LibraryStoreError.invalidSnapshot("同一文件夹中存在重名项目")
            }
        }

        for folder in snapshot.folders {
            guard !folder.id.isEmpty else {
                throw LibraryStoreError.invalidSnapshot("文件夹 ID 为空")
            }
            if let parentID = folder.parentID, !availableFolderIDs.contains(parentID) {
                throw LibraryStoreError.invalidSnapshot("文件夹引用了不存在的父文件夹")
            }
            try validateName(
                folder.title,
                parentID: folder.parentID,
                checksUniqueness: folder.trashedAt == nil
            )

            var visited = Set([folder.id])
            var cursor = folder.parentID
            while let folderID = cursor {
                guard visited.insert(folderID).inserted else {
                    throw LibraryStoreError.invalidSnapshot("文件夹层级存在循环")
                }
                cursor = snapshot.folders.first(where: { $0.id == folderID })?.parentID
            }
        }

        var nonBundledFileNames = Set<String>()
        for document in snapshot.documents {
            guard isSafePathComponent(document.id), isSafePathComponent(document.fileName) else {
                throw LibraryStoreError.invalidSnapshot("文档包含无效路径")
            }
            if let parentID = document.parentID, !availableFolderIDs.contains(parentID) {
                throw LibraryStoreError.invalidSnapshot("文档引用了不存在的父文件夹")
            }
            if !document.isBundled,
               !nonBundledFileNames.insert(document.fileName).inserted {
                throw LibraryStoreError.invalidSnapshot("多个文档引用了同一 PDF 文件")
            }
            try validateName(
                document.title,
                parentID: document.parentID,
                checksUniqueness: document.trashedAt == nil
            )
        }

        let availableDocumentIDs = Set(documentIDs)
        var pageOrdersByDocument: [String: Set<Int>] = [:]
        for page in snapshot.pages {
            guard !page.id.isEmpty, isSafePathComponent(page.id) else {
                throw LibraryStoreError.invalidSnapshot("页面 ID 无效")
            }
            guard availableDocumentIDs.contains(page.documentID) else {
                throw LibraryStoreError.invalidSnapshot("页面引用了不存在的文稿")
            }
            guard page.orderIndex >= 0,
                  page.width.isFinite, page.width > 0,
                  page.height.isFinite, page.height > 0 else {
                throw LibraryStoreError.invalidSnapshot("页面尺寸或顺序无效")
            }
            pageOrdersByDocument[page.documentID, default: []].insert(page.orderIndex)
        }
    }

    private func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains(":")
    }

    private func pageIndex(fromAssetFileName fileName: String) -> Int? {
        guard fileName.hasPrefix("page-") else { return nil }
        let baseName = fileName.split(separator: ".", maxSplits: 1).first ?? ""
        guard let pageNumber = Int(baseName.dropFirst("page-".count)), pageNumber > 0 else {
            return nil
        }
        return pageNumber - 1
    }

    private func migrateLegacyCongruenceDrawings(from applicationSupport: URL) {
        let legacyDirectory = applicationSupport
            .appendingPathComponent("TiyiNote", isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Congruence", isDirectory: true)
            .appendingPathComponent("Drawings", isDirectory: true)
        let targetDirectory = drawingsDirectory.appendingPathComponent("Congruence", isDirectory: true)

        guard
            let legacyFiles = try? fileManager.contentsOfDirectory(
                at: legacyDirectory,
                includingPropertiesForKeys: nil
            ),
            !legacyFiles.isEmpty
        else { return }

        try? fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        for sourceURL in legacyFiles where sourceURL.pathExtension == "drawing" {
            let targetURL = targetDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            if !fileManager.fileExists(atPath: targetURL.path) {
                try? fileManager.copyItem(at: sourceURL, to: targetURL)
            }
        }
    }

    private func persistOpenDocuments() {
        userDefaults.set(openDocumentIDs, forKey: "pdfWorkspace.openDocumentIDs")
    }

    private func collaborationFrontier(
        from operations: [CollaborationOperation]
    ) -> CollaborationVersionVector {
        var frontier = CollaborationVersionVector()
        for operation in operations {
            frontier.formUnion(operation.stamp.context)
            frontier.observe(operation.stamp.dot)
        }
        return frontier
    }

    nonisolated private static func prepareDrawingCollaborationPlan(
        drawing: PKDrawing,
        baseDrawing: PKDrawing?,
        causalContext: CollaborationVersionVector?,
        assumesOnlyAppendedStrokes: Bool,
        preparedPersistence: PreparedDrawingPersistence?,
        page: LibraryPage,
        sourceOperations: [CollaborationOperation],
        existingDrawingURL: URL
    ) -> PreparedDrawingCollaborationPlan? {
        var operations = sourceOperations
        let preexistingOperationCount = operations.count
        let hasStrokeHistory = operations.contains { operation in
            switch operation.payload {
            case .strokeUpsert, .strokeDelete: true
            default: false
            }
        }
        if !hasStrokeHistory,
           let previousData = try? Data(contentsOf: existingDrawingURL),
           let previousDrawing = try? PKDrawing(data: previousData),
           !previousDrawing.strokes.isEmpty {
            operations.append(contentsOf: preparedBootstrapDrawingOperations(
                from: previousDrawing,
                page: page
            ))
        }
        guard !Task.isCancelled else { return nil }

        var observedFrontier = CollaborationVersionVector()
        var maximumLamport: UInt64 = 0
        for operation in operations {
            observedFrontier.formUnion(operation.stamp.context)
            observedFrontier.observe(operation.stamp.dot)
            maximumLamport = max(maximumLamport, operation.stamp.lamport)
        }
        guard !Task.isCancelled else { return nil }

        if let baseDrawing,
           drawing.strokes.count >= baseDrawing.strokes.count,
           baseDrawing.strokes.isEmpty || assumesOnlyAppendedStrokes {
            let baseStrokeCount = baseDrawing.strokes.count
            let nextZIndex = max(
                baseStrokeCount,
                operations.compactMap { operation -> Int? in
                    guard case .strokeUpsert(let stroke) = operation.payload else { return nil }
                    return stroke.zIndex + 1
                }.max() ?? 0
            )
            let expectedAppendedStrokeCount = drawing.strokes.count - baseStrokeCount
            let preparedAppendedStrokeData = preparedPersistence?.appendedStrokeData.flatMap {
                $0.count == expectedAppendedStrokeCount ? $0 : nil
            }
            let mutations = drawing.strokes
                .dropFirst(baseStrokeCount)
                .enumerated()
                .map { offset, stroke in
                    PreparedDrawingCollaborationMutation.upsert(
                        id: UUID().uuidString.lowercased(),
                        data: preparedAppendedStrokeData?[offset]
                            ?? PKDrawing(strokes: [stroke]).dataRepresentation(),
                        zIndex: nextZIndex + offset
                    )
                }
            return PreparedDrawingCollaborationPlan(
                page: page,
                baseOperations: operations,
                preexistingOperationCount: preexistingOperationCount,
                mutations: mutations,
                initialContext: causalContext ?? observedFrontier,
                observedFrontier: observedFrontier,
                maximumLamport: maximumLamport,
                path: .appendOnly
            )
        }

        let currentState = CollaborationMergeEngine.materialize(operations)
        guard !Task.isCancelled else { return nil }
        let storedStrokes = currentState.strokes.values.sorted(by: {
            if $0.zIndex != $1.zIndex { return $0.zIndex < $1.zIndex }
            return $0.id < $1.id
        })

        struct BaseStrokeIdentity {
            let index: Int
            let stored: CollaborationInkStroke
            let exactFingerprint: String
            let stableFingerprint: String
        }
        var baseIdentities: [BaseStrokeIdentity] = []
        var deletableStrokeIDs: Set<String>
        if let baseDrawing {
            // Remote strokes absent from the editor's visual base are never eligible for deletion.
            deletableStrokeIDs = []
            let preparedBaseStrokes = preparedPersistence?.baseStrokes.flatMap {
                $0.count == baseDrawing.strokes.count ? $0 : nil
            }
            let baseStrokePersistence = baseDrawing.strokes.enumerated().map { index, stroke in
                if let preparedStroke = preparedBaseStrokes?[index] {
                    return preparedStroke
                }
                let data = PKDrawing(strokes: [stroke]).dataRepresentation()
                return PreparedDrawingStrokePersistence(
                    data: data,
                    exactFingerprint: Self.collaborationStrokeFingerprint(data),
                    stableFingerprint: Self.collaborationStableStrokeFingerprint(data)
                )
            }

            var storedIndicesByData: [Data: [Int]] = [:]
            for (index, stored) in storedStrokes.enumerated().reversed() {
                storedIndicesByData[stored.drawingData, default: []].append(index)
            }
            var claimedStoredIndices: Set<Int> = []
            var storedIndexByBaseIndex: [Int: Int] = [:]
            for (baseIndex, preparedStroke) in baseStrokePersistence.enumerated() {
                guard var candidates = storedIndicesByData[preparedStroke.data] else { continue }
                while let candidate = candidates.popLast() {
                    if !claimedStoredIndices.contains(candidate) {
                        claimedStoredIndices.insert(candidate)
                        storedIndexByBaseIndex[baseIndex] = candidate
                        break
                    }
                }
                storedIndicesByData[preparedStroke.data] = candidates
            }

            let unresolvedBaseIndices = baseStrokePersistence.indices.filter {
                storedIndexByBaseIndex[$0] == nil
            }
            guard !Task.isCancelled else { return nil }
            if !unresolvedBaseIndices.isEmpty {
                var exactCandidates: [String: [Int]] = [:]
                var stableCandidates: [String: [Int]] = [:]
                for storedIndex in storedStrokes.indices.reversed()
                where !claimedStoredIndices.contains(storedIndex) {
                    let data = storedStrokes[storedIndex].drawingData
                    exactCandidates[
                        Self.collaborationStrokeFingerprint(data),
                        default: []
                    ].append(storedIndex)
                    stableCandidates[
                        Self.collaborationStableStrokeFingerprint(data),
                        default: []
                    ].append(storedIndex)
                }

                func claimStoredIndex(
                    for fingerprint: String,
                    candidates: inout [String: [Int]]
                ) -> Int? {
                    guard var indices = candidates[fingerprint] else { return nil }
                    while let candidate = indices.popLast() {
                        if !claimedStoredIndices.contains(candidate) {
                            candidates[fingerprint] = indices
                            claimedStoredIndices.insert(candidate)
                            return candidate
                        }
                    }
                    candidates[fingerprint] = indices
                    return nil
                }

                for baseIndex in unresolvedBaseIndices {
                    let fingerprint = baseStrokePersistence[baseIndex].exactFingerprint
                    if let storedIndex = claimStoredIndex(
                        for: fingerprint,
                        candidates: &exactCandidates
                    ) {
                        storedIndexByBaseIndex[baseIndex] = storedIndex
                    }
                }
                for baseIndex in unresolvedBaseIndices
                where storedIndexByBaseIndex[baseIndex] == nil {
                    let fingerprint = baseStrokePersistence[baseIndex].stableFingerprint
                    if let storedIndex = claimStoredIndex(
                        for: fingerprint,
                        candidates: &stableCandidates
                    ) {
                        storedIndexByBaseIndex[baseIndex] = storedIndex
                    }
                }
            }
            guard !Task.isCancelled else { return nil }

            for baseIndex in baseStrokePersistence.indices {
                guard let storedIndex = storedIndexByBaseIndex[baseIndex] else { continue }
                let matched = storedStrokes[storedIndex]
                let preparedStroke = baseStrokePersistence[baseIndex]
                deletableStrokeIDs.insert(matched.id)
                baseIdentities.append(
                    BaseStrokeIdentity(
                        index: baseIndex,
                        stored: matched,
                        exactFingerprint: preparedStroke.exactFingerprint,
                        stableFingerprint: preparedStroke.stableFingerprint
                    )
                )
            }
        } else {
            deletableStrokeIDs = Set(currentState.strokes.keys)
            baseIdentities = storedStrokes.enumerated().map { index, stroke in
                BaseStrokeIdentity(
                    index: index,
                    stored: stroke,
                    exactFingerprint: Self.collaborationStrokeFingerprint(stroke.drawingData),
                    stableFingerprint:
                        Self.collaborationStableStrokeFingerprint(stroke.drawingData)
                )
            }
        }

        struct DesiredStroke {
            let index: Int
            let data: Data
            let exactFingerprint: String
            let stableFingerprint: String
        }
        let preparedDrawingStrokes = preparedPersistence?.drawingStrokes.flatMap {
            $0.count == drawing.strokes.count ? $0 : nil
        }
        let desiredStrokes = drawing.strokes.enumerated().map { index, stroke in
            let preparedStroke = preparedDrawingStrokes?[index]
            let data = preparedStroke?.data
                ?? PKDrawing(strokes: [stroke]).dataRepresentation()
            return DesiredStroke(
                index: index,
                data: data,
                exactFingerprint: preparedStroke?.exactFingerprint
                    ?? Self.collaborationStrokeFingerprint(data),
                stableFingerprint: preparedStroke?.stableFingerprint
                    ?? Self.collaborationStableStrokeFingerprint(data)
            )
        }
        guard !Task.isCancelled else { return nil }
        var exactIdentityByDesiredIndex: [Int: CollaborationInkStroke] = [:]
        var usedStrokeIDs: Set<String> = []
        var exactBaseCandidates: [String: [Int]] = [:]
        var stableBaseCandidates: [String: [Int]] = [:]
        for baseIdentityIndex in baseIdentities.indices.reversed() {
            let identity = baseIdentities[baseIdentityIndex]
            exactBaseCandidates[identity.exactFingerprint, default: []].append(baseIdentityIndex)
            stableBaseCandidates[identity.stableFingerprint, default: []].append(baseIdentityIndex)
        }

        func claimBaseIdentityIndex(
            for fingerprint: String,
            candidates: inout [String: [Int]]
        ) -> Int? {
            guard var indices = candidates[fingerprint] else { return nil }
            while let candidate = indices.popLast() {
                if !usedStrokeIDs.contains(baseIdentities[candidate].stored.id) {
                    candidates[fingerprint] = indices
                    return candidate
                }
            }
            candidates[fingerprint] = indices
            return nil
        }

        for desired in desiredStrokes {
            guard let matchedIndex = claimBaseIdentityIndex(
                for: desired.exactFingerprint,
                candidates: &exactBaseCandidates
            ) else { continue }
            let matched = baseIdentities[matchedIndex].stored
            exactIdentityByDesiredIndex[desired.index] = matched
            usedStrokeIDs.insert(matched.id)
            deletableStrokeIDs.remove(matched.id)
        }
        for desired in desiredStrokes where exactIdentityByDesiredIndex[desired.index] == nil {
            guard let matchedIndex = claimBaseIdentityIndex(
                for: desired.stableFingerprint,
                candidates: &stableBaseCandidates
            ) else { continue }
            let matched = baseIdentities[matchedIndex].stored
            exactIdentityByDesiredIndex[desired.index] = matched
            usedStrokeIDs.insert(matched.id)
            deletableStrokeIDs.remove(matched.id)
        }
        guard !Task.isCancelled else { return nil }

        let baseIdentityByDrawingIndex = Dictionary(
            uniqueKeysWithValues: baseIdentities.map { ($0.index, $0) }
        )
        var mutations: [PreparedDrawingCollaborationMutation] = []
        for desired in desiredStrokes {
            if exactIdentityByDesiredIndex[desired.index] != nil { continue }
            if let matched = baseIdentityByDrawingIndex[desired.index]?.stored,
               !usedStrokeIDs.contains(matched.id) {
                usedStrokeIDs.insert(matched.id)
                deletableStrokeIDs.remove(matched.id)
                mutations.append(
                    .upsert(id: matched.id, data: desired.data, zIndex: matched.zIndex)
                )
            } else {
                mutations.append(
                    .upsert(
                        id: UUID().uuidString.lowercased(),
                        data: desired.data,
                        zIndex: desired.index
                    )
                )
            }
        }
        for stroke in currentState.strokes.values where deletableStrokeIDs.contains(stroke.id) {
            mutations.append(.delete(strokeID: stroke.id))
        }

        return PreparedDrawingCollaborationPlan(
            page: page,
            baseOperations: operations,
            preexistingOperationCount: preexistingOperationCount,
            mutations: mutations,
            initialContext: causalContext ?? currentState.frontier,
            observedFrontier: observedFrontier,
            maximumLamport: maximumLamport,
            path: .fullDiff
        )
    }

    nonisolated private static func preparedBootstrapDrawingOperations(
        from drawing: PKDrawing,
        page: LibraryPage
    ) -> [CollaborationOperation] {
        var migrationClock = CollaborationReplicaClock(
            actorID: "migration:\(page.documentID):\(page.id)"
        )
        return drawing.strokes.enumerated().map { zIndex, stroke in
            let data = PKDrawing(strokes: [stroke]).dataRepresentation()
            let seed = Data(
                "\(page.id)|\(zIndex)|\(Self.collaborationStrokeFingerprint(stroke))".utf8
            )
            let operationID = "bootstrap-\(Self.collaborationFingerprint(seed))"
            let strokeID = "stroke-\(Self.collaborationFingerprint(seed))"
            return CollaborationOperation(
                workspaceID: "personal-library",
                documentID: page.documentID,
                pageID: page.id,
                stamp: migrationClock.nextStamp(
                    operationID: operationID,
                    createdAt: page.createdAt
                ),
                payload: .strokeUpsert(
                    CollaborationInkStroke(id: strokeID, drawingData: data, zIndex: zIndex)
                )
            )
        }
    }

    private func commitPreparedDrawingCollaborationPlan(
        _ plan: PreparedDrawingCollaborationPlan
    ) throws -> CollaborationVersionVector {
        collaborationClock.observe(
            frontier: plan.observedFrontier,
            maximumLamport: plan.maximumLamport
        )
        var emissionContext = plan.initialContext
        var operations = plan.baseOperations
        for mutation in plan.mutations {
            let stamp = collaborationClock.nextStamp(observedContext: emissionContext)
            emissionContext.observe(stamp.dot)
            let payload: CollaborationOperationPayload
            switch mutation {
            case .upsert(let id, let data, let zIndex):
                payload = .strokeUpsert(
                    CollaborationInkStroke(id: id, drawingData: data, zIndex: zIndex)
                )
            case .delete(let strokeID):
                payload = .strokeDelete(strokeID: strokeID)
            }
            operations.append(
                CollaborationOperation(
                    workspaceID: "personal-library",
                    documentID: plan.page.documentID,
                    pageID: plan.page.id,
                    stamp: stamp,
                    payload: payload
                )
            )
        }

        let didBootstrap = plan.preexistingOperationCount < plan.baseOperations.count
        guard didBootstrap || !plan.mutations.isEmpty else {
#if DEBUG
            if case .fullDiff = plan.path {
                debugFullDrawingDiffSaveCount += 1
            }
#endif
            return emissionContext
        }
#if DEBUG
        switch plan.path {
        case .appendOnly:
            debugAppendOnlyDrawingSaveCount += 1
        case .fullDiff:
            debugFullDrawingDiffSaveCount += 1
        }
#endif
        scheduleCollaborationOperationsSave(
            operations,
            forPageID: plan.page.id,
            in: plan.page.documentID
        )
        try persistCollaborationClock()
        return emissionContext
    }

    private func recordDrawingCollaborationOperations(
        _ drawing: PKDrawing,
        replacing baseDrawing: PKDrawing? = nil,
        causalContext: CollaborationVersionVector? = nil,
        assumesOnlyAppendedStrokes: Bool = false,
        preparedPersistence: PreparedDrawingPersistence? = nil,
        forPage pageIndex: Int,
        in documentID: String
    ) throws -> CollaborationVersionVector {
        guard let page = pageMetadata(at: pageIndex, in: documentID) else {
            return causalContext ?? CollaborationVersionVector()
        }
        var operations = loadCollaborationOperations(forPageID: page.id, in: documentID)

        let hasStrokeHistory = operations.contains { operation in
            switch operation.payload {
            case .strokeUpsert, .strokeDelete: true
            default: false
            }
        }
        var didBootstrapDrawingHistory = false
        if !hasStrokeHistory,
           let previousData = try? Data(contentsOf: drawingURL(forPageID: page.id, in: documentID)),
           let previousDrawing = try? PKDrawing(data: previousData),
           !previousDrawing.strokes.isEmpty {
            operations.append(contentsOf: bootstrapCollaborationOperations(
                from: previousDrawing,
                page: page
            ))
            didBootstrapDrawingHistory = true
        }

        for operation in operations {
            collaborationClock.observe(operation.stamp)
        }

        if let baseDrawing,
           drawing.strokes.count >= baseDrawing.strokes.count,
           baseDrawing.strokes.isEmpty || assumesOnlyAppendedStrokes {
            var emissionContext = causalContext ?? collaborationFrontier(from: operations)
            func makeStamp() -> CollaborationStamp {
                let stamp = collaborationClock.nextStamp(observedContext: emissionContext)
                emissionContext.observe(stamp.dot)
                return stamp
            }

            let baseStrokeCount = baseDrawing.strokes.count
            let nextZIndex = max(
                baseStrokeCount,
                operations.compactMap { operation -> Int? in
                    guard case .strokeUpsert(let stroke) = operation.payload else { return nil }
                    return stroke.zIndex + 1
                }.max() ?? 0
            )
            let expectedAppendedStrokeCount = drawing.strokes.count - baseStrokeCount
            let preparedAppendedStrokeData = preparedPersistence?.appendedStrokeData.flatMap {
                $0.count == expectedAppendedStrokeCount ? $0 : nil
            }
            let appendedOperations = drawing.strokes
                .dropFirst(baseStrokeCount)
                .enumerated()
                .map { offset, stroke in
                    CollaborationOperation(
                        workspaceID: "personal-library",
                        documentID: documentID,
                        pageID: page.id,
                        stamp: makeStamp(),
                        payload: .strokeUpsert(
                            CollaborationInkStroke(
                                id: UUID().uuidString.lowercased(),
                                drawingData: preparedAppendedStrokeData?[offset]
                                    ?? PKDrawing(strokes: [stroke]).dataRepresentation(),
                                zIndex: nextZIndex + offset
                            )
                        )
                    )
                }
            guard didBootstrapDrawingHistory || !appendedOperations.isEmpty else {
                return emissionContext
            }
#if DEBUG
            debugAppendOnlyDrawingSaveCount += 1
#endif
            operations.append(contentsOf: appendedOperations)
            scheduleCollaborationOperationsSave(
                operations,
                forPageID: page.id,
                in: documentID
            )
            try persistCollaborationClock()
            return emissionContext
        }

#if DEBUG
        debugFullDrawingDiffSaveCount += 1
#endif
        let currentState = CollaborationMergeEngine.materialize(operations)
        let storedStrokes = currentState.strokes.values.sorted(by: {
            if $0.zIndex != $1.zIndex { return $0.zIndex < $1.zIndex }
            return $0.id < $1.id
        })

        struct BaseStrokeIdentity {
            let index: Int
            let stored: CollaborationInkStroke
            let exactFingerprint: String
            let stableFingerprint: String
        }
        var baseIdentities: [BaseStrokeIdentity] = []
        var deletableStrokeIDs: Set<String>
        if let baseDrawing {
            // Only strokes present in the editor's visual base are eligible for deletion. Remote
            // strokes downloaded while this canvas stayed dirty are absent from that base and
            // therefore survive the local delta.
            deletableStrokeIDs = []
            let preparedBaseStrokes = preparedPersistence?.baseStrokes.flatMap {
                $0.count == baseDrawing.strokes.count ? $0 : nil
            }
            let baseStrokePersistence = baseDrawing.strokes.enumerated().map { index, stroke in
                if let preparedStroke = preparedBaseStrokes?[index] {
                    return preparedStroke
                }
                let data = PKDrawing(strokes: [stroke]).dataRepresentation()
                return PreparedDrawingStrokePersistence(
                    data: data,
                    exactFingerprint: Self.collaborationStrokeFingerprint(data),
                    stableFingerprint: Self.collaborationStableStrokeFingerprint(data)
                )
            }

            // Most local strokes preserve the exact serialized bytes. Resolve that overwhelmingly
            // common case without decoding and formatting every stored Pencil sample again.
            var storedIndicesByData: [Data: [Int]] = [:]
            for (index, stored) in storedStrokes.enumerated().reversed() {
                storedIndicesByData[stored.drawingData, default: []].append(index)
            }
            var claimedStoredIndices: Set<Int> = []
            var storedIndexByBaseIndex: [Int: Int] = [:]
            for (baseIndex, preparedStroke) in baseStrokePersistence.enumerated() {
                guard var candidates = storedIndicesByData[preparedStroke.data] else { continue }
                while let candidate = candidates.popLast() {
                    if !claimedStoredIndices.contains(candidate) {
                        claimedStoredIndices.insert(candidate)
                        storedIndexByBaseIndex[baseIndex] = candidate
                        break
                    }
                }
                storedIndicesByData[preparedStroke.data] = candidates
            }

            let unresolvedBaseIndices = baseStrokePersistence.indices.filter {
                storedIndexByBaseIndex[$0] == nil
            }
            if !unresolvedBaseIndices.isEmpty {
                // PencilKit may normalize timing/pressure bytes during serialization. Only when raw
                // bytes fail do we pay for the geometry fingerprints, and indexed buckets keep the
                // matching pass linear even for pages with thousands of strokes.
                var exactCandidates: [String: [Int]] = [:]
                var stableCandidates: [String: [Int]] = [:]
                for storedIndex in storedStrokes.indices.reversed()
                where !claimedStoredIndices.contains(storedIndex) {
                    let data = storedStrokes[storedIndex].drawingData
                    exactCandidates[
                        Self.collaborationStrokeFingerprint(data),
                        default: []
                    ].append(storedIndex)
                    stableCandidates[
                        Self.collaborationStableStrokeFingerprint(data),
                        default: []
                    ].append(storedIndex)
                }

                func claimStoredIndex(
                    for fingerprint: String,
                    candidates: inout [String: [Int]]
                ) -> Int? {
                    guard var indices = candidates[fingerprint] else { return nil }
                    while let candidate = indices.popLast() {
                        if !claimedStoredIndices.contains(candidate) {
                            candidates[fingerprint] = indices
                            claimedStoredIndices.insert(candidate)
                            return candidate
                        }
                    }
                    candidates[fingerprint] = indices
                    return nil
                }

                for baseIndex in unresolvedBaseIndices {
                    let fingerprint = baseStrokePersistence[baseIndex].exactFingerprint
                    if let storedIndex = claimStoredIndex(
                        for: fingerprint,
                        candidates: &exactCandidates
                    ) {
                        storedIndexByBaseIndex[baseIndex] = storedIndex
                    }
                }
                for baseIndex in unresolvedBaseIndices
                where storedIndexByBaseIndex[baseIndex] == nil {
                    let fingerprint = baseStrokePersistence[baseIndex].stableFingerprint
                    if let storedIndex = claimStoredIndex(
                        for: fingerprint,
                        candidates: &stableCandidates
                    ) {
                        storedIndexByBaseIndex[baseIndex] = storedIndex
                    }
                }
            }

            for baseIndex in baseStrokePersistence.indices {
                guard let storedIndex = storedIndexByBaseIndex[baseIndex] else { continue }
                let matched = storedStrokes[storedIndex]
                let preparedStroke = baseStrokePersistence[baseIndex]
                deletableStrokeIDs.insert(matched.id)
                baseIdentities.append(
                    BaseStrokeIdentity(
                        index: baseIndex,
                        stored: matched,
                        exactFingerprint: preparedStroke.exactFingerprint,
                        stableFingerprint: preparedStroke.stableFingerprint
                    )
                )
            }
        } else {
            deletableStrokeIDs = Set(currentState.strokes.keys)
            baseIdentities = storedStrokes.enumerated().map { index, stroke in
                BaseStrokeIdentity(
                    index: index,
                    stored: stroke,
                    exactFingerprint: Self.collaborationStrokeFingerprint(stroke.drawingData),
                    stableFingerprint:
                        Self.collaborationStableStrokeFingerprint(stroke.drawingData)
                )
            }
        }

        var emissionContext = causalContext ?? currentState.frontier
        func makeStamp() -> CollaborationStamp {
            let stamp = collaborationClock.nextStamp(observedContext: emissionContext)
            emissionContext.observe(stamp.dot)
            return stamp
        }

        struct DesiredStroke {
            let index: Int
            let data: Data
            let exactFingerprint: String
            let stableFingerprint: String
        }
        let preparedDrawingStrokes = preparedPersistence?.drawingStrokes.flatMap {
            $0.count == drawing.strokes.count ? $0 : nil
        }
        let desiredStrokes = drawing.strokes.enumerated().map { index, stroke in
            let preparedStroke = preparedDrawingStrokes?[index]
            let data = preparedStroke?.data
                ?? PKDrawing(strokes: [stroke]).dataRepresentation()
            return DesiredStroke(
                index: index,
                data: data,
                exactFingerprint: preparedStroke?.exactFingerprint
                    ?? Self.collaborationStrokeFingerprint(data),
                stableFingerprint: preparedStroke?.stableFingerprint
                    ?? Self.collaborationStableStrokeFingerprint(data)
            )
        }
        var exactIdentityByDesiredIndex: [Int: CollaborationInkStroke] = [:]
        var usedStrokeIDs: Set<String> = []
        var exactBaseCandidates: [String: [Int]] = [:]
        var stableBaseCandidates: [String: [Int]] = [:]
        for baseIdentityIndex in baseIdentities.indices.reversed() {
            let identity = baseIdentities[baseIdentityIndex]
            exactBaseCandidates[identity.exactFingerprint, default: []]
                .append(baseIdentityIndex)
            stableBaseCandidates[identity.stableFingerprint, default: []]
                .append(baseIdentityIndex)
        }

        func claimBaseIdentityIndex(
            for fingerprint: String,
            candidates: inout [String: [Int]]
        ) -> Int? {
            guard var indices = candidates[fingerprint] else { return nil }
            while let candidate = indices.popLast() {
                if !usedStrokeIDs.contains(baseIdentities[candidate].stored.id) {
                    candidates[fingerprint] = indices
                    return candidate
                }
            }
            candidates[fingerprint] = indices
            return nil
        }

        // Resolve exact matches globally before using the serialization-tolerant signature. This
        // keeps truly identical duplicate strokes deterministic while still preserving identity
        // when PencilKit slightly rewrites pressure, timing, or angle samples on disk.
        for desired in desiredStrokes {
            guard let matchedIndex = claimBaseIdentityIndex(
                for: desired.exactFingerprint,
                candidates: &exactBaseCandidates
            ) else { continue }
            let matched = baseIdentities[matchedIndex].stored
            exactIdentityByDesiredIndex[desired.index] = matched
            usedStrokeIDs.insert(matched.id)
            deletableStrokeIDs.remove(matched.id)
        }
        for desired in desiredStrokes where exactIdentityByDesiredIndex[desired.index] == nil {
            guard let matchedIndex = claimBaseIdentityIndex(
                for: desired.stableFingerprint,
                candidates: &stableBaseCandidates
            ) else { continue }
            let matched = baseIdentities[matchedIndex].stored
            exactIdentityByDesiredIndex[desired.index] = matched
            usedStrokeIDs.insert(matched.id)
            deletableStrokeIDs.remove(matched.id)
        }

        let baseIdentityByDrawingIndex = Dictionary(
            uniqueKeysWithValues: baseIdentities.map { ($0.index, $0) }
        )
        var added: [CollaborationOperation] = []
        for desired in desiredStrokes {
            if exactIdentityByDesiredIndex[desired.index] != nil { continue }

            // A lasso transform or bitmap eraser changes PencilKit bytes but normally preserves
            // array position. Exact matches were assigned globally first, so this fallback does
            // not confuse a shifted unchanged stroke with the deleted stroke before it.
            if let matched = baseIdentityByDrawingIndex[desired.index]?.stored,
               !usedStrokeIDs.contains(matched.id) {
                usedStrokeIDs.insert(matched.id)
                deletableStrokeIDs.remove(matched.id)
                added.append(
                    CollaborationOperation(
                        workspaceID: "personal-library",
                        documentID: documentID,
                        pageID: page.id,
                        stamp: makeStamp(),
                        payload: .strokeUpsert(
                            CollaborationInkStroke(
                                id: matched.id,
                                drawingData: desired.data,
                                zIndex: matched.zIndex
                            )
                        )
                    )
                )
                continue
            }

            let strokeID = UUID().uuidString.lowercased()
            let payload = CollaborationOperationPayload.strokeUpsert(
                CollaborationInkStroke(
                    id: strokeID,
                    drawingData: desired.data,
                    zIndex: desired.index
                )
            )
            added.append(
                CollaborationOperation(
                    workspaceID: "personal-library",
                    documentID: documentID,
                    pageID: page.id,
                    stamp: makeStamp(),
                    payload: payload
                )
            )
        }

        let removed = currentState.strokes.values.filter {
            deletableStrokeIDs.contains($0.id)
        }
        for stroke in removed {
            added.append(
                CollaborationOperation(
                    workspaceID: "personal-library",
                    documentID: documentID,
                    pageID: page.id,
                    stamp: makeStamp(),
                    payload: .strokeDelete(strokeID: stroke.id)
                )
            )
        }

        guard !operations.isEmpty || !added.isEmpty else { return emissionContext }
        operations.append(contentsOf: added)
        scheduleCollaborationOperationsSave(
            operations,
            forPageID: page.id,
            in: documentID
        )
        try persistCollaborationClock()
        return emissionContext
    }

    private func recordElementCollaborationOperations(
        _ pageElements: [CanvasPageElement],
        replacing baseElements: [CanvasPageElement]? = nil,
        causalContext: CollaborationVersionVector? = nil,
        forPage pageIndex: Int,
        in documentID: String
    ) throws -> CollaborationVersionVector {
        guard let page = pageMetadata(at: pageIndex, in: documentID) else {
            return causalContext ?? CollaborationVersionVector()
        }
        var operations = loadCollaborationOperations(forPageID: page.id, in: documentID)

        let hasElementHistory = operations.contains { operation in
            switch operation.payload {
            case .elementUpsert, .elementPatch, .elementDelete: true
            default: false
            }
        }
        if !hasElementHistory {
            operations.append(contentsOf: bootstrapElementCollaborationOperations(
                from: loadPageElements(forPage: pageIndex, in: documentID),
                page: page
            ))
        }

        for operation in operations {
            collaborationClock.observe(operation.stamp)
        }
        let currentState = CollaborationMergeEngine.materialize(operations)
        let desiredByID = Dictionary(
            uniqueKeysWithValues: pageElements.sorted(by: pageElementSort).map { ($0.id, $0) }
        )
        let baseByID = baseElements.map { elements in
            Dictionary(uniqueKeysWithValues: elements.map { ($0.id, $0) })
        }
        var emissionContext = causalContext ?? currentState.frontier
        func makeStamp() -> CollaborationStamp {
            let stamp = collaborationClock.nextStamp(observedContext: emissionContext)
            emissionContext.observe(stamp.dot)
            return stamp
        }

        var added: [CollaborationOperation] = []
        for element in desiredByID.values.sorted(by: pageElementSort) {
            let comparisonElement = baseByID.map { $0[element.id] }
                ?? currentState.elements[element.id]
            let payload: CollaborationOperationPayload
            if let comparisonElement {
                let changedFields = collaborationElementFieldsChanged(
                    from: comparisonElement,
                    to: element
                )
                guard !changedFields.isEmpty else { continue }
                payload = .elementPatch(element: element, fields: changedFields)
            } else {
                payload = .elementUpsert(element)
            }
            added.append(
                CollaborationOperation(
                    workspaceID: "personal-library",
                    documentID: documentID,
                    pageID: page.id,
                    stamp: makeStamp(),
                    payload: payload
                )
            )
        }
        let deletableElementIDs = baseByID.map { Set($0.keys) }
            ?? Set(currentState.elements.keys)
        for elementID in deletableElementIDs.sorted(by: {
            $0.uuidString < $1.uuidString
        }) where desiredByID[elementID] == nil {
            added.append(
                CollaborationOperation(
                    workspaceID: "personal-library",
                    documentID: documentID,
                    pageID: page.id,
                    stamp: makeStamp(),
                    payload: .elementDelete(elementID: elementID)
                )
            )
        }

        guard !operations.isEmpty || !added.isEmpty else { return emissionContext }
        operations.append(contentsOf: added)
        try saveCollaborationOperations(operations, forPageID: page.id, in: documentID)
        try persistCollaborationClock()
        return emissionContext
    }

    private func collaborationElementFieldsChanged(
        from source: CanvasPageElement,
        to destination: CanvasPageElement
    ) -> Set<CollaborationElementField> {
        var fields: Set<CollaborationElementField> = []
        if source.logicalBounds != destination.logicalBounds { fields.insert(.logicalBounds) }
        if source.rotationRadians != destination.rotationRadians { fields.insert(.rotationRadians) }
        if source.zIndex != destination.zIndex { fields.insert(.zIndex) }
        if source.isLocked != destination.isLocked { fields.insert(.isLocked) }
        if source.groupID != destination.groupID { fields.insert(.groupID) }
        if source.payload != destination.payload { fields.insert(.payload) }
        return fields
    }

    private func bootstrapCollaborationOperations(
        from drawing: PKDrawing,
        page: LibraryPage
    ) -> [CollaborationOperation] {
        var migrationClock = CollaborationReplicaClock(
            actorID: "migration:\(page.documentID):\(page.id)"
        )
        return drawing.strokes.enumerated().map { zIndex, stroke in
            let data = PKDrawing(strokes: [stroke]).dataRepresentation()
            let seed = Data("\(page.id)|\(zIndex)|\(Self.collaborationStrokeFingerprint(stroke))".utf8)
            let operationID = "bootstrap-\(Self.collaborationFingerprint(seed))"
            let strokeID = "stroke-\(Self.collaborationFingerprint(seed))"
            return CollaborationOperation(
                workspaceID: "personal-library",
                documentID: page.documentID,
                pageID: page.id,
                stamp: migrationClock.nextStamp(
                    operationID: operationID,
                    createdAt: page.createdAt
                ),
                payload: .strokeUpsert(
                    CollaborationInkStroke(id: strokeID, drawingData: data, zIndex: zIndex)
                )
            )
        }
    }

    private func bootstrapElementCollaborationOperations(
        from elements: [CanvasPageElement],
        page: LibraryPage
    ) -> [CollaborationOperation] {
        var migrationClock = CollaborationReplicaClock(
            actorID: "migration-elements:\(page.documentID):\(page.id)"
        )
        return elements.sorted(by: pageElementSort).compactMap { element in
            guard let encoded = try? collaborationJSONEncoder().encode(element) else { return nil }
            let seed = Data(page.id.utf8) + encoded
            let operationID = "bootstrap-element-\(Self.collaborationFingerprint(seed))"
            return CollaborationOperation(
                workspaceID: "personal-library",
                documentID: page.documentID,
                pageID: page.id,
                stamp: migrationClock.nextStamp(
                    operationID: operationID,
                    createdAt: page.createdAt
                ),
                payload: .elementUpsert(element)
            )
        }
    }

    private func loadCollaborationOperations(
        forPageID pageID: String,
        in documentID: String
    ) -> [CollaborationOperation] {
        let url = collaborationOperationsURL(forPageID: pageID, in: documentID)
        return loadCollaborationOperations(at: url)
    }

    private func loadCollaborationOperations(at url: URL) -> [CollaborationOperation] {
        let cacheKey = url.standardizedFileURL.path
        if let pendingSave = pendingCollaborationOperationsSaves[cacheKey] {
            return pendingSave.operations
        }
        guard let signature = collaborationOperationsFileSignature(at: url) else {
            collaborationOperationsCache[cacheKey] = nil
            return []
        }
        if let cached = collaborationOperationsCache[cacheKey],
           cached.signature == signature {
            return cached.operations
        }

        let operations: [CollaborationOperation]
        if let data = try? Data(contentsOf: url),
           let archive = try? JSONDecoder().decode(
            CollaborationPageOperationArchive.self,
            from: data
           ),
           archive.schemaVersion > 0,
           archive.schemaVersion <= CollaborationPageOperationArchive.currentSchemaVersion {
            operations = archive.operations
        } else {
            operations = []
        }
        collaborationOperationsCache[cacheKey] = CollaborationOperationsCacheEntry(
            signature: signature,
            operations: operations
        )
        return operations
    }

    private func saveCollaborationOperations(
        _ operations: [CollaborationOperation],
        forPageID pageID: String,
        in documentID: String
    ) throws {
        let url = collaborationOperationsURL(forPageID: pageID, in: documentID)
        let cacheKey = url.standardizedFileURL.path
        pendingCollaborationOperationsTasks[cacheKey]?.cancel()
        pendingCollaborationOperationsTasks[cacheKey] = nil
        pendingCollaborationOperationsSaves[cacheKey] = nil
        markCollaborationOperationsChanged(cacheKey: cacheKey)
        let encoded = try Self.encodedCollaborationOperations(operations)
        try encoded.data.write(to: url, options: .atomic)
        if let signature = collaborationOperationsFileSignature(at: url) {
            collaborationOperationsCache[cacheKey] =
                CollaborationOperationsCacheEntry(
                    signature: signature,
                    operations: encoded.operations
                )
        } else {
            collaborationOperationsCache[cacheKey] = nil
        }
    }

    /// Drawing edits use this path so the full JSON archive is encoded away from MainActor. The
    /// decoded operation array remains immediately available to recovery and CloudKit export; a
    /// page close or scene transition drains it synchronously if the background encoding has not
    /// completed yet.
    private func scheduleCollaborationOperationsSave(
        _ operations: [CollaborationOperation],
        forPageID pageID: String,
        in documentID: String
    ) {
        let url = collaborationOperationsURL(forPageID: pageID, in: documentID)
        let cacheKey = url.standardizedFileURL.path
        pendingCollaborationOperationsTasks[cacheKey]?.cancel()
        let pendingSave = PendingCollaborationOperationsSave(
            token: UUID(),
            operations: operations,
            targetURL: url,
            documentID: documentID,
            pageID: pageID
        )
        markCollaborationOperationsChanged(cacheKey: cacheKey)
        pendingCollaborationOperationsSaves[cacheKey] = pendingSave
        guard !isDrawingInteractionActive else {
            pendingCollaborationOperationsTasks[cacheKey] = nil
            return
        }
        schedulePendingCollaborationOperationsSave(pendingSave, cacheKey: cacheKey)
    }

    private func markCollaborationOperationsChanged(cacheKey: String) {
        collaborationOperationsRevisionSeed &+= 1
        collaborationOperationsRevisions[cacheKey] = collaborationOperationsRevisionSeed
    }

    private func schedulePendingCollaborationOperationsSaves() {
        guard !isDrawingInteractionActive else { return }
        for (cacheKey, pendingSave) in pendingCollaborationOperationsSaves {
            schedulePendingCollaborationOperationsSave(pendingSave, cacheKey: cacheKey)
        }
    }

    private func schedulePendingCollaborationOperationsSave(
        _ pendingSave: PendingCollaborationOperationsSave,
        cacheKey: String
    ) {
        pendingCollaborationOperationsTasks[cacheKey]?.cancel()
        let delay = drawingPersistenceQuietTimeRemaining()
        pendingCollaborationOperationsTasks[cacheKey] = Task.detached(priority: .background) {
            [weak self] in
            let stagingURL = pendingSave.targetURL
                .deletingLastPathComponent()
                .appendingPathComponent(
                    ".\(pendingSave.targetURL.lastPathComponent)."
                        + "\(pendingSave.token.uuidString.lowercased()).pending"
                )
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
                guard !Task.isCancelled else { return }
                let encoded = try Self.encodedCollaborationOperations(pendingSave.operations)
                guard !Task.isCancelled else { return }
                try encoded.data.write(to: stagingURL, options: .atomic)
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: stagingURL)
                    return
                }
                guard let self else {
                    try? FileManager.default.removeItem(at: stagingURL)
                    return
                }
                await self.finishScheduledCollaborationOperationsSave(
                    pendingSave,
                    cacheKey: cacheKey,
                    encoded: encoded,
                    stagingURL: stagingURL
                )
            } catch {
                try? FileManager.default.removeItem(at: stagingURL)
                guard !Task.isCancelled else { return }
                await self?.failScheduledCollaborationOperationsSave(
                    pendingSave,
                    cacheKey: cacheKey,
                    error: error
                )
            }
        }
    }

    private func finishScheduledCollaborationOperationsSave(
        _ pendingSave: PendingCollaborationOperationsSave,
        cacheKey: String,
        encoded: (data: Data, operations: [CollaborationOperation]),
        stagingURL: URL
    ) {
        guard pendingCollaborationOperationsSaves[cacheKey]?.token == pendingSave.token else {
            try? FileManager.default.removeItem(at: stagingURL)
            return
        }
        pendingCollaborationOperationsTasks[cacheKey] = nil
        guard !isDrawingInteractionActive else {
            try? FileManager.default.removeItem(at: stagingURL)
            return
        }
        if drawingPersistenceQuietTimeRemaining() > 0 {
            try? FileManager.default.removeItem(at: stagingURL)
            schedulePendingCollaborationOperationsSave(pendingSave, cacheKey: cacheKey)
            return
        }
        do {
            // Encoding and writing happen off MainActor; only the same-volume rename is installed
            // here after one final Pencil-idle check.
            try Self.installStagedFile(stagingURL, at: pendingSave.targetURL)
            pendingCollaborationOperationsSaves[cacheKey] = nil
            if let signature = collaborationOperationsFileSignature(at: pendingSave.targetURL) {
                collaborationOperationsCache[cacheKey] = CollaborationOperationsCacheEntry(
                    signature: signature,
                    operations: encoded.operations
                )
            } else {
                collaborationOperationsCache[cacheKey] = nil
            }
            saveState = pendingAssetSaves.isEmpty ? .saved(Date()) : .saving
            signalLocalCloudChange()
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            saveState = .failed("协作操作无法保存：\(error.localizedDescription)")
        }
    }

    private func failScheduledCollaborationOperationsSave(
        _ pendingSave: PendingCollaborationOperationsSave,
        cacheKey: String,
        error: Error
    ) {
        guard pendingCollaborationOperationsSaves[cacheKey]?.token == pendingSave.token else {
            return
        }
        pendingCollaborationOperationsTasks[cacheKey] = nil
        saveState = .failed("协作操作无法保存：\(error.localizedDescription)")
    }

    private func flushPendingCollaborationOperationsSaves(withKeys keys: [String]) -> Bool {
        var firstError: Error?
        var didPersistOperations = false
        for cacheKey in keys {
            pendingCollaborationOperationsTasks[cacheKey]?.cancel()
            pendingCollaborationOperationsTasks[cacheKey] = nil
            guard let pendingSave = pendingCollaborationOperationsSaves[cacheKey] else { continue }
            do {
                let encoded = try Self.encodedCollaborationOperations(pendingSave.operations)
                try encoded.data.write(to: pendingSave.targetURL, options: .atomic)
                pendingCollaborationOperationsSaves[cacheKey] = nil
                if let signature = collaborationOperationsFileSignature(at: pendingSave.targetURL) {
                    collaborationOperationsCache[cacheKey] = CollaborationOperationsCacheEntry(
                        signature: signature,
                        operations: encoded.operations
                    )
                } else {
                    collaborationOperationsCache[cacheKey] = nil
                }
                didPersistOperations = true
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            saveState = .failed("协作操作无法保存：\(firstError.localizedDescription)")
            return false
        }
        if didPersistOperations {
            saveState = pendingAssetSaves.isEmpty ? .saved(Date()) : .saving
            signalLocalCloudChange()
        }
        return true
    }

    nonisolated private static func encodedCollaborationOperations(
        _ operations: [CollaborationOperation]
    ) throws -> (data: Data, operations: [CollaborationOperation]) {
        var unique: [String: CollaborationOperation] = [:]
        for operation in operations {
            if let current = unique[operation.id] {
                unique[operation.id] = .preferred(current, operation)
            } else {
                unique[operation.id] = operation
            }
        }
        let canonicalOperations = unique.values.sorted {
            $0.deterministicallyPrecedes($1)
        }
        let archive = CollaborationPageOperationArchive(operations: canonicalOperations)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try encoder.encode(archive), canonicalOperations)
    }

    private func collaborationOperationsFileSignature(
        at url: URL
    ) -> CollaborationOperationsFileSignature? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let byteCount = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        return CollaborationOperationsFileSignature(
            byteCount: byteCount,
            modifiedAt: attributes[.modificationDate] as? Date
        )
    }

    private func encodedPageElements(_ pageElements: [CanvasPageElement]) -> Data? {
        try? collaborationJSONEncoder().encode(
            CanvasPageElementsArchive(elements: pageElements.sorted(by: pageElementSort))
        )
    }

    private func collaborationJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func pageElementSort(_ lhs: CanvasPageElement, _ rhs: CanvasPageElement) -> Bool {
        if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func materializeCollaborationDrawing(
        from operations: [CollaborationOperation],
        forPageID pageID: String,
        in documentID: String
    ) throws {
        try collaborationDrawingData(from: operations).write(
            to: drawingURL(forPageID: pageID, in: documentID),
            options: .atomic
        )
    }

    private func collaborationDrawingData(
        forPage pageIndex: Int,
        in documentID: String
    ) -> Data {
        guard let pageID = pageID(at: pageIndex, in: documentID) else {
            return PKDrawing().dataRepresentation()
        }
        return collaborationDrawingData(
            from: loadCollaborationOperations(forPageID: pageID, in: documentID)
        )
    }

    private func collaborationDrawingData(
        from operations: [CollaborationOperation]
    ) -> Data {
        let state = CollaborationMergeEngine.materialize(operations)
        let strokes = state.strokes.values
            .sorted {
                if $0.zIndex != $1.zIndex { return $0.zIndex < $1.zIndex }
                return $0.id < $1.id
            }
            .flatMap { stroke -> [PKStroke] in
                (try? PKDrawing(data: stroke.drawingData).strokes) ?? []
            }
        return PKDrawing(strokes: strokes).dataRepresentation()
    }

    private func collaborationElementsData(
        forPage pageIndex: Int,
        in documentID: String
    ) -> Data? {
        guard let pageID = pageID(at: pageIndex, in: documentID) else {
            return encodedPageElements([])
        }
        let state = CollaborationMergeEngine.materialize(
            loadCollaborationOperations(forPageID: pageID, in: documentID)
        )
        return encodedPageElements(Array(state.elements.values))
    }

    private func refreshPendingCollaborationSaves(
        forPageID pageID: String,
        in documentID: String,
        operations: [CollaborationOperation]
    ) {
        let baseKey = "\(documentID)#\(pageID)"
        if var pendingDrawing = pendingAssetSaves[baseKey] {
            pendingDrawing.data = collaborationDrawingData(from: operations)
            pendingAssetSaves[baseKey] = pendingDrawing
        }
        let elementKey = "\(baseKey)#elements"
        if var pendingElements = pendingAssetSaves[elementKey] {
            let state = CollaborationMergeEngine.materialize(operations)
            if let data = encodedPageElements(Array(state.elements.values)) {
                pendingElements.data = data
                pendingAssetSaves[elementKey] = pendingElements
            }
        }
    }

    private func persistCollaborationClock() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(collaborationClock).write(
            to: collaborationClockURL,
            options: .atomic
        )
    }

    nonisolated private static func collaborationFingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func collaborationStrokeFingerprint(_ drawingData: Data) -> String {
        guard let stroke = try? PKDrawing(data: drawingData).strokes.first else {
            return Self.collaborationFingerprint(drawingData)
        }
        return Self.collaborationStrokeFingerprint(stroke)
    }

    nonisolated private static func collaborationStrokeFingerprint(_ stroke: PKStroke) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        stroke.ink.color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let transform = stroke.transform
        var components = [
            String(describing: stroke.ink.inkType),
            String(format: "%.6f,%.6f,%.6f,%.6f", red, green, blue, alpha),
            String(
                format: "%.6f,%.6f,%.6f,%.6f,%.6f,%.6f",
                transform.a,
                transform.b,
                transform.c,
                transform.d,
                transform.tx,
                transform.ty
            )
        ]
        components.reserveCapacity(components.count + stroke.path.count)
        for point in stroke.path {
            components.append(
                String(
                    format: "%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f",
                    point.location.x,
                    point.location.y,
                    point.timeOffset,
                    point.size.width,
                    point.size.height,
                    point.opacity,
                    point.force,
                    point.azimuth,
                    point.altitude
                )
            )
        }
        return Self.collaborationFingerprint(Data(components.joined(separator: "|").utf8))
    }

    /// PencilKit is allowed to normalize dynamic samples when a drawing is serialized. Those
    /// samples are useful for rendering but are too volatile to be the only collaboration
    /// identity: a whole-stroke erase could otherwise fail to find the stored stroke and the next
    /// materialization would visibly resurrect it. This signature keeps the rendered geometry,
    /// ink, color, transform, point order, and point count while deliberately omitting timing,
    /// pressure, opacity, and Pencil angles.
    nonisolated private static func collaborationStableStrokeFingerprint(
        _ drawingData: Data
    ) -> String {
        guard let stroke = try? PKDrawing(data: drawingData).strokes.first else {
            return Self.collaborationFingerprint(drawingData)
        }
        return Self.collaborationStableStrokeFingerprint(stroke)
    }

    nonisolated private static func collaborationStableStrokeFingerprint(
        _ stroke: PKStroke
    ) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        stroke.ink.color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let transform = stroke.transform
        var components = [
            String(describing: stroke.ink.inkType),
            String(format: "%.3f,%.3f,%.3f,%.3f", red, green, blue, alpha),
            String(
                format: "%.3f,%.3f,%.3f,%.3f,%.3f,%.3f",
                transform.a,
                transform.b,
                transform.c,
                transform.d,
                transform.tx,
                transform.ty
            ),
            "points:\(stroke.path.count)"
        ]
        components.reserveCapacity(components.count + stroke.path.count)
        for point in stroke.path {
            components.append(
                String(
                    format: "%.2f,%.2f,%.2f,%.2f",
                    point.location.x,
                    point.location.y,
                    point.size.width,
                    point.size.height
                )
            )
        }
        return Self.collaborationFingerprint(Data(components.joined(separator: "|").utf8))
    }

    private func collaborationOperationsURL(forPageID pageID: String, in documentID: String) -> URL {
        drawingURL(forPageID: pageID, in: documentID)
            .deletingPathExtension()
            .appendingPathExtension("operations.json")
    }

    private func pageBackgroundURL(forPageID pageID: String, in documentID: String) -> URL {
        drawingURL(forPageID: pageID, in: documentID)
            .deletingPathExtension()
            .appendingPathExtension("background.pdf")
    }

    private func prepareDocumentForPageEditing(_ documentID: String) throws {
        guard let metadataIndex = documentMetadata.firstIndex(where: { $0.id == documentID }),
              let currentPDF = pdfDocument(for: documentID) else {
            throw LibraryStoreError.documentNotFound(documentID)
        }
        guard documentMetadata[metadataIndex].trashedAt == nil else {
            throw LibraryStoreError.itemIsInTrash
        }

        let documentPages = pages(in: documentID)
        if documentMetadata[metadataIndex].isBundled {
            let fileName = "\(documentID)-editable-\(UUID().uuidString.lowercased()).pdf"
            let targetURL = importsDirectory.appendingPathComponent(fileName)
            guard let sourceURL = fileURL(for: documentMetadata[metadataIndex]) else {
                throw LibraryStoreError.documentNotFound(documentID)
            }
            let transaction = try beginWorkspaceTransaction(
                kind: "prepare-bundled-page-edit",
                affectedURLs: [registryURL, targetURL] + documentPages.map {
                    pageBackgroundURL(forPageID: $0.id, in: documentID)
                }
            )
            var updatedMetadata = documentMetadata
            updatedMetadata[metadataIndex].fileName = fileName
            updatedMetadata[metadataIndex].isBundled = false
            let contentDate = Date()
            updatedMetadata[metadataIndex].contentModifiedAt = contentDate
            updatedMetadata[metadataIndex].modifiedAt = contentDate
            do {
                try fileManager.copyItem(at: sourceURL, to: targetURL)
                try persistPageBackgroundAssets(
                    pages: documentPages,
                    from: currentPDF,
                    documentID: documentID
                )
                try persistRegistry(
                    folders: folders,
                    documents: updatedMetadata,
                    pages: pages
                )
                documentMetadata = updatedMetadata
                pdfCache[documentID] = PDFDocument(url: targetURL)
                rebuildWorkspaceDocuments()
                try commitWorkspaceTransaction(transaction)
            } catch {
                rollbackWorkspaceTransaction(transaction)
                throw error
            }
            return
        }

        let hasEveryBackground = documentPages.allSatisfy {
            fileManager.fileExists(
                atPath: pageBackgroundURL(forPageID: $0.id, in: documentID).path
            )
        }
        if !hasEveryBackground {
            let transaction = try beginWorkspaceTransaction(
                kind: "prepare-page-backgrounds",
                affectedURLs: documentPages.map {
                    pageBackgroundURL(forPageID: $0.id, in: documentID)
                }
            )
            do {
                try persistPageBackgroundAssets(
                    pages: documentPages,
                    from: currentPDF,
                    documentID: documentID
                )
                try commitWorkspaceTransaction(transaction)
            } catch {
                rollbackWorkspaceTransaction(transaction)
                throw error
            }
        }
    }

    private func commitPageMutation(
        _ proposedDocumentPages: [LibraryPage],
        in documentID: String
    ) throws {
        let previousPages = pages
        let previousPDFData = documentMetadata
            .first(where: { $0.id == documentID })
            .flatMap(fileURL(for:))
            .flatMap { try? Data(contentsOf: $0) }
        var normalizedDocumentPages = proposedDocumentPages.sorted {
            if $0.position != $1.position { return $0.position < $1.position }
            return $0.id < $1.id
        }
        for index in normalizedDocumentPages.indices {
            normalizedDocumentPages[index].orderIndex = index
        }
        pages = previousPages.filter { $0.documentID != documentID } + normalizedDocumentPages
        pages.sort {
            if $0.documentID != $1.documentID { return $0.documentID < $1.documentID }
            if $0.position != $1.position { return $0.position < $1.position }
            return $0.id < $1.id
        }

        do {
            try rebuildPDFDocumentFromPageBackgrounds(documentID: documentID)
            try persistRegistry(folders: folders, documents: documentMetadata, pages: pages)
            pageAssetGeneration &+= 1
        } catch {
            pages = previousPages
            if let previousPDFData,
               let metadata = documentMetadata.first(where: { $0.id == documentID }),
               let targetURL = fileURL(for: metadata) {
                try? previousPDFData.write(to: targetURL, options: .atomic)
                pdfCache[documentID] = PDFDocument(data: previousPDFData)
                rebuildWorkspaceDocuments()
            }
            throw error
        }
    }

    private func appendCollaborationOperation(_ operation: CollaborationOperation) throws {
        var operations = loadCollaborationOperations(
            forPageID: operation.pageID,
            in: operation.documentID
        )
        if !operations.contains(where: { $0.id == operation.id }) {
            operations.append(operation)
            try saveCollaborationOperations(
                operations,
                forPageID: operation.pageID,
                in: operation.documentID
            )
        }
        try persistCollaborationClock()
    }

    /// Local "last page" checks cannot prevent two offline replicas from deleting different
    /// pages. If the merged active set becomes empty, restore a deterministic archived page.
    /// Every replica keeps the same page identity; a later user deletion can then proceed normally.
    private func recoverPageForEmptyDocument(_ documentID: String) throws -> LibraryPage {
        let directory = documentDrawingsDirectory(for: documentID, createIfNeeded: true)
        let operationURLs = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter { $0.lastPathComponent.hasSuffix(".operations.json") } ?? []

        var archivedPages: [(page: LibraryPage, state: MaterializedCollaborationPage)] = []
        for url in operationURLs {
            let operations = loadCollaborationOperations(at: url)
            guard !operations.isEmpty else { continue }
            for operation in operations {
                collaborationClock.observe(operation.stamp)
            }
            let state = CollaborationMergeEngine.materialize(operations)
            guard let pageData = state.metadata["pageArchive"],
                  let page = try? JSONDecoder().decode(LibraryPage.self, from: pageData),
                  page.documentID == documentID else { continue }
            archivedPages.append((page, state))
        }

        var recovered: LibraryPage
        if let candidate = archivedPages.sorted(by: {
            if $0.page.position != $1.page.position { return $0.page.position < $1.page.position }
            return $0.page.id < $1.page.id
        }).first {
            recovered = candidate.page
            if let position = candidate.state.position { recovered.position = position }
        } else {
            let fallbackSize: CGSize
            if let pdfPage = pdfDocument(for: documentID)?.page(at: 0) {
                let bounds = pdfPage.bounds(for: .mediaBox)
                fallbackSize = CGSize(width: max(bounds.width, 1), height: max(bounds.height, 1))
            } else {
                fallbackSize = CGSize(width: 595, height: 842)
            }
            let fingerprint = Self.collaborationFingerprint(Data("recovery|\(documentID)".utf8))
            recovered = LibraryPage(
                id: "recovery-\(fingerprint)",
                documentID: documentID,
                orderIndex: 0,
                position: .legacy(orderIndex: 0),
                width: Double(fallbackSize.width),
                height: Double(fallbackSize.height),
                sourceKind: .template,
                backgroundStyle: .blank,
                backgroundColor: .white
            )
            let archiveOperation = CollaborationOperation(
                workspaceID: "personal-library",
                documentID: documentID,
                pageID: recovered.id,
                stamp: collaborationClock.nextStamp(),
                payload: .metadataSet(
                    field: "pageArchive",
                    value: try encodedCollaborationValue(recovered)
                )
            )
            try appendCollaborationOperation(archiveOperation)
        }

        let restoreStamp = collaborationClock.nextStamp()
        recovered.orderIndex = 0
        recovered.modifiedAt = restoreStamp.createdAt
        try ensureRecoveryBackground(for: recovered)
        try appendCollaborationOperation(
            CollaborationOperation(
                workspaceID: "personal-library",
                documentID: documentID,
                pageID: recovered.id,
                stamp: restoreStamp,
                payload: .pageRestore
            )
        )
        signalLocalCloudChange()
        return recovered
    }

    private func ensureRecoveryBackground(for page: LibraryPage) throws {
        let url = pageBackgroundURL(forPageID: page.id, in: page.documentID)
        guard !fileManager.fileExists(atPath: url.path) else { return }
        let size = CGSize(width: max(page.width, 1), height: max(page.height, 1))
        try templatePagePDFData(
            size: size,
            style: page.backgroundStyle ?? .blank,
            color: page.backgroundColor ?? .white
        ).write(to: url, options: .atomic)
    }

    private func encodedCollaborationValue<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func templatePagePDFData(
        size: CGSize,
        style: CanvasBackgroundStyle,
        color: CanvasBackgroundColor
    ) throws -> Data {
        guard size.width > 0, size.height > 0 else {
            throw PDFWorkspaceError.invalidPDF("页面")
        }
        let bounds = CGRect(origin: .zero, size: size)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        return renderer.pdfData { context in
            context.beginPage()
            drawCanvasBackground(
                in: context.cgContext,
                bounds: bounds,
                style: style,
                color: color
            )
        }
    }

    /// Export a finite snapshot containing the complete canvas. Camera movement never changes
    /// this range, and imported PDF documents retain their original paper bounds.
    func exportBounds(forPage pageIndex: Int, in documentID: String) -> CGRect {
        let paper = CGRect(origin: .zero, size: pageSize(at: pageIndex, in: documentID))
        guard document(withID: documentID)?.kind == .canvas else { return paper }
        var content = loadDrawing(forPage: pageIndex, in: documentID).bounds
        for element in loadPageElements(forPage: pageIndex, in: documentID) {
            let rect = element.logicalBounds
            let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
                .rotated(by: element.rotationRadians)
                .translatedBy(x: -rect.midX, y: -rect.midY)
            content = content.union(rect.applying(transform))
        }
        guard !content.isNull, !content.isInfinite, !content.isEmpty else { return paper }
        return paper.contains(content) ? paper : paper.union(content.insetBy(dx: -24, dy: -24)).integral
    }

    private func renderFlattenedPage(
        documentID: String,
        pageIndex: Int,
        bounds: CGRect,
        context: CGContext
    ) {
        let size = pageSize(at: pageIndex, in: documentID)
        let isCanvas = document(withID: documentID)?.kind == .canvas
        let metadata = pageMetadata(at: pageIndex, in: documentID)
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.setFillColor(UIColor.white.cgColor)
        context.fill(bounds)
        if isCanvas {
            CanvasBackgroundRenderer.draw(
                in: context, bounds: bounds,
                style: metadata?.backgroundStyle ?? .blank,
                color: metadata?.backgroundColor ?? .white
            )
        }

        if (!isCanvas || metadata?.sourceKind == .pdf),
           let page = page(at: pageIndex, in: documentID) {
            let pageBounds = page.bounds(for: .mediaBox)
            let scale = min(
                size.width / max(pageBounds.width, 1),
                size.height / max(pageBounds.height, 1)
            )
            let renderedSize = CGSize(
                width: pageBounds.width * scale,
                height: pageBounds.height * scale
            )
            let origin = CGPoint(
                x: (size.width - renderedSize.width) / 2,
                y: (size.height - renderedSize.height) / 2
            )
            context.saveGState()
            context.translateBy(x: origin.x, y: origin.y + renderedSize.height)
            context.scaleBy(x: scale, y: -scale)
            context.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
        }

        for element in loadPageElements(forPage: pageIndex, in: documentID).sorted(by: {
            if $0.zIndex != $1.zIndex { return $0.zIndex < $1.zIndex }
            return $0.id.uuidString < $1.id.uuidString
        }) {
            drawExportElement(element, in: context)
        }

        let drawing = loadDrawing(forPage: pageIndex, in: documentID)
        guard !drawing.strokes.isEmpty else { return }
        let rasterScale = isCanvas
            ? min(2, hypot(context.ctm.a, context.ctm.b) * 2, 4096 / max(bounds.width, bounds.height))
            : 2
        drawing.image(from: bounds, scale: rasterScale).draw(in: bounds)
    }

    private func drawExportElement(_ element: CanvasPageElement, in context: CGContext) {
        let bounds = element.logicalBounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.rotate(by: CGFloat(element.rotationRadians))
        let localRect = CGRect(
            x: -bounds.width / 2,
            y: -bounds.height / 2,
            width: bounds.width,
            height: bounds.height
        )

        switch element.payload {
        case .text(let payload):
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = switch payload.alignment {
            case .leading: .left
            case .center: .center
            case .trailing: .right
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: exportFont(for: payload),
                .foregroundColor: exportColor(payload.colorHex),
                .paragraphStyle: paragraph
            ]
            if payload.isUnderlined {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            NSAttributedString(string: payload.text, attributes: attributes).draw(in: localRect)
        case .image(let payload):
            UIImage(data: payload.pngData)?.draw(in: localRect, blendMode: .normal, alpha: payload.opacity)
        case .shape(let payload):
            drawExportShape(payload, in: localRect, context: context)
        }
        context.restoreGState()
    }

    private func drawExportShape(
        _ payload: PageShapePayload,
        in rect: CGRect,
        context: CGContext
    ) {
        let lineWidth = max(0.5, payload.lineWidth)
        let drawingRect = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let path = CGMutablePath()
        switch payload.kind {
        case .line, .arrow:
            path.move(to: CGPoint(x: drawingRect.minX, y: drawingRect.midY))
            path.addLine(to: CGPoint(x: drawingRect.maxX, y: drawingRect.midY))
            if payload.kind == .arrow {
                let head = min(drawingRect.height * 0.35, drawingRect.width * 0.18, 18)
                path.move(to: CGPoint(x: drawingRect.maxX, y: drawingRect.midY))
                path.addLine(to: CGPoint(x: drawingRect.maxX - head, y: drawingRect.midY - head * 0.72))
                path.move(to: CGPoint(x: drawingRect.maxX, y: drawingRect.midY))
                path.addLine(to: CGPoint(x: drawingRect.maxX - head, y: drawingRect.midY + head * 0.72))
            }
        case .rectangle:
            path.addRect(drawingRect)
        case .ellipse:
            path.addEllipse(in: drawingRect)
        case .triangle:
            path.move(to: CGPoint(x: drawingRect.midX, y: drawingRect.minY))
            path.addLine(to: CGPoint(x: drawingRect.maxX, y: drawingRect.maxY))
            path.addLine(to: CGPoint(x: drawingRect.minX, y: drawingRect.maxY))
            path.closeSubpath()
        case .diamond:
            path.move(to: CGPoint(x: drawingRect.midX, y: drawingRect.minY))
            path.addLine(to: CGPoint(x: drawingRect.maxX, y: drawingRect.midY))
            path.addLine(to: CGPoint(x: drawingRect.midX, y: drawingRect.maxY))
            path.addLine(to: CGPoint(x: drawingRect.minX, y: drawingRect.midY))
            path.closeSubpath()
        }
        if let fill = payload.fillColorHex,
           ![.line, .arrow].contains(payload.kind) {
            context.addPath(path)
            context.setFillColor(exportColor(fill).cgColor)
            context.fillPath()
        }
        context.addPath(path)
        context.setStrokeColor(exportColor(payload.strokeColorHex).cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineDash(phase: 0, lengths: payload.isDashed ? [7, 5] : [])
        context.strokePath()
    }

    private func exportFont(for payload: PageTextPayload) -> UIFont {
        let size = CGFloat(max(6, payload.fontSize))
        var descriptor = UIFont.systemFont(ofSize: size).fontDescriptor
        let design: UIFontDescriptor.SystemDesign? = switch PageTextFontPreset(
            storedName: payload.fontName
        ) {
        case .system: nil
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
        if let design, let designed = descriptor.withDesign(design) {
            descriptor = designed
        }
        var traits = descriptor.symbolicTraits
        if payload.isBold { traits.insert(.traitBold) }
        if payload.isItalic { traits.insert(.traitItalic) }
        if let styled = descriptor.withSymbolicTraits(traits) { descriptor = styled }
        return UIFont(descriptor: descriptor, size: size)
    }

    private func exportColor(_ rawValue: String) -> UIColor {
        var hex = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard (hex.count == 6 || hex.count == 8),
              let value = UInt64(hex, radix: 16) else { return .black }
        let hasAlpha = hex.count == 8
        return UIColor(
            red: CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xff) / 255,
            green: CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xff) / 255,
            blue: CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xff) / 255,
            alpha: hasAlpha ? CGFloat(value & 0xff) / 255 : 1
        )
    }

    private func makeExportURL(
        title: String,
        suffix: String,
        extension pathExtension: String
    ) throws -> URL {
        let directory = workspaceDirectory.appendingPathComponent("Exports", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let safeTitle = title.components(separatedBy: invalid).joined(separator: "-")
        let token = UUID().uuidString.prefix(8)
        return directory.appendingPathComponent(
            "\(safeTitle)-\(suffix)-\(token).\(pathExtension)"
        )
    }

    private func copyPageAssets(
        from sourcePageID: String,
        to destinationPageID: String,
        in documentID: String
    ) throws -> [URL] {
        let sourceURLs = [
            pageBackgroundURL(forPageID: sourcePageID, in: documentID),
            drawingURL(forPageID: sourcePageID, in: documentID),
            imageAnnotationsURL(forPageID: sourcePageID, in: documentID)
        ]
        let destinationURLs = [
            pageBackgroundURL(forPageID: destinationPageID, in: documentID),
            drawingURL(forPageID: destinationPageID, in: documentID),
            imageAnnotationsURL(forPageID: destinationPageID, in: documentID)
        ]
        guard fileManager.fileExists(atPath: sourceURLs[0].path) else {
            throw PDFWorkspaceError.invalidPDF(documentID)
        }
        var copied: [URL] = []
        do {
            for (source, destination) in zip(sourceURLs, destinationURLs)
            where fileManager.fileExists(atPath: source.path) {
                try fileManager.copyItem(at: source, to: destination)
                copied.append(destination)
            }
            return copied
        } catch {
            for url in copied { try? fileManager.removeItem(at: url) }
            throw error
        }
    }

    private func normalizedPageRotation(_ rotation: Int) -> Int {
        let value = rotation % 360
        return value < 0 ? value + 360 : value
    }

    private func requireEditableSharedDocument(_ documentID: String) throws {
        if readOnlySharedDocumentIDs.contains(documentID) {
            throw LibraryStoreError.readOnlySharedDocument
        }
    }

    private func drawingURL(forPage pageIndex: Int, in documentID: String) -> URL {
        guard let pageID = pageID(at: pageIndex, in: documentID) else {
            return documentDrawingsDirectory(for: documentID, createIfNeeded: true)
                .appendingPathComponent(String(format: "page-%04d.drawing", pageIndex + 1))
        }
        return drawingURL(forPageID: pageID, in: documentID)
    }

    private func drawingURL(forPageID pageID: String, in documentID: String) -> URL {
        let documentDrawingsDirectory = documentDrawingsDirectory(
            for: documentID,
            createIfNeeded: true
        )
        return documentDrawingsDirectory.appendingPathComponent(
            "asset-\(pageID).drawing"
        )
    }

    private func documentDrawingsDirectory(
        for documentID: String,
        createIfNeeded: Bool
    ) -> URL {
        let documentDirectoryName: String
        switch documentID {
        case "congruence": documentDirectoryName = "Congruence"
        case "geometry": documentDirectoryName = "Geometry"
        default: documentDirectoryName = documentID
        }

        let documentDrawingsDirectory = drawingsDirectory
            .appendingPathComponent(documentDirectoryName, isDirectory: true)
        if createIfNeeded {
            try? fileManager.createDirectory(
                at: documentDrawingsDirectory,
                withIntermediateDirectories: true
            )
        }
        return documentDrawingsDirectory
    }

    private func imageAnnotationsURL(forPage pageIndex: Int, in documentID: String) -> URL {
        guard let pageID = pageID(at: pageIndex, in: documentID) else {
            return drawingURL(forPage: pageIndex, in: documentID)
                .deletingPathExtension()
                .appendingPathExtension("images.json")
        }
        return imageAnnotationsURL(forPageID: pageID, in: documentID)
    }

    private func imageAnnotationsURL(forPageID pageID: String, in documentID: String) -> URL {
        drawingURL(forPageID: pageID, in: documentID)
            .deletingPathExtension()
            .appendingPathExtension("images.json")
    }

    private func drawingKey(documentID: String, pageIndex: Int) -> String {
        let pageComponent = pageID(at: pageIndex, in: documentID) ?? "index-\(pageIndex)"
        return "\(documentID)#\(pageComponent)"
    }

    private func pendingSaveKey(for reference: LibraryAssetReference) -> String? {
        switch reference.kind {
        case .pdf, .pageBackground:
            nil
        case .pageDrawing(let pageID):
            "\(reference.documentID)#\(pageID)"
        case .pageElements(let pageID):
            "\(reference.documentID)#\(pageID)#elements"
        case .drawing(let pageIndex):
            drawingKey(documentID: reference.documentID, pageIndex: pageIndex)
        case .imageAnnotations(let pageIndex):
            "\(drawingKey(documentID: reference.documentID, pageIndex: pageIndex))#elements"
        }
    }

    private func cancelPendingSave(for reference: LibraryAssetReference) {
        guard let key = pendingSaveKey(for: reference) else { return }
        pendingSaves[key]?.cancel()
        pendingSaves[key] = nil
        pendingAssetSaves[key] = nil
        saveState = pendingAssetSaves.isEmpty ? .saved(Date()) : .saving
    }

    private func preservePendingLocalEditIfNeeded(
        for reference: LibraryAssetReference
    ) throws -> Bool {
        guard let key = pendingSaveKey(for: reference), pendingAssetSaves[key] != nil else {
            return false
        }
        guard flushPendingSaves(withKeys: [key]) else {
            throw LibraryStoreError.cannotApplyAsset(reference.documentID)
        }
        return true
    }

    private func cancelPendingSaves(forDocumentsNotIn availableIDs: Set<String>) {
        let staleReferences = pendingAssetSaves.values
            .map(\.reference)
            .filter { !availableIDs.contains($0.documentID) }
        for reference in staleReferences {
            cancelPendingSave(for: reference)
        }
        let staleOperationKeys = pendingCollaborationOperationsSaves.compactMap {
            cacheKey, pendingSave in
            availableIDs.contains(pendingSave.documentID) ? nil : cacheKey
        }
        for cacheKey in staleOperationKeys {
            pendingCollaborationOperationsTasks[cacheKey]?.cancel()
            pendingCollaborationOperationsTasks[cacheKey] = nil
            pendingCollaborationOperationsSaves[cacheKey] = nil
            collaborationOperationsCache[cacheKey] = nil
        }
    }

    private func bumpPageAssetRevision(forPage pageIndex: Int, in documentID: String) {
        guard pageIndex >= 0 else { return }
        let stablePageID = pageID(at: pageIndex, in: documentID) ?? "index-\(pageIndex)"
        bumpPageAssetRevision(forPageID: stablePageID, in: documentID)
    }

    private func bumpPageAssetRevision(forPageID pageID: String, in documentID: String) {
        pageAssetGeneration &+= 1
        pageAssetRevisions[
            LibraryPageReference(documentID: documentID, pageID: pageID)
        ] = pageAssetGeneration
    }

    private func lastPageKey(_ documentID: String) -> String {
        "pdfWorkspace.lastPage.\(documentID)"
    }

    private func signalLocalCloudChange() {
        // Saved ink and objects are included in canvas previews, including outside the old page.
        thumbnailCache.removeAll()
        cloudSyncGeneration &+= 1
    }
}
