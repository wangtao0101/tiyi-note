#if DEBUG
import OSLog
import PDFKit
import PencilKit
import SwiftUI
import UIKit

struct LibraryFeatureSmokeConfiguration: Hashable {
    static let argument = "--library-smoke"

    let token: String

    init?(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard let index = arguments.firstIndex(of: Self.argument),
              arguments.indices.contains(index + 1) else { return nil }
        let safe = arguments[index + 1].filter { $0.isLetter || $0.isNumber || $0 == "-" }
        guard !safe.isEmpty else { return nil }
        token = String(safe.prefix(48))
    }
}

struct LibraryFeatureSmokeHarnessView: View {
    let configuration: LibraryFeatureSmokeConfiguration
    @State private var result = "正在验证资料库完整能力…"

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Library Feature Smoke")
                .font(.title2.bold())
            Text(result)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .task {
            result = LibraryFeatureSmokeHarness.run(configuration: configuration)
        }
    }
}

@MainActor
private enum LibraryFeatureSmokeHarness {
    private static let logger = Logger(subsystem: "com.tiyi.note", category: "LibrarySmoke")

    private enum SmokeError: LocalizedError {
        case validationFailed(String)

        var errorDescription: String? {
            switch self {
            case .validationFailed(let detail): "资料库验证失败：\(detail)"
            }
        }
    }

    static func run(configuration: LibraryFeatureSmokeConfiguration) -> String {
        let token = configuration.token
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("TiyiNoteLibrarySmoke", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
        let defaultsName = "com.tiyi.note.library-smoke.\(token)"
        let defaults = UserDefaults(suiteName: defaultsName)!

        try? fileManager.removeItem(at: workspace)
        defaults.removePersistentDomain(forName: defaultsName)

        do {
            try validateCollaborationMerge()
            try validateConflictResolution(token: token)
            try validateDocumentReferenceMerge()
            try validateFolderCausalMerge()
            try validateStaleFolderEditorMerge(token: token)
            try validatePrivateDocumentRecordMerge()
            try validatePermanentDeletionLedger(token: token)
            try validatePendingDocumentReference(token: token)
            try validateWorkspaceTransactionRecovery(token: token)
            try validateEditablePackageRoundTrip(token: token)
            try validateAutomaticBackupRecovery(token: token)
            try validateOfflineLastPageRecovery(token: token)
            try validateStaleEditorMerge(token: token)
            try validateSequentialDrawingIdentity(token: token)
            try validateLargeDrawingAppendFastPath(token: token)
            try validateLegacyDecoding()
            try validateCanvasToolsAndLasso()
            try validateScanPDFRenderer()
            try validateAdvancedObjectsAndExports(token: token)
            let store = DrawingDocumentStore(
                userDefaults: defaults,
                workspaceDirectoryOverride: workspace
            )

            let root = try store.createFolder(
                named: "Smoke Root",
                in: nil,
                color: .orange,
                icon: .briefcase
            )
            try store.setFolderFavorite(root.id, isFavorite: true)
            let destination = try store.createFolder(named: "Destination", in: root.id)
            let child = try store.createFolder(named: "Nested", in: root.id)

            var canvases: [PDFWorkspaceDocument] = []
            for (index, style) in CanvasBackgroundStyle.allCases.enumerated() {
                let colors = CanvasBackgroundColor.allCases
                let canvas = try store.createCanvas(
                    named: "Canvas \(style.rawValue)",
                    in: child.id,
                    backgroundStyle: style,
                    backgroundColor: colors[index % colors.count]
                )
                guard canvas.kind == .canvas,
                      store.pageCount(for: canvas.id) == 1,
                      fileManager.fileExists(atPath: canvas.fileURL.path) else {
                    throw SmokeError.validationFailed("画板 PDF 生成失败：\(style.rawValue)")
                }
                canvases.append(canvas)
            }
            guard let primaryCanvas = canvases.last else {
                throw SmokeError.validationFailed("未生成画板")
            }
            try store.setDocumentFavorite(primaryCanvas.id, isFavorite: true)

            guard let originalPage = store.pages(in: primaryCanvas.id).first else {
                throw SmokeError.validationFailed("画板缺少初始页面")
            }
            let insertedPage = try store.insertTemplatePage(
                after: originalPage.id,
                in: primaryCanvas.id,
                style: .ruled,
                color: .ivory,
                size: CGSize(width: 768, height: 1024)
            )
            let duplicatedPage = try store.duplicatePage(
                originalPage.id,
                in: primaryCanvas.id
            )
            try store.movePage(insertedPage.id, to: 0, in: primaryCanvas.id)
            try store.rotatePage(insertedPage.id, clockwise: true, in: primaryCanvas.id)
            try store.setPageBookmark(
                duplicatedPage.id,
                isBookmarked: true,
                in: primaryCanvas.id
            )
            try store.deletePages([originalPage.id], in: primaryCanvas.id)

            let expectedPageIDs: Set<String> = [insertedPage.id, duplicatedPage.id]
            let editedPages = store.pages(in: primaryCanvas.id)
            guard Set(editedPages.map(\.id)) == expectedPageIDs,
                  editedPages.first?.id == insertedPage.id,
                  editedPages.first?.rotation == 90,
                  editedPages.first?.backgroundStyle == .ruled,
                  editedPages.first?.backgroundColor == .ivory,
                  editedPages.last?.id == duplicatedPage.id,
                  editedPages.last?.isBookmarked == true,
                  store.pageCount(for: primaryCanvas.id) == 2,
                  PDFDocument(url: primaryCanvas.fileURL)?.pageCount == 2 else {
                throw SmokeError.validationFailed("页面插入、复制、移动、旋转、书签或删除结果错误")
            }

            let pageOperations = store.exportCollaborationOperations().filter {
                $0.documentID == primaryCanvas.id
            }
            let hasInsertedPosition = pageOperations.contains { operation in
                guard operation.pageID == insertedPage.id else { return false }
                if case .pagePosition = operation.payload { return true }
                return false
            }
            let hasDuplicatedPosition = pageOperations.contains { operation in
                guard operation.pageID == duplicatedPage.id else { return false }
                if case .pagePosition = operation.payload { return true }
                return false
            }
            let hasRotation = pageOperations.contains {
                guard $0.pageID == insertedPage.id,
                      case .metadataSet(let field, _) = $0.payload else { return false }
                return field == "rotation"
            }
            let hasBookmark = pageOperations.contains {
                guard $0.pageID == duplicatedPage.id,
                      case .metadataSet(let field, _) = $0.payload else { return false }
                return field == "isBookmarked"
            }
            let hasDeleteTombstone = pageOperations.contains {
                guard $0.pageID == originalPage.id else { return false }
                if case .pageDelete = $0.payload { return true }
                return false
            }
            guard hasInsertedPosition,
                  hasDuplicatedPosition,
                  hasRotation,
                  hasBookmark,
                  hasDeleteTombstone else {
                throw SmokeError.validationFailed("页面操作没有完整写入协作日志")
            }

            // A page snapshot may arrive after its immutable operations. Replaying the log must
            // restore every causal field, remove a deleted page resurrected by the stale snapshot,
            // and normalize the winning background CKAsset to the CRDT-selected rotation.
            let currentSnapshot = store.exportLibrarySnapshot()
            var stalePages = editedPages
            if let index = stalePages.firstIndex(where: { $0.id == insertedPage.id }) {
                stalePages[index].position = .legacy(orderIndex: 99)
                stalePages[index].rotation = 0
            }
            if let index = stalePages.firstIndex(where: { $0.id == duplicatedPage.id }) {
                stalePages[index].isBookmarked = false
            }
            stalePages.append(originalPage)
            try store.applyRemoteSnapshot(
                LibrarySnapshot(
                    schemaVersion: currentSnapshot.schemaVersion,
                    folders: currentSnapshot.folders,
                    documents: currentSnapshot.documents,
                    pages: stalePages,
                    generatedAt: currentSnapshot.generatedAt
                )
            )
            try store.finalizeRemotePageChanges(for: [primaryCanvas.id])
            let rematerializedPages = store.pages(in: primaryCanvas.id)
            let backgroundReference = LibraryAssetReference(
                documentID: primaryCanvas.id,
                kind: .pageBackground(pageID: insertedPage.id)
            )
            let materializedBackgroundRotation = store.assetURL(for: backgroundReference)
                .flatMap(PDFDocument.init(url:))?
                .page(at: 0)?
                .rotation
            guard Set(rematerializedPages.map(\.id)) == expectedPageIDs,
                  rematerializedPages.first?.id == insertedPage.id,
                  rematerializedPages.first?.rotation == 90,
                  rematerializedPages.last?.id == duplicatedPage.id,
                  rematerializedPages.last?.isBookmarked == true,
                  materializedBackgroundRotation == 90 else {
                throw SmokeError.validationFailed("迟到页面快照覆盖了因果日志或旋转资产")
            }

            guard store.deletedPages(in: primaryCanvas.id).map(\.id) == [originalPage.id] else {
                throw SmokeError.validationFailed("页面回收站没有列出已删除页面")
            }
            try store.restoreDeletedPages([originalPage.id], in: primaryCanvas.id)
            guard store.pages(in: primaryCanvas.id).contains(where: {
                $0.id == originalPage.id
            }), store.pageCount(for: primaryCanvas.id) == 3 else {
                throw SmokeError.validationFailed("页面从协作历史恢复失败")
            }
            try store.deletePages([originalPage.id], in: primaryCanvas.id)
            guard store.pageCount(for: primaryCanvas.id) == 2,
                  store.deletedPages(in: primaryCanvas.id).map(\.id) == [originalPage.id] else {
                throw SmokeError.validationFailed("恢复后的页面无法再次安全删除")
            }

            guard let bundledPDF = Bundle.main.url(forResource: "Congruence", withExtension: "pdf"),
                  let imported = try store.importPDFs(from: [bundledPDF], into: root.id).first else {
                throw SmokeError.validationFailed("PDF 导入失败")
            }
            try store.moveItems(
                folderIDs: [child.id],
                documentIDs: [imported.id],
                to: destination.id
            )
            guard store.folder(withID: child.id)?.parentID == destination.id,
                  store.document(withID: imported.id)?.parentID == destination.id else {
                throw SmokeError.validationFailed("批量移动未原子生效")
            }

            try store.moveToTrash(folderID: child.id)
            guard store.folder(withID: child.id)?.trashedAt != nil,
                  store.document(withID: primaryCanvas.id)?.trashedAt != nil else {
                throw SmokeError.validationFailed("文件夹递归移入回收站失败")
            }
            try store.restore(folderID: child.id)
            guard store.folder(withID: child.id)?.trashedAt == nil,
                  store.document(withID: primaryCanvas.id)?.trashedAt == nil else {
                throw SmokeError.validationFailed("文件夹递归恢复失败")
            }
            try store.setDocumentFavorite(primaryCanvas.id, isFavorite: true)

            let importedURL = imported.fileURL
            try store.moveToTrash(documentID: imported.id)
            try store.permanentlyDelete(documentID: imported.id)
            guard store.document(withID: imported.id) == nil,
                  !fileManager.fileExists(atPath: importedURL.path) else {
                throw SmokeError.validationFailed("永久删除没有清理 PDF")
            }

            let disposableFolder = try store.createFolder(named: "Disposable", in: root.id)
            let disposableCanvas = try store.createCanvas(
                named: "Disposable Canvas",
                in: disposableFolder.id,
                backgroundStyle: .ruled,
                backgroundColor: .ivory
            )
            try store.moveToTrash(folderID: disposableFolder.id)
            try store.emptyTrash()
            guard store.folder(withID: disposableFolder.id) == nil,
                  store.document(withID: disposableCanvas.id) == nil else {
                throw SmokeError.validationFailed("清空回收站失败")
            }

            let reloaded = DrawingDocumentStore(
                userDefaults: defaults,
                workspaceDirectoryOverride: workspace
            )
            guard let reloadedRoot = reloaded.folder(withID: root.id),
                  reloadedRoot.color == .orange,
                  reloadedRoot.icon == .briefcase,
                  reloadedRoot.isFavorite,
                  let reloadedCanvas = reloaded.document(withID: primaryCanvas.id),
                  reloadedCanvas.kind == .canvas,
                  reloadedCanvas.canvasBackgroundStyle == primaryCanvas.canvasBackgroundStyle,
                  reloadedCanvas.canvasBackgroundColor == primaryCanvas.canvasBackgroundColor,
                  reloadedCanvas.isFavorite,
                  reloaded.pageCount(for: primaryCanvas.id) == 2,
                  Set(reloaded.pages(in: primaryCanvas.id).map(\.id)) == expectedPageIDs,
                  reloaded.pages(in: primaryCanvas.id).first?.id == insertedPage.id,
                  reloaded.pages(in: primaryCanvas.id).first?.rotation == 90,
                  reloaded.pages(in: primaryCanvas.id).last?.isBookmarked == true,
                  PDFDocument(url: reloadedCanvas.fileURL)?.pageCount == 2 else {
                throw SmokeError.validationFailed("重启后的模型字段或画板资产丢失")
            }

            try? fileManager.removeItem(at: workspace)
            defaults.removePersistentDomain(forName: defaultsName)
            logger.notice("TIYI_LIBRARY_SMOKE_PASS token=\(token, privacy: .public)")
            return "资料库完整能力测试通过（\(token)）"
        } catch {
            let message = error.localizedDescription
            logger.error(
                "TIYI_LIBRARY_SMOKE_FAIL token=\(token, privacy: .public) error=\(message, privacy: .public)"
            )
            return "资料库测试失败：\(message)"
        }
    }

    private static func validateLegacyDecoding() throws {
        let folderJSON = Data(
            """
            {"id":"legacy-folder","title":"Legacy","parentID":null,"createdAt":0,"modifiedAt":0}
            """.utf8
        )
        let documentJSON = Data(
            """
            {"id":"legacy-document","title":"Legacy.pdf","parentID":null,"fileName":"legacy.pdf","isBundled":false,"createdAt":0,"modifiedAt":0}
            """.utf8
        )
        let decoder = JSONDecoder()
        let folder = try decoder.decode(LibraryFolder.self, from: folderJSON)
        let document = try decoder.decode(LibraryDocumentMetadata.self, from: documentJSON)
        let legacyText = try decoder.decode(
            PageTextPayload.self,
            from: Data(
                """
                {"text":"Legacy Text","fontName":"Serif","fontSize":18,"colorHex":"#112233FF","isBold":true,"alignment":"center"}
                """.utf8
            )
        )
        let encodedElement = try JSONEncoder().encode(
            CanvasPageElement(
                logicalBounds: CGRect(x: 1, y: 2, width: 30, height: 40),
                rotationRadians: 0.4,
                zIndex: 9,
                isLocked: true,
                groupID: UUID(),
                payload: .text(legacyText)
            )
        )
        guard var legacyElementObject = try JSONSerialization.jsonObject(
            with: encodedElement
        ) as? [String: Any] else {
            throw SmokeError.validationFailed("无法构造旧版对象 JSON")
        }
        legacyElementObject.removeValue(forKey: "rotationRadians")
        legacyElementObject.removeValue(forKey: "zIndex")
        legacyElementObject.removeValue(forKey: "isLocked")
        legacyElementObject.removeValue(forKey: "groupID")
        let legacyElement = try decoder.decode(
            CanvasPageElement.self,
            from: JSONSerialization.data(withJSONObject: legacyElementObject)
        )
        guard folder.color == .blue,
              folder.icon == .folder,
              !folder.isFavorite,
              folder.trashedAt == nil,
              document.kind == .pdf,
              document.canvasBackgroundStyle == nil,
              document.canvasBackgroundColor == nil,
              !document.isFavorite,
              document.trashedAt == nil,
              legacyText.isBold,
              !legacyText.isItalic,
              !legacyText.isUnderlined,
              legacyText.alignment == .center,
              legacyElement.rotationRadians == 0,
              legacyElement.zIndex == 0,
              !legacyElement.isLocked,
              legacyElement.groupID == nil else {
            throw SmokeError.validationFailed("旧版 JSON 默认值迁移失败")
        }
    }

    private static func validatePermanentDeletionLedger(token: String) throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("TiyiNoteDeletionLedgerSmoke", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
        let seedURL = base.appendingPathComponent("Seed", isDirectory: true)
        let clientAURL = base.appendingPathComponent("A", isDirectory: true)
        let clientBURL = base.appendingPathComponent("B", isDirectory: true)
        let defaultsNames = [
            "com.tiyi.note.tombstone-smoke.seed.\(token)",
            "com.tiyi.note.tombstone-smoke.a.\(token)",
            "com.tiyi.note.tombstone-smoke.b.\(token)"
        ]
        let defaults = defaultsNames.map { UserDefaults(suiteName: $0)! }
        defer {
            try? fileManager.removeItem(at: base)
            for (index, name) in defaultsNames.enumerated() {
                defaults[index].removePersistentDomain(forName: name)
            }
        }
        try? fileManager.removeItem(at: base)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)

        let seed = DrawingDocumentStore(
            userDefaults: defaults[0],
            workspaceDirectoryOverride: seedURL
        )
        let root = try seed.createFolder(named: "Deleted Root", in: nil)
        let child = try seed.createFolder(named: "Deleted Child", in: root.id)
        let original = try seed.createCanvas(
            named: "Deleted Original",
            in: child.id,
            backgroundStyle: .grid,
            backgroundColor: .ivory
        )
        let concurrentlyDeleted = try seed.createCanvas(
            named: "Both Delete",
            in: nil,
            backgroundStyle: .blank,
            backgroundColor: .white
        )
        try fileManager.copyItem(at: seedURL, to: clientAURL)
        try fileManager.copyItem(at: seedURL, to: clientBURL)

        let storeA = DrawingDocumentStore(
            userDefaults: defaults[1],
            workspaceDirectoryOverride: clientAURL
        )
        let storeB = DrawingDocumentStore(
            userDefaults: defaults[2],
            workspaceDirectoryOverride: clientBURL
        )
        let lateFolder = try storeB.createFolder(named: "Offline Late Child", in: child.id)
        let lateDocument = try storeB.createCanvas(
            named: "Offline Late Document",
            in: lateFolder.id,
            backgroundStyle: .dotted,
            backgroundColor: .green
        )
        try storeB.renameDocument(original.id, to: "Offline Edited Original")
        let staleSnapshot = storeB.exportLibrarySnapshot()

        try storeA.permanentlyDelete(folderID: root.id)
        try storeA.permanentlyDelete(documentID: concurrentlyDeleted.id)
        try storeB.permanentlyDelete(documentID: concurrentlyDeleted.id)
        try storeB.applyRemoteDeletionTombstones(storeA.exportDeletionTombstones())
        try storeA.applyRemoteDeletionTombstones(storeB.exportDeletionTombstones())

        // Replaying a stale live snapshot after the tombstones must not resurrect either the
        // original subtree or the descendant/document created concurrently while offline.
        try storeA.applyRemoteSnapshot(staleSnapshot)
        let tombstonesA = storeA.exportDeletionTombstones()
        let bothDelete = tombstonesA.first {
            $0.reference.kind == .document
                && $0.reference.entityID == concurrentlyDeleted.id
        }
        let expectedDeletedIDs: Set<String> = [
            root.id,
            child.id,
            original.id,
            lateFolder.id,
            lateDocument.id,
            concurrentlyDeleted.id
        ]
        let actualDeletedIDs = Set(tombstonesA.map(\.reference.entityID))
        guard expectedDeletedIDs.isSubset(of: actualDeletedIDs),
              bothDelete?.stamps.count == 2,
              storeA.folder(withID: root.id) == nil,
              storeA.folder(withID: lateFolder.id) == nil,
              storeA.document(withID: original.id) == nil,
              storeA.document(withID: lateDocument.id) == nil,
              storeA.document(withID: concurrentlyDeleted.id) == nil,
              storeB.folder(withID: lateFolder.id) == nil,
              storeB.document(withID: lateDocument.id) == nil else {
            throw SmokeError.validationFailed("永久删除因果墓碑未能删除优先、继承子树或合并并发删除")
        }

        let reloadedA = DrawingDocumentStore(
            userDefaults: defaults[1],
            workspaceDirectoryOverride: clientAURL
        )
        guard reloadedA.folder(withID: root.id) == nil,
              reloadedA.folder(withID: lateFolder.id) == nil,
              reloadedA.document(withID: original.id) == nil,
              reloadedA.document(withID: lateDocument.id) == nil,
              reloadedA.exportDeletionTombstones().contains(where: {
                  $0.reference.entityID == lateDocument.id
              }) else {
            throw SmokeError.validationFailed("永久删除墓碑重启后丢失或旧数据复活")
        }
    }

