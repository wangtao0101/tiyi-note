import CloudKit
import CryptoKit
import Foundation
import OSLog

/// Multiple zone coordinators share one DrawingDocumentStore. Serializing complete passes avoids
/// stale snapshot interleaving (private library applies A, shared zone later applies a snapshot
/// captured before A). CloudKit itself remains incremental; only local transactions are gated.
private actor CloudLibrarySyncTransactionGate {
    static let shared = CloudLibrarySyncTransactionGate()

    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Synchronizes the shared library model through one custom zone in the user's private database.
/// It uses zone-change tokens rather than queries, so the CloudKit schema needs no query indexes.
actor CloudLibrarySyncCoordinator {
    static let containerIdentifier = "iCloud.com.tiyi.note"
    static let defaultZoneName = "TiyiNoteLibrary"
    static let documentShareZonePrefix = "TiyiNoteDocument."

    static func documentShareZoneName(for documentID: String) -> String {
        let component = Data(documentID.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return documentShareZonePrefix + component
    }

    static func documentID(fromShareZoneName zoneName: String) -> String? {
        guard zoneName.hasPrefix(documentShareZonePrefix) else { return nil }
        var component = String(zoneName.dropFirst(documentShareZonePrefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = component.count % 4
        if remainder != 0 { component += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: component) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private enum RecordType {
        static let folder = "TiyiFolder"
        static let document = "TiyiDocument"
        static let documentReference = "TiyiDocumentReference"
        static let page = "TiyiPage"
        static let operation = "TiyiOperation"
        static let acknowledgement = "TiyiAcknowledgement"
        static let pageAnnotation = "TiyiPageAnnotation"
    }

    private enum Field {
        static let entityID = "entityID"
        static let title = "title"
        static let parentID = "parentID"
        static let fileName = "fileName"
        static let isBundled = "isBundled"
        static let createdAt = "createdAt"
        static let modifiedAt = "modifiedAt"
        static let contentModifiedAt = "contentModifiedAt"
        static let folderPayload = "folderPayload"
        static let folderColor = "folderColor"
        static let folderIcon = "folderIcon"
        static let isFavorite = "isFavorite"
        static let trashedAt = "trashedAt"
        static let documentKind = "documentKind"
        static let backgroundStyle = "backgroundStyle"
        static let backgroundColor = "backgroundColor"
        static let documentID = "documentID"
        static let pageIndex = "pageIndex"
        static let orderIndex = "orderIndex"
        static let pagePosition = "pagePosition"
        static let pageWidth = "pageWidth"
        static let pageHeight = "pageHeight"
        static let pageRotation = "pageRotation"
        static let pageSourceKind = "pageSourceKind"
        static let isBookmarked = "isBookmarked"
        static let deletedAt = "deletedAt"
        static let isDeleted = "isDeleted"
        static let deletionPayload = "deletionPayload"
        static let pdfAsset = "pdfAsset"
        static let drawingAsset = "drawingAsset"
        static let imagesAsset = "imagesAsset"
        static let elementsAsset = "elementsAsset"
        static let pageBackgroundAsset = "pageBackgroundAsset"
        static let workspaceID = "workspaceID"
        static let pageID = "pageID"
        static let operationStamp = "operationStamp"
        static let operationPayload = "operationPayload"
        static let referencePayload = "referencePayload"
        static let participantID = "participantID"
        static let acknowledgementPayload = "acknowledgementPayload"
    }

    private enum SyncError: LocalizedError {
        case noDataSource
        case accountUnavailable
        case missingAsset(URL)
        case malformedRecord(String)
        case missingOperationResult(String)
        case sharedZoneUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .noDataSource:
                "CloudKit 同步尚未连接本地资料库"
            case .accountUnavailable:
                "iCloud 账户当前不可用"
            case .missingAsset(let url):
                "等待上传的文件不存在：\(url.lastPathComponent)"
            case .malformedRecord(let name):
                "CloudKit 记录格式无效：\(name)"
            case .missingOperationResult(let name):
                "CloudKit 没有返回记录结果：\(name)"
            case .sharedZoneUnavailable(let name):
                "共享文稿区域不可用：\(name)"
            }
        }
    }

    private struct ManifestEntry: Codable {
        let reference: CloudLibraryEntityReference
        let fingerprint: String
        let isTombstone: Bool
        let modifiedAt: Date
        /// Lets a coordinator retire child records when their document is permanently deleted or
        /// moves to a different (shared) zone. Older manifests decode this as nil and are repaired
        /// from the immutable CloudKit operation on their next pass.
        let ownerDocumentID: String?
    }

    private struct UploadManifest: Codable {
        var entriesByKey: [String: ManifestEntry] = [:]
    }

    private struct UploadCandidate {
        let reference: CloudLibraryEntityReference
        let fingerprint: String
        let modifiedAt: Date
        let isTombstone: Bool
        let record: CKRecord

        var manifestEntry: ManifestEntry {
            ManifestEntry(
                reference: reference,
                fingerprint: fingerprint,
                isTombstone: isTombstone,
                modifiedAt: modifiedAt,
                ownerDocumentID: record[Field.documentID] as? String
            )
        }
    }

    private enum DownloadedChange {
        case folder(LibraryFolder)
        case document(LibraryDocumentMetadata, pdfAssetURL: URL?)
        case documentReference(LibraryDocumentReference)
        case page(
            LibraryPage,
            backgroundAssetURL: URL?,
            drawingAssetURL: URL?,
            elementsAssetURL: URL?
        )
        case operation(CollaborationOperation)
        case acknowledgement(CollaborationAcknowledgement)
        case pageAnnotation(
            documentID: String,
            pageIndex: Int,
            modifiedAt: Date,
            drawingAssetURL: URL?,
            imagesAssetURL: URL?
        )
        case deletion(LibraryEntityDeletionTombstone)

        var reference: CloudLibraryEntityReference {
            switch self {
            case .folder(let folder):
                CloudLibraryEntityReference(kind: .folder, entityID: folder.id)
            case .document(let document, _):
                CloudLibraryEntityReference(kind: .document, entityID: document.id)
            case .documentReference(let reference):
                CloudLibraryEntityReference(
                    kind: .documentReference,
                    entityID: reference.documentID
                )
            case .page(let page, _, _, _):
                CloudLibraryEntityReference(kind: .page, entityID: page.id)
            case .operation(let operation):
                CloudLibraryEntityReference(kind: .operation, entityID: operation.id)
            case .acknowledgement(let acknowledgement):
                CloudLibraryEntityReference(
                    kind: .acknowledgement,
                    entityID: acknowledgement.participantID
                )
            case .pageAnnotation(let documentID, let pageIndex, _, _, _):
                CloudLibraryEntityReference(
                    kind: .pageAnnotation,
                    entityID: "\(documentID)#\(pageIndex)"
                )
            case .deletion(let tombstone):
                tombstone.reference
            }
        }

        var modifiedAt: Date {
            switch self {
            case .folder(let folder): folder.modifiedAt
            case .document(let document, _): document.modifiedAt
            case .documentReference(let reference):
                [
                    reference.parent.stamp.createdAt,
                    reference.favorite.stamp.createdAt,
                    reference.trash.stamp.createdAt
                ].max() ?? .distantPast
            case .page(let page, _, _, _): page.modifiedAt
            case .operation(let operation): operation.stamp.createdAt
            case .acknowledgement(let acknowledgement): acknowledgement.lastSeenAt
            case .pageAnnotation(_, _, let date, _, _): date
            case .deletion(let tombstone): tombstone.deletedAt
            }
        }
    }

    private weak var dataSource: (any CloudLibrarySyncDataSource)?
    private let logger = Logger(subsystem: "com.tiyi.note", category: "CloudSync")
    private let container: CKContainer
    private let database: CKDatabase
    private let databaseScope: CKDatabase.Scope
    private let zoneID: CKRecordZone.ID
    private let scopedDocumentID: String?
    private let shouldCreateZone: Bool
    private let reportsStatus: Bool
    private var allowsUploads: Bool
    private let tokenStore: UserDefaults
    private let changeTokenKey: String
    private let uploadManifestKey: String
    private let uploadBatchSize: Int

    private var zoneIsReady = false
    private var isSynchronizing = false
    private var needsAnotherPass = false
    private var scheduledTask: Task<Void, Never>?
    private var excludedDocumentIDs: Set<String> = []
    private var currentParticipantID: String?
    private var activeParticipantIDs: Set<String> = []

    init(
        dataSource: (any CloudLibrarySyncDataSource)? = nil,
        zoneName: String = CloudLibrarySyncCoordinator.defaultZoneName,
        ownerName: String = CKCurrentUserDefaultName,
        databaseScope: CKDatabase.Scope = .private,
        scopedDocumentID: String? = nil,
        shouldCreateZone: Bool = true,
        reportsStatus: Bool = true,
        allowsUploads: Bool = true,
        tokenStore: UserDefaults = .standard,
        uploadBatchSize: Int = 100
    ) {
        self.dataSource = dataSource
        let container = CKContainer(identifier: Self.containerIdentifier)
        self.container = container
        self.databaseScope = databaseScope
        database = container.database(with: databaseScope)
        zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
        self.scopedDocumentID = scopedDocumentID
        self.shouldCreateZone = shouldCreateZone
        self.reportsStatus = reportsStatus
        self.allowsUploads = allowsUploads
        self.tokenStore = tokenStore
        self.uploadBatchSize = max(1, min(uploadBatchSize, 200))
        let keyScope = "\(databaseScope.rawValue).\(ownerName).\(zoneName)"
        changeTokenKey = "cloudLibrary.zoneToken.\(Self.containerIdentifier).\(keyScope)"
        uploadManifestKey = "cloudLibrary.uploadManifest.\(Self.containerIdentifier).\(keyScope)"
    }

    deinit {
        scheduledTask?.cancel()
    }

    func setDataSource(_ dataSource: (any CloudLibrarySyncDataSource)?) {
        self.dataSource = dataSource
    }

    func setExcludedDocumentIDs(_ documentIDs: Set<String>) {
        excludedDocumentIDs = documentIDs
    }

    /// A participant whose CKShare permission was downgraded must still download changes, but
    /// must never repeatedly attempt writes that CloudKit will reject.
    func setAllowsUploads(_ allowsUploads: Bool) {
        self.allowsUploads = allowsUploads
    }

    func syncNowOrThrow() async throws {
        scheduledTask?.cancel()
        scheduledTask = nil
        try await performSyncPass()
    }

    /// Debounces rapid PencilKit/library changes into one synchronization pass.
    func scheduleSync(after delay: TimeInterval = 0.8) async {
        scheduledTask?.cancel()
        await reportStatus(.scheduled)
        let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
        scheduledTask = Task { [weak self] in
            if nanoseconds > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            guard !Task.isCancelled else { return }
            await self?.synchronizeReportingErrors()
        }
    }

    /// Starts immediately. Errors become status updates; local files are never discarded on failure.
    func syncNow() async {
        scheduledTask?.cancel()
        scheduledTask = nil
        await synchronizeReportingErrors()
    }

    func cancelScheduledSync() async {
        scheduledTask?.cancel()
        scheduledTask = nil
        if !isSynchronizing {
            await reportStatus(.idle)
        }
    }

    /// Call after CKAccountChanged. A fresh account must never reuse the previous zone token/manifest.
    func resetForAccountChange() async {
        scheduledTask?.cancel()
        scheduledTask = nil
        zoneIsReady = false
        clearChangeToken()
        clearUploadManifest()
        await scheduleSync(after: 0)
    }

    private func synchronizeReportingErrors() async {
        if isSynchronizing {
            needsAnotherPass = true
            return
        }

        isSynchronizing = true
        scheduledTask = nil
        await reportStatus(.syncing)
        var retryDelay: TimeInterval?

        do {
            repeat {
                needsAnotherPass = false
                try await performSyncPass()
            } while needsAnotherPass
            await reportStatus(.succeeded(Date()))
        } catch {
            let cocoaError = error as NSError
            logger.error(
                "CloudKit sync failed: domain=\(cocoaError.domain, privacy: .public) code=\(cocoaError.code) description=\(cocoaError.localizedDescription, privacy: .public)"
            )
#if DEBUG
            // CloudKit's userInfo can exceed the unified-log message limit. Log every field on
            // its own line so server rejection reasons and request IDs remain visible in Console.
            for (key, value) in cocoaError.userInfo.sorted(by: {
                String(describing: $0.key) < String(describing: $1.key)
            }) {
                logger.error(
                    "CloudKit error detail \(String(describing: key), privacy: .public)=\(String(reflecting: value), privacy: .public)"
                )
            }
#endif
            retryDelay = retryDelayIfTransient(error)
            await reportFailure(error)
        }

        isSynchronizing = false
        if let retryDelay {
            scheduleRetry(after: retryDelay)
        }
    }

    private func performSyncPass() async throws {
        await CloudLibrarySyncTransactionGate.shared.acquire()
        do {
            try await performUnlockedSyncPass()
            await CloudLibrarySyncTransactionGate.shared.release()
        } catch {
            await CloudLibrarySyncTransactionGate.shared.release()
            throw error
        }
    }

    private func performUnlockedSyncPass() async throws {
        guard dataSource != nil else { throw SyncError.noDataSource }
        let accountStatus = try await container.accountStatus()
        guard accountStatus == .available else { throw SyncError.accountUnavailable }

        try await ensureZone()
        await refreshShareParticipants()
        await ensurePushSubscription()
        try await downloadAndApplyChanges()
        if allowsUploads {
            try await uploadPendingChanges()
        }
    }

    /// Push is only a latency optimization; change tokens remain the source of truth. Failure to
    /// register (common on simulators and unsigned Catalyst builds) must not block normal sync.
    private func ensurePushSubscription() async {
        let subscriptionID = "TiyiNote.Zone.\(databaseScope.rawValue).\(zoneID.ownerName).\(zoneID.zoneName)"
        do {
            _ = try await database.subscription(for: subscriptionID)
            return
        } catch let error as CKError where error.code == .unknownItem {
            // Create below.
        } catch {
            logger.debug("CloudKit subscription lookup skipped: \(error.localizedDescription, privacy: .public)")
            return
        }

        let subscription = CKRecordZoneSubscription(
            zoneID: zoneID,
            subscriptionID: subscriptionID
        )
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo
        do {
            _ = try await database.save(subscription)
        } catch {
            logger.debug("CloudKit subscription creation skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ensureZone() async throws {
        guard !zoneIsReady else { return }

        // Fetch first so an existing zone is reused and a container/account failure can be
        // distinguished from a zone-creation failure in CloudKit diagnostics.
        let fetchResults = try await database.recordZones(for: [zoneID])
        if let fetchResult = fetchResults[zoneID] {
            switch fetchResult {
            case .success:
                zoneIsReady = true
                return
            case .failure(let error as CKError) where error.code == .zoneNotFound:
                guard shouldCreateZone else {
                    throw SyncError.sharedZoneUnavailable(zoneID.zoneName)
                }
                break
            case .failure(let error):
                throw error
            }
        }

        let zone = CKRecordZone(zoneID: zoneID)
        let result = try await database.modifyRecordZones(saving: [zone], deleting: [])
        guard let saveResult = result.saveResults[zoneID] else {
            throw SyncError.missingOperationResult(zoneID.zoneName)
        }
        _ = try saveResult.get()
        zoneIsReady = true
    }

    /// CKShare membership, not a wall-clock lease, defines who must acknowledge history. Removed
    /// participants stop blocking future compaction; an invited participant with no ACK blocks it.
    private func refreshShareParticipants() async {
        guard scopedDocumentID != nil else {
            currentParticipantID = nil
            activeParticipantIDs = []
            return
        }
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        guard let share = try? await database.record(for: shareID) as? CKShare else {
            // prepareShare populates content before creating CKShare. No acknowledgement is
            // otherwise available during that bootstrap pass. Seed the owner's ACK record before
            // the zone becomes shared; later participants add their own records after acceptance.
            if databaseScope == .private {
                currentParticipantID = CKCurrentUserDefaultName
                activeParticipantIDs = [CKCurrentUserDefaultName]
            } else {
                currentParticipantID = nil
                activeParticipantIDs = []
            }
            return
        }
        let active = Set(share.participants.compactMap(Self.stableParticipantID))
        activeParticipantIDs = active
        currentParticipantID = share.currentUserParticipant.flatMap(Self.stableParticipantID)
            ?? (databaseScope == .private ? Self.stableParticipantID(share.owner) : nil)
    }

    private static func stableParticipantID(_ participant: CKShare.Participant) -> String? {
        guard let recordName = participant.userIdentity.userRecordID?.recordName,
              !recordName.isEmpty else { return nil }
        return recordName
    }

    private func downloadAndApplyChanges() async throws {
        var token = loadChangeToken()
        var retriedExpiredToken = false
        var retriedMissingZone = false

        while true {
            let stagingDirectory = try makeDownloadStagingDirectory()
            do {
                let download = try await fetchCompleteChangeSet(
                    since: token,
                    stagingDirectory: stagingDirectory
                )
                if !download.changes.isEmpty {
                    try await applyDownloadedChanges(download.changes)
                    try await updateManifestForDownloadedChanges(download.changes)
                }
                // Commit only the final page token, after the complete cross-page graph and all
                // staged assets have been installed successfully.
                try saveChangeToken(download.finalToken)
                removeDownloadStagingDirectory(stagingDirectory)
                return
            } catch let error as CKError where error.code == .changeTokenExpired && !retriedExpiredToken {
                removeDownloadStagingDirectory(stagingDirectory)
                retriedExpiredToken = true
                token = nil
            } catch let error as CKError where error.code == .zoneNotFound && !retriedMissingZone {
                removeDownloadStagingDirectory(stagingDirectory)
                retriedMissingZone = true
                zoneIsReady = false
                token = nil
                // The old manifest belongs to a zone that no longer exists. Local records must
                // be eligible for a complete re-upload after the replacement zone is created.
                clearUploadManifest()
                guard shouldCreateZone else {
                    throw SyncError.sharedZoneUnavailable(zoneID.zoneName)
                }
                try await ensureZone()
            } catch {
                removeDownloadStagingDirectory(stagingDirectory)
                throw error
            }
        }
    }

    private func fetchCompleteChangeSet(
        since initialToken: CKServerChangeToken?,
        stagingDirectory: URL
    ) async throws -> (changes: [DownloadedChange], finalToken: CKServerChangeToken) {
        var token = initialToken
        var accumulatedChanges: [DownloadedChange] = []

        while true {
            let page = try await database.recordZoneChanges(
                inZoneWith: zoneID,
                since: token,
                desiredKeys: nil,
                resultsLimit: 200
            )

            accumulatedChanges.reserveCapacity(
                accumulatedChanges.count
                    + page.modificationResultsByID.count
                    + page.deletions.count
            )
            for result in page.modificationResultsByID.values {
                guard let decoded = decodeRemoteRecord(try result.get().record) else { continue }
                // CKAsset file URLs are callback-scoped. Materialize every page before asking
                // CloudKit for the next one, otherwise cross-page accumulation can lose bytes.
                accumulatedChanges.append(
                    try stageAssets(in: decoded, at: stagingDirectory)
                )
            }
            for deletion in page.deletions {
                guard let reference = reference(
                    recordType: deletion.recordType,
                    recordName: deletion.recordID.recordName
                ) else { continue }
                accumulatedChanges.append(
                    .deletion(
                        .legacy(
                            reference: reference,
                            ownerDocumentID: reference.kind == .document
                                ? reference.entityID
                                : nil,
                            deletedAt: Date()
                        )
                    )
                )
            }

            token = page.changeToken
            if !page.moreComing {
                return (accumulatedChanges, page.changeToken)
            }
        }
    }

    private func makeDownloadStagingDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TiyiNoteCloudDownloads", isDirectory: true)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func removeDownloadStagingDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    private func stageAssets(
        in change: DownloadedChange,
        at directory: URL
    ) throws -> DownloadedChange {
        switch change {
        case .folder, .documentReference, .operation, .acknowledgement, .deletion:
            return change
        case .document(let document, let pdfAssetURL):
            let stagedPDF = try pdfAssetURL.map {
                try copyDownloadedAsset($0, to: directory, pathExtension: "pdf")
            }
            return .document(document, pdfAssetURL: stagedPDF)
        case .page(
            let page,
            let backgroundAssetURL,
            let drawingAssetURL,
            let elementsAssetURL
        ):
            let stagedBackground = try backgroundAssetURL.map {
                try copyDownloadedAsset($0, to: directory, pathExtension: "background.pdf")
            }
            let stagedDrawing = try drawingAssetURL.map {
                try copyDownloadedAsset($0, to: directory, pathExtension: "drawing")
            }
            let stagedElements = try elementsAssetURL.map {
                try copyDownloadedAsset($0, to: directory, pathExtension: "elements.json")
            }
            return .page(
                page,
                backgroundAssetURL: stagedBackground,
                drawingAssetURL: stagedDrawing,
                elementsAssetURL: stagedElements
            )
        case .pageAnnotation(
            let documentID,
            let pageIndex,
            let modifiedAt,
            let drawingAssetURL,
            let imagesAssetURL
        ):
            let stagedDrawing = try drawingAssetURL.map {
                try copyDownloadedAsset($0, to: directory, pathExtension: "drawing")
            }
            let stagedImages = try imagesAssetURL.map {
                try copyDownloadedAsset($0, to: directory, pathExtension: "images.json")
            }
            return .pageAnnotation(
                documentID: documentID,
                pageIndex: pageIndex,
                modifiedAt: modifiedAt,
                drawingAssetURL: stagedDrawing,
                imagesAssetURL: stagedImages
            )
        }
    }

    private func copyDownloadedAsset(
        _ sourceURL: URL,
        to directory: URL,
        pathExtension: String
    ) throws -> URL {
        try requireReadableFile(at: sourceURL)
        let targetURL = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pathExtension)
        try FileManager.default.copyItem(at: sourceURL, to: targetURL)
        return targetURL
    }

    private func uploadPendingChanges() async throws {
        var manifest = loadUploadManifest()
        let allCandidates = try await makeUploadCandidates(manifest: &manifest)
        let candidates = Array(allCandidates.prefix(uploadBatchSize))
        guard !candidates.isEmpty else {
            // makeUploadCandidates may have retired stale immutable-operation entries even when
            // there is no CloudKit write to perform.
            try saveUploadManifest(manifest)
            return
        }

        let records = candidates.map(\.record)
        let candidatesByRecordID = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.record.recordID, $0) }
        )
        let results = try await database.modifyRecords(
            saving: records,
            deleting: [],
            savePolicy: .ifServerRecordUnchanged,
            atomically: false
        )

        var firstFailure: Error?
        for record in records {
            guard let candidate = candidatesByRecordID[record.recordID] else { continue }
            guard let result = results.saveResults[record.recordID] else {
                firstFailure = firstFailure ?? SyncError.missingOperationResult(record.recordID.recordName)
                continue
            }
            do {
                switch result {
                case .success:
                    break
                case .failure(let error):
                    try await resolveConflict(
                        error: error,
                        clientRecord: record,
                        candidate: candidate
                    )
                }
                manifest.entriesByKey[manifestKey(candidate.reference)] = candidate.manifestEntry
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        try saveUploadManifest(manifest)

        if let firstFailure { throw firstFailure }
        if allCandidates.count > uploadBatchSize {
            needsAnotherPass = true
        }
    }

    private func makeUploadCandidates(
        manifest: inout UploadManifest
    ) async throws -> [UploadCandidate] {
        guard let dataSource else { throw SyncError.noDataSource }
        var fullSnapshot = await dataSource.exportLibrarySnapshot()
        let personalReferenceIDs: Set<String> = scopedDocumentID == nil
            ? Set(fullSnapshot.documents.map(\.id)).union(excludedDocumentIDs)
            : []
        let personalReferences = scopedDocumentID == nil
            ? try await dataSource.exportDocumentReferences(for: personalReferenceIDs)
            : []
        let personalReferencesByID = Dictionary(
            uniqueKeysWithValues: personalReferences.map { ($0.documentID, $0) }
        )
        if !personalReferenceIDs.isEmpty {
            // exportDocumentReferences migrates legacy records by assigning causal field stamps.
            fullSnapshot = await dataSource.exportLibrarySnapshot()
        }
        let includedDocumentIDs: Set<String>
        if let scopedDocumentID {
            includedDocumentIDs = [scopedDocumentID]
        } else {
            includedDocumentIDs = Set(fullSnapshot.documents.map(\.id))
                .subtracting(excludedDocumentIDs)
        }
        let scopedDocuments = fullSnapshot.documents.compactMap { document -> LibraryDocumentMetadata? in
            guard includedDocumentIDs.contains(document.id) else { return nil }
            var document = document
            if scopedDocumentID != nil {
                // CKShare zones contain content only. Every participant keeps placement,
                // favorite, and personal-trash state in their own private library zone.
                document.parentID = nil
                document.isFavorite = false
                document.trashedAt = nil
                document.modifiedAt = document.contentModifiedAt
                document.parentRevision = nil
                document.favoriteRevision = nil
                document.trashRevision = nil
            }
            return document
        }
        let snapshot = LibrarySnapshot(
            folders: scopedDocumentID == nil ? fullSnapshot.folders : [],
            documents: scopedDocuments,
            pages: fullSnapshot.pages.filter { includedDocumentIDs.contains($0.documentID) }
        )
        var currentCandidates: [String: UploadCandidate] = [:]

        for folder in snapshot.folders {
            let reference = CloudLibraryEntityReference(kind: .folder, entityID: folder.id)
            let payload = try encodedCollaboration(folder)
            let fingerprint = payloadFingerprint(prefix: "folder", data: payload)
            let record = makeBaseRecord(reference: reference, modifiedAt: folder.modifiedAt)
            record[Field.title] = folder.title as CKRecordValue
            record[Field.parentID] = folder.parentID as CKRecordValue?
            record[Field.createdAt] = folder.createdAt as CKRecordValue
            record[Field.folderColor] = folder.color.rawValue as CKRecordValue
            record[Field.folderIcon] = folder.icon.rawValue as CKRecordValue
            record[Field.isFavorite] = NSNumber(value: folder.isFavorite)
            record[Field.trashedAt] = folder.trashedAt as CKRecordValue?
            record[Field.folderPayload] = payload as CKRecordValue
            currentCandidates[manifestKey(reference)] = UploadCandidate(
                reference: reference,
                fingerprint: fingerprint,
                modifiedAt: folder.modifiedAt,
                isTombstone: false,
                record: record
            )
        }

        if scopedDocumentID == nil, !excludedDocumentIDs.isEmpty {
            for referenceValue in personalReferences where excludedDocumentIDs.contains(
                referenceValue.documentID
            ) {
                let reference = CloudLibraryEntityReference(
                    kind: .documentReference,
                    entityID: referenceValue.documentID
                )
                let payload = try encodedCollaboration(referenceValue)
                let modifiedAt = referenceValue.latestDisplayDate
                let record = makeBaseRecord(reference: reference, modifiedAt: modifiedAt)
                record[Field.documentID] = referenceValue.documentID as CKRecordValue
                record[Field.referencePayload] = payload as CKRecordValue
                currentCandidates[manifestKey(reference)] = UploadCandidate(
                    reference: reference,
                    fingerprint: payloadFingerprint(prefix: "document-reference", data: payload),
                    modifiedAt: modifiedAt,
                    isTombstone: false,
                    record: record
                )
            }
        }

        // Every document gets a metadata record so bundled samples can be renamed/moved across
        // devices. Only user-imported PDFs upload their bytes; samples already ship in each app.
        for document in snapshot.documents {
            let reference = CloudLibraryEntityReference(kind: .document, entityID: document.id)
            let record = makeBaseRecord(reference: reference, modifiedAt: document.modifiedAt)
            record[Field.title] = document.title as CKRecordValue
            record[Field.parentID] = document.parentID as CKRecordValue?
            record[Field.fileName] = document.fileName as CKRecordValue
            record[Field.isBundled] = NSNumber(value: document.isBundled)
            record[Field.createdAt] = document.createdAt as CKRecordValue
            record[Field.contentModifiedAt] = document.contentModifiedAt as CKRecordValue
            record[Field.documentKind] = document.kind.rawValue as CKRecordValue
            record[Field.backgroundStyle] = document.canvasBackgroundStyle?.rawValue as CKRecordValue?
            record[Field.backgroundColor] = document.canvasBackgroundColor?.rawValue as CKRecordValue?
            record[Field.isFavorite] = NSNumber(value: document.isFavorite)
            record[Field.trashedAt] = document.trashedAt as CKRecordValue?
            var fingerprintData = try encodedCollaboration(document)
            if scopedDocumentID == nil,
               let personalReference = personalReferencesByID[document.id] {
                let payload = try encodedCollaboration(personalReference)
                record[Field.referencePayload] = payload as CKRecordValue
                fingerprintData.append(payload)
            }
            if !document.isBundled {
                let assetReference = LibraryAssetReference(documentID: document.id, kind: .pdf)
                guard let pdfURL = await dataSource.assetURL(for: assetReference) else {
                    throw SyncError.missingAsset(URL(fileURLWithPath: document.fileName))
                }
                try requireReadableFile(at: pdfURL)
                record[Field.pdfAsset] = CKAsset(fileURL: pdfURL)
            }
            let fingerprint = payloadFingerprint(prefix: "document", data: fingerprintData)
            currentCandidates[manifestKey(reference)] = UploadCandidate(
                reference: reference,
                fingerprint: fingerprint,
                modifiedAt: document.modifiedAt,
                isTombstone: false,
                record: record
            )
        }

        // Pages have stable identities. Reordering updates metadata without renaming or moving
        // the page's drawing/element assets.
        for document in snapshot.documents {
            let availableReferences = Set(
                await dataSource.availableAssetReferences(for: document.id)
            )
            for page in snapshot.pages
                .filter({ $0.documentID == document.id })
                .sorted(by: {
                    if $0.position != $1.position { return $0.position < $1.position }
                    return $0.id < $1.id
                }) {
                let drawingReference = LibraryAssetReference(
                    documentID: document.id,
                    kind: .pageDrawing(pageID: page.id)
                )
                let elementsReference = LibraryAssetReference(
                    documentID: document.id,
                    kind: .pageElements(pageID: page.id)
                )
                let backgroundReference = LibraryAssetReference(
                    documentID: document.id,
                    kind: .pageBackground(pageID: page.id)
                )
                let background = availableReferences.contains(backgroundReference)
                    ? await dataSource.assetURL(for: backgroundReference)
                    : nil
                let drawing = availableReferences.contains(drawingReference)
                    ? await dataSource.assetURL(for: drawingReference)
                    : nil
                let elements = availableReferences.contains(elementsReference)
                    ? await dataSource.assetURL(for: elementsReference)
                    : nil
                if let background { try requireReadableFile(at: background) }
                if let drawing { try requireReadableFile(at: drawing) }
                if let elements { try requireReadableFile(at: elements) }
                let modifiedAt = max(
                    page.modifiedAt,
                    fileModificationDate(background) ?? .distantPast,
                    fileModificationDate(drawing) ?? .distantPast,
                    fileModificationDate(elements) ?? .distantPast
                )
                let reference = CloudLibraryEntityReference(kind: .page, entityID: page.id)
                let fingerprint = pageFingerprint(
                    page: page,
                    modifiedAt: modifiedAt,
                    backgroundURL: background,
                    drawingURL: drawing,
                    elementsURL: elements
                )
                let record = makeBaseRecord(reference: reference, modifiedAt: modifiedAt)
                record[Field.documentID] = document.id as CKRecordValue
                record[Field.orderIndex] = NSNumber(value: page.orderIndex)
                record[Field.pagePosition] = try encodedCollaboration(page.position) as CKRecordValue
                record[Field.pageWidth] = NSNumber(value: page.width)
                record[Field.pageHeight] = NSNumber(value: page.height)
                record[Field.pageRotation] = NSNumber(value: page.rotation)
                record[Field.pageSourceKind] = page.sourceKind.rawValue as CKRecordValue
                record[Field.backgroundStyle] = page.backgroundStyle?.rawValue as CKRecordValue?
                record[Field.backgroundColor] = page.backgroundColor?.rawValue as CKRecordValue?
                record[Field.isBookmarked] = NSNumber(value: page.isBookmarked)
                record[Field.createdAt] = page.createdAt as CKRecordValue
                if let background {
                    record[Field.pageBackgroundAsset] = CKAsset(fileURL: background)
                }
                if let drawing {
                    record[Field.drawingAsset] = CKAsset(fileURL: drawing)
                }
                if let elements {
                    record[Field.elementsAsset] = CKAsset(fileURL: elements)
                }
                currentCandidates[manifestKey(reference)] = UploadCandidate(
                    reference: reference,
                    fingerprint: fingerprint,
                    modifiedAt: modifiedAt,
                    isTombstone: false,
                    record: record
                )
            }
        }

        // Collaboration events are append-only and use unique record IDs. Two participants never
        // update the same operation record, so CloudKit conflicts are limited to duplicate IDs.
        let collaborationOperations = await dataSource.exportCollaborationOperations()
        for operation in collaborationOperations
        where includedDocumentIDs.contains(operation.documentID) {
            let reference = CloudLibraryEntityReference(
                kind: .operation,
                entityID: operation.id
            )
            let stampData = try encodedCollaboration(operation.stamp)
            let payloadData = try encodedCollaboration(operation.payload)
            let fingerprint = collaborationOperationFingerprint(
                operation: operation,
                stampData: stampData,
                payloadData: payloadData
            )
            let record = makeBaseRecord(
                reference: reference,
                modifiedAt: operation.stamp.createdAt
            )
            record[Field.workspaceID] = operation.workspaceID as CKRecordValue
            record[Field.documentID] = operation.documentID as CKRecordValue
            record[Field.pageID] = operation.pageID as CKRecordValue
            record[Field.operationStamp] = stampData as CKRecordValue
            record[Field.operationPayload] = payloadData as CKRecordValue
            currentCandidates[manifestKey(reference)] = UploadCandidate(
                reference: reference,
                fingerprint: fingerprint,
                modifiedAt: operation.stamp.createdAt,
                isTombstone: false,
                record: record
            )
        }

        if let scopedDocumentID,
           let currentParticipantID,
           includedDocumentIDs.contains(scopedDocumentID) {
            var frontier = CollaborationVersionVector()
            for operation in collaborationOperations where operation.documentID == scopedDocumentID {
                frontier.formUnion(operation.stamp.context)
                frontier.observe(operation.stamp.dot)
            }
            let existing = await dataSource.exportCollaborationAcknowledgements(
                for: scopedDocumentID
            ).first { $0.participantID == currentParticipantID }
            let previousFrontier = existing?.frontier ?? CollaborationVersionVector()
            let mergedFrontier = previousFrontier.union(frontier)
            let heartbeatDue = existing.map {
                Date().timeIntervalSince($0.lastSeenAt) >= 86_400
            } ?? true
            let acknowledgement = CollaborationAcknowledgement(
                documentID: scopedDocumentID,
                participantID: currentParticipantID,
                frontier: mergedFrontier,
                lastSeenAt: mergedFrontier != previousFrontier || heartbeatDue
                    ? Date()
                    : (existing?.lastSeenAt ?? Date())
            )
            try await dataSource.applyRemoteCollaborationAcknowledgements([acknowledgement])
            if databaseScope == .private, !activeParticipantIDs.isEmpty {
                let acknowledgements = await dataSource.exportCollaborationAcknowledgements(
                    for: scopedDocumentID
                )
                let acknowledgedCount = collaborationOperations.lazy
                    .filter { $0.documentID == scopedDocumentID }
                    .filter {
                        CollaborationMergeEngine.canCompact(
                            $0,
                            acknowledgements: acknowledgements,
                            activeParticipantIDs: self.activeParticipantIDs
                        )
                    }
                    .count
                logger.debug(
                    "ACK-safe operations=\(acknowledgedCount, privacy: .public); destructive GC remains disabled"
                )
            }
            let payload = try encodedCollaboration(acknowledgement)
            let reference = CloudLibraryEntityReference(
                kind: .acknowledgement,
                entityID: acknowledgement.participantID
            )
            let record = makeBaseRecord(
                reference: reference,
                modifiedAt: acknowledgement.lastSeenAt
            )
            record[Field.documentID] = scopedDocumentID as CKRecordValue
            record[Field.participantID] = acknowledgement.participantID as CKRecordValue
            record[Field.acknowledgementPayload] = payload as CKRecordValue
            currentCandidates[manifestKey(reference)] = UploadCandidate(
                reference: reference,
                fingerprint: payloadFingerprint(prefix: "acknowledgement", data: payload),
                modifiedAt: acknowledgement.lastSeenAt,
                isTombstone: false,
                record: record
            )
        }

        // Causal tombstones are explicit current state, not inferred from this device's upload
        // manifest. They therefore survive reinstall/new-device sync and always override a live
        // record with the same stable ID, including a concurrent edit from a long-offline client.
        let exportedTombstones = await dataSource.exportDeletionTombstones()
        let permanentlyDeletedDocumentIDs = Set(
            exportedTombstones.lazy
                .filter { $0.reference.kind == .document }
                .map { $0.reference.entityID }
        )
        for tombstone in exportedTombstones {
            let isInScope: Bool
            if let scopedDocumentID {
                isInScope = tombstone.reference.kind != .folder
                    && (tombstone.ownerDocumentID == scopedDocumentID
                        || (tombstone.reference.kind == .document
                            && tombstone.reference.entityID == scopedDocumentID))
            } else if tombstone.reference.kind == .folder {
                isInScope = true
            } else {
                let documentID = tombstone.ownerDocumentID ?? tombstone.reference.entityID
                isInScope = !excludedDocumentIDs.contains(documentID)
            }
            guard isInScope else { continue }

            let payload = try encodedCollaboration(tombstone)
            let record = makeBaseRecord(
                reference: tombstone.reference,
                modifiedAt: tombstone.deletedAt
            )
            record[Field.isDeleted] = NSNumber(value: true)
            record[Field.deletedAt] = tombstone.deletedAt as CKRecordValue
            record[Field.deletionPayload] = payload as CKRecordValue
            if let ownerDocumentID = tombstone.ownerDocumentID {
                record[Field.documentID] = ownerDocumentID as CKRecordValue
            }
            currentCandidates[manifestKey(tombstone.reference)] = UploadCandidate(
                reference: tombstone.reference,
                fingerprint: payloadFingerprint(prefix: "tombstone", data: payload),
                modifiedAt: tombstone.deletedAt,
                isTombstone: true,
                record: record
            )
        }

        // A missing local immutable operation normally means local corruption/interrupted file
        // replacement, so re-fetch it by stable ID. The two intentional exceptions are a parent
        // document deletion and a document that this coordinator no longer owns (for example, it
        // moved from the private library zone to a shared zone). In those cases the parent state
        // shadows the append-only history and this manifest must forget the child entry; otherwise
        // every pass would re-fetch an operation that the store is required to ignore.
        let missingOperationEntries = manifest.entriesByKey.filter { key, entry in
            entry.reference.kind == .operation
                && !entry.isTombstone
                && currentCandidates[key] == nil
        }
        for (key, oldEntry) in missingOperationEntries {
            if let ownerDocumentID = oldEntry.ownerDocumentID,
               permanentlyDeletedDocumentIDs.contains(ownerDocumentID)
                    || !includedDocumentIDs.contains(ownerDocumentID) {
                manifest.entriesByKey.removeValue(forKey: key)
                continue
            }
            do {
                let remoteRecord = try await database.record(
                    for: recordID(for: oldEntry.reference)
                )
                if case .operation(let operation)? = decodeRemoteRecord(remoteRecord) {
                    guard !permanentlyDeletedDocumentIDs.contains(operation.documentID),
                          includedDocumentIDs.contains(operation.documentID) else {
                        manifest.entriesByKey.removeValue(forKey: key)
                        continue
                    }
                    try await dataSource.applyRemoteCollaborationOperations([operation])
                    manifest.entriesByKey[key] = ManifestEntry(
                        reference: oldEntry.reference,
                        fingerprint: oldEntry.fingerprint,
                        isTombstone: oldEntry.isTombstone,
                        modifiedAt: oldEntry.modifiedAt,
                        ownerDocumentID: operation.documentID
                    )
                    needsAnotherPass = true
                }
            } catch let error as CKError where error.code == .unknownItem {
                logger.error(
                    "Immutable operation missing locally and remotely: \(oldEntry.reference.entityID, privacy: .public)"
                )
            }
        }

        var pending = currentCandidates.compactMap { key, candidate in
            manifest.entriesByKey[key]?.fingerprint == candidate.fingerprint
                && manifest.entriesByKey[key]?.isTombstone == candidate.isTombstone
                ? nil
                : candidate
        }

        for (key, oldEntry) in manifest.entriesByKey
        where currentCandidates[key] == nil
            && !oldEntry.isTombstone
            && oldEntry.reference.kind != .acknowledgement
            && oldEntry.reference.kind != .operation {
            let deletedAt = Date()
            let legacyTombstone = LibraryEntityDeletionTombstone.legacy(
                reference: oldEntry.reference,
                ownerDocumentID: oldEntry.reference.kind == .document
                    ? oldEntry.reference.entityID
                    : nil,
                deletedAt: deletedAt
            )
            let payload = try encodedCollaboration(legacyTombstone)
            let record = makeBaseRecord(reference: oldEntry.reference, modifiedAt: deletedAt)
            record[Field.isDeleted] = NSNumber(value: true)
            record[Field.deletedAt] = deletedAt as CKRecordValue
            record[Field.deletionPayload] = payload as CKRecordValue
            if oldEntry.reference.kind == .pageAnnotation,
               let page = parsePageEntityID(oldEntry.reference.entityID) {
                record[Field.documentID] = page.documentID as CKRecordValue
                record[Field.pageIndex] = NSNumber(value: page.pageIndex)
            }
            pending.append(
                UploadCandidate(
                    reference: oldEntry.reference,
                    fingerprint: payloadFingerprint(prefix: "tombstone", data: payload),
                    modifiedAt: deletedAt,
                    isTombstone: true,
                    record: record
                )
            )
        }

        return pending.sorted {
            if uploadRank($0.reference.kind) != uploadRank($1.reference.kind) {
                return uploadRank($0.reference.kind) < uploadRank($1.reference.kind)
            }
            return $0.reference.entityID < $1.reference.entityID
        }
    }

    private func resolveConflict(
        error: Error,
        clientRecord: CKRecord,
        candidate: UploadCandidate
    ) async throws {
        guard
            let cloudError = error as? CKError,
            cloudError.code == .serverRecordChanged,
            let conflictRecord = cloudError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord
        else { throw error }

        let clientDeletion: LibraryEntityDeletionTombstone? = {
            guard case .deletion(let value)? = decodeRemoteRecord(clientRecord) else { return nil }
            return value
        }()
        let serverDeletion: LibraryEntityDeletionTombstone? = {
            guard case .deletion(let value)? = decodeRemoteRecord(conflictRecord) else { return nil }
            return value
        }()
        if clientDeletion != nil || serverDeletion != nil {
            let mergedDeletion: LibraryEntityDeletionTombstone
            switch (clientDeletion, serverDeletion) {
            case let (client?, server?):
                mergedDeletion = server.merged(with: client)
            case let (client?, nil):
                mergedDeletion = client
            case let (nil, server?):
                mergedDeletion = server
            case (nil, nil):
                preconditionFailure("deletion branch requires a tombstone")
            }
            try await dataSource?.applyRemoteDeletionTombstones([mergedDeletion])

            // A live client record never overwrites a server tombstone. If both sides deleted,
            // repair only when their causal antichains differ so all delete dots are retained.
            if clientDeletion == nil || mergedDeletion == serverDeletion {
                needsAnotherPass = true
                return
            }
            try populateDeletionRecord(conflictRecord, with: mergedDeletion)
            let repair = try await database.modifyRecords(
                saving: [conflictRecord],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: true
            )
            guard let repairResult = repair.saveResults[conflictRecord.recordID] else {
                throw SyncError.missingOperationResult(conflictRecord.recordID.recordName)
            }
            _ = try repairResult.get()
            needsAnotherPass = true
            return
        }

        if candidate.reference.kind == .operation,
           case .operation(let clientOperation)? = decodeRemoteRecord(clientRecord),
           case .operation(let serverOperation)? = decodeRemoteRecord(conflictRecord) {
            let preferred = CollaborationOperation.preferred(
                serverOperation,
                clientOperation
            )
            if preferred == serverOperation {
                try await applyDownloadedChanges([.operation(serverOperation)])
                needsAnotherPass = true
                return
            }
            // Duplicate operation IDs are invalid, but old/corrupt clients can create them. The
            // canonical byte order picks one globally and repairs the single server record so all
            // replicas converge instead of trusting wall clocks or arrival order.
            overlayManagedFields(from: clientRecord, onto: conflictRecord)
            let repair = try await database.modifyRecords(
                saving: [conflictRecord],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: true
            )
            guard let repairResult = repair.saveResults[conflictRecord.recordID] else {
                throw SyncError.missingOperationResult(conflictRecord.recordID.recordName)
            }
            _ = try repairResult.get()
            return
        }

        if candidate.reference.kind == .folder,
           case .folder(let clientFolder)? = decodeRemoteRecord(clientRecord),
           case .folder(let serverFolder)? = decodeRemoteRecord(conflictRecord) {
            let mergedFolder = serverFolder.merged(with: clientFolder)
            if mergedFolder == serverFolder {
                try await applyDownloadedChanges([.folder(serverFolder)])
                needsAnotherPass = true
                return
            }
            try populateFolderRecord(conflictRecord, with: mergedFolder)
            let repair = try await database.modifyRecords(
                saving: [conflictRecord],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: true
            )
            guard let repairResult = repair.saveResults[conflictRecord.recordID] else {
                throw SyncError.missingOperationResult(conflictRecord.recordID.recordName)
            }
            _ = try repairResult.get()
            try await applyDownloadedChanges([.folder(mergedFolder)])
            needsAnotherPass = true
            return
        }

        if candidate.reference.kind == .document,
           scopedDocumentID == nil,
           case .document(let clientDocument, _)? = decodeRemoteRecord(clientRecord) {
            // CKError's conflict copy can omit a materialized CKAsset URL. Fetching the complete
            // record also gives the exact server change tag used by the merge repair.
            let fullServerRecord = try await database.record(for: conflictRecord.recordID)
            guard case .document(let serverDocument, let serverAssetURL)? = decodeRemoteRecord(
                fullServerRecord
            ) else {
                throw SyncError.malformedRecord(fullServerRecord.recordID.recordName)
            }
            let mergedDocument = serverDocument.mergedPrivateRecord(with: clientDocument)
            if mergedDocument == serverDocument {
                try await applyDownloadedChanges([
                    .document(serverDocument, pdfAssetURL: serverAssetURL)
                ])
                needsAnotherPass = true
                return
            }

            let clientProvidesContent = sameDocumentContent(mergedDocument, clientDocument)
            try populateDocumentRecord(
                fullServerRecord,
                with: mergedDocument,
                reference: mergedDocument.personalReference,
                assetFrom: clientProvidesContent ? clientRecord : fullServerRecord
            )
            let repair = try await database.modifyRecords(
                saving: [fullServerRecord],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: true
            )
            guard let repairResult = repair.saveResults[fullServerRecord.recordID] else {
                throw SyncError.missingOperationResult(fullServerRecord.recordID.recordName)
            }
            _ = try repairResult.get()
            // Metadata can be installed immediately. The next pass fetches the materialized asset
            // if the server side supplied the winning content.
            try await applyDownloadedChanges([
                .document(mergedDocument, pdfAssetURL: nil)
            ])
            needsAnotherPass = true
            return
        }

        if candidate.reference.kind == .documentReference,
           case .documentReference(let clientReference)? = decodeRemoteRecord(clientRecord),
           case .documentReference(let serverReference)? = decodeRemoteRecord(conflictRecord) {
            let mergedReference = serverReference.merged(with: clientReference)
            try await dataSource?.applyRemoteDocumentReferences([mergedReference])
            if mergedReference == serverReference {
                needsAnotherPass = true
                return
            }

            let payload = try encodedCollaboration(mergedReference)
            conflictRecord[Field.entityID] = mergedReference.documentID as CKRecordValue
            conflictRecord[Field.documentID] = mergedReference.documentID as CKRecordValue
            conflictRecord[Field.referencePayload] = payload as CKRecordValue
            conflictRecord[Field.modifiedAt] = ([
                mergedReference.parent.stamp.createdAt,
                mergedReference.favorite.stamp.createdAt,
                mergedReference.trash.stamp.createdAt
            ].max() ?? .distantPast) as CKRecordValue
            conflictRecord[Field.isDeleted] = NSNumber(value: false)
            let repair = try await database.modifyRecords(
                saving: [conflictRecord],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: true
            )
            guard let repairResult = repair.saveResults[conflictRecord.recordID] else {
                throw SyncError.missingOperationResult(conflictRecord.recordID.recordName)
            }
            _ = try repairResult.get()
            needsAnotherPass = true
            return
        }

        if candidate.reference.kind == .acknowledgement,
           case .acknowledgement(let clientAcknowledgement)? = decodeRemoteRecord(clientRecord),
           case .acknowledgement(let serverAcknowledgement)? = decodeRemoteRecord(conflictRecord) {
            let mergedAcknowledgement = serverAcknowledgement.merged(
                with: clientAcknowledgement
            )
            try await dataSource?.applyRemoteCollaborationAcknowledgements(
                [mergedAcknowledgement]
            )
            if mergedAcknowledgement == serverAcknowledgement {
                needsAnotherPass = true
                return
            }
            let payload = try encodedCollaboration(mergedAcknowledgement)
            conflictRecord[Field.entityID] = mergedAcknowledgement.participantID as CKRecordValue
            conflictRecord[Field.documentID] = mergedAcknowledgement.documentID as CKRecordValue
            conflictRecord[Field.participantID] = mergedAcknowledgement.participantID as CKRecordValue
            conflictRecord[Field.acknowledgementPayload] = payload as CKRecordValue
            conflictRecord[Field.modifiedAt] = mergedAcknowledgement.lastSeenAt as CKRecordValue
            conflictRecord[Field.isDeleted] = NSNumber(value: false)
            let repair = try await database.modifyRecords(
                saving: [conflictRecord],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: true
            )
            guard let repairResult = repair.saveResults[conflictRecord.recordID] else {
                throw SyncError.missingOperationResult(conflictRecord.recordID.recordName)
            }
            _ = try repairResult.get()
            needsAnotherPass = true
            return
        }

        let serverDate = date(in: conflictRecord, key: Field.modifiedAt)
            ?? conflictRecord.modificationDate
            ?? .distantPast
        if candidate.modifiedAt <= serverDate {
            // Conflict records omit asset file URLs, so fetch a materialized copy before applying.
            let fullServerRecord = try await database.record(for: conflictRecord.recordID)
            guard let change = decodeRemoteRecord(fullServerRecord) else {
                throw SyncError.malformedRecord(fullServerRecord.recordID.recordName)
            }
            try await applyDownloadedChanges([change])
            // Recompute the upload fingerprint from the just-installed server value. This also
            // prevents a stale pre-conflict candidate from hiding a newer local revision.
            needsAnotherPass = true
            return
        }

        // Preserve the server change tag, overlay newer local values, then retry once.
        overlayManagedFields(from: clientRecord, onto: conflictRecord)
        let retry = try await database.modifyRecords(
            saving: [conflictRecord],
            deleting: [],
            savePolicy: .ifServerRecordUnchanged,
            atomically: true
        )
        guard let result = retry.saveResults[conflictRecord.recordID] else {
            throw SyncError.missingOperationResult(conflictRecord.recordID.recordName)
        }
        _ = try result.get()
    }

    private func applyDownloadedChanges(_ changes: [DownloadedChange]) async throws {
        guard let dataSource else { throw SyncError.noDataSource }
        var snapshot = await dataSource.exportLibrarySnapshot()
        let changes = topologicallySorted(changes, baseSnapshot: snapshot)
        var metadataChanged = false
        var pageChangedDocumentIDs: Set<String> = []
        var downloadedDocumentReferences: [LibraryDocumentReference] = []
        var downloadedAcknowledgements: [CollaborationAcknowledgement] = []
        for change in changes {
            switch change {
            case .document(let document, _):
                pageChangedDocumentIDs.insert(document.id)
            case .page(let page, _, _, _):
                pageChangedDocumentIDs.insert(page.documentID)
            case .operation(let operation):
                pageChangedDocumentIDs.insert(operation.documentID)
            case .deletion(let tombstone) where tombstone.reference.kind == .page:
                let reference = tombstone.reference
                if let page = snapshot.pages.first(where: { $0.id == reference.entityID }) {
                    pageChangedDocumentIDs.insert(page.documentID)
                }
            default:
                break
            }
        }

        let causalTombstones = changes.compactMap { change -> LibraryEntityDeletionTombstone? in
            guard case .deletion(let tombstone) = change else { return nil }
            return tombstone
        }
        if !causalTombstones.isEmpty {
            try await dataSource.applyRemoteDeletionTombstones(causalTombstones)
            snapshot = await dataSource.exportLibrarySnapshot()
        }

        // Page tombstones must be installed while their document metadata still exists. A normal
        // document/subtree deletion carries both page and document tombstones in the same batch;
        // waiting until after applyRemoteSnapshot would make the Store unable to resolve the path.
        let existingDocumentIDs = Set(snapshot.documents.map(\.id))
        for case .deletion(let tombstone) in changes {
            let reference = tombstone.reference
            let deletedAt = tombstone.deletedAt
            switch reference.kind {
            case .page:
                guard let page = snapshot.pages.first(where: { $0.id == reference.entityID }),
                      existingDocumentIDs.contains(page.documentID) else { continue }
                try await removeStablePageAssetsIfNotNewer(
                    page: page,
                    deletedAt: deletedAt,
                    dataSource: dataSource
                )
            case .pageAnnotation:
                guard let page = parsePageEntityID(reference.entityID),
                      existingDocumentIDs.contains(page.documentID) else { continue }
                try await removePageAnnotationIfNotNewer(
                    documentID: page.documentID,
                    pageIndex: page.pageIndex,
                    deletedAt: deletedAt,
                    dataSource: dataSource
                )
            case .folder, .document, .documentReference, .operation, .acknowledgement:
                continue
            }
        }

        for change in changes {
            switch change {
            case .folder(let remote):
                if let index = snapshot.folders.firstIndex(where: { $0.id == remote.id }) {
                    let merged = snapshot.folders[index].merged(with: remote)
                    if merged != snapshot.folders[index] {
                        snapshot.folders[index] = merged
                        metadataChanged = true
                    }
                } else {
                    snapshot.folders.append(remote)
                    metadataChanged = true
                }
            case .document(let remote, _):
                if let index = snapshot.documents.firstIndex(where: { $0.id == remote.id }) {
                    if scopedDocumentID != nil {
                        let local = snapshot.documents[index]
                        if remote.contentModifiedAt >= local.contentModifiedAt {
                            var merged = remote
                            merged.parentID = local.parentID
                            merged.isFavorite = local.isFavorite
                            merged.trashedAt = local.trashedAt
                            merged.parentRevision = local.parentRevision
                            merged.favoriteRevision = local.favoriteRevision
                            merged.trashRevision = local.trashRevision
                            merged.modifiedAt = max(local.modifiedAt, remote.contentModifiedAt)
                            snapshot.documents[index] = merged
                            metadataChanged = true
                        }
                    } else {
                        let merged = snapshot.documents[index].mergedPrivateRecord(with: remote)
                        if merged != snapshot.documents[index] {
                            snapshot.documents[index] = merged
                            metadataChanged = true
                        }
                    }
                } else {
                    snapshot.documents.append(remote)
                    metadataChanged = true
                }
            case .documentReference(let reference):
                downloadedDocumentReferences.append(reference)
            case .acknowledgement(let acknowledgement):
                downloadedAcknowledgements.append(acknowledgement)
            case .page(let remote, _, _, _):
                guard snapshot.documents.contains(where: { $0.id == remote.documentID }) else {
                    continue
                }
                if let index = snapshot.pages.firstIndex(where: { $0.id == remote.id }) {
                    if remote.modifiedAt >= snapshot.pages[index].modifiedAt {
                        snapshot.pages[index] = remote
                        metadataChanged = true
                    }
                } else {
                    snapshot.pages.append(remote)
                    metadataChanged = true
                }
            case .operation:
                break
            case .deletion(let tombstone):
                let reference = tombstone.reference
                let deletedAt = tombstone.deletedAt
                switch reference.kind {
                case .folder:
                    if let local = snapshot.folders.first(where: { $0.id == reference.entityID }),
                       deletedAt >= local.modifiedAt {
                        let descendants = descendantFolderIDs(of: reference.entityID, in: snapshot.folders)
                            .union([reference.entityID])
                        snapshot.folders.removeAll { descendants.contains($0.id) }
                        snapshot.documents.removeAll { document in
                            document.parentID.map(descendants.contains) ?? false
                        }
                        let survivingDocumentIDs = Set(snapshot.documents.map(\.id))
                        snapshot.pages.removeAll { !survivingDocumentIDs.contains($0.documentID) }
                        metadataChanged = true
                    }
                case .document:
                    if let local = snapshot.documents.first(where: { $0.id == reference.entityID }),
                       deletedAt >= local.modifiedAt {
                        snapshot.documents.removeAll { $0.id == reference.entityID }
                        snapshot.pages.removeAll { $0.documentID == reference.entityID }
                        metadataChanged = true
                    }
                case .page:
                    if let local = snapshot.pages.first(where: { $0.id == reference.entityID }),
                       deletedAt >= local.modifiedAt {
                        snapshot.pages.removeAll { $0.id == reference.entityID }
                        metadataChanged = true
                    }
                case .pageAnnotation, .documentReference, .acknowledgement:
                    break
                case .operation:
                    // Immutable collaboration records are retained until acknowledged compaction.
                    break
                }
            case .pageAnnotation:
                break
            }
        }

        if metadataChanged {
            snapshot.generatedAt = Date()
            try await dataSource.applyRemoteSnapshot(snapshot)
            snapshot = await dataSource.exportLibrarySnapshot()
        }
        if !downloadedDocumentReferences.isEmpty {
            try await dataSource.applyRemoteDocumentReferences(downloadedDocumentReferences)
            snapshot = await dataSource.exportLibrarySnapshot()
        }
        if !downloadedAcknowledgements.isEmpty {
            try await dataSource.applyRemoteCollaborationAcknowledgements(
                downloadedAcknowledgements
            )
        }

        for change in changes {
            switch change {
            case .document(let document, let pdfURL):
                guard let current = snapshot.documents.first(where: { $0.id == document.id }),
                      current.contentModifiedAt <= document.contentModifiedAt,
                      !document.isBundled,
                      let pdfURL else { continue }
                try await dataSource.applyRemoteAsset(
                    from: pdfURL,
                    for: LibraryAssetReference(documentID: document.id, kind: .pdf)
                )
            case .page(let page, let backgroundURL, let drawingURL, let elementsURL):
                guard snapshot.documents.contains(where: { $0.id == page.documentID }),
                      snapshot.pages.contains(where: { $0.id == page.id }) else { continue }
                let drawingReference = LibraryAssetReference(
                    documentID: page.documentID,
                    kind: .pageDrawing(pageID: page.id)
                )
                let elementsReference = LibraryAssetReference(
                    documentID: page.documentID,
                    kind: .pageElements(pageID: page.id)
                )
                let backgroundReference = LibraryAssetReference(
                    documentID: page.documentID,
                    kind: .pageBackground(pageID: page.id)
                )
                let localModifiedAt = max(
                    fileModificationDate(await dataSource.assetURL(for: backgroundReference))
                        ?? .distantPast,
                    fileModificationDate(await dataSource.assetURL(for: drawingReference))
                        ?? .distantPast,
                    fileModificationDate(await dataSource.assetURL(for: elementsReference))
                        ?? .distantPast
                )
                guard localModifiedAt <= change.modifiedAt else { continue }
                try await installOrRemoveAsset(
                    sourceURL: backgroundURL,
                    reference: backgroundReference,
                    dataSource: dataSource
                )
                try await installOrRemoveAsset(
                    sourceURL: drawingURL,
                    reference: drawingReference,
                    dataSource: dataSource
                )
                try await installOrRemoveAsset(
                    sourceURL: elementsURL,
                    reference: elementsReference,
                    dataSource: dataSource
                )
            case .pageAnnotation(
                let documentID,
                let pageIndex,
                _,
                let drawingURL,
                let imagesURL
            ):
                // The same change set can contain a page update followed by deletion of its
                // document. Metadata has already been merged above, so an absent document means
                // the page assets are intentionally obsolete rather than a retryable Store error.
                guard snapshot.documents.contains(where: { $0.id == documentID }) else { continue }
                guard let stablePage = snapshot.pages
                    .filter({ $0.documentID == documentID })
                    .sorted(by: {
                        if $0.position != $1.position { return $0.position < $1.position }
                        return $0.id < $1.id
                    })
                    .dropFirst(pageIndex).first else { continue }
                let drawingReference = LibraryAssetReference(
                    documentID: documentID,
                    kind: .pageDrawing(pageID: stablePage.id)
                )
                let imagesReference = LibraryAssetReference(
                    documentID: documentID,
                    kind: .pageElements(pageID: stablePage.id)
                )
                let localModifiedAt = max(
                    fileModificationDate(await dataSource.assetURL(for: drawingReference))
                        ?? .distantPast,
                    fileModificationDate(await dataSource.assetURL(for: imagesReference))
                        ?? .distantPast
                )
                guard localModifiedAt <= change.modifiedAt else { continue }
                try await installOrRemoveAsset(
                    sourceURL: drawingURL,
                    reference: drawingReference,
                    dataSource: dataSource
                )
                try await installOrRemoveAsset(
                    sourceURL: imagesURL,
                    reference: imagesReference,
                    dataSource: dataSource
                )
            case .operation, .acknowledgement, .deletion, .folder, .documentReference:
                break
            }
        }

        let collaborationOperations = changes.compactMap { change -> CollaborationOperation? in
            guard case .operation(let operation) = change else { return nil }
            return operation
        }
        if !collaborationOperations.isEmpty {
            try await dataSource.applyRemoteCollaborationOperations(collaborationOperations)
        }
        if !pageChangedDocumentIDs.isEmpty {
            try await dataSource.finalizeRemotePageChanges(for: pageChangedDocumentIDs)
        }
    }

    private func removePageAnnotationIfNotNewer(
        documentID: String,
        pageIndex: Int,
        deletedAt: Date,
        dataSource: any CloudLibrarySyncDataSource
    ) async throws {
        let drawingReference = LibraryAssetReference(
            documentID: documentID,
            kind: .drawing(pageIndex: pageIndex)
        )
        let imagesReference = LibraryAssetReference(
            documentID: documentID,
            kind: .imageAnnotations(pageIndex: pageIndex)
        )
        let localModifiedAt = max(
            fileModificationDate(await dataSource.assetURL(for: drawingReference)) ?? .distantPast,
            fileModificationDate(await dataSource.assetURL(for: imagesReference)) ?? .distantPast
        )
        guard localModifiedAt <= deletedAt else { return }
        try await dataSource.removeRemoteAsset(for: drawingReference)
        try await dataSource.removeRemoteAsset(for: imagesReference)
    }

    private func removeStablePageAssetsIfNotNewer(
        page: LibraryPage,
        deletedAt: Date,
        dataSource: any CloudLibrarySyncDataSource
    ) async throws {
        let drawingReference = LibraryAssetReference(
            documentID: page.documentID,
            kind: .pageDrawing(pageID: page.id)
        )
        let elementsReference = LibraryAssetReference(
            documentID: page.documentID,
            kind: .pageElements(pageID: page.id)
        )
        let backgroundReference = LibraryAssetReference(
            documentID: page.documentID,
            kind: .pageBackground(pageID: page.id)
        )
        let localModifiedAt = max(
            fileModificationDate(await dataSource.assetURL(for: backgroundReference)) ?? .distantPast,
            fileModificationDate(await dataSource.assetURL(for: drawingReference)) ?? .distantPast,
            fileModificationDate(await dataSource.assetURL(for: elementsReference)) ?? .distantPast
        )
        guard localModifiedAt <= deletedAt else { return }
        try await dataSource.removeRemoteAsset(for: backgroundReference)
        try await dataSource.removeRemoteAsset(for: drawingReference)
        try await dataSource.removeRemoteAsset(for: elementsReference)
    }

    private func topologicallySorted(
        _ changes: [DownloadedChange],
        baseSnapshot: LibrarySnapshot
    ) -> [DownloadedChange] {
        var parentByFolderID = Dictionary(
            uniqueKeysWithValues: baseSnapshot.folders.map { ($0.id, $0.parentID) }
        )
        for case .folder(let folder) in changes {
            parentByFolderID[folder.id] = folder.parentID
        }

        func folderDepth(_ folderID: String) -> Int {
            var depth = 0
            var cursor: String? = folderID
            var visited: Set<String> = []
            while let current = cursor,
                  visited.insert(current).inserted,
                  let parent = parentByFolderID[current] ?? nil {
                depth += 1
                cursor = parent
            }
            return depth
        }

        func orderingKey(_ change: DownloadedChange) -> (phase: Int, depth: Int, id: String) {
            switch change {
            case .folder(let folder):
                return (0, folderDepth(folder.id), folder.id)
            case .documentReference(let reference):
                return (1, 0, reference.documentID)
            case .document(let document, _):
                return (2, 0, document.id)
            case .page(let page, _, _, _):
                return (3, 0, page.id)
            case .operation(let operation):
                return (4, 0, operation.id)
            case .acknowledgement(let acknowledgement):
                return (5, 0, acknowledgement.participantID)
            case .pageAnnotation(let documentID, let pageIndex, _, _, _):
                return (6, 0, "\(documentID)#\(pageIndex)")
            case .deletion(let tombstone):
                let reference = tombstone.reference
                switch reference.kind {
                case .operation:
                    return (7, 0, reference.entityID)
                case .acknowledgement:
                    return (8, 0, reference.entityID)
                case .page:
                    return (9, 0, reference.entityID)
                case .pageAnnotation:
                    return (10, 0, reference.entityID)
                case .documentReference:
                    return (11, 0, reference.entityID)
                case .document:
                    return (12, 0, reference.entityID)
                case .folder:
                    // Children are removed before parents. This is also safe when a remote store
                    // chooses not to cascade a folder tombstone locally.
                    return (13, -folderDepth(reference.entityID), reference.entityID)
                }
            }
        }

        return changes.sorted { lhs, rhs in
            let left = orderingKey(lhs)
            let right = orderingKey(rhs)
            if left.phase != right.phase { return left.phase < right.phase }
            if left.depth != right.depth { return left.depth < right.depth }
            return left.id < right.id
        }
    }

    private func installOrRemoveAsset(
        sourceURL: URL?,
        reference: LibraryAssetReference,
        dataSource: any CloudLibrarySyncDataSource
    ) async throws {
        if let sourceURL {
            try await dataSource.applyRemoteAsset(from: sourceURL, for: reference)
        } else {
            try await dataSource.removeRemoteAsset(for: reference)
        }
    }

    private func decodeRemoteRecord(_ record: CKRecord) -> DownloadedChange? {
        guard let kind = entityKind(forRecordType: record.recordType) else { return nil }
        let isDeleted = (record[Field.isDeleted] as? NSNumber)?.boolValue ?? false
        if isDeleted {
            let id = (record[Field.entityID] as? String)
                ?? reference(recordType: record.recordType, recordName: record.recordID.recordName)?.entityID
            guard let id else { return nil }
            let deletedAt = date(in: record, key: Field.deletedAt)
                ?? date(in: record, key: Field.modifiedAt)
                ?? record.modificationDate
                ?? Date()
            let reference = CloudLibraryEntityReference(kind: kind, entityID: id)
            if let payload = record[Field.deletionPayload] as? Data,
               let tombstone = try? JSONDecoder().decode(
                   LibraryEntityDeletionTombstone.self,
                   from: payload
               ),
               tombstone.reference == reference {
                return .deletion(tombstone)
            }
            let ownerDocumentID: String?
            if kind == .document {
                ownerDocumentID = id
            } else {
                ownerDocumentID = record[Field.documentID] as? String
            }
            return .deletion(
                .legacy(
                    reference: reference,
                    ownerDocumentID: ownerDocumentID,
                    deletedAt: deletedAt
                )
            )
        }

        guard let modifiedAt = date(in: record, key: Field.modifiedAt) ?? record.modificationDate else {
            return nil
        }
        switch kind {
        case .folder:
            guard
                let id = record[Field.entityID] as? String,
                let title = record[Field.title] as? String
            else { return nil }
            if let payload = record[Field.folderPayload] as? Data,
               let folder = try? JSONDecoder().decode(LibraryFolder.self, from: payload),
               folder.id == id {
                return .folder(folder)
            }
            return .folder(
                LibraryFolder(
                    id: id,
                    title: title,
                    parentID: record[Field.parentID] as? String,
                    createdAt: date(in: record, key: Field.createdAt) ?? modifiedAt,
                    modifiedAt: modifiedAt,
                    color: (record[Field.folderColor] as? String)
                        .flatMap(LibraryFolderColor.init(rawValue:)) ?? .blue,
                    icon: (record[Field.folderIcon] as? String)
                        .flatMap(LibraryFolderIcon.init(rawValue:)) ?? .folder,
                    isFavorite: (record[Field.isFavorite] as? NSNumber)?.boolValue ?? false,
                    trashedAt: date(in: record, key: Field.trashedAt)
                )
            )
        case .document:
            guard
                let id = record[Field.entityID] as? String,
                let title = record[Field.title] as? String,
                let fileName = record[Field.fileName] as? String
            else { return nil }
            let isBundled = (record[Field.isBundled] as? NSNumber)?.boolValue ?? false
            let assetURL = (record[Field.pdfAsset] as? CKAsset)?.fileURL
            guard isBundled || assetURL != nil else { return nil }
            var metadata = LibraryDocumentMetadata(
                id: id,
                title: title,
                parentID: record[Field.parentID] as? String,
                fileName: fileName,
                isBundled: isBundled,
                createdAt: date(in: record, key: Field.createdAt) ?? modifiedAt,
                modifiedAt: modifiedAt,
                contentModifiedAt: date(in: record, key: Field.contentModifiedAt) ?? modifiedAt,
                kind: (record[Field.documentKind] as? String)
                    .flatMap(LibraryDocumentKind.init(rawValue:)) ?? .pdf,
                canvasBackgroundStyle: (record[Field.backgroundStyle] as? String)
                    .flatMap(CanvasBackgroundStyle.init(rawValue:)),
                canvasBackgroundColor: (record[Field.backgroundColor] as? String)
                    .flatMap(CanvasBackgroundColor.init(rawValue:)),
                isFavorite: (record[Field.isFavorite] as? NSNumber)?.boolValue ?? false,
                trashedAt: date(in: record, key: Field.trashedAt)
            )
            if let payload = record[Field.referencePayload] as? Data,
               let personalReference = try? JSONDecoder().decode(
                   LibraryDocumentReference.self,
                   from: payload
               ),
               personalReference.documentID == id {
                metadata = metadata.applyingPersonalReference(personalReference)
            }
            return .document(metadata, pdfAssetURL: assetURL)
        case .documentReference:
            guard
                let id = record[Field.entityID] as? String,
                let data = record[Field.referencePayload] as? Data,
                let reference = try? JSONDecoder().decode(
                    LibraryDocumentReference.self,
                    from: data
                ),
                reference.documentID == id
            else { return nil }
            return .documentReference(reference)
        case .page:
            guard
                let id = record[Field.entityID] as? String,
                let documentID = record[Field.documentID] as? String,
                let orderIndex = integer(in: record, key: Field.orderIndex),
                let width = (record[Field.pageWidth] as? NSNumber)?.doubleValue,
                let height = (record[Field.pageHeight] as? NSNumber)?.doubleValue
            else { return nil }
            return .page(
                LibraryPage(
                    id: id,
                    documentID: documentID,
                    orderIndex: orderIndex,
                    position: collaborationPosition(in: record, fallbackOrderIndex: orderIndex),
                    createdAt: date(in: record, key: Field.createdAt) ?? modifiedAt,
                    modifiedAt: modifiedAt,
                    width: width,
                    height: height,
                    rotation: integer(in: record, key: Field.pageRotation) ?? 0,
                    sourceKind: (record[Field.pageSourceKind] as? String)
                        .flatMap(LibraryPageSourceKind.init(rawValue:)) ?? .pdf,
                    backgroundStyle: (record[Field.backgroundStyle] as? String)
                        .flatMap(CanvasBackgroundStyle.init(rawValue:)),
                    backgroundColor: (record[Field.backgroundColor] as? String)
                        .flatMap(CanvasBackgroundColor.init(rawValue:)),
                    isBookmarked: (record[Field.isBookmarked] as? NSNumber)?.boolValue ?? false
                ),
                backgroundAssetURL: (record[Field.pageBackgroundAsset] as? CKAsset)?.fileURL,
                drawingAssetURL: (record[Field.drawingAsset] as? CKAsset)?.fileURL,
                elementsAssetURL: (record[Field.elementsAsset] as? CKAsset)?.fileURL
            )
        case .operation:
            guard
                let id = record[Field.entityID] as? String,
                let workspaceID = record[Field.workspaceID] as? String,
                let documentID = record[Field.documentID] as? String,
                let pageID = record[Field.pageID] as? String,
                let stampData = record[Field.operationStamp] as? Data,
                let payloadData = record[Field.operationPayload] as? Data,
                let stamp = try? JSONDecoder().decode(CollaborationStamp.self, from: stampData),
                let payload = try? JSONDecoder().decode(
                    CollaborationOperationPayload.self,
                    from: payloadData
                ),
                stamp.operationID == id
            else { return nil }
            return .operation(
                CollaborationOperation(
                    workspaceID: workspaceID,
                    documentID: documentID,
                    pageID: pageID,
                    stamp: stamp,
                    payload: payload
                )
            )
        case .acknowledgement:
            guard
                let id = record[Field.entityID] as? String,
                let documentID = record[Field.documentID] as? String,
                let participantID = record[Field.participantID] as? String,
                let payload = record[Field.acknowledgementPayload] as? Data,
                let acknowledgement = try? JSONDecoder().decode(
                    CollaborationAcknowledgement.self,
                    from: payload
                ),
                id == participantID,
                acknowledgement.documentID == documentID,
                acknowledgement.participantID == participantID
            else { return nil }
            return .acknowledgement(acknowledgement)
        case .pageAnnotation:
            guard
                let documentID = record[Field.documentID] as? String,
                let pageIndex = integer(in: record, key: Field.pageIndex)
            else { return nil }
            return .pageAnnotation(
                documentID: documentID,
                pageIndex: pageIndex,
                modifiedAt: modifiedAt,
                drawingAssetURL: (record[Field.drawingAsset] as? CKAsset)?.fileURL,
                imagesAssetURL: (record[Field.imagesAsset] as? CKAsset)?.fileURL
            )
        }
    }

    private func updateManifestForDownloadedChanges(_ changes: [DownloadedChange]) async throws {
        var manifest = loadUploadManifest()
        for change in changes {
            let reference = change.reference
            let fingerprint: String
            let isTombstone: Bool
            switch change {
            case .folder(let folder):
                fingerprint = metadataFingerprint(prefix: "folder", modifiedAt: folder.modifiedAt)
                isTombstone = false
            case .document(let document, _):
                fingerprint = metadataFingerprint(prefix: "document", modifiedAt: document.modifiedAt)
                isTombstone = false
            case .documentReference(let referenceValue):
                let payload = try encodedCollaboration(referenceValue)
                fingerprint = payloadFingerprint(prefix: "document-reference", data: payload)
                isTombstone = false
            case .page(let page, let backgroundURL, let drawingURL, let elementsURL):
                fingerprint = pageFingerprint(
                    page: page,
                    modifiedAt: change.modifiedAt,
                    backgroundURL: backgroundURL,
                    drawingURL: drawingURL,
                    elementsURL: elementsURL
                )
                isTombstone = false
            case .operation(let operation):
                let stampData = try encodedCollaboration(operation.stamp)
                let payloadData = try encodedCollaboration(operation.payload)
                fingerprint = collaborationOperationFingerprint(
                    operation: operation,
                    stampData: stampData,
                    payloadData: payloadData
                )
                isTombstone = false
            case .acknowledgement(let acknowledgement):
                let payload = try encodedCollaboration(acknowledgement)
                fingerprint = payloadFingerprint(prefix: "acknowledgement", data: payload)
                isTombstone = false
            case .pageAnnotation(_, _, let modifiedAt, let drawingURL, let imagesURL):
                fingerprint = annotationFingerprint(
                    modifiedAt: modifiedAt,
                    drawingURL: drawingURL,
                    imagesURL: imagesURL
                )
                isTombstone = false
            case .deletion(let tombstone):
                fingerprint = payloadFingerprint(
                    prefix: "tombstone",
                    data: try encodedCollaboration(tombstone)
                )
                isTombstone = true
            }
            manifest.entriesByKey[manifestKey(reference)] = ManifestEntry(
                reference: reference,
                fingerprint: fingerprint,
                isTombstone: isTombstone,
                modifiedAt: change.modifiedAt,
                ownerDocumentID: {
                    if case .operation(let operation) = change {
                        return operation.documentID
                    }
                    return nil
                }()
            )
        }
        try saveUploadManifest(manifest)
    }

    private func makeBaseRecord(
        reference: CloudLibraryEntityReference,
        modifiedAt: Date
    ) -> CKRecord {
        let record = CKRecord(
            recordType: recordType(for: reference.kind),
            recordID: recordID(for: reference)
        )
        record[Field.entityID] = reference.entityID as CKRecordValue
        record[Field.modifiedAt] = modifiedAt as CKRecordValue
        record[Field.isDeleted] = NSNumber(value: false)
        return record
    }

    private func populateFolderRecord(_ record: CKRecord, with folder: LibraryFolder) throws {
        record[Field.entityID] = folder.id as CKRecordValue
        record[Field.title] = folder.title as CKRecordValue
        record[Field.parentID] = folder.parentID as CKRecordValue?
        record[Field.createdAt] = folder.createdAt as CKRecordValue
        record[Field.modifiedAt] = folder.modifiedAt as CKRecordValue
        record[Field.folderColor] = folder.color.rawValue as CKRecordValue
        record[Field.folderIcon] = folder.icon.rawValue as CKRecordValue
        record[Field.isFavorite] = NSNumber(value: folder.isFavorite)
        record[Field.trashedAt] = folder.trashedAt as CKRecordValue?
        record[Field.folderPayload] = try encodedCollaboration(folder) as CKRecordValue
        record[Field.deletedAt] = nil
        record[Field.deletionPayload] = nil
        record[Field.isDeleted] = NSNumber(value: false)
    }

    private func populateDeletionRecord(
        _ record: CKRecord,
        with tombstone: LibraryEntityDeletionTombstone
    ) throws {
        record[Field.entityID] = tombstone.reference.entityID as CKRecordValue
        record[Field.modifiedAt] = tombstone.deletedAt as CKRecordValue
        record[Field.deletedAt] = tombstone.deletedAt as CKRecordValue
        record[Field.isDeleted] = NSNumber(value: true)
        record[Field.deletionPayload] = try encodedCollaboration(tombstone) as CKRecordValue
        if let ownerDocumentID = tombstone.ownerDocumentID {
            record[Field.documentID] = ownerDocumentID as CKRecordValue
        }
    }

    private func populateDocumentRecord(
        _ record: CKRecord,
        with document: LibraryDocumentMetadata,
        reference: LibraryDocumentReference?,
        assetFrom sourceRecord: CKRecord
    ) throws {
        record[Field.entityID] = document.id as CKRecordValue
        record[Field.title] = document.title as CKRecordValue
        record[Field.parentID] = document.parentID as CKRecordValue?
        record[Field.fileName] = document.fileName as CKRecordValue
        record[Field.isBundled] = NSNumber(value: document.isBundled)
        record[Field.createdAt] = document.createdAt as CKRecordValue
        record[Field.modifiedAt] = document.modifiedAt as CKRecordValue
        record[Field.contentModifiedAt] = document.contentModifiedAt as CKRecordValue
        record[Field.documentKind] = document.kind.rawValue as CKRecordValue
        record[Field.backgroundStyle] = document.canvasBackgroundStyle?.rawValue as CKRecordValue?
        record[Field.backgroundColor] = document.canvasBackgroundColor?.rawValue as CKRecordValue?
        record[Field.isFavorite] = NSNumber(value: document.isFavorite)
        record[Field.trashedAt] = document.trashedAt as CKRecordValue?
        record[Field.referencePayload] = try reference.map(encodedCollaboration) as CKRecordValue?
        record[Field.pdfAsset] = document.isBundled ? nil : sourceRecord[Field.pdfAsset]
        record[Field.deletedAt] = nil
        record[Field.deletionPayload] = nil
        record[Field.isDeleted] = NSNumber(value: false)
    }

    private func sameDocumentContent(
        _ lhs: LibraryDocumentMetadata,
        _ rhs: LibraryDocumentMetadata
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.fileName == rhs.fileName
            && lhs.isBundled == rhs.isBundled
            && lhs.createdAt == rhs.createdAt
            && lhs.contentModifiedAt == rhs.contentModifiedAt
            && lhs.kind == rhs.kind
            && lhs.canvasBackgroundStyle == rhs.canvasBackgroundStyle
            && lhs.canvasBackgroundColor == rhs.canvasBackgroundColor
    }

    private func overlayManagedFields(from client: CKRecord, onto server: CKRecord) {
        for key in managedFields(forRecordType: client.recordType) {
            server[key] = client[key]
        }
    }

    private func managedFields(forRecordType type: String) -> [String] {
        let common = [
            Field.entityID,
            Field.modifiedAt,
            Field.deletedAt,
            Field.isDeleted,
            Field.deletionPayload
        ]
        switch type {
        case RecordType.folder:
            return common + [
                Field.title, Field.parentID, Field.createdAt, Field.folderColor,
                Field.folderIcon, Field.isFavorite, Field.trashedAt, Field.folderPayload
            ]
        case RecordType.document:
            return common + [
                Field.title, Field.parentID, Field.fileName, Field.isBundled,
                Field.createdAt, Field.contentModifiedAt, Field.documentKind,
                Field.backgroundStyle, Field.backgroundColor, Field.isFavorite,
                Field.trashedAt, Field.referencePayload, Field.pdfAsset
            ]
        case RecordType.documentReference:
            return common + [Field.documentID, Field.referencePayload]
        case RecordType.page:
            return common + [
                Field.documentID, Field.orderIndex, Field.pagePosition, Field.createdAt,
                Field.pageWidth, Field.pageHeight, Field.pageRotation,
                Field.pageSourceKind, Field.backgroundStyle, Field.backgroundColor,
                Field.isBookmarked, Field.pageBackgroundAsset,
                Field.drawingAsset, Field.elementsAsset
            ]
        case RecordType.operation:
            return common + [
                Field.workspaceID, Field.documentID, Field.pageID,
                Field.operationStamp, Field.operationPayload
            ]
        case RecordType.acknowledgement:
            return common + [
                Field.documentID, Field.participantID, Field.acknowledgementPayload
            ]
        case RecordType.pageAnnotation:
            return common + [
                Field.documentID, Field.pageIndex, Field.drawingAsset, Field.imagesAsset
            ]
        default:
            return common
        }
    }

    private func uploadRank(_ kind: CloudLibraryEntityKind) -> Int {
        switch kind {
        case .folder: 0
        case .documentReference: 1
        case .document: 2
        case .page: 3
        case .operation: 4
        case .acknowledgement: 5
        case .pageAnnotation: 6
        }
    }

    private func descendantFolderIDs(
        of folderID: String,
        in folders: [LibraryFolder]
    ) -> Set<String> {
        var result: Set<String> = []
        var pending = [folderID]
        while let parent = pending.popLast() {
            for child in folders where child.parentID == parent && result.insert(child.id).inserted {
                pending.append(child.id)
            }
        }
        return result
    }

    private func recordID(for reference: CloudLibraryEntityReference) -> CKRecord.ID {
        let name: String
        switch reference.kind {
        case .folder:
            name = "folder.\(encodeRecordNameComponent(reference.entityID))"
        case .document:
            name = "document.\(encodeRecordNameComponent(reference.entityID))"
        case .documentReference:
            name = "document-reference.\(encodeRecordNameComponent(reference.entityID))"
        case .page:
            name = "page.\(encodeRecordNameComponent(reference.entityID))"
        case .operation:
            name = "operation.\(encodeRecordNameComponent(reference.entityID))"
        case .acknowledgement:
            name = "acknowledgement.\(encodeRecordNameComponent(reference.entityID))"
        case .pageAnnotation:
            if let page = parsePageEntityID(reference.entityID) {
                name = "annotation.\(encodeRecordNameComponent(page.documentID)).\(page.pageIndex)"
            } else {
                name = "annotation.\(encodeRecordNameComponent(reference.entityID))"
            }
        }
        return CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    private func reference(recordType: String, recordName: String) -> CloudLibraryEntityReference? {
        guard let kind = entityKind(forRecordType: recordType) else { return nil }
        let parts = recordName.split(separator: ".", omittingEmptySubsequences: false)
        switch kind {
        case .folder, .document, .documentReference, .page, .operation, .acknowledgement:
            guard parts.count == 2,
                  let id = decodeRecordNameComponent(String(parts[1])) else { return nil }
            return CloudLibraryEntityReference(kind: kind, entityID: id)
        case .pageAnnotation:
            guard parts.count == 3,
                  let documentID = decodeRecordNameComponent(String(parts[1])),
                  let pageIndex = Int(parts[2]) else { return nil }
            return CloudLibraryEntityReference(
                kind: .pageAnnotation,
                entityID: "\(documentID)#\(pageIndex)"
            )
        }
    }

    private func recordType(for kind: CloudLibraryEntityKind) -> String {
        switch kind {
        case .folder: RecordType.folder
        case .document: RecordType.document
        case .documentReference: RecordType.documentReference
        case .page: RecordType.page
        case .operation: RecordType.operation
        case .acknowledgement: RecordType.acknowledgement
        case .pageAnnotation: RecordType.pageAnnotation
        }
    }

    private func entityKind(forRecordType type: String) -> CloudLibraryEntityKind? {
        switch type {
        case RecordType.folder: .folder
        case RecordType.document: .document
        case RecordType.documentReference: .documentReference
        case RecordType.page: .page
        case RecordType.operation: .operation
        case RecordType.acknowledgement: .acknowledgement
        case RecordType.pageAnnotation: .pageAnnotation
        default: nil
        }
    }

    private func parsePageEntityID(_ value: String) -> (documentID: String, pageIndex: Int)? {
        guard let separator = value.lastIndex(of: "#"),
              let pageIndex = Int(value[value.index(after: separator)...]) else { return nil }
        return (String(value[..<separator]), pageIndex)
    }

    private func encodeRecordNameComponent(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func decodeRecordNameComponent(_ value: String) -> String? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func manifestKey(_ reference: CloudLibraryEntityReference) -> String {
        "\(reference.kind.rawValue)|\(encodeRecordNameComponent(reference.entityID))"
    }

    private func metadataFingerprint(prefix: String, modifiedAt: Date) -> String {
        "\(prefix)|\(dateFingerprint(modifiedAt))"
    }

    private func payloadFingerprint(prefix: String, data: Data) -> String {
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(prefix)|\(digest)"
    }

    private func annotationFingerprint(
        modifiedAt: Date,
        drawingURL: URL?,
        imagesURL: URL?
    ) -> String {
        "annotation|\(dateFingerprint(modifiedAt))|\(fileFingerprint(drawingURL))|\(fileFingerprint(imagesURL))"
    }

    private func pageFingerprint(
        page: LibraryPage,
        modifiedAt: Date,
        backgroundURL: URL?,
        drawingURL: URL?,
        elementsURL: URL?
    ) -> String {
        [
            "page",
            dateFingerprint(modifiedAt),
            String(page.orderIndex),
            positionFingerprint(page.position),
            String(format: "%.3f", page.width),
            String(format: "%.3f", page.height),
            String(page.rotation),
            page.sourceKind.rawValue,
            page.backgroundStyle?.rawValue ?? "none",
            page.backgroundColor?.rawValue ?? "none",
            page.isBookmarked ? "1" : "0",
            fileFingerprint(backgroundURL),
            fileFingerprint(drawingURL),
            fileFingerprint(elementsURL)
        ].joined(separator: "|")
    }

    private func collaborationOperationFingerprint(
        operation: CollaborationOperation,
        stampData: Data,
        payloadData: Data
    ) -> String {
        var digestInput = Data(operation.id.utf8)
        digestInput.append(stampData)
        digestInput.append(payloadData)
        let digest = SHA256.hash(data: digestInput)
            .map { String(format: "%02x", $0) }
            .joined()
        return "operation|\(digest)"
    }

    private func fileFingerprint(_ url: URL?) -> String {
        guard let url,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return "none" }
        return "\(values.fileSize ?? -1):\(dateFingerprint(values.contentModificationDate ?? .distantPast))"
    }

    private func fileModificationDate(_ url: URL?) -> Date? {
        guard let url else { return nil }
        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func dateFingerprint(_ date: Date) -> String {
        String(format: "%.6f", date.timeIntervalSinceReferenceDate)
    }

    private func requireReadableFile(at url: URL) throws {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else {
            throw SyncError.missingAsset(url)
        }
    }

    private func date(in record: CKRecord, key: String) -> Date? {
        record[key] as? Date
    }

    private func collaborationPosition(
        in record: CKRecord,
        fallbackOrderIndex: Int
    ) -> CollaborativePosition {
        guard let data = record[Field.pagePosition] as? Data,
              let position = try? JSONDecoder().decode(CollaborativePosition.self, from: data)
        else { return .legacy(orderIndex: fallbackOrderIndex) }
        return position
    }

    private func encodedCollaboration<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func positionFingerprint(_ position: CollaborativePosition) -> String {
        position.components.map { component in
            "\(component.digit):\(encodeRecordNameComponent(component.actorID)):\(component.sequence)"
        }.joined(separator: ",")
    }

    private func integer(in record: CKRecord, key: String) -> Int? {
        (record[key] as? NSNumber)?.intValue
    }

    private func loadChangeToken() -> CKServerChangeToken? {
        guard let data = tokenStore.data(forKey: changeTokenKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: CKServerChangeToken.self,
            from: data
        )
    }

    private func saveChangeToken(_ token: CKServerChangeToken) throws {
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: token,
            requiringSecureCoding: true
        )
        tokenStore.set(data, forKey: changeTokenKey)
    }

    private func clearChangeToken() {
        tokenStore.removeObject(forKey: changeTokenKey)
    }

    private func loadUploadManifest() -> UploadManifest {
        guard let data = tokenStore.data(forKey: uploadManifestKey),
              let manifest = try? JSONDecoder().decode(UploadManifest.self, from: data)
        else { return UploadManifest() }
        return manifest
    }

    private func saveUploadManifest(_ manifest: UploadManifest) throws {
        tokenStore.set(try JSONEncoder().encode(manifest), forKey: uploadManifestKey)
    }

    private func clearUploadManifest() {
        tokenStore.removeObject(forKey: uploadManifestKey)
    }

    private func reportStatus(_ status: CloudLibrarySyncStatus) async {
        guard reportsStatus, let dataSource else { return }
        await dataSource.cloudSyncDidUpdateStatus(status)
    }

    private func reportFailure(_ error: Error) async {
        if let syncError = error as? SyncError, case .accountUnavailable = syncError {
            await reportStatus(.waitingForAccount)
        } else if isNetworkError(error) {
            await reportStatus(.waitingForNetwork)
        } else {
            await reportStatus(.failed(error.localizedDescription))
        }
    }

    private func isNetworkError(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }
        switch error.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .zoneBusy:
            return true
        default:
            return false
        }
    }

    private func retryDelayIfTransient(_ error: Error) -> TimeInterval? {
        guard let error = error as? CKError else { return nil }
        let suggested = (error.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue
        let httpStatus = (error.userInfo["CKHTTPStatus"] as? NSNumber)?.intValue
        switch error.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .zoneBusy,
             .requestRateLimited:
            return max(suggested ?? 15, 2)
        case .serverRejectedRequest where httpStatus.map({ $0 >= 500 }) == true:
            // A newly provisioned container can briefly surface Apple backend failures as
            // serverRejectedRequest instead of serviceUnavailable. Retry only 5xx responses;
            // schema/permission rejections remain terminal and visible to the user.
            return max(suggested ?? 15, 2)
        default:
            return nil
        }
    }

    private func scheduleRetry(after delay: TimeInterval) {
        scheduledTask?.cancel()
        let nanoseconds = UInt64(max(delay, 2) * 1_000_000_000)
        scheduledTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.synchronizeReportingErrors()
        }
    }
}

