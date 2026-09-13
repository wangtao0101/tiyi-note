import CloudKit
import CryptoKit
import Foundation

/// Private-library v2 transport. Change tokens fetch small headers only; immutable PDFs are fetched
/// on demand, covers separately. Upload work comes directly from SQLite's durable outbox.
actor SparseCloudLibrarySync {
    static let recordType = "TiyiLibraryEntryV2"
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let store: DrawingDocumentStore
    private var ready = false
    private let tokenKey: String
    private var accountID: String?
    private let shouldCreateZone: Bool
    private let isFamilyLibrary: Bool

    init(database: CKDatabase, zoneID: CKRecordZone.ID, store: DrawingDocumentStore,
         shouldCreateZone: Bool = true, isFamilyLibrary: Bool = false) {
        self.database = database; self.zoneID = zoneID; self.store = store
        self.shouldCreateZone = shouldCreateZone; self.isFamilyLibrary = isFamilyLibrary
        tokenKey = isFamilyLibrary
            ? "sparse-zone-token|\(database.databaseScope.rawValue)|\(zoneID.ownerName)|\(zoneID.zoneName)"
            : "sparse-zone-token|\(zoneID.ownerName)|\(zoneID.zoneName)"
    }

    func sync(allowsUploads: Bool = true) async throws {
        try Task.checkCancellation()
        let container = CKContainer(identifier: CloudLibrarySyncCoordinator.containerIdentifier)
        let currentAccount = try await container.userRecordID().recordName
        if let storedAccount = try await store.sparseSyncState("icloud-owner"),
           String(data: storedAccount, encoding: .utf8) != currentAccount {
            throw NSError(domain: "TiyiSync", code: 1, userInfo: [NSLocalizedDescriptionKey: "当前 iCloud 账户与本地资料库所属账户不同"])
        }
        try await store.setSparseSyncState("icloud-owner", Data(currentAccount.utf8))
        accountID = currentAccount
        if isFamilyLibrary, database.databaseScope == .shared {
            do {
                let record = try await database.record(for: CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID))
                guard let share = record as? CKShare,
                      database.databaseScope == .private || (share.currentUserParticipant?.acceptanceStatus == .accepted
                        && share.currentUserParticipant?.permission == .readWrite) else {
                    throw CKError(.permissionFailure)
                }
            } catch let error as CKError where [.permissionFailure, .unknownItem, .zoneNotFound, .userDeletedZone].contains(error.code) {
                await store.setLibraryWriteAllowed(false)
                throw error
            }
        }
        if !ready {
            if shouldCreateZone { _ = try await database.save(CKRecordZone(zoneID: zoneID)) }
            let subscription: CKSubscription = database.databaseScope == .shared
                ? CKDatabaseSubscription(subscriptionID: "tiyi-family-shared-database")
                : CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: "sparse|\(zoneID.zoneName)")
            let info = CKSubscription.NotificationInfo(); info.shouldSendContentAvailable = true
            subscription.notificationInfo = info
            _ = try? await database.save(subscription)
            ready = true
        }
        try await downloadHeaders()
        if allowsUploads { try await uploadOutbox() }
        try await downloadRequestedAssets()
    }

    private static let headerKeys = ["kind", "entityID", "documentID", "pageID", "payload", "digest", "hasFile", "payloadSize"]

    static func recordName(kind: String, id: String) -> String {
        kind + "." + Data(id.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
    }

    private func downloadHeaders() async throws {
        var token: CKServerChangeToken?
        if let bytes = try await store.sparseSyncState(tokenKey), !bytes.isEmpty {
            token = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: bytes)
        }
        var didReset = false
        while true {
            try Task.checkCancellation()
            do {
                let result = try await database.recordZoneChanges(inZoneWith: zoneID, since: token,
                    desiredKeys: Self.headerKeys, resultsLimit: 100)
                var entries: [SparseLibraryEntry] = []
                for (_, change) in result.modificationResultsByID {
                    var record = try change.get().record
                    // A zone-wide share is delivered in the same change stream as library entries.
                    guard record.recordType != CKRecord.SystemType.share else { continue }
                    if record["payload"] == nil { record = try await database.record(for: record.recordID) }
                    guard let entry = decode(record) else { throw malformed(record.recordID.recordName) }
                    entries.append(entry)
                }
                try await store.applySparseRemoteEntries(entries)
                // Every page is committed before advancing its token. A crash retries idempotently.
                try await store.setSparseSyncState(tokenKey,
                    NSKeyedArchiver.archivedData(withRootObject: result.changeToken, requiringSecureCoding: true))
                token = result.changeToken
                if !result.moreComing { return }
            } catch let error as CKError where error.code == .changeTokenExpired && !didReset {
                token = nil; didReset = true
                try await store.setSparseSyncState(tokenKey, Data())
            }
        }
    }

    private func uploadOutbox() async throws {
        while true {
            try Task.checkCancellation()
            try await store.requireLibraryWriteAccess()
            let pending = try await store.sparsePendingEntries(limit: 60)
            guard !pending.isEmpty else { return }
            // Metadata/ink precede images. PDFs have their own single-record request so a large
            // transfer cannot hold a batch containing a rename or a cover.
            let batch = pending.first?.kind == "asset" ? Array(pending.prefix(1))
                : Array(pending.prefix { $0.kind != "asset" })
            let ids = batch.map { CKRecord.ID(recordName: Self.recordName(kind: $0.kind, id: $0.id), zoneID: zoneID) }
            let existing = try await database.records(for: ids, desiredKeys: Self.headerKeys)
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("sparse-upload-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            var records: [CKRecord] = []
            var attempted: [SparseLibraryEntry] = []
            for (entry, id) in zip(batch, ids) {
                let record: CKRecord
                if let result = existing[id] {
                    switch result {
                    case .success(let value): record = value
                    case .failure(let error as CKError) where error.code == .unknownItem:
                        record = CKRecord(recordType: Self.recordType, recordID: id)
                    case .failure(let error): throw error
                    }
                } else { throw malformed(id.recordName) }
                let digest = Self.digest(entry.payload)
                if record["digest"] as? String == digest {
                    try await store.sparseAcknowledge(entry)
                    continue
                }
                if record.recordChangeTag != nil, record["payload"] == nil,
                   let size = record["payloadSize"] as? NSNumber, size.intValue > 0 {
                    // Immutable operation IDs never conflict in normal use; fetch its external
                    // payload only if an existing ID actually carries different bytes.
                    let full = try await database.record(for: id)
                    if let file = (full["payloadFile"] as? CKAsset)?.fileURL {
                        record["payload"] = try Data(contentsOf: file) as CKRecordValue
                    }
                }
                if record.recordChangeTag != nil, let remote = decode(record),
                   let merged = try await store.mergeSparseUpload(entry, with: remote), merged.payload != entry.payload {
                    // Preserve concurrent edits locally first; the revised outbox is sent next pass.
                    try await store.applySparseMergedEntry(merged)
                    continue
                }
                record["kind"] = entry.kind as CKRecordValue
                record["entityID"] = entry.id as CKRecordValue
                record["documentID"] = entry.documentID as CKRecordValue
                record["pageID"] = entry.pageID as CKRecordValue
                record["payloadSize"] = NSNumber(value: entry.payload.count)
                if entry.payload.count > 128_000 {
                    let url = staging.appendingPathComponent(UUID().uuidString)
                    try entry.payload.write(to: url)
                    record["payload"] = nil
                    record["payloadFile"] = CKAsset(fileURL: url)
                } else {
                    record["payload"] = entry.payload as CKRecordValue
                    record["payloadFile"] = nil
                }
                record["digest"] = digest as CKRecordValue
                record["hasFile"] = NSNumber(value: entry.filePath != nil)
                if let path = entry.filePath {
                    guard FileManager.default.fileExists(atPath: path) else { throw malformed("本地资源缺失") }
                    record["file"] = CKAsset(fileURL: URL(fileURLWithPath: path))
                }
                records.append(record); attempted.append(entry)
            }
            guard !records.isEmpty else { continue }
            let results = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
            for (entry, record) in zip(attempted, records) {
                guard let result = results.saveResults[record.recordID] else { throw malformed(record.recordID.recordName) }
                switch result {
                case .success: try await store.sparseAcknowledge(entry)
                case .failure(let error as CKError) where error.code == .serverRecordChanged:
                    // Keep the durable task; re-read the server revision and merge on the next loop.
                    continue
                case .failure(let error): throw error
                }
            }
        }
    }

    private func downloadRequestedAssets() async throws {
        for entry in try await store.sparseAssetsToDownload() {
            try Task.checkCancellation()
            let id = CKRecord.ID(recordName: Self.recordName(kind: entry.kind, id: entry.id), zoneID: zoneID)
            let record = try await database.record(for: id)
            guard let remote = decode(record), let url = (record["file"] as? CKAsset)?.fileURL else { throw malformed(id.recordName) }
            try await store.installSparseRemoteFile(from: url, entry: remote)
        }
    }

    private func decode(_ record: CKRecord) -> SparseLibraryEntry? {
        guard let kind = record["kind"] as? String, let id = record["entityID"] as? String,
              let payload = (record["payload"] as? Data) ?? (record["payloadFile"] as? CKAsset)?.fileURL.flatMap({ try? Data(contentsOf: $0) }),
              record.recordID.recordName == Self.recordName(kind: kind, id: id) else { return nil }
        return SparseLibraryEntry(kind: kind, id: id, documentID: record["documentID"] as? String ?? "",
            pageID: record["pageID"] as? String ?? "", payload: payload, filePath: nil, revision: 0, pending: false)
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func malformed(_ name: String) -> NSError {
        NSError(domain: "TiyiSync", code: 2, userInfo: [NSLocalizedDescriptionKey: "同步记录或资源无效：\(name)"])
    }
}