    private static func validateOfflineLastPageRecovery(token: String) throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("TiyiNoteDeleteMergeSmoke", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
        let seedURL = base.appendingPathComponent("Seed", isDirectory: true)
        let clientAURL = base.appendingPathComponent("A", isDirectory: true)
        let clientBURL = base.appendingPathComponent("B", isDirectory: true)
        let seedDefaultsName = "com.tiyi.note.delete-smoke.seed.\(token)"
        let defaultsAName = "com.tiyi.note.delete-smoke.a.\(token)"
        let defaultsBName = "com.tiyi.note.delete-smoke.b.\(token)"
        let seedDefaults = UserDefaults(suiteName: seedDefaultsName)!
        let defaultsA = UserDefaults(suiteName: defaultsAName)!
        let defaultsB = UserDefaults(suiteName: defaultsBName)!
        defer {
            try? fileManager.removeItem(at: base)
            seedDefaults.removePersistentDomain(forName: seedDefaultsName)
            defaultsA.removePersistentDomain(forName: defaultsAName)
            defaultsB.removePersistentDomain(forName: defaultsBName)
        }
        try? fileManager.removeItem(at: base)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)

        let seed = DrawingDocumentStore(
            userDefaults: seedDefaults,
            workspaceDirectoryOverride: seedURL
        )
        let document = try seed.createCanvas(
            named: "Offline Delete",
            in: nil,
            backgroundStyle: .blank,
            backgroundColor: .white
        )
        guard let firstPage = seed.pages(in: document.id).first else {
            throw SmokeError.validationFailed("离线删除测试缺少初始页")
        }
        let secondPage = try seed.insertTemplatePage(
            after: firstPage.id,
            in: document.id,
            style: .grid,
            color: .ivory,
            size: CGSize(width: 768, height: 1024)
        )
        try fileManager.copyItem(at: seedURL, to: clientAURL)
        try fileManager.copyItem(at: seedURL, to: clientBURL)

        let storeA = DrawingDocumentStore(
            userDefaults: defaultsA,
            workspaceDirectoryOverride: clientAURL
        )
        let storeB = DrawingDocumentStore(
            userDefaults: defaultsB,
            workspaceDirectoryOverride: clientBURL
        )
        try storeA.deletePages([firstPage.id], in: document.id)
        try storeB.deletePages([secondPage.id], in: document.id)

        let offlineOperationsA = storeA.exportCollaborationOperations().filter {
            $0.documentID == document.id
        }
        let offlineOperationsB = storeB.exportCollaborationOperations().filter {
            $0.documentID == document.id
        }
        try storeA.applyRemoteCollaborationOperations(offlineOperationsB)
        try storeB.applyRemoteCollaborationOperations(offlineOperationsA)