struct CloudDocumentSharePreparation {
    let documentID: String
    let share: CKShare
    let container: CKContainer
    let zoneID: CKRecordZone.ID
    let syncCoordinator: CloudLibrarySyncCoordinator
}

enum CloudDocumentAccessLevel: String, Hashable, Sendable {
    case owner
    case readWrite
    case readOnly

    var canEdit: Bool { self != .readOnly }
    var canManageParticipants: Bool { self == .owner }
}

struct CloudDocumentSharedZone: Hashable {
    let documentID: String
    let zoneID: CKRecordZone.ID
    let databaseScope: CKDatabase.Scope
    let accessLevel: CloudDocumentAccessLevel

    var key: String {
        "\(databaseScope.rawValue)|\(zoneID.ownerName)|\(zoneID.zoneName)"
    }
}

enum CloudDocumentShareService {
    static func prepareShare(
        documentID: String,
        title: String,
        dataSource: any CloudLibrarySyncDataSource
    ) async throws -> CloudDocumentSharePreparation {
        let container = CKContainer(identifier: CloudLibrarySyncCoordinator.containerIdentifier)
        let zoneName = CloudLibrarySyncCoordinator.documentShareZoneName(for: documentID)
        let zoneID = CKRecordZone.ID(
            zoneName: zoneName,
            ownerName: CKCurrentUserDefaultName
        )
        let coordinator = CloudLibrarySyncCoordinator(
            dataSource: dataSource,
            zoneName: zoneName,
            databaseScope: .private,
            scopedDocumentID: documentID,
            shouldCreateZone: true,
            reportsStatus: false
        )
        // Populate the document-specific zone before exposing its invitation URL.
        try await coordinator.syncNowOrThrow()

        let database = container.privateCloudDatabase
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        let share: CKShare
        do {
            guard let existing = try await database.record(for: shareID) as? CKShare else {
                throw CKError(.unknownItem)
            }
            share = existing
        } catch let error as CKError where error.code == .unknownItem {
            let newShare = CKShare(recordZoneID: zoneID)
            newShare[CKShare.SystemFieldKey.title] = title as CKRecordValue
            newShare.publicPermission = .none
            let result = try await database.modifyRecords(
                saving: [newShare],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: true
            )
            guard let saveResult = result.saveResults[newShare.recordID] else {
                throw CKError(.internalError)
            }
            guard let saved = try saveResult.get() as? CKShare else {
                throw CKError(.internalError)
            }
            share = saved
        }
        return CloudDocumentSharePreparation(
            documentID: documentID,
            share: share,
            container: container,
            zoneID: zoneID,
            syncCoordinator: coordinator
        )
    }

