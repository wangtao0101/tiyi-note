#if DEBUG
import CloudKit
import OSLog
import PencilKit
import SwiftUI
import UIKit

struct CloudKitSmokeConfiguration: Hashable {
    static let argument = "--cloud-smoke"

    let token: String

    init?(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard let flagIndex = arguments.firstIndex(of: Self.argument),
              arguments.indices.contains(flagIndex + 1) else { return nil }
        let proposedToken = arguments[flagIndex + 1]
        let safeToken = proposedToken.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        guard !safeToken.isEmpty else { return nil }
        token = String(safeToken.prefix(48))
    }
}

struct CloudKitSmokeHarnessView: View {
    let configuration: CloudKitSmokeConfiguration

    @State private var result = "正在进行真实 iCloud 往返测试…"

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("CloudKit Smoke")
                .font(.title2.bold())
            Text(result)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .task {
            result = await CloudKitSmokeHarness.run(configuration: configuration)
        }
    }
}

@MainActor
private enum CloudKitSmokeHarness {
    private static let logger = Logger(subsystem: "com.tiyi.note", category: "CloudSmoke")

    private enum SmokeError: LocalizedError {
        case missingBundledPDF
        case importFailed
        case syncFailed(client: String, status: String)
        case validationFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingBundledPDF:
                "找不到内置测试 PDF"
            case .importFailed:
                "测试 PDF 导入失败"
            case .syncFailed(let client, let status):
                "客户端 \(client) 同步失败：\(status)"
            case .validationFailed(let detail):
                "下载校验失败：\(detail)"
            }
        }
    }

    static func run(configuration: CloudKitSmokeConfiguration) async -> String {
        let token = configuration.token
        let zoneName = "TiyiNoteSmoke-\(token)"
        let fileManager = FileManager.default
        let baseDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("TiyiNoteCloudSmoke", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
        let defaultsAName = "com.tiyi.note.cloud-smoke.a.\(token)"
        let defaultsBName = "com.tiyi.note.cloud-smoke.b.\(token)"
        let defaultsA = UserDefaults(suiteName: defaultsAName)!
        let defaultsB = UserDefaults(suiteName: defaultsBName)!

        try? fileManager.removeItem(at: baseDirectory)
        defaultsA.removePersistentDomain(forName: defaultsAName)
        defaultsB.removePersistentDomain(forName: defaultsBName)

        do {
            try await probePrivateDefaultZone(token: token)
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            let expected = try await makeAndUploadClientA(
                token: token,
                zoneName: zoneName,
                workspaceDirectory: baseDirectory.appendingPathComponent("ClientA"),
                defaults: defaultsA
            )
            try await downloadAndValidateClientB(
                expected: expected,
                zoneName: zoneName,
                workspaceDirectory: baseDirectory.appendingPathComponent("ClientB"),
                defaults: defaultsB
            )
            try await validateConcurrentStrokeMerge(
                expected: expected,
                zoneName: zoneName,
                clientAWorkspace: baseDirectory.appendingPathComponent("ClientA"),
                clientBWorkspace: baseDirectory.appendingPathComponent("ClientB"),
                defaultsA: defaultsA,
                defaultsB: defaultsB
            )
            try await validateOwnerShare(
                token: token,
                workspaceDirectory: baseDirectory.appendingPathComponent("ShareOwner"),
                defaults: UserDefaults(
                    suiteName: "com.tiyi.note.cloud-smoke.share.\(token)"
                )!
            )
            try await deleteSmokeZone(named: zoneName)
            try? fileManager.removeItem(at: baseDirectory)
            defaultsA.removePersistentDomain(forName: defaultsAName)
            defaultsB.removePersistentDomain(forName: defaultsBName)
            logger.notice("TIYI_CLOUD_SMOKE_PASS token=\(token, privacy: .public)")
            return "真实 iCloud 往返测试通过（\(token)）"
        } catch {
            // A failed run can leave a partially-created test zone. Cleanup is best-effort and
            // deliberately targets only this run's unique smoke zone and temporary directory.
            try? await deleteSmokeZone(named: zoneName)
            try? fileManager.removeItem(at: baseDirectory)
            defaultsA.removePersistentDomain(forName: defaultsAName)
            defaultsB.removePersistentDomain(forName: defaultsBName)
            let message = error.localizedDescription
            let cocoaError = error as NSError
            for (key, value) in cocoaError.userInfo {
                logger.error(
                    "TIYI_CLOUD_SMOKE_DETAIL key=\(String(describing: key), privacy: .public) value=\(String(reflecting: value), privacy: .public)"
                )
            }
            logger.error(
                "TIYI_CLOUD_SMOKE_FAIL token=\(token, privacy: .public) error=\(message, privacy: .public)"
            )
            return "真实 iCloud 往返测试失败：\(message)"
        }
    }

    private struct ExpectedValues {
        let rootFolderID: String
        let childFolderID: String
        let documentID: String
        let pageID: String
        let documentTitle: String
        let canvasDocumentID: String
        let canvasTitle: String
        let drawingData: Data
        let imageAnnotationsData: Data
        let expectedImageCount: Int
    }

    private static func makeAndUploadClientA(
        token: String,
        zoneName: String,
        workspaceDirectory: URL,
        defaults: UserDefaults
    ) async throws -> ExpectedValues {
        let store = DrawingDocumentStore(
            userDefaults: defaults,
            workspaceDirectoryOverride: workspaceDirectory
        )
        let rootFolder = try store.createFolder(named: "Cloud Smoke \(token)", in: nil)
        try store.updateFolderAppearance(rootFolder.id, color: .purple, icon: .graduationCap)
        try store.setFolderFavorite(rootFolder.id, isFavorite: true)
        let childFolder = try store.createFolder(named: "Nested \(token)", in: rootFolder.id)
        guard let bundledPDF = Bundle.main.url(forResource: "Congruence", withExtension: "pdf") else {
            throw SmokeError.missingBundledPDF
        }
        guard let document = try store.importPDFs(from: [bundledPDF], into: childFolder.id).first else {
            throw SmokeError.importFailed
        }

        let drawing = makeDrawing()
        let image = makeImage()
        let imageAnnotation = CanvasImageAnnotation(
            id: UUID(),
            image: image,
            logicalBounds: CGRect(x: 42, y: 64, width: 48, height: 32),
            rotationRadians: 0.125
        )
        store.flush(drawing, forPage: 0, in: document.id)
        store.flush([imageAnnotation], forPage: 0, in: document.id)

        let drawingReference = LibraryAssetReference(
            documentID: document.id,
            kind: .drawing(pageIndex: 0)
        )
        let imagesReference = LibraryAssetReference(
            documentID: document.id,
            kind: .imageAnnotations(pageIndex: 0)
        )
        guard let drawingURL = store.assetURL(for: drawingReference),
              let imagesURL = store.assetURL(for: imagesReference) else {
            throw SmokeError.validationFailed("客户端 A 批注资产路径缺失")
        }
        let drawingData = try Data(contentsOf: drawingURL)
        let imageAnnotationsData = try Data(contentsOf: imagesURL)
        guard let pageID = store.pageID(at: 0, in: document.id) else {
            throw SmokeError.validationFailed("客户端 A 缺少稳定 pageID")
        }
        let canvas = try store.createCanvas(
            named: "Canvas \(token)",
            in: childFolder.id,
            backgroundStyle: .dotted,
            backgroundColor: .green
        )
        try store.setDocumentFavorite(canvas.id, isFavorite: true)
        try store.moveToTrash(documentID: document.id)

        let coordinator = CloudLibrarySyncCoordinator(
            dataSource: store,
            zoneName: zoneName,
            tokenStore: defaults
        )
        await coordinator.syncNow()
        try requireSuccessfulSync(store.cloudSyncStatus, client: "A")

        return ExpectedValues(
            rootFolderID: rootFolder.id,
            childFolderID: childFolder.id,
            documentID: document.id,
            pageID: pageID,
            documentTitle: document.title,
            canvasDocumentID: canvas.id,
            canvasTitle: canvas.title,
            drawingData: drawingData,
            imageAnnotationsData: imageAnnotationsData,
            expectedImageCount: 1
        )
    }

    private static func downloadAndValidateClientB(
        expected: ExpectedValues,
        zoneName: String,
        workspaceDirectory: URL,
        defaults: UserDefaults
    ) async throws {
        let store = DrawingDocumentStore(
            userDefaults: defaults,
            workspaceDirectoryOverride: workspaceDirectory
        )
        let coordinator = CloudLibrarySyncCoordinator(
            dataSource: store,
            zoneName: zoneName,
            tokenStore: defaults
        )
        await coordinator.syncNow()
        try requireSuccessfulSync(store.cloudSyncStatus, client: "B")

        guard let root = store.folder(withID: expected.rootFolderID),
              root.parentID == nil,
              root.color == .purple,
              root.icon == .graduationCap,
              root.isFavorite else {
            throw SmokeError.validationFailed("根文件夹缺失")
        }
        guard let child = store.folder(withID: expected.childFolderID),
              child.parentID == expected.rootFolderID else {
            throw SmokeError.validationFailed("嵌套文件夹层级错误")
        }
        guard let document = store.document(withID: expected.documentID),
              document.parentID == expected.childFolderID,
              document.title == expected.documentTitle,
              document.trashedAt != nil,
              store.pageCount(for: expected.documentID) > 0 else {
            throw SmokeError.validationFailed("PDF 元数据或文件内容缺失")
        }
        guard let canvas = store.document(withID: expected.canvasDocumentID),
              canvas.title == expected.canvasTitle,
              canvas.parentID == expected.childFolderID,
              canvas.kind == .canvas,
              canvas.canvasBackgroundStyle == .dotted,
              canvas.canvasBackgroundColor == .green,
              canvas.isFavorite,
              canvas.trashedAt == nil,
              store.pageCount(for: expected.canvasDocumentID) == 1 else {
            throw SmokeError.validationFailed("画板元数据、背景或 PDF 资产缺失")
        }
        let downloadedDrawing = store.loadDrawing(forPage: 0, in: expected.documentID)
        let drawingReference = LibraryAssetReference(
            documentID: expected.documentID,
            kind: .drawing(pageIndex: 0)
        )
        let expectedDrawing = try PKDrawing(data: expected.drawingData)
        guard let drawingURL = store.assetURL(for: drawingReference),
              FileManager.default.fileExists(atPath: drawingURL.path),
              downloadedDrawing.strokes.count == expectedDrawing.strokes.count,
              downloadedDrawing.bounds == expectedDrawing.bounds else {
            throw SmokeError.validationFailed("PencilKit 批注不一致")
        }
        let images = store.loadImageAnnotations(forPage: 0, in: expected.documentID)
        let imagesReference = LibraryAssetReference(
            documentID: expected.documentID,
            kind: .imageAnnotations(pageIndex: 0)
        )
        guard images.count == expected.expectedImageCount,
              images.first?.image.pngData()?.isEmpty == false,
              let imagesURL = store.assetURL(for: imagesReference),
              (try Data(contentsOf: imagesURL)) == expected.imageAnnotationsData else {
            throw SmokeError.validationFailed("图片批注不一致")
        }
    }

    private static func requireSuccessfulSync(
        _ status: CloudLibrarySyncStatus,
        client: String
    ) throws {
        guard case .succeeded = status else {
            throw SmokeError.syncFailed(client: client, status: String(describing: status))
        }
    }

    private static func validateConcurrentStrokeMerge(
        expected: ExpectedValues,
        zoneName: String,
        clientAWorkspace: URL,
        clientBWorkspace: URL,
        defaultsA: UserDefaults,
        defaultsB: UserDefaults
    ) async throws {
        let storeA = DrawingDocumentStore(
            userDefaults: defaultsA,
            workspaceDirectoryOverride: clientAWorkspace
        )
        let storeB = DrawingDocumentStore(
            userDefaults: defaultsB,
            workspaceDirectoryOverride: clientBWorkspace
        )
        let baseA = storeA.loadDrawing(forPage: 0, in: expected.documentID)
        let baseB = storeB.loadDrawing(forPage: 0, in: expected.documentID)
        guard baseA.strokes.count == 1, baseB.strokes.count == 1 else {
            let actualPageIDA = storeA.pageID(at: 0, in: expected.documentID) ?? "nil"
            let actualPageIDB = storeB.pageID(at: 0, in: expected.documentID) ?? "nil"
            let referenceB = actualPageIDB == "nil" ? nil : LibraryAssetReference(
                documentID: expected.documentID,
                kind: .pageDrawing(pageID: actualPageIDB)
            )
            let fileB = referenceB.flatMap(storeB.assetURL(for:))
            let fileSizeB = fileB.flatMap {
                try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
            } ?? -1
            throw SmokeError.validationFailed(
                "并发测试缺少共同基础笔迹（A=\(baseA.strokes.count)，B=\(baseB.strokes.count)，预期页=\(expected.pageID)，A页=\(actualPageIDA)，B页=\(actualPageIDB)，B文件=\(fileSizeB)）"
            )
        }
        let baseElementsA = storeA.loadPageElements(forPage: 0, in: expected.documentID)
        let baseElementsB = storeB.loadPageElements(forPage: 0, in: expected.documentID)
        guard baseElementsA.count == 1,
              baseElementsA == baseElementsB,
              let sharedElementID = baseElementsA.first?.id else {
            throw SmokeError.validationFailed("对象字段并发测试缺少共同图片对象")
        }

        // Both replicas edit before either one downloads the other's change. Folder metadata uses
        // one causal register per field, so a rename cannot overwrite an independent move/favorite.
        let concurrentFolderTitle = "Concurrent Folder"
        try storeA.renameFolder(expected.childFolderID, to: concurrentFolderTitle)
        try storeB.moveFolder(expected.childFolderID, to: nil)
        try storeB.setFolderFavorite(expected.childFolderID, isFavorite: true)

        let additionA = makeDrawing(offset: 160, color: .systemGreen)
        let additionB = makeDrawing(offset: 320, color: .systemBlue)
        storeA.flush(
            PKDrawing(strokes: baseA.strokes + additionA.strokes),
            forPage: 0,
            in: expected.documentID
        )
        storeB.flush(
            PKDrawing(strokes: baseB.strokes + additionB.strokes),
            forPage: 0,
            in: expected.documentID
        )
        var movedElements = baseElementsA
        movedElements[0].logicalBounds = movedElements[0].logicalBounds.offsetBy(dx: 27, dy: 19)
        storeA.flush(movedElements, forPage: 0, in: expected.documentID)
        var fadedElements = baseElementsB
        if case .image(var imagePayload) = fadedElements[0].payload {
            imagePayload.opacity = 0.47
            fadedElements[0].payload = .image(imagePayload)
        }
        storeB.flush(fadedElements, forPage: 0, in: expected.documentID)

        let coordinatorA = CloudLibrarySyncCoordinator(
            dataSource: storeA,
            zoneName: zoneName,
            tokenStore: defaultsA
        )
        let coordinatorB = CloudLibrarySyncCoordinator(
            dataSource: storeB,
            zoneName: zoneName,
            tokenStore: defaultsB
        )
        await coordinatorA.syncNow()
        try requireSuccessfulSync(storeA.cloudSyncStatus, client: "A-concurrent-upload")
        await coordinatorB.syncNow()
        try requireSuccessfulSync(storeB.cloudSyncStatus, client: "B-concurrent-merge")
        await coordinatorA.syncNow()
        try requireSuccessfulSync(storeA.cloudSyncStatus, client: "A-concurrent-merge")

        let pageIDA = storeA.pageID(at: 0, in: expected.documentID)
        let pageIDB = storeB.pageID(at: 0, in: expected.documentID)
        guard let pageIDA, pageIDA == pageIDB else {
            throw SmokeError.validationFailed("两个客户端的稳定 pageID 不一致")
        }
        let operationsA = storeA.exportCollaborationOperations().filter { $0.pageID == pageIDA }
        let operationsB = storeB.exportCollaborationOperations().filter { $0.pageID == pageIDA }
        let stateA = CollaborationMergeEngine.materialize(operationsA)
        let stateB = CollaborationMergeEngine.materialize(operationsB)
        let drawingA = storeA.loadDrawing(forPage: 0, in: expected.documentID)
        let drawingB = storeB.loadDrawing(forPage: 0, in: expected.documentID)
        let mergedElementA = storeA.loadPageElements(
            forPage: 0,
            in: expected.documentID
        ).first(where: { $0.id == sharedElementID })
        let mergedElementB = storeB.loadPageElements(
            forPage: 0,
            in: expected.documentID
        ).first(where: { $0.id == sharedElementID })
        let mergedOpacity: Double? = {
            guard let mergedElementA,
                  case .image(let payload) = mergedElementA.payload else { return nil }
            return payload.opacity
        }()
        guard stateA.strokes.count == 3,
              stateA.strokes == stateB.strokes,
              drawingA.strokes.count == 3,
              drawingB.strokes.count == 3,
              mergedElementA == mergedElementB,
              mergedElementA?.logicalBounds == movedElements[0].logicalBounds,
              mergedOpacity == 0.47,
              !stateA.conflicts.contains(where: { $0.targetID == sharedElementID.uuidString }),
              let folderA = storeA.folder(withID: expected.childFolderID),
              let folderB = storeB.folder(withID: expected.childFolderID),
              folderA.title == concurrentFolderTitle,
              folderB.title == concurrentFolderTitle,
              folderA.parentID == nil,
              folderB.parentID == nil,
              folderA.isFavorite,
              folderB.isFavorite else {
            throw SmokeError.validationFailed(
                "离线并发笔迹、对象字段或文件夹修改没有无损收敛（opA=\(operationsA.count)，opB=\(operationsB.count)，stateA=\(stateA.strokes.count)，stateB=\(stateB.strokes.count)，drawA=\(drawingA.strokes.count)，drawB=\(drawingB.strokes.count)）"
            )
        }

        // Permanent deletion is remove-wins and causal, never a wall-clock race. B publishes an
        // offline rename first; A then collides with that live record using a tombstone. A fresh
        // replica must still see the object as deleted and retain the ledger entry.
        let deletionDocument = try storeA.createCanvas(
            named: "Deletion Conflict",
            in: nil,
            backgroundStyle: .ruled,
            backgroundColor: .ivory
        )
        await coordinatorA.syncNow()
        try requireSuccessfulSync(storeA.cloudSyncStatus, client: "A-delete-seed")
        await coordinatorB.syncNow()
        try requireSuccessfulSync(storeB.cloudSyncStatus, client: "B-delete-seed")
        guard storeB.document(withID: deletionDocument.id) != nil else {
            throw SmokeError.validationFailed("永久删除冲突测试的共同文稿没有下载")
        }

        try storeB.renameDocument(
            deletionDocument.id,
            to: "Deletion Conflict Offline Edit"
        )
        try storeA.moveToTrash(documentID: deletionDocument.id)
        try storeA.permanentlyDelete(documentID: deletionDocument.id)
        await coordinatorB.syncNow()
        try requireSuccessfulSync(storeB.cloudSyncStatus, client: "B-delete-live-edit")
        await coordinatorA.syncNow()
        try requireSuccessfulSync(storeA.cloudSyncStatus, client: "A-delete-tombstone")
        await coordinatorB.syncNow()
        try requireSuccessfulSync(storeB.cloudSyncStatus, client: "B-delete-download")
        await coordinatorA.syncNow()
        try requireSuccessfulSync(storeA.cloudSyncStatus, client: "A-delete-converge")

        let deletionLedgerConverged = [storeA, storeB].allSatisfy { store in
            store.document(withID: deletionDocument.id) == nil
                && store.exportDeletionTombstones().contains(where: {
                    $0.reference.kind == .document
                        && $0.reference.entityID == deletionDocument.id
                        && !$0.stamps.isEmpty
                })
        }
        guard deletionLedgerConverged else {
            throw SmokeError.validationFailed("离线编辑覆盖了永久删除，或因果墓碑没有在两端收敛")
        }

        let defaultsCName = "com.tiyi.note.cloud-smoke.delete-c.\(expected.documentID)"
        let defaultsC = UserDefaults(suiteName: defaultsCName)!
        defaultsC.removePersistentDomain(forName: defaultsCName)
        defer { defaultsC.removePersistentDomain(forName: defaultsCName) }
        let storeC = DrawingDocumentStore(
            userDefaults: defaultsC,
            workspaceDirectoryOverride: clientBWorkspace
                .deletingLastPathComponent()
                .appendingPathComponent("ClientC-Deletion")
        )
        let coordinatorC = CloudLibrarySyncCoordinator(
            dataSource: storeC,
            zoneName: zoneName,
            tokenStore: defaultsC
        )
        await coordinatorC.syncNow()
        try requireSuccessfulSync(storeC.cloudSyncStatus, client: "C-delete-fresh")
        guard storeC.document(withID: deletionDocument.id) == nil,
              storeC.exportDeletionTombstones().contains(where: {
                  $0.reference.kind == .document
                      && $0.reference.entityID == deletionDocument.id
              }) else {
            throw SmokeError.validationFailed("新设备重新下载后复活了已永久删除的文稿")
        }
    }

    private static func validateOwnerShare(
        token: String,
        workspaceDirectory: URL,
        defaults: UserDefaults
    ) async throws {
        let referenceZoneName = "TiyiNoteShareReference-\(token)"
        let store = DrawingDocumentStore(
            userDefaults: defaults,
            workspaceDirectoryOverride: workspaceDirectory
        )
        let personalFolder = try store.createFolder(named: "Personal Share Folder", in: nil)
        let document = try store.createCanvas(
            named: "Share Smoke \(token)",
            in: personalFolder.id,
            backgroundStyle: .grid,
            backgroundColor: .ivory
        )
        let zoneName = CloudLibrarySyncCoordinator.documentShareZoneName(for: document.id)
        do {
            let personalCoordinatorA = CloudLibrarySyncCoordinator(
                dataSource: store,
                zoneName: referenceZoneName,
                tokenStore: defaults
            )
            await personalCoordinatorA.setExcludedDocumentIDs([document.id])
            try await personalCoordinatorA.syncNowOrThrow()

            let preparation = try await CloudDocumentShareService.prepareShare(
                documentID: document.id,
                title: document.title,
                dataSource: store
            )
            // Download the content-only record that the owner just uploaded. It must not replace
            // the owner's personal folder placement.
            try await preparation.syncCoordinator.syncNowOrThrow()
            let ownerOperations = store.exportCollaborationOperations().filter {
                $0.documentID == document.id
            }
            let ownerAcknowledgements = store.exportCollaborationAcknowledgements(
                for: document.id
            )
            guard let ownerAcknowledgement = ownerAcknowledgements.first,
                  ownerOperations.allSatisfy({ operation in
                      ownerAcknowledgement.frontier.contains(operation.stamp.dot)
                  }) else {
                throw SmokeError.validationFailed("owner 没有上传完整的协作 ACK frontier")
            }
            let zones = try await CloudDocumentShareService.discoverSharedZones()
            guard preparation.share.recordID.recordName == CKRecordNameZoneWideShare,
                  preparation.zoneID.zoneName == zoneName,
                  store.document(withID: document.id)?.parentID == personalFolder.id,
                  zones.contains(where: {
                      $0.documentID == document.id
                          && $0.databaseScope == .private
                          && $0.accessLevel == .owner
            }) else {
                throw SmokeError.validationFailed("CKShare owner 区域创建或发现失败")
            }

            // Simulate another owner device. Its private reference arrives before the CKShare
            // content and must remain pending until that content is mounted.
            let defaultsBName = "com.tiyi.note.cloud-smoke.share-b.\(token)"
            let defaultsB = UserDefaults(suiteName: defaultsBName)!
            defaultsB.removePersistentDomain(forName: defaultsBName)
            defer { defaultsB.removePersistentDomain(forName: defaultsBName) }
            let storeB = DrawingDocumentStore(
                userDefaults: defaultsB,
                workspaceDirectoryOverride: workspaceDirectory
                    .deletingLastPathComponent()
                    .appendingPathComponent("ShareOwnerB")
            )
            let personalCoordinatorB = CloudLibrarySyncCoordinator(
                dataSource: storeB,
                zoneName: referenceZoneName,
                tokenStore: defaultsB
            )
            await personalCoordinatorB.setExcludedDocumentIDs([document.id])
            try await personalCoordinatorB.syncNowOrThrow()
            let pendingReferenceURL = workspaceDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("ShareOwnerB")
                .appendingPathComponent("pending-document-references.json")
            guard let pendingData = try? Data(contentsOf: pendingReferenceURL),
                  let pending = try? JSONDecoder().decode(
                      [String: LibraryDocumentReference].self,
                      from: pendingData
                  ),
                  pending[document.id]?.parent.value == personalFolder.id else {
                throw SmokeError.validationFailed("第二设备没有持久化先到达的个人文件夹引用")
            }
            let sharedCoordinatorB = CloudLibrarySyncCoordinator(
                dataSource: storeB,
                zoneName: preparation.zoneID.zoneName,
                ownerName: preparation.zoneID.ownerName,
                databaseScope: .private,
                scopedDocumentID: document.id,
                shouldCreateZone: false,
                reportsStatus: false,
                tokenStore: defaultsB
            )
            try await sharedCoordinatorB.syncNowOrThrow()
            guard storeB.document(withID: document.id)?.parentID == personalFolder.id else {
                let actualParent = storeB.document(withID: document.id)?.parentID ?? "nil"
                let folderExists = storeB.folder(withID: personalFolder.id) != nil
                throw SmokeError.validationFailed(
                    "共享内容覆盖了第二设备的个人文件夹引用（parent=\(actualParent)，folder=\(folderExists)）"
                )
            }

            // Offline changes to different personal fields must both survive one-record sync.
            try store.moveDocument(document.id, to: nil)
            try storeB.setDocumentFavorite(document.id, isFavorite: true)
            try await personalCoordinatorA.syncNowOrThrow()
            try await personalCoordinatorB.syncNowOrThrow()
            try await personalCoordinatorA.syncNowOrThrow()
            try await personalCoordinatorB.syncNowOrThrow()
            guard store.document(withID: document.id)?.parentID == nil,
                  store.document(withID: document.id)?.isFavorite == true,
                  storeB.document(withID: document.id)?.parentID == nil,
                  storeB.document(withID: document.id)?.isFavorite == true else {
                throw SmokeError.validationFailed("个人引用的离线移动和收藏没有无损收敛")
            }

            // A fresh third device proves the reference was not accidentally tombstoned while B
            // had received the reference but had not mounted shared content yet.
            let defaultsCName = "com.tiyi.note.cloud-smoke.share-c.\(token)"
            let defaultsC = UserDefaults(suiteName: defaultsCName)!
            defaultsC.removePersistentDomain(forName: defaultsCName)
            defer { defaultsC.removePersistentDomain(forName: defaultsCName) }
            let storeCWorkspace = workspaceDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("ShareOwnerC")
            let storeC = DrawingDocumentStore(
                userDefaults: defaultsC,
                workspaceDirectoryOverride: storeCWorkspace
            )
            let personalCoordinatorC = CloudLibrarySyncCoordinator(
                dataSource: storeC,
                zoneName: referenceZoneName,
                tokenStore: defaultsC
            )
            await personalCoordinatorC.setExcludedDocumentIDs([document.id])
            try await personalCoordinatorC.syncNowOrThrow()
            let pendingCData = try Data(contentsOf: storeCWorkspace.appendingPathComponent(
                "pending-document-references.json"
            ))
            let pendingC = try JSONDecoder().decode(
                [String: LibraryDocumentReference].self,
                from: pendingCData
            )
            guard pendingC[document.id]?.parent.value == nil,
                  pendingC[document.id]?.favorite.value == true else {
                throw SmokeError.validationFailed("第三设备无法下载最终个人引用，记录可能被误删")
            }

            try await deleteSmokeZone(named: referenceZoneName)
            try await deleteSmokeZone(named: zoneName)
        } catch {
            try? await deleteSmokeZone(named: referenceZoneName)
            try? await deleteSmokeZone(named: zoneName)
            throw error
        }
    }

    private static func makeDrawing(
        offset: CGFloat = 0,
        color: UIColor = .systemRed
    ) -> PKDrawing {
        let points = [
            PKStrokePoint(
                location: CGPoint(x: 20 + offset, y: 30),
                timeOffset: 0,
                size: CGSize(width: 5, height: 5),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ),
            PKStrokePoint(
                location: CGPoint(x: 100 + offset, y: 120),
                timeOffset: 0.2,
                size: CGSize(width: 5, height: 5),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let stroke = PKStroke(ink: PKInk(.pen, color: color), path: path)
        return PKDrawing(strokes: [stroke])
    }

    /// Verifies the container independently of custom-zone APIs and initializes the real folder
    /// record type in a brand-new Development schema. The temporary record is deleted immediately.
    private static func probePrivateDefaultZone(token: String) async throws {
        let database = CKContainer(
            identifier: CloudLibrarySyncCoordinator.containerIdentifier
        ).privateCloudDatabase
        let recordID = CKRecord.ID(recordName: "tiyi-smoke-probe-\(token)")
        let record = CKRecord(recordType: "TiyiFolder", recordID: recordID)
        let now = Date()
        record["entityID"] = recordID.recordName as CKRecordValue
        record["title"] = "Cloud Smoke Probe" as CKRecordValue
        record["createdAt"] = now as CKRecordValue
        record["modifiedAt"] = now as CKRecordValue
        record["isDeleted"] = NSNumber(value: false)
        let acknowledgementID = CKRecord.ID(
            recordName: "tiyi-smoke-acknowledgement-\(token)"
        )
        let acknowledgementRecord = CKRecord(
            recordType: "TiyiAcknowledgement",
            recordID: acknowledgementID
        )
        let acknowledgement = CollaborationAcknowledgement(
            documentID: "smoke-probe",
            participantID: "smoke-probe",
            frontier: CollaborationVersionVector(),
            lastSeenAt: now
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        acknowledgementRecord["entityID"] = "smoke-probe" as CKRecordValue
        acknowledgementRecord["documentID"] = "smoke-probe" as CKRecordValue
        acknowledgementRecord["participantID"] = "smoke-probe" as CKRecordValue
        acknowledgementRecord["acknowledgementPayload"] = try encoder.encode(
            acknowledgement
        ) as CKRecordValue
        acknowledgementRecord["modifiedAt"] = now as CKRecordValue
        acknowledgementRecord["isDeleted"] = NSNumber(value: false)
        let save = try await database.modifyRecords(
            saving: [record, acknowledgementRecord],
            deleting: [],
            savePolicy: .changedKeys,
            atomically: true
        )
        guard let saveResult = save.saveResults[recordID] else {
            throw SmokeError.validationFailed("默认 Zone 没有返回测试记录结果")
        }
        _ = try saveResult.get()
        guard let acknowledgementSaveResult = save.saveResults[acknowledgementID] else {
            throw SmokeError.validationFailed("默认 Zone 没有返回 ACK 测试记录结果")
        }
        _ = try acknowledgementSaveResult.get()

        let deletion = try await database.modifyRecords(
            saving: [],
            deleting: [recordID, acknowledgementID],
            atomically: true
        )
        if let deleteResult = deletion.deleteResults[recordID] {
            try deleteResult.get()
        }
        if let deleteResult = deletion.deleteResults[acknowledgementID] {
            try deleteResult.get()
        }
    }

    private static func makeImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
        return renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
    }

    private static func deleteSmokeZone(named zoneName: String) async throws {
        let container = CKContainer(identifier: CloudLibrarySyncCoordinator.containerIdentifier)
        let zoneID = CKRecordZone.ID(
            zoneName: zoneName,
            ownerName: CKCurrentUserDefaultName
        )
        let result = try await container.privateCloudDatabase.modifyRecordZones(
            saving: [],
            deleting: [zoneID]
        )
        if let deletion = result.deleteResults[zoneID] {
            do {
                try deletion.get()
            } catch let cloudError as CKError where cloudError.code == .zoneNotFound {
                return
            }
        }
    }
}
#endif
