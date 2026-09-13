import SwiftUI
import PencilKit
import CloudKit

/// A document-owned attachment. The source region and snapshot never change when an answer is edited.
struct PageQuestionPayload: Codable, Hashable, Sendable {
    var snapshotPNG: Data
    var sourceBounds: CGRect?
    var markerUsesLasso: Bool?
    var answerPackage: Data?
    var sections: [TiyiPracticeSection] = []
    var lastPageID: String?
    var isCompleted = false

    var isValid: Bool {
        !snapshotPNG.isEmpty && snapshotPNG.count <= 32_000_000
            && UIImage(data: snapshotPNG) != nil
            && (answerPackage?.count ?? 0) <= 100_000_000
            && sections.count <= 1
    }
}

extension Notification.Name { static let documentQuestionDismissed = Notification.Name("tiyi.document-question.dismissed") }

extension CanvasPageElement {
    var question: PageQuestionPayload? {
        guard case .question(let value) = payload else { return nil }
        return value
    }

    /// Upgrade once, preserving the original crop and later user-controlled lock state.
    var normalizedQuestionMarker: CanvasPageElement {
        guard var question, question.markerUsesLasso != true else { return self }
        var result = self
        if question.sourceBounds == nil {
            question.sourceBounds = logicalBounds
            result.logicalBounds = CGRect(x: logicalBounds.midX - 16,
                                          y: logicalBounds.midY - 16, width: 32, height: 32)
        }
        question.markerUsesLasso = true
        result.payload = .question(question)
        result.isLocked = false
        return result
    }

}

/// CloudKit's inline record limit also applies to collaboration operations, not just page snapshots.
/// Decode the asset immediately while CloudKit still owns its downloaded file; callers stage decoded values.
enum CloudOperationPayloadTransport {
    static let inlineLimit = 256_000
    static func write(_ data: Data, to record: CKRecord, directory: URL) throws {
        if data.count <= inlineLimit {
            record["operationPayload"] = data as CKRecordValue
            record["operationPayloadAsset"] = nil
        } else {
            let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
            try data.write(to: url, options: .atomic)
            record["operationPayload"] = nil
            record["operationPayloadAsset"] = CKAsset(fileURL: url)
        }
    }
    static func read(from record: CKRecord) throws -> Data {
        if let asset = record["operationPayloadAsset"] as? CKAsset, let url = asset.fileURL {
            return try Data(contentsOf: url)
        }
        guard let data = record["operationPayload"] as? Data else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
}

@MainActor final class DocumentQuestionSession: Identifiable {
    let id = UUID()
    let workspace: TiyiPracticeWorkspace
    private let sourceStore: DrawingDocumentStore
    private let documentID: String
    private let pageID: String
    private let directory: URL
    private var element: CanvasPageElement
    private var savedElement: CanvasPageElement?
    private var context: CollaborationVersionVector