        // Exchange the deterministic pageRestore events too, as CloudKit would on the next pass.
        try storeA.applyRemoteCollaborationOperations(
            storeB.exportCollaborationOperations().filter { $0.documentID == document.id }
        )
        try storeB.applyRemoteCollaborationOperations(
            storeA.exportCollaborationOperations().filter { $0.documentID == document.id }
        )
        let pagesA = storeA.pages(in: document.id)
        let pagesB = storeB.pages(in: document.id)
        guard pagesA.count == 1,
              pagesB.count == 1,
              pagesA.first?.id == pagesB.first?.id,
              Set([firstPage.id, secondPage.id]).contains(pagesA[0].id) else {
            throw SmokeError.validationFailed("两个离线端删除不同末页后没有确定性恢复并收敛")
        }
    }

    private static func validateStaleEditorMerge(token: String) throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("TiyiNoteStaleEditorSmoke", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
        let seedURL = base.appendingPathComponent("Seed", isDirectory: true)
        let clientAURL = base.appendingPathComponent("A", isDirectory: true)
        let clientBURL = base.appendingPathComponent("B", isDirectory: true)
        let defaultsNames = [
            "com.tiyi.note.stale-smoke.seed.\(token)",
            "com.tiyi.note.stale-smoke.a.\(token)",
            "com.tiyi.note.stale-smoke.b.\(token)"
        ]
        let defaults = defaultsNames.map { UserDefaults(suiteName: $0)! }
        defer {
            try? fileManager.removeItem(at: base)
            for (index, name) in defaultsNames.enumerated() {
                defaults[index].removePersistentDomain(forName: name)
            }
        }
        try? fileManager.removeItem(at: base)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)

        let seed = DrawingDocumentStore(
            userDefaults: defaults[0],
            workspaceDirectoryOverride: seedURL
        )
        let document = try seed.createCanvas(
            named: "Stale Editor",
            in: nil,
            backgroundStyle: .blank,
            backgroundColor: .white
        )
        let sharedElementID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000111"
        )!
        let baseElement = CanvasPageElement(
            id: sharedElementID,
            logicalBounds: CGRect(x: 20, y: 30, width: 240, height: 80),
            payload: .text(PageTextPayload(text: "Base"))
        )
        let deletedWhileEditingID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000112"
        )!
        let deletedWhileEditingElement = CanvasPageElement(
            id: deletedWhileEditingID,
            logicalBounds: CGRect(x: 20, y: 150, width: 240, height: 80),
            payload: .text(PageTextPayload(text: "Delete Candidate"))
        )
        seed.flush(
            [baseElement, deletedWhileEditingElement],
            forPage: 0,
            in: document.id
        )
        try fileManager.copyItem(at: seedURL, to: clientAURL)
        try fileManager.copyItem(at: seedURL, to: clientBURL)

        let storeA = DrawingDocumentStore(
            userDefaults: defaults[1],
            workspaceDirectoryOverride: clientAURL
        )
        let storeB = DrawingDocumentStore(
            userDefaults: defaults[2],
            workspaceDirectoryOverride: clientBURL
        )
        let visualBaseDrawing = storeA.loadDrawing(forPage: 0, in: document.id)
        let visualBaseElements = storeA.loadPageElements(forPage: 0, in: document.id)
        let visualFrontier = storeA.collaborationFrontier(forPage: 0, in: document.id)

        var remoteElement = baseElement
        remoteElement.payload = .text(PageTextPayload(text: "Remote"))
        storeB.flush(makeSmokeDrawing(offset: 260, color: .systemBlue), forPage: 0, in: document.id)
        // Omitting the second object is a causal remote delete while its editor remains open on A.
        storeB.flush([remoteElement], forPage: 0, in: document.id)

        // A's editor is still showing the old base when B's operations land.
        try storeA.applyRemoteCollaborationOperations(
            storeB.exportCollaborationOperations().filter { $0.documentID == document.id }
        )
        let localDrawing = makeSmokeDrawing(offset: 40, color: .systemGreen)
        var localElement = baseElement
        localElement.payload = .text(PageTextPayload(text: "Local"))
        _ = storeA.scheduleSave(
            localDrawing,
            replacing: visualBaseDrawing,
            causalContext: visualFrontier,
            forPage: 0,
            in: document.id
        )
        _ = storeA.scheduleSave(
            [localElement, deletedWhileEditingElement],
            replacing: visualBaseElements,
            causalContext: visualFrontier,
            forPage: 0,
            in: document.id
        )
        var editedDeletedElement = deletedWhileEditingElement
        editedDeletedElement.payload = .text(PageTextPayload(text: "Edited Before Delete Arrived"))
        _ = storeA.scheduleSave(
            [remoteElement, editedDeletedElement],
            replacing: [remoteElement],
            causalContext: visualFrontier,
            forPage: 0,
            in: document.id
        )
        guard storeA.flushPendingSaves(forPage: 0, in: document.id),
              let pageID = storeA.pageID(at: 0, in: document.id) else {
            throw SmokeError.validationFailed("脏画布合并测试无法落盘")
        }
        let operations = storeA.exportCollaborationOperations().filter {
            $0.documentID == document.id && $0.pageID == pageID
        }
        let state = CollaborationMergeEngine.materialize(operations)
        guard state.strokes.count == 2,
              storeA.loadDrawing(forPage: 0, in: document.id).strokes.count == 2,
              state.elements.count == 1,
              state.conflicts.contains(where: {
                  $0.targetID == sharedElementID.uuidString
              }),
              state.conflicts.contains(where: {
                  $0.targetID == deletedWhileEditingID.uuidString
              }) else {
            throw SmokeError.validationFailed(
                "远端操作落在旧编辑器期间发生误删、静默丢弃或被错误判成因果覆盖"
            )
        }
    }

    private static func makeSmokeDrawing(offset: CGFloat, color: UIColor) -> PKDrawing {
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
        return PKDrawing(strokes: [
            PKStroke(
                ink: PKInk(.pen, color: color),
                path: PKStrokePath(controlPoints: points, creationDate: Date())
            )
        ])
    }

    private static func validateSequentialDrawingIdentity(token: String) throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("TiyiNoteSequentialDrawingSmoke", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
        let defaultsName = "com.tiyi.note.sequential-drawing-smoke.\(token)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        defer {
            try? fileManager.removeItem(at: workspace)
            defaults.removePersistentDomain(forName: defaultsName)
        }

        let store = DrawingDocumentStore(
            userDefaults: defaults,
            workspaceDirectoryOverride: workspace
        )
        let document = try store.createCanvas(
            named: "Sequential Apple Pencil Saves",
            in: nil,
            backgroundStyle: .blank,
            backgroundColor: .white
        )
        guard let pageID = store.pageID(at: 0, in: document.id) else {
            throw SmokeError.validationFailed("连续笔迹测试缺少页面")
        }

        let expectedStrokeCount = 8
        var submittedDrawing = PKDrawing()
        var context = store.collaborationFrontier(forPage: 0, in: document.id)
        for index in 0..<expectedStrokeCount {
            let stroke = makeNormalizationSensitiveStroke(index: index)
            let desiredDrawing = PKDrawing(strokes: submittedDrawing.strokes + [stroke])
            context = store.scheduleSave(
                desiredDrawing,
                replacing: submittedDrawing,
                causalContext: context,
                assumesOnlyAppendedStrokes: true,
                forPage: 0,
                in: document.id
            )
            submittedDrawing = desiredDrawing
        }
        guard store.flushPendingSaves(forPage: 0, in: document.id) else {
            throw SmokeError.validationFailed("连续笔迹测试无法落盘")
        }

        let operations = store.exportCollaborationOperations().filter {
            $0.documentID == document.id && $0.pageID == pageID
        }
        let strokeUpserts = operations.compactMap { operation -> CollaborationInkStroke? in
            guard case .strokeUpsert(let stroke) = operation.payload else { return nil }
            return stroke
        }
        let state = CollaborationMergeEngine.materialize(operations)
        let idsByZIndex = Dictionary(grouping: strokeUpserts, by: \.zIndex)
            .mapValues { Set($0.map(\.id)) }
        let materializedIDs = Set(state.strokes.keys)
        guard strokeUpserts.count == expectedStrokeCount,
              Set(strokeUpserts.map(\.id)).count == expectedStrokeCount,
              idsByZIndex.count == expectedStrokeCount,
              idsByZIndex.values.allSatisfy({ $0.count == 1 }),
              state.strokes.count == expectedStrokeCount,
              store.debugAppendOnlyDrawingSaveCount == expectedStrokeCount,
              store.debugFullDrawingDiffSaveCount == 0,
              store.loadDrawing(forPage: 0, in: document.id).strokes.count
                  == expectedStrokeCount else {
            throw SmokeError.validationFailed(
                "连续保存没有保持增量路径，或把旧笔迹重复分配 ID："
                    + "upsert=\(strokeUpserts.count)，"
                    + "append=\(store.debugAppendOnlyDrawingSaveCount)，"
                    + "full=\(store.debugFullDrawingDiffSaveCount)，"
                    + "state=\(state.strokes.count)"
            )
        }

        let reloaded = DrawingDocumentStore(
            userDefaults: defaults,
            workspaceDirectoryOverride: workspace
        )
        let reloadedOperations = reloaded.exportCollaborationOperations().filter {
            $0.documentID == document.id && $0.pageID == pageID
        }
        let reloadedState = CollaborationMergeEngine.materialize(reloadedOperations)
        guard Set(reloadedState.strokes.keys) == materializedIDs,
              reloadedState.strokes.count == expectedStrokeCount,
              reloaded.loadDrawing(forPage: 0, in: document.id).strokes.count
                  == expectedStrokeCount else {
            throw SmokeError.validationFailed("连续笔迹重启后 ID 或内容不稳定")
        }
    }

    private static func makeNormalizationSensitiveStroke(index: Int) -> PKStroke {
        let xOffset = CGFloat(index) * 37.129_731
        let yOffset = CGFloat(index % 3) * 41.713_619
        let points = (0..<74).map { sample in
            let progress = CGFloat(sample) / 73
            return PKStrokePoint(
                location: CGPoint(
                    x: 18.317_429 + xOffset + progress * 96.583_217,
                    y: 27.913_683 + yOffset + sin(progress * .pi * 2) * 13.719_381
                ),
                timeOffset: sample < 37
                    ? TimeInterval(sample) * 0.011_731
                    : 1.379 + TimeInterval(sample - 37) * 0.010_913,
                size: CGSize(
                    width: 3.413_729 + progress * 1.271_933,
                    height: 3.193_117 + progress * 1.117_291
                ),
                opacity: 0.917_319 + progress * 0.071_337,
                force: 0.231_719 + progress * 0.617_293,
                azimuth: 0.173_119 + progress * 0.319_731,
                altitude: 0.713_179 + progress * 0.271_933
            )
        }
        return PKStroke(
            ink: PKInk(.pen, color: UIColor(red: 0.08, green: 0.12, blue: 0.18, alpha: 1)),
            path: PKStrokePath(
                controlPoints: points,
                creationDate: Date(timeIntervalSince1970: 1_725_408_000 + TimeInterval(index))
            )
        )
    }

    private static func validateLargeDrawingAppendFastPath(token: String) throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("TiyiNoteLargeDrawingAppendSmoke", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
        let defaultsName = "com.tiyi.note.large-drawing-append-smoke.\(token)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        defer {
            try? fileManager.removeItem(at: workspace)
            defaults.removePersistentDomain(forName: defaultsName)
        }

        let store = DrawingDocumentStore(
            userDefaults: defaults,
            workspaceDirectoryOverride: workspace
        )
        let document = try store.createCanvas(
            named: "Large Drawing Append",
            in: nil,
            backgroundStyle: .blank,
            backgroundColor: .white
        )
        let initialStrokeCount = 240
        let initialStrokes = (0..<initialStrokeCount).flatMap { index in
            makeSmokeDrawing(
                offset: CGFloat(index) * 2.125,
                color: UIColor(
                    hue: CGFloat(index % 17) / 17,
                    saturation: 0.72,
                    brightness: 0.68,
                    alpha: 1
                )
            ).strokes
        }
        let initialDrawing = PKDrawing(strokes: initialStrokes)
        let initialInteractionID = UUID()
        store.setDrawingInteractionActive(true, id: initialInteractionID)
        _ = store.scheduleSave(
            initialDrawing,
            replacing: PKDrawing(),
            causalContext: store.collaborationFrontier(forPage: 0, in: document.id),
            assumesOnlyAppendedStrokes: true,
            forPage: 0,
            in: document.id
        )
        guard store.flushPendingSaves(forPage: 0, in: document.id) else {
            throw SmokeError.validationFailed("大日志基线无法落盘")
        }
        store.setDrawingInteractionActive(false, id: initialInteractionID)

        let reloaded = DrawingDocumentStore(
            userDefaults: defaults,
            workspaceDirectoryOverride: workspace
        )
        let baseDrawing = reloaded.loadDrawing(forPage: 0, in: document.id)
        let appendedStrokeCount = 6
        let appendedStrokes = (0..<appendedStrokeCount).flatMap { index in
            makeSmokeDrawing(
                offset: 700 + CGFloat(index) * 13,
                color: UIColor(red: 0.12, green: 0.24, blue: 0.72, alpha: 1)
            ).strokes
        }
        let desiredDrawing = PKDrawing(strokes: baseDrawing.strokes + appendedStrokes)
        let interactionID = UUID()
        reloaded.setDrawingInteractionActive(true, id: interactionID)
        _ = reloaded.scheduleSave(
            desiredDrawing,
            replacing: baseDrawing,
            causalContext: reloaded.collaborationFrontier(forPage: 0, in: document.id),
            assumesOnlyAppendedStrokes: true,
            forPage: 0,
            in: document.id
        )

        guard let pageID = reloaded.pageID(at: 0, in: document.id) else {
            throw SmokeError.validationFailed("大日志增量测试缺少页面")
        }
        let pendingOperations = reloaded.exportCollaborationOperations().filter {
            $0.documentID == document.id && $0.pageID == pageID
        }
        let pendingStrokeUpsertCount = pendingOperations.reduce(into: 0) { count, operation in
            if case .strokeUpsert = operation.payload { count += 1 }
        }
        let pendingDeleteCount = pendingOperations.reduce(into: 0) { count, operation in
            if case .strokeDelete = operation.payload { count += 1 }
        }
        guard reloaded.debugAppendOnlyDrawingSaveCount == 1,
              reloaded.debugFullDrawingDiffSaveCount == 0,
              pendingStrokeUpsertCount == initialStrokeCount + appendedStrokeCount,
              pendingDeleteCount == 0 else {
            throw SmokeError.validationFailed("大日志新增笔画退回了全量指纹或产生误删除")
        }

        guard reloaded.flushPendingSaves(forPage: 0, in: document.id) else {
            throw SmokeError.validationFailed("大日志增量无法落盘")
        }
        reloaded.setDrawingInteractionActive(false, id: interactionID)
        let verified = DrawingDocumentStore(
            userDefaults: defaults,
            workspaceDirectoryOverride: workspace
        )
        guard verified.loadDrawing(forPage: 0, in: document.id).strokes.count
                == initialStrokeCount + appendedStrokeCount else {
            throw SmokeError.validationFailed("大日志增量重启后丢失")
        }
    }

    private enum ExportPixelProbe {
        case saturated
    }

    private static func containsExportPixels(
        _ image: UIImage,
        logicalRect: CGRect,
        logicalPageSize: CGSize,
        probe: ExportPixelProbe,
        minimumPixelCount: Int = 24
    ) -> Bool {
        guard logicalPageSize.width > 0,
              logicalPageSize.height > 0,
              let cgImage = image.cgImage else { return false }

        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return false }
        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let scaleX = CGFloat(width) / logicalPageSize.width
        let scaleY = CGFloat(height) / logicalPageSize.height
        let topLeftRect = CGRect(
            x: logicalRect.minX * scaleX,
            y: logicalRect.minY * scaleY,
            width: logicalRect.width * scaleX,
            height: logicalRect.height * scaleY
        ).intersection(CGRect(x: 0, y: 0, width: width, height: height))

        func matchingPixelCount(in rect: CGRect) -> Int {
            let minX = max(0, Int(rect.minX.rounded(.down)))
            let maxX = min(width, Int(rect.maxX.rounded(.up)))
            let minY = max(0, Int(rect.minY.rounded(.down)))
            let maxY = min(height, Int(rect.maxY.rounded(.up)))
            guard minX < maxX, minY < maxY else { return 0 }

            var count = 0
            for y in minY..<maxY {
                for x in minX..<maxX {
                    let index = (y * width + x) * 4
                    let red = Int(pixels[index])
                    let green = Int(pixels[index + 1])
                    let blue = Int(pixels[index + 2])
                    let matches = switch probe {
                    case .saturated:
                        max(red, green, blue) >= 100
                            && max(red, green, blue) - min(red, green, blue) >= 48
                    }
                    if matches {
                        count += 1
                    }
                }
            }
            return count
        }

        // UIImage and PDFKit can expose opposite row origins while retaining an `.up`
        // orientation. Probe both representations so this verifies content rather than a
        // framework-specific bitmap convention.
        let verticallyFlippedRect = CGRect(
            x: topLeftRect.minX,
            y: CGFloat(height) - topLeftRect.maxY,
            width: topLeftRect.width,
            height: topLeftRect.height
        )
        return max(
            matchingPixelCount(in: topLeftRect),
            matchingPixelCount(in: verticallyFlippedRect)
        ) >= minimumPixelCount
    }

    private static func validateCanvasToolsAndLasso() throws {
        let controller = CanvasController()
        let first = makeSmokeDrawing(offset: 0, color: .systemBlue)
        let second = makeSmokeDrawing(offset: 300, color: .systemGreen)
        controller.installInitialDrawing(
            PKDrawing(strokes: first.strokes + second.strokes)
        )

        let lassoPolygon = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 180, y: 0),
            CGPoint(x: 180, y: 180),
            CGPoint(x: 0, y: 180)
        ]
        let selected = controller.strokeIndices(inside: lassoPolygon)
        guard selected == [0],
              let selectedBounds = controller.boundsForStrokes(at: selected),
              !selectedBounds.isNull,
              controller.drawingForStrokes(at: selected, normalized: true).strokes.count == 1 else {
            throw SmokeError.validationFailed("套索命中测试或笔迹归一化失败")
        }

        let duplicated = controller.duplicateStrokes(
            at: selected,
            offset: CGSize(width: 20, height: 25),
            within: CGSize(width: 700, height: 900)
        )
        guard duplicated == [2], controller.drawing.strokes.count == 3 else {
            throw SmokeError.validationFailed("套索复制没有生成独立笔迹")
        }

        let boundsBeforeMove = controller.drawing.strokes[0].renderBounds
        let centerBeforeMove = CGPoint(x: boundsBeforeMove.midX, y: boundsBeforeMove.midY)
        controller.beginTransformingStrokes(at: [0])
        controller.previewStrokeTransform(
            CGAffineTransform(translationX: 35, y: 18)
        )
        controller.commitStrokeTransform(
            CGAffineTransform(translationX: 35, y: 18),
            actionName: "Smoke Move"
        )
        let boundsAfterMove = controller.drawing.strokes[0].renderBounds
        let centerAfterMove = CGPoint(x: boundsAfterMove.midX, y: boundsAfterMove.midY)
        guard abs(centerAfterMove.x - centerBeforeMove.x - 35) < 0.5,
              abs(centerAfterMove.y - centerBeforeMove.y - 18) < 0.5 else {
            throw SmokeError.validationFailed("套索变换没有提交到 PencilKit")
        }

        let normalizedCopy = controller.drawingForStrokes(at: [0], normalized: true)
        let pasted = controller.pasteDrawing(
            normalizedCopy,
            centeredAt: CGPoint(x: 500, y: 650),
            within: CGSize(width: 700, height: 900)
        )
        guard pasted == [3], controller.drawing.strokes.count == 4 else {
            throw SmokeError.validationFailed("笔迹拷贝/粘贴原语失败")
        }

        controller.updateTool(
            kind: .pen,
            color: .graphite,
            width: 1,
            eraserSize: .small,
            eraserMode: .precision
        )
        guard (controller.canvasView.tool as? PKInkingTool)?.inkType == .monoline else {
            throw SmokeError.validationFailed("圆珠笔没有配置为不透明 monoline")
        }
        controller.updateTool(
            kind: .fountainPen,
            color: .ocean,
            width: 5,
            eraserSize: .small,
            eraserMode: .precision
        )
        guard (controller.canvasView.tool as? PKInkingTool)?.inkType == .fountainPen else {
            throw SmokeError.validationFailed("钢笔工具配置失败")
        }
        controller.updateTool(
            kind: .pencil,
            color: .iris,
            width: 6,
            eraserSize: .medium,
            eraserMode: .precision
        )
        guard (controller.canvasView.tool as? PKInkingTool)?.inkType == .pencil else {
            throw SmokeError.validationFailed("铅笔工具配置失败")
        }
        controller.updateTool(
            kind: .marker,
            color: .amber,
            width: 18,
            eraserSize: .medium,
            eraserMode: .precision
        )
        guard (controller.canvasView.tool as? PKInkingTool)?.inkType == .marker else {
            throw SmokeError.validationFailed("荧光笔工具配置失败")
        }
        controller.updateTool(
            kind: .eraser,
            color: .graphite,
            width: 4,
            eraserSize: .large,
            eraserMode: .precision
        )
        guard let precisionEraser = controller.canvasView.tool as? PKEraserTool,
              precisionEraser.eraserType == .fixedWidthBitmap,
              precisionEraser.width == CanvasEraserSize.large.width else {
            throw SmokeError.validationFailed("精细橡皮擦尺寸配置失败")
        }
        controller.updateTool(
            kind: .eraser,
            color: .graphite,
            width: 4,
            eraserSize: .small,
            eraserMode: .stroke
        )
        guard (controller.canvasView.tool as? PKEraserTool)?.eraserType == .vector else {
            throw SmokeError.validationFailed("整笔橡皮擦配置失败")
        }
        controller.updateTool(
            kind: .lasso,
            color: .graphite,
            width: 4,
            eraserSize: .small,
            eraserMode: .stroke
        )
        guard controller.canvasView.tool is PKLassoTool,
              !controller.canvasView.drawingGestureRecognizer.isEnabled else {
            throw SmokeError.validationFailed("套索工具没有接管绘图手势")
        }
    }

    private static func validateScanPDFRenderer() throws {
        func image(size: CGSize, color: UIColor) -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(size: size, format: format).image { context in
                color.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                UIColor.white.setStroke()
                let inset = CGRect(origin: .zero, size: size).insetBy(dx: 12, dy: 12)
                context.cgContext.stroke(inset, width: 4)
            }
        }

        let portrait = image(size: CGSize(width: 300, height: 500), color: .systemBlue)
        let landscape = image(size: CGSize(width: 500, height: 300), color: .systemOrange)
        let data = DocumentScanPDFRenderer.makePDFData(images: [portrait, landscape])
        let cropped = PageImageCropRenderer.crop(
            portrait,
            leftTrim: 0.25,
            rightTrim: 0.25,
            topTrim: 0.2,
            bottomTrim: 0.2
        )
        let scanDocument = PDFDocument(data: data)
        let portraitBounds = scanDocument?.page(at: 0)?.bounds(for: .mediaBox)
        let landscapeBounds = scanDocument?.page(at: 1)?.bounds(for: .mediaBox)
        guard !data.isEmpty,
              scanDocument?.pageCount == 2,
              let portraitBounds,
              let landscapeBounds,
              portraitBounds.height > portraitBounds.width,
              landscapeBounds.width > landscapeBounds.height,
              cropped?.cgImage?.width == 150,
              cropped?.cgImage?.height == 300,
              DocumentScanPDFRenderer.makePDFData(images: []).isEmpty else {
            let cropSize = cropped?.cgImage.map { "\($0.width)x\($0.height)" } ?? "nil"
            throw SmokeError.validationFailed(
                "扫描 PDF 方向或图片裁剪结果错误（portrait=\(String(describing: portraitBounds))，landscape=\(String(describing: landscapeBounds))，crop=\(cropSize)）"
            )
        }
    }

    private static func validateAdvancedObjectsAndExports(token: String) throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("TiyiNoteAdvancedSmoke", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
        let defaultsName = "com.tiyi.note.advanced-smoke.\(token)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        defer {
            try? fileManager.removeItem(at: workspace)
            defaults.removePersistentDomain(forName: defaultsName)
        }

        let store = DrawingDocumentStore(
            userDefaults: defaults,
            workspaceDirectoryOverride: workspace
        )
        let document = try store.createCanvas(
            named: "Advanced Objects",
            in: nil,
            backgroundStyle: .grid,
            backgroundColor: .ivory
        )
        let groupID = UUID()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 180, height: 120)).image {
            context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 180, height: 120))
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 36, y: 24, width: 108, height: 72))
        }
        guard let pngData = image.pngData() else {
            throw SmokeError.validationFailed("高级对象测试图片无法编码")
        }

        var expectedElements = [
            CanvasPageElement(
                logicalBounds: CGRect(x: 42, y: 55, width: 260, height: 110),
                rotationRadians: 0.08,
                zIndex: 2,
                isLocked: true,
                groupID: groupID,
                payload: .text(
                    PageTextPayload(
                        text: "Styled collaborative text",
                        fontName: PageTextFontPreset.serif.rawValue,
                        fontSize: 31,
                        colorHex: InkPaletteColor.coral.rgbaHex,
                        isBold: true,
                        isItalic: true,
                        isUnderlined: true,
                        alignment: .center
                    )
                )
            ),
            CanvasPageElement(
                logicalBounds: CGRect(x: 320, y: 80, width: 190, height: 126),
                rotationRadians: -0.12,
                zIndex: 3,
                groupID: groupID,
                payload: .image(PageImagePayload(pngData: pngData, opacity: 0.42))
            ),
            CanvasPageElement(
                logicalBounds: CGRect(x: 90, y: 250, width: 210, height: 150),
                zIndex: 4,
                payload: .shape(
                    PageShapePayload(
                        kind: .triangle,
                        strokeColorHex: InkPaletteColor.ocean.rgbaHex,
                        fillColorHex: InkPaletteColor.amber.rgbaHex,
                        lineWidth: 7.5,
                        isDashed: true
                    )
                )
            ),
            CanvasPageElement(
                logicalBounds: CGRect(x: 335, y: 260, width: 170, height: 170),
                rotationRadians: 0.2,
                zIndex: 5,
                payload: .shape(
                    PageShapePayload(
                        kind: .diamond,
                        strokeColorHex: InkPaletteColor.forest.rgbaHex,
                        fillColorHex: InkPaletteColor.iris.rgbaHex,
                        lineWidth: 4,
                        isDashed: false
                    )
                )
            )
        ]
        store.flush(expectedElements, forPage: 0, in: document.id)
        store.flush(makeSmokeDrawing(offset: 130, color: .systemPurple), forPage: 0, in: document.id)
        let drawingBeforeTransform = store.loadDrawing(forPage: 0, in: document.id)
        let drawingAfterTransform = drawingBeforeTransform.transformed(
            using: CGAffineTransform(translationX: 24, y: 17)
        )
        _ = store.scheduleSave(
            drawingAfterTransform,
            replacing: drawingBeforeTransform,
            causalContext: store.collaborationFrontier(forPage: 0, in: document.id),
            forPage: 0,
            in: document.id
        )
        guard store.flushPendingSaves(forPage: 0, in: document.id) else {
            throw SmokeError.validationFailed("变换后的稳定笔迹无法落盘")
        }

        expectedElements[0].logicalBounds = expectedElements[0].logicalBounds.offsetBy(
            dx: 18,
            dy: 9
        )
        if case .image(var imagePayload) = expectedElements[1].payload {
            imagePayload.opacity = 0.58
            expectedElements[1].payload = .image(imagePayload)
        }
        store.flush(expectedElements, forPage: 0, in: document.id)

        let operations = store.exportCollaborationOperations().filter {
            $0.documentID == document.id
        }
        let emittedPatchFields = operations.compactMap { operation -> Set<CollaborationElementField>? in
            guard case .elementPatch(_, let fields) = operation.payload else { return nil }
            return fields
        }
        let strokeIDs = Set(operations.compactMap { operation -> String? in
            guard case .strokeUpsert(let stroke) = operation.payload else { return nil }
            return stroke.id
        })
        let materializedState = CollaborationMergeEngine.materialize(operations)
        guard emittedPatchFields.contains([.logicalBounds]),
              emittedPatchFields.contains([.payload]),
              strokeIDs.count == 1,
              materializedState.strokes.count == 1,
              store.loadPageElements(forPage: 0, in: document.id) == expectedElements else {
            throw SmokeError.validationFailed("高级对象字段补丁或变换笔迹稳定 ID 失败")
        }

        guard let sourcePageID = store.pages(in: document.id).first?.id else {
            throw SmokeError.validationFailed("页面复制测试缺少源页面")
        }
        let duplicatedPage = try store.duplicatePage(sourcePageID, in: document.id)
        guard let duplicatedPageIndex = store.pages(in: document.id).firstIndex(where: {
            $0.id == duplicatedPage.id
        }) else {
            throw SmokeError.validationFailed("复制页面没有稳定索引")
        }
        let duplicatedBaseDrawing = store.loadDrawing(
            forPage: duplicatedPageIndex,
            in: document.id
        )
        let duplicatedEditedDrawing = PKDrawing(
            strokes: duplicatedBaseDrawing.strokes
                + makeSmokeDrawing(offset: 360, color: .systemGreen).strokes
        )
        _ = store.scheduleSave(
            duplicatedEditedDrawing,
            replacing: duplicatedBaseDrawing,
            causalContext: store.collaborationFrontier(
                forPage: duplicatedPageIndex,
                in: document.id
            ),
            forPage: duplicatedPageIndex,
            in: document.id
        )
        guard store.flushPendingSaves(forPage: duplicatedPageIndex, in: document.id) else {
            throw SmokeError.validationFailed("复制页面第一次编辑无法落盘")
        }
        let duplicatedOperations = store.exportCollaborationOperations().filter {
            $0.documentID == document.id && $0.pageID == duplicatedPage.id
        }
        let duplicatedState = CollaborationMergeEngine.materialize(duplicatedOperations)
        guard duplicatedState.strokes.count == 2,
              duplicatedOperations.filter({ $0.id.hasPrefix("bootstrap-") }).count == 1 else {
            throw SmokeError.validationFailed("复制页面未建立确定性的笔迹协作基线")
        }

        let reloaded = DrawingDocumentStore(
            userDefaults: defaults,
            workspaceDirectoryOverride: workspace
        )
        guard reloaded.loadPageElements(forPage: 0, in: document.id) == expectedElements,
              reloaded.loadDrawing(forPage: 0, in: document.id).strokes.count == 1,
              reloaded.loadDrawing(forPage: 1, in: document.id).strokes.count == 2 else {
            throw SmokeError.validationFailed("高级对象或专业笔刷内容重启后丢失")
        }

        let flattenedURL = try reloaded.exportFlattenedPDF(documentID: document.id)
        guard let flattened = PDFDocument(url: flattenedURL),
              flattened.pageCount == reloaded.pageCount(for: document.id),
              (try Data(contentsOf: flattenedURL)).count > 1_000,
              UIPrintInteractionController.canPrint(flattenedURL) else {
            throw SmokeError.validationFailed("扁平 PDF 不完整或系统打印链路无法接受")
        }

        let imageURLs = try reloaded.exportPageImages(documentID: document.id)
        guard imageURLs.count == reloaded.pageCount(for: document.id),
              try imageURLs.allSatisfy({ url in
                  let data = try Data(contentsOf: url)
                  return data.count > 1_000 && UIImage(data: data) != nil
              }) else {
            throw SmokeError.validationFailed("逐页 PNG 导出不完整")
        }

        let logicalPageSize = reloaded.pageSize(at: 0, in: document.id)
        let imageProbe = CGRect(x: 390, y: 115, width: 50, height: 50)
        let shapeProbe = CGRect(x: 385, y: 310, width: 70, height: 70)
        let inkProbe = CGRect(x: 178, y: 58, width: 62, height: 62)
        let textProbe = CGRect(x: 68, y: 78, width: 72, height: 54)
        let contentProbes = [imageProbe, shapeProbe, inkProbe]
        guard let flattenedFirstPage = flattened.page(at: 0),
              let exportedPageImage = UIImage(contentsOfFile: imageURLs[0].path) else {
            throw SmokeError.validationFailed("导出的 PDF 或首图无法解码")
        }
        let flattenedPreview = flattenedFirstPage.thumbnail(
            of: logicalPageSize,
            for: .mediaBox
        )
        let pdfContentResults = contentProbes.map { probe in
            containsExportPixels(
                flattenedPreview,
                logicalRect: probe,
                logicalPageSize: logicalPageSize,
                probe: .saturated
            )
        }
        let pngContentResults = contentProbes.map { probe in
            containsExportPixels(
                exportedPageImage,
                logicalRect: probe,
                logicalPageSize: logicalPageSize,
                probe: .saturated
            )
        }
        let pdfTextResult = containsExportPixels(
            flattenedPreview,
            logicalRect: textProbe,
            logicalPageSize: logicalPageSize,
            probe: .saturated,
            minimumPixelCount: 120
        )
        let pngTextResult = containsExportPixels(
            exportedPageImage,
            logicalRect: textProbe,
            logicalPageSize: logicalPageSize,
            probe: .saturated,
            minimumPixelCount: 120
        )
        guard pdfContentResults.allSatisfy({ $0 }),
              pngContentResults.allSatisfy({ $0 }),
              pdfTextResult,
              pngTextResult else {
            throw SmokeError.validationFailed(
                "PDF 或逐页 PNG 没有真实渲染文字、图片、图形和笔迹"
                    + "（pdf=\(pdfContentResults)/\(pdfTextResult)，"
                    + "png=\(pngContentResults)/\(pngTextResult)）"
            )
        }

        let packageData = try reloaded.editableDocumentPackageData(documentID: document.id)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let package = try decoder.decode(EditableDocumentPackage.self, from: packageData)
        guard package.pageAssets.count == reloaded.pageCount(for: document.id),
              let elementsData = package.pageAssets.first?.elementsData,
              let archive = try? JSONDecoder().decode(
                  CanvasPageElementsArchive.self,
                  from: elementsData
              ),
              archive.elements == expectedElements,
              package.pageAssets.first?.operations.contains(where: {
                  if case .elementPatch = $0.payload { return true }
                  return false
              }) == true else {
            throw SmokeError.validationFailed("可编辑包没有保留对象、分组或协作补丁")
        }
    }

    private static func validateCollaborationMerge() throws {
        let workspaceID = "smoke-workspace"
        let documentID = "smoke-document"
        let pageID = "smoke-page"
        let sharedElementID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

        func textElement(id: UUID, text: String) -> CanvasPageElement {
            CanvasPageElement(
                id: id,
                logicalBounds: CGRect(x: 10, y: 20, width: 200, height: 80),
                payload: .text(PageTextPayload(text: text))
            )
        }

        func operation(
            clock: inout CollaborationReplicaClock,
            operationID: String,
            payload: CollaborationOperationPayload,
            createdAt: Date = Date()
        ) -> CollaborationOperation {
            CollaborationOperation(
                workspaceID: workspaceID,
                documentID: documentID,
                pageID: pageID,
                stamp: clock.nextStamp(operationID: operationID, createdAt: createdAt),
                payload: payload
            )
        }

        let left = CollaborativePosition.legacy(orderIndex: 0)
        let right = CollaborativePosition.legacy(orderIndex: 1)
        let insertedA = CollaborativePosition.between(
            left,
            right,
            actorID: "actor-a",
            sequence: 1
        )
        let insertedB = CollaborativePosition.between(
            left,
            right,
            actorID: "actor-b",
            sequence: 1
        )
        let concurrentPositions = [insertedB, insertedA].sorted()
        guard insertedA != insertedB,
              left < concurrentPositions[0],
              concurrentPositions[1] < right else {
            throw SmokeError.validationFailed("并发页序没有产生稳定顺序")
        }
        let betweenConcurrent = CollaborativePosition.between(
            concurrentPositions[0],
            concurrentPositions[1],
            actorID: "actor-c",
            sequence: 1
        )
        guard concurrentPositions[0] < betweenConcurrent,
              betweenConcurrent < concurrentPositions[1] else {
            throw SmokeError.validationFailed("冲突页序之间无法继续插页")
        }

        var clockA = CollaborationReplicaClock(actorID: "actor-a")
        var clockB = CollaborationReplicaClock(actorID: "actor-b")
        let editA = operation(
            clock: &clockA,
            operationID: "edit-a",
            payload: .elementUpsert(textElement(id: sharedElementID, text: "A")),
            createdAt: .distantFuture
        )
        let editB = operation(
            clock: &clockB,
            operationID: "edit-b",
            payload: .elementUpsert(textElement(id: sharedElementID, text: "B")),
            createdAt: .distantPast
        )
        let mergeAB = CollaborationMergeEngine.materialize([editA, editB])
        let mergeBA = CollaborationMergeEngine.materialize([editB, editA, editA])
        guard mergeAB == mergeBA,
              mergeAB.elements.count == 1,
              mergeAB.conflicts.count == 1 else {
            throw SmokeError.validationFailed("对象并发合并不满足交换律或幂等性")
        }

        let malformedA = CollaborationOperation(
            workspaceID: workspaceID,
            documentID: documentID,
            pageID: pageID,
            stamp: editA.stamp,
            payload: .elementUpsert(textElement(id: sharedElementID, text: "损坏副本 A"))
        )
        let malformedB = CollaborationOperation(
            workspaceID: workspaceID,
            documentID: documentID,
            pageID: pageID,
            stamp: editA.stamp,
            payload: .elementUpsert(textElement(id: sharedElementID, text: "损坏副本 B"))
        )
        guard CollaborationMergeEngine.materialize([malformedA, malformedB])
            == CollaborationMergeEngine.materialize([malformedB, malformedA, malformedB]) else {
            throw SmokeError.validationFailed("重复 operationID 的异常载荷依赖到达顺序")
        }

        let secondElementID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let independentEdit = operation(
            clock: &clockA,
            operationID: "edit-independent",
            payload: .elementUpsert(textElement(id: secondElementID, text: "独立对象"))
        )
        let independentMerge = CollaborationMergeEngine.materialize([editA, independentEdit, editB])
        guard independentMerge.elements.count == 2 else {
            throw SmokeError.validationFailed("不同对象的并发编辑发生了覆盖")
        }

        // New clients emit field patches. Moving an object and editing its payload are independent
        // registers, so they must merge without manufacturing a conflict or trusting device time.
        let patchedElementID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000020"
        )!
        var patchSeedClock = CollaborationReplicaClock(actorID: "patch-seed")
        let patchBaseElement = CanvasPageElement(
            id: patchedElementID,
            logicalBounds: CGRect(x: 30, y: 40, width: 180, height: 70),
            zIndex: 2,
            payload: .text(PageTextPayload(text: "Base"))
        )
        let patchBase = operation(
            clock: &patchSeedClock,
            operationID: "patch-base",
            payload: .elementUpsert(patchBaseElement)
        )
        var movePatchClock = CollaborationReplicaClock(actorID: "patch-move")
        var payloadPatchClock = CollaborationReplicaClock(actorID: "patch-payload")
        movePatchClock.observe(patchBase.stamp)
        payloadPatchClock.observe(patchBase.stamp)
        var movedElement = patchBaseElement
        movedElement.logicalBounds = movedElement.logicalBounds.offsetBy(dx: 45, dy: 20)
        let movePatch = operation(
            clock: &movePatchClock,
            operationID: "patch-move",
            payload: .elementPatch(element: movedElement, fields: [.logicalBounds]),
            createdAt: .distantFuture
        )
        var styledElement = patchBaseElement
        styledElement.payload = .text(
            PageTextPayload(
                text: "Styled",
                fontName: PageTextFontPreset.serif.rawValue,
                fontSize: 29,
                colorHex: "#1976D2FF",
                isBold: true,
                isItalic: true,
                isUnderlined: true,
                alignment: .center
            )
        )
        let payloadPatch = operation(
            clock: &payloadPatchClock,
            operationID: "patch-payload",
            payload: .elementPatch(element: styledElement, fields: [.payload]),
            createdAt: .distantPast
        )
        let patchState = CollaborationMergeEngine.materialize([
            payloadPatch,
            patchBase,
            movePatch
        ])
        guard patchState.elements[patchedElementID]?.logicalBounds == movedElement.logicalBounds,
              patchState.elements[patchedElementID]?.payload == styledElement.payload,
              patchState.conflicts.isEmpty,
              patchState == CollaborationMergeEngine.materialize([
                  movePatch,
                  payloadPatch,
                  patchBase,
                  payloadPatch
              ]) else {
            throw SmokeError.validationFailed("对象字段补丁没有无冲突合并或乱序收敛")
        }

        var competingMoveClock = CollaborationReplicaClock(actorID: "patch-move-2")
        competingMoveClock.observe(patchBase.stamp)
        var competingMovedElement = patchBaseElement
        competingMovedElement.logicalBounds = competingMovedElement.logicalBounds.offsetBy(
            dx: -20,
            dy: 60
        )
        let competingMove = operation(
            clock: &competingMoveClock,
            operationID: "patch-move-2",
            payload: .elementPatch(
                element: competingMovedElement,
                fields: [.logicalBounds]
            )
        )
        guard CollaborationMergeEngine.materialize([
            patchBase,
            movePatch,
            competingMove
        ]).conflicts.count == 1 else {
            throw SmokeError.validationFailed("对象同字段并发编辑没有保留一个冲突版本")
        }

        var clockC = CollaborationReplicaClock(actorID: "actor-c")
        let concurrentDelete = operation(
            clock: &clockC,
            operationID: "delete-c",
            payload: .elementDelete(elementID: sharedElementID)
        )
        let deleteMerge = CollaborationMergeEngine.materialize([editA, concurrentDelete])
        guard deleteMerge.elements[sharedElementID] == nil,
              deleteMerge.conflicts.contains(where: { $0.targetID == sharedElementID.uuidString }) else {
            throw SmokeError.validationFailed("删除与编辑冲突没有保留可恢复副本")
        }

        var causalDeleteClock = CollaborationReplicaClock(actorID: "delete-after-edit")
        causalDeleteClock.observe(editA.stamp)
        let causalDelete = operation(
            clock: &causalDeleteClock,
            operationID: "delete-after-edit",
            payload: .elementDelete(elementID: sharedElementID)
        )
        let causalDeleteState = CollaborationMergeEngine.materialize([causalDelete, editA])
        guard causalDeleteState.elements[sharedElementID] == nil,
              causalDeleteState.conflicts.isEmpty else {
            throw SmokeError.validationFailed("正常对象删除被误报成并发冲突")
        }

        // Two concurrent deletes form a causal antichain. Seeing only one of them is insufficient
        // to resurrect an element, stroke, or page; the restore must causally observe both.
        let antichainElementID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000003"
        )!
        var elementDeleteClockA = CollaborationReplicaClock(actorID: "delete-element-a")
        var elementDeleteClockZ = CollaborationReplicaClock(actorID: "delete-element-z")
        let elementDeleteA = operation(
            clock: &elementDeleteClockA,
            operationID: "delete-element-a",
            payload: .elementDelete(elementID: antichainElementID)
        )
        let elementDeleteZ = operation(
            clock: &elementDeleteClockZ,
            operationID: "delete-element-z",
            payload: .elementDelete(elementID: antichainElementID)
        )
        var elementRestoreClock = CollaborationReplicaClock(actorID: "restore-element")
        elementRestoreClock.observe(elementDeleteZ.stamp)
        let partialElementRestore = operation(
            clock: &elementRestoreClock,
            operationID: "restore-element-partial",
            payload: .elementUpsert(textElement(id: antichainElementID, text: "Partial"))
        )
        let partialElementState = CollaborationMergeEngine.materialize([
            elementDeleteA,
            elementDeleteZ,
            partialElementRestore
        ])
        elementRestoreClock.observe(elementDeleteA.stamp)
        let completeElementRestore = operation(
            clock: &elementRestoreClock,
            operationID: "restore-element-complete",
            payload: .elementUpsert(textElement(id: antichainElementID, text: "Complete"))
        )
        let completeElementState = CollaborationMergeEngine.materialize([
            elementDeleteA,
            elementDeleteZ,
            partialElementRestore,
            completeElementRestore
        ])
        guard partialElementState.elements[antichainElementID] == nil,
              completeElementState.elements[antichainElementID] == textElement(
                  id: antichainElementID,
                  text: "Complete"
              ) else {
            throw SmokeError.validationFailed("对象恢复没有等待全部并发删除进入因果上下文")
        }

        var strokeDeleteClockA = CollaborationReplicaClock(actorID: "delete-stroke-a")
        var strokeDeleteClockZ = CollaborationReplicaClock(actorID: "delete-stroke-z")
        let strokeDeleteA = operation(
            clock: &strokeDeleteClockA,
            operationID: "delete-stroke-a",
            payload: .strokeDelete(strokeID: "antichain-stroke")
        )
        let strokeDeleteZ = operation(
            clock: &strokeDeleteClockZ,
            operationID: "delete-stroke-z",
            payload: .strokeDelete(strokeID: "antichain-stroke")
        )
        var strokeRestoreClock = CollaborationReplicaClock(actorID: "restore-stroke")
        strokeRestoreClock.observe(strokeDeleteZ.stamp)
        let partialStrokeRestore = operation(
            clock: &strokeRestoreClock,
            operationID: "restore-stroke-partial",
            payload: .strokeUpsert(
                CollaborationInkStroke(id: "antichain-stroke", drawingData: Data([3]))
            )
        )
        strokeRestoreClock.observe(strokeDeleteA.stamp)
        let completeStrokeRestore = operation(
            clock: &strokeRestoreClock,
            operationID: "restore-stroke-complete",
            payload: .strokeUpsert(
                CollaborationInkStroke(id: "antichain-stroke", drawingData: Data([4]))
            )
        )
        guard CollaborationMergeEngine.materialize([
            strokeDeleteA,
            strokeDeleteZ,
            partialStrokeRestore
        ]).strokes["antichain-stroke"] == nil,
              CollaborationMergeEngine.materialize([
                  strokeDeleteA,
                  strokeDeleteZ,
                  partialStrokeRestore,
                  completeStrokeRestore
              ]).strokes["antichain-stroke"]?.drawingData == Data([4]) else {
            throw SmokeError.validationFailed("笔迹恢复没有等待全部并发删除进入因果上下文")
        }

        var pageDeleteClockA = CollaborationReplicaClock(actorID: "delete-page-a")
        var pageDeleteClockZ = CollaborationReplicaClock(actorID: "delete-page-z")
        let pageDeleteA = operation(
            clock: &pageDeleteClockA,
            operationID: "delete-page-a",
            payload: .pageDelete
        )
        let pageDeleteZ = operation(
            clock: &pageDeleteClockZ,
            operationID: "delete-page-z",
            payload: .pageDelete
        )
        var pageRestoreClock = CollaborationReplicaClock(actorID: "restore-page")
        pageRestoreClock.observe(pageDeleteZ.stamp)
        let partialPageRestore = operation(
            clock: &pageRestoreClock,
            operationID: "restore-page-partial",
            payload: .pageRestore
        )
        pageRestoreClock.observe(pageDeleteA.stamp)
        let completePageRestore = operation(
            clock: &pageRestoreClock,
            operationID: "restore-page-complete",
            payload: .pageRestore
        )
        guard CollaborationMergeEngine.materialize([
            pageDeleteA,
            pageDeleteZ,
            partialPageRestore
        ]).isDeleted,
              !CollaborationMergeEngine.materialize([
                  pageDeleteA,
                  pageDeleteZ,
                  partialPageRestore,
                  completePageRestore
              ]).isDeleted else {
            throw SmokeError.validationFailed("页面恢复没有等待全部并发删除进入因果上下文")
        }


        let convergenceSet = [editA, editB, independentEdit, concurrentDelete]
        let deliveryOrders = [
            convergenceSet,
            Array(convergenceSet.reversed()),
            [concurrentDelete, editA, independentEdit, editB, editA],
            [editB, independentEdit, editA, concurrentDelete, editB]
        ]
        let expectedConvergence = CollaborationMergeEngine.materialize(convergenceSet)
        guard deliveryOrders.allSatisfy({
            CollaborationMergeEngine.materialize($0) == expectedConvergence
        }) else {
            throw SmokeError.validationFailed("乱序、重复投递下的协作状态未收敛")
        }

        var titleClockA = CollaborationReplicaClock(actorID: "title-a")
        var titleClockB = CollaborationReplicaClock(actorID: "title-b")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let titleA = operation(
            clock: &titleClockA,
            operationID: "title-a",
            payload: .metadataSet(
                field: "document.title",
                value: try encoder.encode("并发标题 A")
            )
        )
        let titleB = operation(
            clock: &titleClockB,
            operationID: "title-b",
            payload: .metadataSet(
                field: "document.title",
                value: try encoder.encode("并发标题 B")
            )
        )
        let titleMergeAB = CollaborationMergeEngine.materialize([titleA, titleB])
        let titleMergeBA = CollaborationMergeEngine.materialize([titleB, titleA, titleA])
        guard titleMergeAB == titleMergeBA,
              titleMergeAB.metadata["document.title"] != nil,
              titleMergeAB.conflicts.count == 1 else {
            throw SmokeError.validationFailed("文稿标题并发修改没有确定性合并或保留冲突")
        }

        clockB.observe(editA.stamp)
        let causalEdit = operation(
            clock: &clockB,
            operationID: "edit-after-a",
            payload: .elementUpsert(textElement(id: sharedElementID, text: "A 之后")),
            createdAt: .distantPast
        )
        let causalMerge = CollaborationMergeEngine.materialize([causalEdit, editA])
        guard causalMerge.elements[sharedElementID] == textElement(
            id: sharedElementID,
            text: "A 之后"
        ), causalMerge.conflicts.isEmpty else {
            throw SmokeError.validationFailed("因果顺序被设备时间偏差干扰")
        }

        // A dirty editor can be based on an older frontier while this process has already emitted
        // or downloaded newer operations. It must branch instead of reusing the primary actor
        // counter, otherwise the stamp claims to observe a local event whose remote context it
        // intentionally excludes.
        var dirtyEditorClock = CollaborationReplicaClock(actorID: "dirty-editor")
        let editorBase = operation(
            clock: &dirtyEditorClock,
            operationID: "dirty-editor-base",
            payload: .metadataSet(field: "base", value: Data([1]))
        )
        var dirtyEditorBaseFrontier = editorBase.stamp.context
        dirtyEditorBaseFrontier.observe(editorBase.stamp.dot)
        var behindEditorRemoteClock = CollaborationReplicaClock(actorID: "dirty-remote")
        let behindEditorRemote = operation(
            clock: &behindEditorRemoteClock,
            operationID: "dirty-remote",
            payload: .metadataSet(field: "remote", value: Data([2]))
        )
        dirtyEditorClock.observe(behindEditorRemote.stamp)
        let fullContextLocal = operation(
            clock: &dirtyEditorClock,
            operationID: "dirty-full-context",
            payload: .metadataSet(field: "current", value: Data([3]))
        )
        let staleEditorStamp = dirtyEditorClock.nextStamp(
            observedContext: dirtyEditorBaseFrontier,
            operationID: "dirty-stale-save"
        )
        let staleEditorSave = CollaborationOperation(
            workspaceID: workspaceID,
            documentID: documentID,
            pageID: pageID,
            stamp: staleEditorStamp,
            payload: .metadataSet(field: "stale", value: Data([4]))
        )
        guard staleEditorStamp.dot.actorID != dirtyEditorClock.actorID,
              staleEditorStamp.causalRelation(to: behindEditorRemote.stamp) == .concurrent,
              staleEditorStamp.causalRelation(to: fullContextLocal.stamp) == .concurrent,
              CollaborationMergeEngine.materialize([
                  editorBase,
                  behindEditorRemote,
                  fullContextLocal,
                  staleEditorSave
              ]).metadata.count == 4 else {
            throw SmokeError.validationFailed("旧画布保存没有形成一致的因果分支")
        }

        let strokeA = operation(
            clock: &clockA,
            operationID: "stroke-a",
            payload: .strokeUpsert(CollaborationInkStroke(id: "stroke-a", drawingData: Data([1])))
        )
        let strokeB = operation(
            clock: &clockB,
            operationID: "stroke-b",
            payload: .strokeUpsert(CollaborationInkStroke(id: "stroke-b", drawingData: Data([2])))
        )
        guard CollaborationMergeEngine.materialize([strokeB, strokeA]).strokes.count == 2 else {
            throw SmokeError.validationFailed("并发笔迹没有按 OR-Set 合并")
        }
        var causalStrokeDeleteClock = CollaborationReplicaClock(actorID: "stroke-delete-after")
        causalStrokeDeleteClock.observe(strokeA.stamp)
        let causalStrokeDelete = operation(
            clock: &causalStrokeDeleteClock,
            operationID: "stroke-delete-after",
            payload: .strokeDelete(strokeID: "stroke-a")
        )
        let causalStrokeDeleteState = CollaborationMergeEngine.materialize([
            causalStrokeDelete,
            strokeA
        ])
        guard causalStrokeDeleteState.strokes["stroke-a"] == nil,
              causalStrokeDeleteState.conflicts.isEmpty else {
            throw SmokeError.validationFailed("正常笔迹删除被误报成并发冲突")
        }
        var concurrentStrokeUpdateClock = CollaborationReplicaClock(
            actorID: "stroke-transform-concurrent"
        )
        concurrentStrokeUpdateClock.observe(strokeA.stamp)
        let concurrentStrokeUpdate = operation(
            clock: &concurrentStrokeUpdateClock,
            operationID: "stroke-transform-concurrent",
            payload: .strokeUpsert(
                CollaborationInkStroke(
                    id: "stroke-a",
                    drawingData: Data([9, 9]),
                    zIndex: 0
                )
            )
        )
        let deleteVersusTransform = CollaborationMergeEngine.materialize([
            concurrentStrokeUpdate,
            strokeA,
            causalStrokeDelete
        ])
        guard deleteVersusTransform.strokes["stroke-a"] == nil,
              deleteVersusTransform.conflicts.contains(where: {
                  $0.targetID == "stroke-a"
              }) else {
            throw SmokeError.validationFailed("笔迹变换与并发删除没有执行 remove-wins")
        }

        let acknowledgementA = CollaborationAcknowledgement(
            documentID: documentID,
            participantID: "participant-a",
            frontier: CollaborationVersionVector(
                counters: [editA.stamp.dot.actorID: editA.stamp.dot.counter]
            ),
            lastSeenAt: Date()
        )
        let acknowledgementB = CollaborationAcknowledgement(
            documentID: documentID,
            participantID: "participant-b",
            frontier: CollaborationVersionVector(),
            lastSeenAt: Date()
        )
        guard !CollaborationMergeEngine.canCompact(
            editA,
            acknowledgements: [acknowledgementA, acknowledgementB],
            activeParticipantIDs: ["participant-a", "participant-b"]
        ), CollaborationMergeEngine.canCompact(
            editA,
            acknowledgements: [acknowledgementA],
            activeParticipantIDs: ["participant-a"]
        ) else {
            throw SmokeError.validationFailed("操作日志压缩没有等待所有活跃参与者确认")
        }
        let acknowledgementA2 = CollaborationAcknowledgement(
            documentID: documentID,
            participantID: "participant-a",
            frontier: CollaborationVersionVector(
                counters: [editB.stamp.dot.actorID: editB.stamp.dot.counter]
            ),
            lastSeenAt: .distantFuture
        )
        let mergedAcknowledgement = acknowledgementA.merged(with: acknowledgementA2)
        guard mergedAcknowledgement.frontier.contains(editA.stamp.dot),
              mergedAcknowledgement.frontier.contains(editB.stamp.dot),
              mergedAcknowledgement.lastSeenAt == .distantFuture else {
            throw SmokeError.validationFailed("同一参与者多设备 ACK 没有按 frontier 并集合并")
        }
    }

    private static func validateConflictResolution(token: String) throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("TiyiNoteConflictResolutionSmoke", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
        let defaultsName = "com.tiyi.note.conflict-resolution-smoke.\(token)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        defer {
            try? fileManager.removeItem(at: workspace)
            defaults.removePersistentDomain(forName: defaultsName)
        }

        let store = DrawingDocumentStore(
            userDefaults: defaults,
            workspaceDirectoryOverride: workspace
        )
        let document = try store.createCanvas(
            named: "Conflict Resolution",
            in: nil,
            backgroundStyle: .blank,
            backgroundColor: .white
        )
        guard let pageID = store.pageID(at: 0, in: document.id) else {
            throw SmokeError.validationFailed("冲突处理测试缺少稳定 pageID")
        }

        func textElement(id: UUID, text: String) -> CanvasPageElement {
            CanvasPageElement(
                id: id,
                logicalBounds: CGRect(x: 80, y: 90, width: 220, height: 76),
                payload: .text(PageTextPayload(text: text))
            )
        }

        func concurrentPair(
            elementID: UUID,
            leftText: String,
            rightText: String,
            suffix: String
        ) -> [CollaborationOperation] {
            var leftClock = CollaborationReplicaClock(actorID: "conflict-left-\(suffix)")
            var rightClock = CollaborationReplicaClock(actorID: "conflict-right-\(suffix)")
            return [
                CollaborationOperation(
                    workspaceID: "personal-library",
                    documentID: document.id,
                    pageID: pageID,
                    stamp: leftClock.nextStamp(operationID: "conflict-left-\(suffix)"),
                    payload: .elementUpsert(textElement(id: elementID, text: leftText))
                ),
                CollaborationOperation(
                    workspaceID: "personal-library",
                    documentID: document.id,
                    pageID: pageID,
                    stamp: rightClock.nextStamp(operationID: "conflict-right-\(suffix)"),
                    payload: .elementUpsert(textElement(id: elementID, text: rightText))
                )
            ]
        }

        let restoredElementID = UUID()
        try store.applyRemoteCollaborationOperations(
            concurrentPair(
                elementID: restoredElementID,
                leftText: "恢复版本 A",
                rightText: "恢复版本 B",
                suffix: "restore"
            )
        )
        guard let restoreConflict = store.collaborationConflicts(in: document.id).first else {
            throw SmokeError.validationFailed("同字段并发没有出现在冲突版本列表")
        }
        try store.restoreCollaborationConflict(restoreConflict)
        let restoredTexts: [String] = store.loadPageElements(forPage: 0, in: document.id).compactMap {
            guard case .text(let payload) = $0.payload else { return nil }
            return payload.text
        }
        guard store.collaborationConflicts(in: document.id).isEmpty,
              restoredTexts.count == 2,
              Set(restoredTexts) == ["恢复版本 A", "恢复版本 B"] else {
            throw SmokeError.validationFailed("恢复冲突副本没有同时保留当前版本和冲突版本")
        }

        let dismissedElementID = UUID()
        try store.applyRemoteCollaborationOperations(
            concurrentPair(
                elementID: dismissedElementID,
                leftText: "忽略版本 A",
                rightText: "忽略版本 B",
                suffix: "dismiss"
            )
        )
        guard let dismissConflict = store.collaborationConflicts(in: document.id).first else {
            throw SmokeError.validationFailed("第二个同字段冲突没有进入待处理列表")
        }
        try store.dismissCollaborationConflict(dismissConflict)
        let dismissedTexts: [String] = store.loadPageElements(forPage: 0, in: document.id).compactMap {
            guard case .text(let payload) = $0.payload,
                  ["忽略版本 A", "忽略版本 B"].contains(payload.text) else { return nil }
            return payload.text
        }
        guard store.collaborationConflicts(in: document.id).isEmpty,
              dismissedTexts.count == 1 else {
            throw SmokeError.validationFailed("忽略冲突后仍有待处理项或错误恢复了副本")
        }

        let reloaded = DrawingDocumentStore(
            userDefaults: defaults,
            workspaceDirectoryOverride: workspace
        )
        let reloadedTexts: [String] = reloaded.loadPageElements(forPage: 0, in: document.id).compactMap {
            guard case .text(let payload) = $0.payload else { return nil }
            return payload.text
        }
        guard reloaded.collaborationConflicts(in: document.id).isEmpty,
              reloadedTexts.count == 3,
              Set(reloadedTexts).isSuperset(of: ["恢复版本 A", "恢复版本 B"]) else {
            throw SmokeError.validationFailed("冲突处理结果在重启后复活或丢失")
        }
    }

    private static func validateDocumentReferenceMerge() throws {
        var seedClock = CollaborationReplicaClock(actorID: "reference-seed")
        let seedStamp = seedClock.nextStamp(
            operationID: "reference-seed",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let base = LibraryDocumentReference(
            documentID: "shared-document",
            parent: LibraryDocumentReferenceRegister(value: nil, stamp: seedStamp),
            favorite: LibraryDocumentReferenceRegister(value: false, stamp: seedStamp),
            trash: LibraryDocumentReferenceRegister(value: nil, stamp: seedStamp)
        )

        var moveClock = CollaborationReplicaClock(actorID: "reference-move")
        var favoriteClock = CollaborationReplicaClock(actorID: "reference-favorite")
        for clockStamp in [base.parent.stamp, base.favorite.stamp, base.trash.stamp] {
            moveClock.observe(clockStamp)
            favoriteClock.observe(clockStamp)
        }
        var moved = base
        moved.parent = LibraryDocumentReferenceRegister(
            value: "folder-a",
            stamp: moveClock.nextStamp(
                operationID: "reference-move",
                createdAt: .distantFuture
            )
        )
        var favorited = base
        favorited.favorite = LibraryDocumentReferenceRegister(
            value: true,
            stamp: favoriteClock.nextStamp(
                operationID: "reference-favorite",
                createdAt: .distantPast
            )
        )

        let mergedAB = moved.merged(with: favorited)
        let mergedBA = favorited.merged(with: moved)
        guard mergedAB == mergedBA,
              mergedAB.parent.value == "folder-a",
              mergedAB.favorite.value else {
            throw SmokeError.validationFailed("个人文稿引用的独立离线字段发生覆盖")
        }

        var parentClockA = CollaborationReplicaClock(actorID: "reference-parent-a")
        var parentClockB = CollaborationReplicaClock(actorID: "reference-parent-b")
        parentClockA.observe(seedStamp)
        parentClockB.observe(seedStamp)
        var parentA = base
        var parentB = base
        parentA.parent = LibraryDocumentReferenceRegister(
            value: "folder-a",
            stamp: parentClockA.nextStamp(
                operationID: "parent-a",
                createdAt: .distantFuture
            )
        )
        parentB.parent = LibraryDocumentReferenceRegister(
            value: "folder-b",
            stamp: parentClockB.nextStamp(
                operationID: "parent-b",
                createdAt: .distantPast
            )
        )
        let parentMergeAB = parentA.merged(with: parentB)
        let parentMergeBA = parentB.merged(with: parentA)
        guard parentMergeAB == parentMergeBA,
              parentMergeAB.parent.value != nil else {
            throw SmokeError.validationFailed("个人文稿引用并发移动依赖到达顺序或设备时间")
        }

        var malformedA = base
        var malformedB = base
        malformedA.parent = LibraryDocumentReferenceRegister(value: "folder-x", stamp: seedStamp)
        malformedB.parent = LibraryDocumentReferenceRegister(value: "folder-y", stamp: seedStamp)
        guard malformedA.merged(with: malformedB) == malformedB.merged(with: malformedA) else {
            throw SmokeError.validationFailed("个人引用异常同 dot 载荷没有确定性收敛")
        }
    }

    private static func validateFolderCausalMerge() throws {
        var seedClock = CollaborationReplicaClock(actorID: "folder-seed")
        let seed = seedClock.nextStamp(
            operationID: "folder-seed",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let base = LibraryFolder(
            id: "causal-folder",
            title: "原名",
            parentID: nil,
            createdAt: seed.createdAt,
            modifiedAt: seed.createdAt,
            color: .blue,
            icon: .folder,
            isFavorite: false,
            trashedAt: nil,
            titleRevision: seed,
            parentRevision: seed,
            colorRevision: seed,
            iconRevision: seed,
            favoriteRevision: seed,
            trashRevision: seed
        )

        func clock(_ actorID: String) -> CollaborationReplicaClock {
            var result = CollaborationReplicaClock(actorID: actorID)
            result.observe(seed)
            return result
        }
        var renameClock = clock("folder-rename")
        var moveClock = clock("folder-move")
        var favoriteClock = clock("folder-favorite")
        var renamed = base
        renamed.title = "离线改名"
        renamed.titleRevision = renameClock.nextStamp(
            operationID: "folder-rename",
            createdAt: .distantPast
        )
        var moved = base
        moved.parentID = "destination"
        moved.parentRevision = moveClock.nextStamp(
            operationID: "folder-move",
            createdAt: .distantFuture
        )
        var favorited = base
        favorited.isFavorite = true
        favorited.favoriteRevision = favoriteClock.nextStamp(
            operationID: "folder-favorite",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let mergeOrders = [
            [renamed, moved, favorited],
            [favorited, renamed, moved],
            [moved, favorited, renamed]
        ]
        let results = mergeOrders.map { $0.dropFirst().reduce($0[0]) { $0.merged(with: $1) } }
        guard let expected = results.first,
              results.allSatisfy({ $0 == expected }),
              expected.title == "离线改名",
              expected.parentID == "destination",
              expected.isFavorite else {
            throw SmokeError.validationFailed("私人文件夹逐字段并发合并未交换、结合或保留全部修改")
        }

        var sameFieldClockA = clock("folder-parent-a")
        var sameFieldClockB = clock("folder-parent-b")
        var parentA = base
        var parentB = base
        parentA.parentID = "parent-a"
        parentA.parentRevision = sameFieldClockA.nextStamp(
            operationID: "folder-parent-a",
            createdAt: .distantFuture
        )
        parentB.parentID = "parent-b"
        parentB.parentRevision = sameFieldClockB.nextStamp(
            operationID: "folder-parent-b",
            createdAt: .distantPast
        )
        guard parentA.merged(with: parentB) == parentB.merged(with: parentA) else {
            throw SmokeError.validationFailed("私人文件夹同字段冲突依赖到达顺序或设备时间")
        }
    }

    private static func validateStaleFolderEditorMerge(token: String) throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("TiyiNoteFolderEditorSmoke", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
        let defaultsAName = "com.tiyi.note.folder-editor-smoke.a.\(token)"
        let defaultsBName = "com.tiyi.note.folder-editor-smoke.b.\(token)"
        let defaultsA = UserDefaults(suiteName: defaultsAName)!
        let defaultsB = UserDefaults(suiteName: defaultsBName)!
        defer {
            try? fileManager.removeItem(at: base)
            defaultsA.removePersistentDomain(forName: defaultsAName)
            defaultsB.removePersistentDomain(forName: defaultsBName)
        }

        let storeA = DrawingDocumentStore(
            userDefaults: defaultsA,
            workspaceDirectoryOverride: base.appendingPathComponent("a", isDirectory: true)
        )
        let folder = try storeA.createFolder(named: "Editor Base", in: nil)
        let destinationA = try storeA.createFolder(named: "Destination A", in: nil)
        let destinationB = try storeA.createFolder(named: "Destination B", in: nil)
        let storeB = DrawingDocumentStore(
            userDefaults: defaultsB,
            workspaceDirectoryOverride: base.appendingPathComponent("b", isDirectory: true)
        )
        try storeB.applyRemoteSnapshot(storeA.librarySnapshot)
        guard let openingContext = storeA.folderEditorCollaborationContext(for: folder.id) else {
            throw SmokeError.validationFailed("文件夹编辑器没有捕获打开时的因果版本")
        }

        try storeB.updateFolderMetadata(
            folder.id,
            title: "Remote Rename",
            color: .purple
        )
        guard let remoteFolder = storeB.folder(withID: folder.id),
              let remoteTitleStamp = remoteFolder.titleRevision else {
            throw SmokeError.validationFailed("文件夹远端编辑没有生成字段版本")
        }

        // The remote record lands while A's sheet is still open. Saving the sheet changes title
        // and icon only; its untouched color must remain remote purple, and the stale title edit
        // must be concurrent with (not causally after) the unseen remote rename.
        try storeA.applyRemoteSnapshot(storeB.librarySnapshot)
        try storeA.updateFolderMetadata(
            folder.id,
            title: "Local Rename",
            icon: .star,
            causalContext: openingContext
        )
        guard let localFolder = storeA.folder(withID: folder.id),
              let localTitleStamp = localFolder.titleRevision,
              localTitleStamp.causalRelation(to: remoteTitleStamp) == .concurrent,
              localFolder.color == .purple,
              localFolder.colorRevision == remoteFolder.colorRevision,
              localFolder.icon == .star else {
            throw SmokeError.validationFailed("旧文件夹编辑器覆盖了未编辑字段或伪造了因果顺序")
        }

        let mergedAB = localFolder.merged(with: remoteFolder)
        let mergedBA = remoteFolder.merged(with: localFolder)
        guard mergedAB == mergedBA,
              mergedAB.color == .purple,
              mergedAB.icon == .star else {
            throw SmokeError.validationFailed("旧文件夹编辑器的并发结果没有确定性收敛")
        }

        let reloadedA = DrawingDocumentStore(
            userDefaults: defaultsA,
            workspaceDirectoryOverride: base.appendingPathComponent("a", isDirectory: true)
        )
        guard reloadedA.folder(withID: folder.id) == localFolder else {
            throw SmokeError.validationFailed("文件夹字段级因果事务重启后丢失")
        }

        // A destination picker is another long-lived editor. A remote move landing behind it must
        // not be folded into the local move's observed context.
        try storeB.applyRemoteSnapshot(storeA.librarySnapshot)
        let moveContext = storeA.libraryMoveCollaborationContext(
            folderIDs: [folder.id],
            documentIDs: []
        )
        try storeB.moveFolder(folder.id, to: destinationB.id)
        guard let remoteMovedFolder = storeB.folder(withID: folder.id),
              let remoteMoveStamp = remoteMovedFolder.parentRevision else {
            throw SmokeError.validationFailed("文件夹远端移动没有生成字段版本")
        }
        try storeA.applyRemoteSnapshot(storeB.librarySnapshot)
        try storeA.moveItems(
            folderIDs: [folder.id],
            documentIDs: [],
            to: destinationA.id,
            causalContext: moveContext
        )
        guard let localMovedFolder = storeA.folder(withID: folder.id),
              let localMoveStamp = localMovedFolder.parentRevision,
              localMoveStamp.causalRelation(to: remoteMoveStamp) == .concurrent,
              localMovedFolder.parentID == destinationA.id,
              localMovedFolder.merged(with: remoteMovedFolder)
                == remoteMovedFolder.merged(with: localMovedFolder) else {
            throw SmokeError.validationFailed("旧移动选择器伪造因果顺序或无法确定性收敛")
        }
    }

    private static func validatePrivateDocumentRecordMerge() throws {
        var seedClock = CollaborationReplicaClock(actorID: "private-document-seed")
        let seed = seedClock.nextStamp(
            operationID: "private-document-seed",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let base = LibraryDocumentMetadata(
            id: "private-document",
            title: "初始标题",
            parentID: nil,
            fileName: "private-document.pdf",
            isBundled: false,
            createdAt: seed.createdAt,
            modifiedAt: seed.createdAt,
            contentModifiedAt: seed.createdAt,
            parentRevision: seed,
            favoriteRevision: seed,
            trashRevision: seed
        )

        var content = base
        content.title = "内容端改名"
        content.contentModifiedAt = Date(timeIntervalSince1970: 20)
        content.modifiedAt = content.contentModifiedAt

        var favoriteClock = CollaborationReplicaClock(actorID: "private-document-favorite")
        favoriteClock.observe(seed)
        var organization = base
        let favoriteStamp = favoriteClock.nextStamp(
            operationID: "private-document-favorite",
            createdAt: .distantFuture
        )
        organization.isFavorite = true
        organization.favoriteRevision = favoriteStamp
        organization.modifiedAt = favoriteStamp.createdAt

        let mergedAB = content.mergedPrivateRecord(with: organization)
        let mergedBA = organization.mergedPrivateRecord(with: content)
        guard mergedAB == mergedBA,
              mergedAB.title == "内容端改名",
              mergedAB.isFavorite else {
            throw SmokeError.validationFailed("私人文稿内容和个人整理状态互相覆盖")
        }
    }

    private static func validatePendingDocumentReference(token: String) throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("TiyiNoteReferenceSmoke", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
        let defaultsAName = "com.tiyi.note.reference-smoke.a.\(token)"
        let defaultsBName = "com.tiyi.note.reference-smoke.b.\(token)"
        let defaultsA = UserDefaults(suiteName: defaultsAName)!
        let defaultsB = UserDefaults(suiteName: defaultsBName)!
        defer {
            try? fileManager.removeItem(at: base)
            defaultsA.removePersistentDomain(forName: defaultsAName)
            defaultsB.removePersistentDomain(forName: defaultsBName)
        }

        let storeA = DrawingDocumentStore(
            userDefaults: defaultsA,
            workspaceDirectoryOverride: base.appendingPathComponent("A")
        )
        let folder = try storeA.createFolder(named: "Reference Folder", in: nil)
        let document = try storeA.createCanvas(
            named: "Reference Document",
            in: folder.id,
            backgroundStyle: .blank,
            backgroundColor: .white
        )
        guard let reference = try storeA.exportDocumentReferences(for: [document.id]).first else {
            throw SmokeError.validationFailed("无法导出个人文稿引用")
        }

        let storeB = DrawingDocumentStore(
            userDefaults: defaultsB,
            workspaceDirectoryOverride: base.appendingPathComponent("B")
        )
        try storeB.applyRemoteDocumentReferences([reference])
        try storeB.applyRemoteSnapshot(storeA.exportLibrarySnapshot())
        guard storeB.document(withID: document.id)?.parentID == folder.id else {
            throw SmokeError.validationFailed("先到达的个人引用没有在共享内容挂载后应用")
        }
    }

    private static func validateWorkspaceTransactionRecovery(token: String) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("TiyiNoteTransactionSmoke", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        for stage in 1...3 {
            let workspace = root.appendingPathComponent("Stage-\(stage)", isDirectory: true)
            let defaultsName = "com.tiyi.note.transaction-smoke.\(stage).\(token)"
            let defaults = UserDefaults(suiteName: defaultsName)!
            defaults.removePersistentDomain(forName: defaultsName)
            defer { defaults.removePersistentDomain(forName: defaultsName) }

            let store = DrawingDocumentStore(
                userDefaults: defaults,
                workspaceDirectoryOverride: workspace
            )
            let document = try store.createCanvas(
                named: "Transaction Stage \(stage)",
                in: nil,
                backgroundStyle: .grid,
                backgroundColor: .ivory
            )
            guard let page = store.pages(in: document.id).first else {
                throw SmokeError.validationFailed("事务恢复测试缺少页面")
            }
            let backgroundReference = LibraryAssetReference(
                documentID: document.id,
                kind: .pageBackground(pageID: page.id)
            )
            guard let backgroundURL = store.assetURL(for: backgroundReference) else {
                throw SmokeError.validationFailed("事务恢复测试缺少背景")
            }
            let backgroundBefore = try Data(contentsOf: backgroundURL)
            let pdfBefore = try Data(contentsOf: document.fileURL)
            let operationsBefore = store.exportCollaborationOperations()

            try store.debugLeaveInterruptedRotationTransaction(
                pageID: page.id,
                in: document.id,
                completedStage: stage
            )
            let recovered = DrawingDocumentStore(
                userDefaults: defaults,
                workspaceDirectoryOverride: workspace
            )
            guard let recoveredDocument = recovered.document(withID: document.id),
                  recovered.pages(in: document.id).first?.rotation == page.rotation,
                  let recoveredBackgroundURL = recovered.assetURL(for: backgroundReference),
                  try Data(contentsOf: recoveredBackgroundURL) == backgroundBefore,
                  try Data(contentsOf: recoveredDocument.fileURL) == pdfBefore,
                  recovered.exportCollaborationOperations() == operationsBefore else {
                throw SmokeError.validationFailed("事务在阶段 \(stage) 中断后未完整回滚")
            }
            let transactionsDirectory = workspace.appendingPathComponent(
                "Transactions",
                isDirectory: true
            )
            let leftovers = try fileManager.contentsOfDirectory(
                at: transactionsDirectory,
                includingPropertiesForKeys: nil
            )
            guard leftovers.isEmpty else {
                throw SmokeError.validationFailed("恢复后仍残留事务日志")
            }
            try recovered.rotatePage(page.id, clockwise: true, in: document.id)
            guard recovered.pages(in: document.id).first?.rotation == 90 else {
                throw SmokeError.validationFailed("事务恢复后无法继续写入")
            }
        }
    }

    private static func validateEditablePackageRoundTrip(token: String) throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("TiyiNotePackageSmoke", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
        let defaultsName = "com.tiyi.note.package-smoke.\(token)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        defer {
            try? fileManager.removeItem(at: workspace)
            defaults.removePersistentDomain(forName: defaultsName)
        }

        let store = DrawingDocumentStore(
            userDefaults: defaults,
            workspaceDirectoryOverride: workspace
        )
        let original = try store.createCanvas(
            named: "Package Round Trip",
            in: nil,
            backgroundStyle: .grid,
            backgroundColor: .ivory
        )
        guard let firstPage = store.pages(in: original.id).first else {
            throw SmokeError.validationFailed("可编辑包测试缺少初始页面")
        }
        let secondPage = try store.insertTemplatePage(
            after: firstPage.id,
            in: original.id,
            style: .dotted,
            color: .green
        )
        try store.rotatePage(secondPage.id, clockwise: true, in: original.id)
        try store.setPageBookmark(secondPage.id, isBookmarked: true, in: original.id)
        store.flush(makeSmokeDrawing(offset: 70, color: .systemPurple), forPage: 0, in: original.id)
        let element = CanvasPageElement(
            logicalBounds: CGRect(x: 40, y: 50, width: 220, height: 80),
            rotationRadians: 0.2,
            payload: .text(
                PageTextPayload(
                    text: "可编辑恢复",
                    fontName: "System",
                    fontSize: 24,
                    colorHex: "#112233FF",
                    isBold: true,
                    alignment: .center
                )
            )
        )
        store.flush([element], forPage: 1, in: original.id)
        try store.renameDocument(original.id, to: "Package Round Trip Renamed")

        let originalPages = store.pages(in: original.id)
        let originalDrawing = store.loadDrawing(forPage: 0, in: original.id)
        let originalElements = store.loadPageElements(forPage: 1, in: original.id)
        let originalOperations = store.exportCollaborationOperations().filter {
            $0.documentID == original.id
        }
        let packageURL = try store.exportEditableDocumentPackage(documentID: original.id)
        let restored = try store.importEditableDocumentPackage(from: packageURL)
        let restoredPages = store.pages(in: restored.id)
        let restoredOperations = store.exportCollaborationOperations().filter {
            $0.documentID == restored.id
        }
        let restoredTitleState = CollaborationMergeEngine.materialize(
            restoredOperations.filter {
                $0.pageID == CollaborationReservedID.documentMetadata
            }
        )
        let restoredTitle = restoredTitleState.metadata["document.title"].flatMap {
            try? JSONDecoder().decode(String.self, from: $0)
        }

        guard restored.id != original.id,
              restored.kind == original.kind,
              restored.canvasBackgroundStyle == original.canvasBackgroundStyle,
              restored.canvasBackgroundColor == original.canvasBackgroundColor,
              restoredPages.count == originalPages.count,
              Set(restoredPages.map(\.id)).isDisjoint(with: originalPages.map(\.id)),
              zip(restoredPages, originalPages).allSatisfy({ restoredPage, originalPage in
                  restoredPage.rotation == originalPage.rotation
                      && restoredPage.isBookmarked == originalPage.isBookmarked
                      && restoredPage.backgroundStyle == originalPage.backgroundStyle
                      && restoredPage.backgroundColor == originalPage.backgroundColor
              }),
              store.loadDrawing(forPage: 0, in: restored.id).strokes.count
                == originalDrawing.strokes.count,
              store.loadPageElements(forPage: 1, in: restored.id) == originalElements,
              Set(restoredOperations.map(\.id)).isDisjoint(with: originalOperations.map(\.id)),
              restoredTitle == restored.title else {
            throw SmokeError.validationFailed(".tiyinote 导出、ID 重写或可编辑内容恢复不完整")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exported = try decoder.decode(
            EditableDocumentPackage.self,
            from: Data(contentsOf: packageURL)
        )
        let invalid = EditableDocumentPackage(
            schemaVersion: EditableDocumentPackage.currentSchemaVersion + 1,
            document: exported.document,
            pages: exported.pages,
            sourcePDFData: exported.sourcePDFData,
            pageAssets: exported.pageAssets,
            documentOperations: exported.documentOperations
        )
        let invalidURL = fileManager.temporaryDirectory.appendingPathComponent(
            "invalid-\(token).tiyinote"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(invalid).write(to: invalidURL, options: .atomic)
        defer { try? fileManager.removeItem(at: invalidURL) }
        let documentCount = store.documents.count
        do {
            _ = try store.importEditableDocumentPackage(from: invalidURL)
            throw SmokeError.validationFailed("不支持版本的可编辑包被错误接受")
        } catch let error as LibraryStoreError {
            guard case .invalidSnapshot = error, store.documents.count == documentCount else {
                throw SmokeError.validationFailed("无效可编辑包没有原子失败")
            }
        }
    }

    private static func validateAutomaticBackupRecovery(token: String) throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("TiyiNoteAutomaticBackupSmoke", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
        let workspace = base.appendingPathComponent("Workspace", isDirectory: true)
        let destination = base.appendingPathComponent("Destination", isDirectory: true)
        let defaultsName = "com.tiyi.note.backup-smoke.\(token)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        defer {
            try? fileManager.removeItem(at: base)
            defaults.removePersistentDomain(forName: defaultsName)
        }

        let store = DrawingDocumentStore(
            userDefaults: defaults,
            workspaceDirectoryOverride: workspace
        )
        let document = try store.createCanvas(
            named: "Backup Version 0",
            in: nil,
            backgroundStyle: .grid,
            backgroundColor: .ivory
        )
        guard let firstPage = store.pages(in: document.id).first else {
            throw SmokeError.validationFailed("自动备份测试缺少页面")
        }
        _ = try store.insertTemplatePage(
            after: firstPage.id,
            in: document.id,
            style: .dotted,
            color: .green
        )
        let coordinator = AutomaticBackupCoordinator(
            documentStore: store,
            fileManager: fileManager,
            userDefaults: defaults,
            destinationOverride: destination
        )
        coordinator.setRetentionCount(3)
        for version in 1...5 {
            try store.renameDocument(document.id, to: "Backup Version \(version)")
            _ = try coordinator.performBackupNow()
        }

        let versionDirectory = destination
            .appendingPathComponent("Tiyi Note Backups", isDirectory: true)
            .appendingPathComponent(document.id, isDirectory: true)
        let versions = try fileManager.contentsOfDirectory(
            at: versionDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "tiyinote" }
        guard versions.count == 3 else {
            throw SmokeError.validationFailed("自动备份没有按文稿保留最近 3 个版本")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let packages = try versions.map {
            try decoder.decode(EditableDocumentPackage.self, from: Data(contentsOf: $0))
        }
        guard packages.contains(where: {
            $0.document.title == "Backup Version 5" && $0.pages.count == 2
        }), let newestURL = versions.first(where: { url in
            (try? decoder.decode(
                EditableDocumentPackage.self,
                from: Data(contentsOf: url)
            ).document.title) == "Backup Version 5"
        }) else {
            throw SmokeError.validationFailed("自动备份内容不是最新的完整可编辑状态")
        }

        try store.moveToTrash(documentID: document.id)
        try store.permanentlyDelete(documentID: document.id)
        let restored = try store.importEditableDocumentPackage(from: newestURL)
        guard restored.id != document.id,
              restored.title == "Backup Version 5",
              store.pages(in: restored.id).count == 2 else {
            throw SmokeError.validationFailed("自动备份无法在永久删除后恢复为安全副本")
        }
    }
}
#endif