    static func loadExistingShare(
        zone: CloudDocumentSharedZone,
        dataSource: any CloudLibrarySyncDataSource
    ) async throws -> CloudDocumentSharePreparation {
        let container = CKContainer(identifier: CloudLibrarySyncCoordinator.containerIdentifier)
        let database = container.database(with: zone.databaseScope)
        let shareID = CKRecord.ID(
            recordName: CKRecordNameZoneWideShare,
            zoneID: zone.zoneID
        )
        guard let share = try await database.record(for: shareID) as? CKShare else {
            throw CKError(.unknownItem)
        }
        let coordinator = CloudLibrarySyncCoordinator(
            dataSource: dataSource,
            zoneName: zone.zoneID.zoneName,
            ownerName: zone.zoneID.ownerName,
            databaseScope: zone.databaseScope,
            scopedDocumentID: zone.documentID,
            shouldCreateZone: false,
            reportsStatus: false,
            allowsUploads: zone.accessLevel.canEdit
        )
        return CloudDocumentSharePreparation(
            documentID: zone.documentID,
            share: share,
            container: container,
            zoneID: zone.zoneID,
            syncCoordinator: coordinator
        )
    }

    static func discoverSharedZones() async throws -> [CloudDocumentSharedZone] {
        let container = CKContainer(identifier: CloudLibrarySyncCoordinator.containerIdentifier)
        async let privateZones = container.privateCloudDatabase.allRecordZones()
        async let participantZones = container.sharedCloudDatabase.allRecordZones()
        let zoneGroups = try await [
            (CKDatabase.Scope.private, privateZones),
            (CKDatabase.Scope.shared, participantZones)
        ]
        var discovered: [CloudDocumentSharedZone] = []
        for (scope, zones) in zoneGroups {
            let database = container.database(with: scope)
            for zone in zones {
                guard let documentID = CloudLibrarySyncCoordinator.documentID(
                    fromShareZoneName: zone.zoneID.zoneName
                ) else { continue }

                let shareID = CKRecord.ID(
                    recordName: CKRecordNameZoneWideShare,
                    zoneID: zone.zoneID
                )
                guard let shareRecord = try? await database.record(for: shareID),
                      let share = shareRecord as? CKShare else {
                    // A cancelled, revoked, or partially accepted share is not mounted.
                    continue
                }
                let accessLevel: CloudDocumentAccessLevel
                if scope == .private {
                    accessLevel = .owner
                } else {
                    accessLevel = share.currentUserParticipant?.permission == .readWrite
                        ? .readWrite
                        : .readOnly
                }
                discovered.append(CloudDocumentSharedZone(
                    documentID: documentID,
                    zoneID: zone.zoneID,
                    databaseScope: scope,
                    accessLevel: accessLevel
                ))
            }
        }
        return discovered
    }

    static func accept(_ metadata: CKShare.Metadata) async throws {
        let container = CKContainer(identifier: metadata.containerIdentifier)
        let result = try await container.accept([metadata])
        guard let accepted = result[metadata] else { throw CKError(.internalError) }
        _ = try accepted.get()
    }
}

/// DrawingDocumentStore already exposes the five snapshot/asset operations required above.
extension DrawingDocumentStore: CloudLibrarySyncDataSource {}
