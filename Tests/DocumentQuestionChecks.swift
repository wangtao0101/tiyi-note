#if DEBUG
import SwiftUI
import PencilKit
import PDFKit
import CloudKit

struct DocumentQuestionChecksView: View {
    @State private var result = "检查中"
    var body: some View {
        Text(result).accessibilityIdentifier(result == "通过" ? "question-checks-passed" : "question-checks-result")
            .task {
                do { try DocumentQuestionChecks.run(); result = "通过" }
                catch { result = error.localizedDescription }
            }
    }
}

@MainActor enum DocumentQuestionChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "QuestionChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("question-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaultsName = root.lastPathComponent
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let store = DrawingDocumentStore(userDefaults: defaults, workspaceDirectoryOverride: root.appendingPathComponent("source"), includesBundledSamples: false)
        let document = try store.createCanvas(named: "圈题持久化", in: nil, backgroundStyle: .grid, backgroundColor: .white)
        let pageID = store.pages(in: document.id)[0].id
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 480)).image { ctx in
            UIColor.yellow.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 480))
            ("题目" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        let png = image.pngData()!
        let element = CanvasPageElement(logicalBounds: CGRect(x: -80, y: 120, width: 120, height: 480), isLocked: true,
                                       payload: .question(PageQuestionPayload(snapshotPNG: png)))
        var movedMarker = element.normalizedQuestionMarker
        try require(!movedMarker.isLocked && movedMarker.logicalBounds.size == CGSize(width: 32, height: 32), "旧标记未接入套索")
        movedMarker.logicalBounds = movedMarker.logicalBounds.offsetBy(dx: 90, dy: -50)
        try require(movedMarker.logicalBounds.midX == element.logicalBounds.midX + 90, "标记位移错误")
        try require(movedMarker.question?.sourceBounds == element.logicalBounds, "旧标记移动后丢失原题范围")
        movedMarker.isLocked = true
        try require(movedMarker.normalizedQuestionMarker == movedMarker, "再次加载覆盖了用户锁定或位置")
        try require(movedMarker.question?.snapshotPNG == png, "移动标记改变了题目快照")
        let session = try DocumentQuestionSession(store: store, documentID: document.id, pageID: pageID, element: element, isNew: true)
        defer { session.discardWorkingCopy() }
        try require(store.loadPageElements(forPage: 0, in: document.id).count == 1, "首次确认没有保存标记")
        let answer = session.workspace
        let points = [CGPoint(x: 100, y: 500), CGPoint(x: 240, y: 550)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.monoline, color: .blue), path: PKStrokePath(controlPoints: points, creationDate: Date()))])
        answer.store.flush(drawing, forPage: 0, in: answer.documentID)
        try answer.appendPage()
        answer.isCompleted = true
        try answer.checkpoint()
        let checkpointOperationCount = store.exportCollaborationOperations().count
        try answer.checkpoint()
        try require(store.exportCollaborationOperations().count == checkpointOperationCount, "未修改作答却重复生成大附件")
        let saved = store.loadPageElements(forPage: 0, in: document.id)[0]
        try require(saved.question?.snapshotPNG == png, "作答改变了题目快照")
        try require(saved.logicalBounds == element.logicalBounds && saved.question?.isCompleted == true, "圈题位置或完成状态丢失")
        try require(saved.question?.sections.first?.pageIDs.count == 2, "作答页索引未保存")
        let resumed = try DocumentQuestionSession(store: store, documentID: document.id, pageID: pageID, element: saved)
        defer { resumed.discardWorkingCopy() }
        try require(resumed.workspace.pageCount == 2 && resumed.workspace.isCompleted, "重进没有恢复作答状态")
        try require(resumed.workspace.currentPageID == answer.currentPageID, "没有恢复最后作答页")
        try require(resumed.workspace.store.loadDrawing(forPage: 0, in: resumed.workspace.documentID).strokes.count == 1, "作答笔迹丢失")
        let restoredDrawing = resumed.workspace.store.loadDrawing(forPage: 0, in: resumed.workspace.documentID)
        let inkRect = CGRect(x: 50, y: 450, width: 250, height: 150)
        try require(drawing.image(from: inkRect, scale: 2).pngData() == restoredDrawing.image(from: inkRect, scale: 2).pngData(), "作答恢复后笔迹外观改变")
        // Existing source edits survive an answer checkpoint; only the attachment's delta is emitted.
        let other = CanvasPageElement(logicalBounds: CGRect(x: 10, y: 10, width: 60, height: 30), payload: .text(PageTextPayload(text: "原稿更新")))
        store.scheduleSave([other], replacing: [], forPage: 0, in: document.id)
        try require(store.flushAllPendingSaves(), "原稿修改保存失败")
        resumed.workspace.isCompleted = false
        try resumed.workspace.checkpoint()
        try require(store.loadPageElements(forPage: 0, in: document.id).contains(other), "作答覆盖了其他页面对象")
        // The complete parent export carries nested answer assets and can be restored in another local library.
        let package = try store.editableDocumentPackageData(documentID: document.id)
        let url = root.appendingPathComponent("roundtrip.tiyinote")
        try package.write(to: url)
        let restoredStore = DrawingDocumentStore(userDefaults: defaults, workspaceDirectoryOverride: root.appendingPathComponent("restored"), includesBundledSamples: false)
        let imported = try restoredStore.importEditableDocumentPackage(from: url)
        let importedElements = restoredStore.loadPageElements(forPage: 0, in: imported.id)
        try require(importedElements.contains(where: { $0.question?.snapshotPNG == png && $0.question?.answerPackage != nil }), "文稿导出导入丢失圈题")
        let restoredElement = importedElements.first { $0.question != nil }!
        let restoredAnswer = try DocumentQuestionSession(store: restoredStore, documentID: imported.id,
            pageID: restoredStore.pages(in: imported.id)[0].id, element: restoredElement)
        defer { restoredAnswer.discardWorkingCopy() }
        try require(restoredAnswer.workspace.store.loadDrawing(forPage: 0, in: restoredAnswer.workspace.documentID).strokes.count == 1, "导入后的嵌套笔迹丢失")
        // Real encoded operation payloads, plus a payload well over the inline CKRecord limit.
        let operationData = try JSONEncoder().encode(store.exportCollaborationOperations().last!.payload)
        for data in [Data([1, 2]), operationData, Data(repeating: 0xAF, count: 1_200_000)] {
            let record = CKRecord(recordType: "CollaborationOperation")
            try CloudOperationPayloadTransport.write(data, to: record, directory: root)
            let received = try CloudOperationPayloadTransport.read(from: record)
            try require(received == data, "CloudKit 附件数据不一致")
            try require((record["operationPayloadAsset"] != nil) == (data.count > CloudOperationPayloadTransport.inlineLimit), "大数据未使用 CKAsset")
        }
        // Two concurrently opened answers must retain the losing version instead of silently discarding it.
        let current = store.loadPageElements(forPage: 0, in: document.id).first { $0.question != nil }!
        let a = try DocumentQuestionSession(store: store, documentID: document.id, pageID: pageID, element: current)
        let b = try DocumentQuestionSession(store: store, documentID: document.id, pageID: pageID, element: current)
        defer { a.discardWorkingCopy(); b.discardWorkingCopy() }
        a.workspace.isCompleted = true
        try a.workspace.checkpoint()
        try b.workspace.appendPage()
        try require(!store.collaborationConflicts(in: document.id).isEmpty, "并行作答没有保留冲突版本")
        // Rendering a crop copies PDF print and ink but never navigation markers.
        let pdfData = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 300)).pdfData { ctx in
            ctx.beginPage(); UIColor.red.setFill(); ctx.fill(CGRect(x: 20, y: 20, width: 100, height: 100))
        }
        let pdfPage = PDFDocument(data: pdfData)!.page(at: 0)!
        let crop = CGRect(x: 10, y: 10, width: 140, height: 160)
        let plain = LassoSnapshotRenderer.render(page: pdfPage, drawing: drawing, pageElements: [], cropRect: crop, logicalPageSize: CGSize(width: 200, height: 300))!
        let marked = LassoSnapshotRenderer.render(page: pdfPage, drawing: drawing, pageElements: [element], cropRect: crop, logicalPageSize: CGSize(width: 200, height: 300))!
        try require(plain.image.pngData() == marked.image.pngData(), "题目快照混入了圈题标记")
        try require(plain.logicalSize == crop.size, "题目范围比例改变")
        var visibleMarker = element.normalizedQuestionMarker
        visibleMarker.logicalBounds = CGRect(x: 50, y: 50, width: 32, height: 32)
        let markerScreenshot = LassoSnapshotRenderer.render(page: pdfPage, drawing: drawing, pageElements: [visibleMarker], cropRect: crop, logicalPageSize: CGSize(width: 200, height: 300), includesQuestionMarkers: true)!
        try require(markerScreenshot.image.pngData() != plain.image.pngData(), "普通套索截图遗漏了作答标记")

    }
}
#endif