    init(store: DrawingDocumentStore, documentID: String, pageID: String,
         element suppliedElement: CanvasPageElement, isNew: Bool = false) throws {
        guard let index = store.pageIndex(for: pageID, in: documentID) else { throw CocoaError(.fileNoSuchFile) }
        guard store.flushAllPendingSaves() else { throw CocoaError(.fileWriteUnknown) }
        let element: CanvasPageElement
        if isNew {
            element = suppliedElement
        } else {
            // A retained canvas/selection can still hold the marker from before the last answer.
            // Resolve its stable ID against the source document before restoring an editable package.
            guard let saved = store.loadPageElements(forPage: index, in: documentID).first(where: { $0.id == suppliedElement.id }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            element = saved
        }
        guard let payload = element.question, payload.isValid,
              let image = UIImage(data: payload.snapshotPNG) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        sourceStore = store
        self.documentID = documentID
        self.pageID = pageID
        self.element = element
        savedElement = isNew ? nil : element
        context = store.collaborationFrontier(forPage: index, in: documentID)
        // A fresh directory always restores the document's current synced package, never stale cached answers.
        directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
            .appendingPathComponent("DocumentQuestionSessions/\(UUID().uuidString)")
        let sectionID = element.id.uuidString
        workspace = try TiyiPracticeWorkspace(directory: directory, title: "圈题作答",
            sections: payload.sections.isEmpty ? [.init(id: sectionID, label: "圈题作答")] : payload.sections,
            packageData: payload.answerPackage,
            seeds: payload.answerPackage == nil ? [.init(questionID: sectionID, image: image)] : [],
            lastPageID: payload.lastPageID)
        workspace.assistantContext = { [weak workspace] in
            TiyiAssistantContext(scope: .init(kind: "document_question", sourceId: documentID, questionId: element.id.uuidString),
                title: "圈题作答", prompt: "当前题目是从文稿圈选的题面。请以本轮题目图片和最新作答为准。",
                captureQuestion: { [.init(id: "question", label: "题面", data: payload.snapshotPNG)] },
                capture: { try workspace?.assistantImages() ?? [] })
        }
        // Reject nested attachments even when loading an externally supplied editable package.
        guard workspace.store.pages(in: workspace.documentID).allSatisfy({ page in
            workspace.store.loadPageElements(forPage: page.orderIndex, in: workspace.documentID)
                .allSatisfy { $0.question == nil }
        }) else { throw CocoaError(.fileReadCorruptFile) }
        workspace.packageExportDate = Date(timeIntervalSince1970: 0)
        workspace.isCompleted = payload.isCompleted
        workspace.onCheckpoint = { [weak self] data, sections, lastPage in
            try self?.save(data: data, sections: sections, lastPage: lastPage)
        }
        workspace.onToggleCompleted = { [weak self] in
            guard let self else { return }
            self.workspace.isCompleted.toggle()
            do { try self.workspace.checkpoint() }
            catch { self.workspace.isCompleted.toggle(); throw error }
        }
        if isNew { try workspace.checkpoint() }
    }

    private func save(data: Data, sections: [TiyiPracticeSection], lastPage: String?) throws {
        guard let index = sourceStore.pageIndex(for: pageID, in: documentID),
              var payload = element.question else { throw CocoaError(.fileNoSuchFile) }
        if savedElement != nil {
            guard sourceStore.loadPageElements(forPage: index, in: documentID).contains(where: { $0.id == element.id }) else {
                throw NSError(domain: "DocumentQuestion", code: 1, userInfo: [NSLocalizedDescriptionKey: "原文稿中的圈题已被删除，作答仍保留在本机。请恢复原圈题后再保存。"])
            }
        }
        payload.answerPackage = data
        payload.sections = sections
        payload.lastPageID = lastPage
        payload.isCompleted = workspace.isCompleted
        var updated = element
        updated.payload = .question(payload)
        guard updated != savedElement else { return }
        // Only this attachment participates in the delta. Other page objects may have changed remotely.
        // Retain the opening causal context so simultaneous answer edits are preserved as conflict versions.
        let nextContext = sourceStore.scheduleSave([updated], replacing: savedElement.map { [$0] } ?? [],
            causalContext: context, forPage: index, in: documentID)
        if case .failed(let message) = sourceStore.saveState {
            throw NSError(domain: "DocumentQuestion", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard sourceStore.flushAllPendingSaves() else { throw CocoaError(.fileWriteUnknown) }
        context = nextContext
        element = updated
        savedElement = updated
        workspace.statusText = "已保存到文稿"
    }

    func discardWorkingCopy() {
        workspace.onCheckpoint = nil
        workspace.onToggleCompleted = nil
        UserDefaults.standard.removePersistentDomain(forName: "tiyi.practice.\(directory.lastPathComponent)")
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Region capture deliberately uses geometry, so printed PDF content can be circled without OCR or objects.
struct QuestionCaptureOverlay: View {
    let projection: PageProjection
    let onConfirm: (CGRect) -> Void
    @State private var points: [CGPoint] = []
    @State private var crop: CGRect?
    @State private var dragOrigin: CGRect?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                LassoInputView(shouldBeginDrag: { point, _ in
                    crop.map { !projection.displayRect($0, displaySize: geometry.size).contains(point) } ?? true
                }, onBegan: { point in
                        crop = nil
                        points = [projection.logicalPoint(point, displaySize: geometry.size)]
                    }, onMoved: { point in
                        points.append(projection.logicalPoint(point, displaySize: geometry.size))
                    }, onEnded: { point in
                        points.append(projection.logicalPoint(point, displaySize: geometry.size))
                        finishSelection()
                    }, onTap: { point in dismissOutside(point, displaySize: geometry.size) },
                       onDoubleTap: { point in dismissOutside(point, displaySize: geometry.size) })
                    .accessibilityIdentifier("question-capture-area")
                if crop == nil {
                    Path { path in
                        guard let first = points.first else { return }
                        path.move(to: projection.displayPoint(first, displaySize: geometry.size))
                        for point in points.dropFirst() { path.addLine(to: projection.displayPoint(point, displaySize: geometry.size)) }
                    }.stroke(TiyiNoteTheme.lassoBlue, style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round, dash: [4, 3]))
                    .allowsHitTesting(false)
                }
                if let crop {
                    let rect = projection.displayRect(crop, displaySize: geometry.size)
                    Rectangle().fill(Color.clear)
                        .overlay { Rectangle().stroke(TiyiNoteTheme.lassoBlue, lineWidth: 1.15).allowsHitTesting(false) }
                        .contentShape(Rectangle())
                        .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                        .accessibilityIdentifier("question-selection-box")
                        .gesture(DragGesture().onChanged { value in
                            let origin = dragOrigin ?? crop; dragOrigin = origin
                            let delta = projection.logicalTranslation(value.translation, displaySize: geometry.size)
                            self.crop = projection.constrain(origin.offsetBy(dx: delta.width, dy: delta.height))
                        }.onEnded { _ in dragOrigin = nil })
                    ForEach(0..<4) { corner in
                        let point = CGPoint(x: corner % 2 == 0 ? rect.minX : rect.maxX,
                                            y: corner < 2 ? rect.minY : rect.maxY)
                        Circle().fill(Color.white).frame(width: 9, height: 9)
                            .overlay { Circle().stroke(TiyiNoteTheme.lassoBlue, lineWidth: 1.35) }
                            .contentShape(Circle().inset(by: -12))
                            .position(point)
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                let origin = dragOrigin ?? crop; dragOrigin = origin
                                let delta = projection.logicalTranslation(value.translation, displaySize: geometry.size)
                                let x = corner % 2 == 0 ? min(origin.minX + delta.width, origin.maxX - 12) : origin.minX
                                let y = corner < 2 ? min(origin.minY + delta.height, origin.maxY - 12) : origin.minY
                                let maxX = corner % 2 == 1 ? max(origin.maxX + delta.width, origin.minX + 12) : origin.maxX
                                let maxY = corner >= 2 ? max(origin.maxY + delta.height, origin.minY + 12) : origin.maxY
                                self.crop = clipped(CGRect(x: x, y: y, width: maxX - x, height: maxY - y))
                            }.onEnded { _ in dragOrigin = nil })
                            .accessibilityLabel("调整圈题范围 \(corner + 1)")
                    }
                }
                if let crop {
                    SelectionActionButton(title: "作答", symbol: CanvasToolKind.question.symbolName, tint: TiyiNoteTheme.textPrimary) { onConfirm(crop) }
                        .accessibilityIdentifier("question-confirm")
                        .modifier(SelectionActionBarChrome(identifier: "question-action-bar"))
                        .position(SelectionActionBarLayout.position(
                            bounds: projection.displayRect(crop, displaySize: geometry.size),
                            displaySize: geometry.size, halfWidth: 21))
                }
            }
            .contentShape(Rectangle())
        }
    }

