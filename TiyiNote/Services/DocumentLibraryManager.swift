import CloudKit
import Combine
import CryptoKit
import OSLog
import SwiftUI
#if targetEnvironment(macCatalyst)
import Security
#endif

struct DocumentLibrary: Codable, Identifiable, Equatable {
    static let personalID = "personal"
    let id: String
    var title: String
    let accountID: String?
    let zoneName: String?
    let ownerName: String?
    let isOwner: Bool

    var isPersonal: Bool { id == Self.personalID }
    var zoneID: CKRecordZone.ID? {
        guard let zoneName, let ownerName else { return nil }
        return CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
    }
    static let personal = DocumentLibrary(id: personalID, title: "我的文稿库",
        accountID: nil, zoneName: nil, ownerName: nil, isOwner: true)
}

enum FamilyLibraryCloud {
    static let zonePrefix = "TiyiFamilyLibrary."

    static var isAvailable: Bool {
#if targetEnvironment(macCatalyst)
        guard let task = SecTaskCreateFromSelf(nil),
              let ids = SecTaskCopyValueForEntitlement(task,
                "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String] else { return false }
        return ids.contains(CloudLibrarySyncCoordinator.containerIdentifier)
#elseif targetEnvironment(simulator)
        return FileManager.default.ubiquityIdentityToken != nil
#else
        return true
#endif
    }

    static func container() throws -> CKContainer {
        guard isAvailable else { throw failure("请先登录 iCloud，并使用支持 iCloud 的 Tiyi 版本。") }
        return CKContainer(identifier: CloudLibrarySyncCoordinator.containerIdentifier)
    }

    static func libraryID(zoneName: String) -> String? {
        guard zoneName.hasPrefix(zonePrefix),
              let uuid = UUID(uuidString: String(zoneName.dropFirst(zonePrefix.count))) else { return nil }
        return "family." + uuid.uuidString.lowercased()
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "TiyiFamilyLibrary", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

enum FamilyLibraryInvitation {
    private static let logger = Logger(subsystem: "com.tiyi.documents", category: "FamilyInvitation")

    static func isShareURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https",
              ["icloud.com", "www.icloud.com", "icloud.com.cn", "www.icloud.com.cn"]
                .contains(parts.host?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443 else { return false }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        return path.count == 3 && path[0].isEmpty && path[1] == "share" && !path[2].isEmpty
    }

    static func url(from text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), isShareURL(url),
              !trimmed.contains(where: { $0.isWhitespace }) else {
            throw FamilyLibraryCloud.failure("请粘贴完整的 iCloud 邀请链接，支持 icloud.com 和 icloud.com.cn 的共享链接。")
        }
        return url
    }

    static func accept(_ url: URL, familyOnly: Bool) async throws {
        guard isShareURL(url) else { throw FamilyLibraryCloud.failure("这不是有效的 iCloud 邀请链接。") }
        var stage = "prepare"
        do {
            let container = try FamilyLibraryCloud.container()
            stage = "fetchMetadata"
            let metadata = try await container.shareMetadata(for: url)
            stage = "validateMetadata"
            guard metadata.containerIdentifier == CloudLibrarySyncCoordinator.containerIdentifier else {
                throw FamilyLibraryCloud.failure("这不是 Tiyi 的邀请链接。")
            }
            let isFamily = FamilyLibraryCloud.libraryID(zoneName: metadata.share.recordID.zoneID.zoneName) != nil
            if familyOnly, !isFamily {
                throw FamilyLibraryCloud.failure("这不是家庭库邀请，请向创建者获取家庭库的邀请链接。")
            }
            if isFamily, metadata.participantRole != .owner, metadata.participantPermission != .readWrite {
                throw FamilyLibraryCloud.failure("请让创建者邀请当前 iCloud 账号，并允许编辑。")
            }
            if metadata.participantStatus != .accepted, metadata.participantRole != .owner {
                stage = "acceptShare"
                try await CloudDocumentShareService.accept(metadata)
            }
            await MainActor.run {
                NotificationCenter.default.post(name: .tiyiCloudKitShareAccepted, object: metadata)
            }
        } catch {
            let underlying = error as NSError
            logger.error("Invitation failed: stage=\(stage, privacy: .public) domain=\(underlying.domain, privacy: .public) code=\(underlying.code) description=\(underlying.localizedDescription, privacy: .private)")
            throw NSError(domain: "TiyiFamilyLibrary.Invitation", code: underlying.code,
                userInfo: [NSLocalizedDescriptionKey: message(for: error),
                           NSUnderlyingErrorKey: underlying, "stage": stage])
        }
    }

    static func message(for error: Error) -> String {
        guard let cloudError = error as? CKError else { return error.localizedDescription }
        switch cloudError.code {
        case .notAuthenticated:
            return "请先在设备的系统设置中登录 iCloud，再返回接受邀请。"
        case .unknownItem:
            return "当前账号无法找到这个邀请。请确认链接完整，并让创建者检查是否已邀请当前 iCloud 账号。"
        case .zoneNotFound, .userDeletedZone:
            return "当前账号无法访问这个家庭库，请让创建者检查共享状态。"
        case .permissionFailure:
            return "当前 iCloud 账号无法接受此邀请，请让创建者邀请这个账号。"
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
            return "暂时无法连接 iCloud，请稍后重试。"
        default:
            return cloudError.localizedDescription
        }
    }
}

/// Keeps every library mounted independently. Selecting a library only changes the visible store.
@MainActor final class DocumentLibraryManager: ObservableObject {
    @Published private(set) var libraries: [DocumentLibrary] = [.personal]
    @Published private(set) var selectedID = DocumentLibrary.personalID
    @Published private(set) var defaultID = DocumentLibrary.personalID
    @Published var errorMessage: String?
    @Published private(set) var isRefreshing = false
    private let directory: URL
    private let defaults: UserDefaults
    private var personalStore: DrawingDocumentStore?
    private var stores: [String: DrawingDocumentStore] = [:]
    private var coordinators: [String: CloudLibrarySyncCoordinator] = [:]
    private var browserStates: [String: LibraryBrowserState] = [:]
    private var observations: Set<AnyCancellable> = []
    private var accountID: String?
    private var accountGeneration = 0
    private var familyWritesSuspended = false
    private var lastDiscovery = Date.distantPast
    private var needsForcedRefresh = false
    var isPresentingDocuments = false
    var pendingEntryLibraryID: String?

    private struct Catalog: Codable {
        let accountID: String?
        let libraries: [DocumentLibrary]
    }

    init(directory: URL? = nil, defaults: UserDefaults = .standard, personalStore: DrawingDocumentStore? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appendingPathComponent("TiyiNote/Libraries", isDirectory: true)
        self.defaults = defaults
        self.personalStore = personalStore
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let url = self.directory.appendingPathComponent("catalog.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let saved = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
                accountID = saved.accountID
                libraries += saved.libraries.filter { !$0.isPersonal && $0.accountID == saved.accountID }
            }
            restoreDefault()
            selectedID = defaultID
        } catch { errorMessage = "无法读取文稿库：\(error.localizedDescription)" }
        NotificationCenter.default.publisher(for: .CKAccountChanged).sink { [weak self] _ in
            Task { @MainActor in await self?.accountChanged() }
        }.store(in: &observations)
        for name in [Notification.Name.tiyiCloudKitShareAccepted, .tiyiCloudKitRemoteChange] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in await self?.refresh(force: true) }
            }.store(in: &observations)
        }
        NotificationCenter.default.publisher(for: .tiyiCloudKitShareAcceptanceFailed).sink { [weak self] note in
            let message = (note.object as? Error).map { FamilyLibraryInvitation.message(for: $0) }
                ?? "无法接受这个 iCloud 协作邀请。"
            Task { @MainActor in self?.errorMessage = message }
        }.store(in: &observations)
    }

    var selectedLibrary: DocumentLibrary { library(selectedID) ?? .personal }
    func library(_ id: String) -> DocumentLibrary? { libraries.first { $0.id == id } }
    var currentStore: DrawingDocumentStore { store(for: selectedLibrary) }

    func store(for library: DocumentLibrary) -> DrawingDocumentStore {
        if library.isPersonal {
            if let personalStore { return personalStore }
            let store = DrawingDocumentStore()
            personalStore = store
            return store
        }
        if let store = stores[library.id] { return store }
        // Separate actor identities, defaults, files, outbox and change tokens for every account/library.
        let key = SHA256.hash(data: Data("\(library.accountID ?? "")|\(library.ownerName ?? "")|\(library.id)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let store = DrawingDocumentStore(userDefaults: UserDefaults(suiteName: "Tiyi.family.\(key)")!,
            workspaceDirectoryOverride: directory.appendingPathComponent(key), includesBundledSamples: false,
            keepsFavoritesPersonal: true, replicaIdentityNamespace: key)
        store.libraryWriteAllowed = !familyWritesSuspended
        stores[library.id] = store
        return store
    }

    func browsingState(for id: String) -> LibraryBrowserState {
        if let state = browserStates[id] { return state }
        let state = LibraryBrowserState(); browserStates[id] = state
        return state
    }

    func select(_ id: String) {
        guard library(id) != nil else { return }
        selectedID = id
    }

    func enterDocuments() {
        select(pendingEntryLibraryID ?? defaultID)
        pendingEntryLibraryID = nil
    }
    func setDefault(_ id: String) {
        guard library(id) != nil else { return }
        defaultID = id
        defaults.set(id, forKey: defaultKey)
    }

    private var defaultKey: String { "documentLibrary.default|\(accountID ?? "local")" }
    private func restoreDefault() {
        let saved = defaults.string(forKey: defaultKey) ?? DocumentLibrary.personalID
        defaultID = library(saved) == nil ? DocumentLibrary.personalID : saved
    }

    func requireImportLibrary(_ id: String) throws -> DrawingDocumentStore {
        guard let library = library(id) else { throw FamilyLibraryCloud.failure("该文稿库已不可用，请重新选择导入位置。") }
        if !library.isPersonal, familyWritesSuspended { throw FamilyLibraryCloud.failure("正在确认 iCloud 账号，请稍后再导入家庭库。") }
        let store = store(for: library)
        try store.requireLibraryWriteAccess()
        return store
    }

    func coordinator(for library: DocumentLibrary) -> CloudLibrarySyncCoordinator? {
        guard !familyWritesSuspended, !library.isPersonal, let zone = library.zoneID, FamilyLibraryCloud.isAvailable else { return nil }
        if let coordinator = coordinators[library.id] { return coordinator }
        let coordinator = CloudLibrarySyncCoordinator(dataSource: store(for: library), zoneName: zone.zoneName,
            ownerName: zone.ownerName, databaseScope: library.isOwner ? .private : .shared,
            shouldCreateZone: false, isFamilyLibrary: true)
        coordinators[library.id] = coordinator
        return coordinator
    }

    func createFamily(named name: String) async throws -> DocumentLibrary {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 60 else { throw FamilyLibraryCloud.failure("请输入 1–60 个字的文稿库名称。") }
        let container = try FamilyLibraryCloud.container()
        let requestGeneration = accountGeneration
        let account = try await container.userRecordID().recordName
        guard requestGeneration == accountGeneration else { throw FamilyLibraryCloud.failure("iCloud 账号已改变，请重试。") }
        await bindAccount(account)
        guard accountID == account else { throw FamilyLibraryCloud.failure("iCloud 账号已改变，请重试。") }
        let generation = accountGeneration
        let zone = CKRecordZone.ID(zoneName: FamilyLibraryCloud.zonePrefix + UUID().uuidString.lowercased(), ownerName: CKCurrentUserDefaultName)
        let database = container.privateCloudDatabase
        _ = try await database.save(CKRecordZone(zoneID: zone))
        let share = CKShare(recordZoneID: zone)
        share[CKShare.SystemFieldKey.title] = title as CKRecordValue
        share.publicPermission = .none
        _ = try await database.save(share)
        guard generation == accountGeneration else { throw FamilyLibraryCloud.failure("iCloud 账号已改变，请重新打开文稿库。") }
        let library = DocumentLibrary(id: FamilyLibraryCloud.libraryID(zoneName: zone.zoneName)!, title: title,
            accountID: account, zoneName: zone.zoneName, ownerName: zone.ownerName, isOwner: true)
        accountGeneration += 1 // Invalidate any discovery snapshot captured before this creation.
        familyWritesSuspended = false
        libraries.append(library)
        try saveCatalog()
        select(library.id)
        return library
    }

    func shareForManagement(_ id: String) async throws -> CKShare {
        guard let library = library(id), !library.isPersonal, library.isOwner, let zone = library.zoneID else {
            throw FamilyLibraryCloud.failure("只有创建者可以管理家庭库成员。")
        }
        let container = try FamilyLibraryCloud.container()
        guard try await container.userRecordID().recordName == library.accountID else {
            throw FamilyLibraryCloud.failure("iCloud 账号已改变，请重新打开文稿库。")
        }
        do {
            let record = try await container.privateCloudDatabase.record(for: CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zone))
            guard let share = record as? CKShare else { throw FamilyLibraryCloud.failure("无法加载家庭库邀请。") }
            return share
        } catch let error as CKError where error.code == .unknownItem {
            // Stopping sharing removes membership, not the creator's library. A later invitation
            // starts a new private share in the existing zone and never resurrects old members.
            let share = CKShare(recordZoneID: zone)
            share[CKShare.SystemFieldKey.title] = library.title as CKRecordValue
            share.publicPermission = .none
            guard let saved = try await container.privateCloudDatabase.save(share) as? CKShare else {
                throw FamilyLibraryCloud.failure("无法创建家庭库邀请。")
            }
            return saved
        }
    }

    func createOneTimeInvitation(to id: String) async throws -> URL {
        guard let library = library(id), !library.isPersonal, library.isOwner else {
            throw FamilyLibraryCloud.failure("只有创建者可以邀请家庭库成员。")
        }
        let generation = accountGeneration
        let container = try FamilyLibraryCloud.container()
        guard try await container.userRecordID().recordName == library.accountID,
              generation == accountGeneration else {
            throw FamilyLibraryCloud.failure("iCloud 账号已改变，请重新打开文稿库。")
        }
        return try await saveInvitation(.oneTimeURLParticipant(), to: library, container: container,
            generation: generation)
    }

    private func saveInvitation(_ participant: CKShare.Participant, to library: DocumentLibrary,
                                container: CKContainer, generation: Int) async throws -> URL {
        for attempt in 0..<2 {
            let share = try await shareForManagement(library.id)
            guard generation == accountGeneration, self.library(library.id)?.accountID == library.accountID else {
                throw FamilyLibraryCloud.failure("iCloud 账号已改变，请重新打开文稿库。")
            }
            participant.role = .privateUser
            participant.permission = .readWrite
            share.publicPermission = .none
            share.addParticipant(participant)
            do {
                let result = try await container.privateCloudDatabase.modifyRecords(saving: [share],
                    deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
                guard let savedResult = result.saveResults[share.recordID] else { throw CKError(.internalError) }
                let saved = try savedResult.get()
                guard generation == accountGeneration else {
                    throw FamilyLibraryCloud.failure("iCloud 账号已改变，请重新打开文稿库。")
                }
                let savedShare = saved as? CKShare
                // Only the participant-specific URL lets an unbound recipient claim this slot.
                // Never fall back to the ordinary share URL, which requires named membership.
                let invitationURL = savedShare?.oneTimeURL(for: participant.participantID)
                guard let url = invitationURL else {
                    throw FamilyLibraryCloud.failure("暂时无法读取一次性邀请链接，请重试。")
                }
                return url
            } catch let error as CKError where error.code == .serverRecordChanged && attempt == 0 {
                // Re-fetch before retrying so a concurrent invitation/removal isn't overwritten.
                continue
            }
        }
        throw FamilyLibraryCloud.failure("成员信息已改变，请重试。")
    }

    /// Discovery must finish successfully before absence can revoke a cached mount. Transient errors
    /// preserve every library, including its pending offline edits and selected/default state.
    func refresh(force: Bool = false) async {
        guard FamilyLibraryCloud.isAvailable else { return }
        guard !isRefreshing else {
            needsForcedRefresh = needsForcedRefresh || force
            return
        }
        guard force || Date().timeIntervalSince(lastDiscovery) > 25 else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            if needsForcedRefresh {
                needsForcedRefresh = false
                Task { await self.refresh(force: true) }
            }
        }
        do {
            let container = try FamilyLibraryCloud.container()
            let requestGeneration = accountGeneration
            let account = try await container.userRecordID().recordName
            guard requestGeneration == accountGeneration else { return }
            await bindAccount(account)
            guard accountID == account else { return }
            let generation = accountGeneration
            async let owned = container.privateCloudDatabase.allRecordZones()
            async let shared = container.sharedCloudDatabase.allRecordZones()
            let groups = try await [(true, owned), (false, shared)]
            var found: [DocumentLibrary] = []
            for (isOwner, zones) in groups {
                let database = isOwner ? container.privateCloudDatabase : container.sharedCloudDatabase
                for zone in zones {
                    guard let id = FamilyLibraryCloud.libraryID(zoneName: zone.zoneID.zoneName) else { continue }
                    let record: CKRecord
                    do {
                        record = try await database.record(for: CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zone.zoneID))
                    } catch let error as CKError where [.unknownItem, .zoneNotFound, .userDeletedZone, .permissionFailure].contains(error.code) {
                        if isOwner, error.code == .unknownItem {
                            found.append(DocumentLibrary(id: id, title: library(id)?.title ?? "家庭文稿库",
                                accountID: account, zoneName: zone.zoneID.zoneName, ownerName: zone.zoneID.ownerName, isOwner: true))
                        }
                        continue
                    }
                    guard let share = record as? CKShare else { continue }
                    if !isOwner {
                        guard share.currentUserParticipant?.acceptanceStatus == .accepted,
                              share.currentUserParticipant?.permission == .readWrite else { continue }
                    }
                    found.append(DocumentLibrary(id: id, title: share[CKShare.SystemFieldKey.title] as? String ?? "家庭文稿库",
                        accountID: account, zoneName: zone.zoneID.zoneName, ownerName: zone.zoneID.ownerName, isOwner: isOwner))
                }
            }
            guard generation == accountGeneration, !Task.isCancelled else { return }
            await replaceFamilies(found, expectedGeneration: generation)
            guard generation == accountGeneration else { return }
            try saveCatalog()
            lastDiscovery = Date()
        } catch {
            if !(error is CancellationError), cloudKitTransientRetryDelay(for: error) == nil {
                errorMessage = error.localizedDescription
            }
        }
    }

    func maintain() async {
        guard maintenanceIsAllowed else { return }
        await refresh()
        guard maintenanceIsAllowed else { return }
        for library in libraries where !library.isPersonal {
            guard !Task.isCancelled, let coordinator = coordinator(for: library) else { continue }
            await coordinator.scheduleSync(after: 1)
        }
    }

    private var maintenanceIsAllowed: Bool {
        let loaded = Array(stores.values) + [personalStore].compactMap { $0 }
        return !loaded.contains { $0.isDrawingInteractionActive || $0.hasPendingLocalDrawingPersistence || $0.hadRecentDrawingInteraction(within: 10) }
    }

    @discardableResult
    func cancelFamilySync(suspend: Bool = false) async -> Bool {
        var cancelled = false
        for coordinator in coordinators.values {
            let didCancel = suspend ? await coordinator.suspendAutomaticSync() : await coordinator.cancelScheduledSync()
            cancelled = didCancel || cancelled
        }
        return cancelled
    }

    func resumeFamilySync() async {
        for coordinator in coordinators.values { await coordinator.resumeAutomaticSync() }
    }

    private func accountChanged() async {
        accountGeneration += 1
        familyWritesSuspended = true
        for store in stores.values { store.libraryWriteAllowed = false }
        for coordinator in coordinators.values {
            await coordinator.setAllowsUploads(false)
            _ = await coordinator.suspendAutomaticSync()
        }
        coordinators.removeAll()
        libraries = [.personal]
        selectedID = DocumentLibrary.personalID
        lastDiscovery = .distantPast
        await refresh(force: true)
    }

    private func bindAccount(_ account: String) async {
        guard accountID != account else { return }
        accountGeneration += 1
        let generation = accountGeneration
        familyWritesSuspended = true
        for store in stores.values { store.libraryWriteAllowed = false }
        for coordinator in coordinators.values {
            await coordinator.setAllowsUploads(false)
            _ = await coordinator.suspendAutomaticSync()
        }
        guard generation == accountGeneration else { return }
        coordinators.removeAll(); stores.removeAll(); browserStates.removeAll()
        libraries = [.personal]; selectedID = DocumentLibrary.personalID
        accountID = account
        restoreDefault()
    }

    func replaceFamilies(_ found: [DocumentLibrary], expectedGeneration: Int? = nil) async {
        let ids = Set(found.map(\.id))
        for library in libraries where !library.isPersonal && !ids.contains(library.id) {
            stores[library.id]?.libraryWriteAllowed = false
            if let coordinator = coordinators.removeValue(forKey: library.id) {
                await coordinator.setAllowsUploads(false)
                _ = await coordinator.suspendAutomaticSync()
            }
        }
        if let expectedGeneration, expectedGeneration != accountGeneration { return }
        familyWritesSuspended = false
        libraries = [.personal] + found.sorted { $0.title == $1.title ? $0.id < $1.id : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        for library in found { stores[library.id]?.libraryWriteAllowed = true }
        if library(selectedID) == nil { selectedID = DocumentLibrary.personalID }
        let previousDefault = defaultID
        restoreDefault()
        if previousDefault != DocumentLibrary.personalID, library(previousDefault) == nil {
            setDefault(DocumentLibrary.personalID)
        }
    }

    private func saveCatalog() throws {
        try JSONEncoder().encode(Catalog(accountID: accountID, libraries: libraries.filter { !$0.isPersonal }))
            .write(to: directory.appendingPathComponent("catalog.json"), options: .atomic)
    }
}