    private func dismissOutside(_ point: CGPoint, displaySize: CGSize) {
        guard let crop, !projection.displayRect(crop, displaySize: displaySize).contains(point) else { return }
        self.crop = nil
        points = []
        dragOrigin = nil
    }

    private func clipped(_ rect: CGRect) -> CGRect {
        projection.isUnbounded ? rect : rect.intersection(projection.logicalBounds)
    }
    private func finishSelection() {
        guard let first = points.first else { return }
        let bounds = points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        guard bounds.width > 12, bounds.height > 12 else { points = []; return }
        crop = clipped(bounds.insetBy(dx: -8, dy: -8))
    }
}

/// Marker input belongs to the canvas, just like shapes. In particular, this visual must not
/// intercept the canvas finger-selection recognizer or Pencil drawing contacts.
struct QuestionMarkerView: View {
    static let visualScale: CGFloat = 0.75
    static let maximumDisplaySize: CGFloat = 24
    let isCompleted: Bool

    var body: some View {
        Image(systemName: CanvasToolKind.question.symbolName)
            .resizable()
            .scaledToFit()
            .scaleEffect(Self.visualScale)
            .foregroundStyle(TiyiNoteTheme.selectionBlue)
            .accessibilityLabel(isCompleted ? "继续圈题作答，已完成" : "继续圈题作答")
            .accessibilityHint("点击选中，再进入作答或删除")
            .accessibilityIdentifier("question-marker")
            .allowsHitTesting(false)
    }
}
