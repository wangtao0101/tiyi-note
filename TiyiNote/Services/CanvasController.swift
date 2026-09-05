import PencilKit
import SwiftUI

final class CanvasController: NSObject, ObservableObject {
    /// Simulator touch synthesis normally stands in for Pencil input. Navigation regressions can
    /// opt into the real iPad policy, where fingers navigate and only Pencil creates ink or lassos.
    static var allowsFingerDrawing: Bool {
#if targetEnvironment(simulator)
        !ProcessInfo.processInfo.arguments.contains("--pencil-only-ui-test")
#else
        false
#endif
    }

    /// Handwriting history stores only the inverse of the edit. A normal Pencil contact therefore
    /// contributes one small "remove trailing stroke" command instead of retaining another copy of
    /// the complete page. Full drawings are kept only for inherently whole-page edits such as an
    /// eraser pass, lasso transform, or Clear.
    private static let maximumUndoDepth = 80
    /// Automatic fitting is deliberately absent from the production ink path. A timer cannot know
    /// whether an eight-second pause means "finished writing" or "about to write the next line";
    /// waking then to materialize the complete PKDrawing is exactly the kind of intermittent work
    /// that causes a late first Pencil sample. Shapes remain available through the explicit shape
    /// tool. The old held-ink recognizer is opt-in only for its isolated regression coverage until
    /// it can be driven by a dedicated interaction instead of an idle timer.
    private static var allowsDeferredInkShapeRecognition: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--enable-deferred-ink-shape-recognition")
#else
        false
#endif
    }

    private static var shapeRecognitionIdleDelay: UInt64 {
#if DEBUG
        // Shape UI tests deliberately exercise the feature in a short-lived isolated workspace.
        // Keep their wait bounded without weakening the shipping input path.
        if ProcessInfo.processInfo.arguments.contains("--text-interaction-ui-test") {
            return 800_000_000
        }
#endif
        return 8_000_000_000
    }
    let canvasView: PKCanvasView

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// Kept out of `ObservableObject` publishing on purpose. Publishing at Pencil-down forces the
    /// complete SwiftUI page hierarchy to recompute exactly when PencilKit needs the main thread.
    private(set) var isUsingTool = false
    @Published private(set) var lastSnappedShapeKind: PageShapeKind?
#if DEBUG
    private(set) var synchronizedDrawingInstallCount = 0
#endif

    /// `true` means every edit since the previous callback only appended ink. The page view uses
    /// this hint to keep the collaboration save on its cheap append-only path without reading the
    /// complete `PKDrawing` after every Pencil lift.
    var onDrawingChanged: ((Bool) -> Void)?
    var onBecameActive: (() -> Void)?
    var onToolInteractionChanged: ((Bool) -> Void)?

    private var isInstallingDrawing = false
    private var strokeTransformSession: StrokeTransformSession?
    private var toolInteractionOriginDrawing: PKDrawing?
    private var toolInteractionDidChangeDrawing = false
    private var toolInteractionEndWorkItem: DispatchWorkItem?
    private var postLiftDrawingRetryCount = 0
    private var undoActions: [DrawingHistoryAction] = []
    private var redoActions: [DrawingHistoryAction] = []
    private var eraserBaselineDrawing: PKDrawing?
    private var knownStrokeCount = 0
    private var selectedToolKind = CanvasToolKind.pen
    private var shapeGestureOriginStrokeCount: Int?
    private var shapeGestureEndedAt: Date?
    private var shapeSnapInkStyle: ShapeSnapInkStyle?
    private var shapeRecognitionTask: Task<Void, Never>?
    private var shapeGestureRevision: UInt64 = 0
    private var authoritativeSnappedDrawing: PKDrawing?
    private var isAnnotationInputEditable = true

    override init() {
        let canvasView = TiyiPencilCanvasView(frame: .zero)
        self.canvasView = canvasView
        super.init()

        canvasView.delegate = self
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.alwaysBounceHorizontal = false
        canvasView.alwaysBounceVertical = false
        canvasView.bounces = false
        canvasView.isScrollEnabled = false
        canvasView.overrideUserInterfaceStyle = .light
        configureAnnotationInput(isEditable: true)
        canvasView.tool = PKInkingTool(.monoline, color: InkPaletteColor.graphite.uiColor, width: 4)
    }

    /// PencilKit writes in a positive local tile space; all editing, history and persistence use
    /// stable world coordinates. The origin only moves when navigation exhausts the tile margin.
    private(set) var canvasWorldOrigin: CGPoint = .zero

    var drawing: PKDrawing {
        let localDrawing = canvasView.drawing
        guard canvasWorldOrigin != .zero else { return localDrawing }
        return localDrawing.transformed(using: CGAffineTransform(
            translationX: canvasWorldOrigin.x, y: canvasWorldOrigin.y
        ))
    }

    func prepareUnboundedViewport(_ viewport: CGRect) -> CGRect {
        var nextOrigin = canvasWorldOrigin
        let tile: CGFloat = 4096
        if viewport.minX < nextOrigin.x + viewport.width {
            nextOrigin.x = floor((viewport.minX - viewport.width) / tile) * tile
        }
        if viewport.minY < nextOrigin.y + viewport.height {
            nextOrigin.y = floor((viewport.minY - viewport.height) / tile) * tile
        }
        if nextOrigin != canvasWorldOrigin, !isUsingTool {
            let worldDrawing = drawing
            canvasWorldOrigin = nextOrigin
            installCanvasDrawing(worldDrawing, preservingShapeAuthority: true)
        }
        return viewport.offsetBy(dx: -canvasWorldOrigin.x, dy: -canvasWorldOrigin.y)
    }
    /// Lightweight count maintained at transaction boundaries. Production accessibility and
    /// toolbar refreshes use this instead of materializing `self.drawing` during an unrelated
    /// SwiftUI body update.
    var strokeCount: Int { knownStrokeCount }

    func installInitialDrawing(_ drawing: PKDrawing) {
        installCanvasDrawing(drawing)
        canvasView.undoManager?.removeAllActions()
        undoActions.removeAll()
        redoActions.removeAll()
        toolInteractionOriginDrawing = nil
        toolInteractionDidChangeDrawing = false
        toolInteractionEndWorkItem?.cancel()
        toolInteractionEndWorkItem = nil
        postLiftDrawingRetryCount = 0
        eraserBaselineDrawing = selectedToolKind == .eraser ? drawing : nil
        shapeRecognitionTask?.cancel()
        shapeRecognitionTask = nil
        authoritativeSnappedDrawing = nil
        resetShapeTrackingState()
        setToolInteractionActive(false)
        refreshHistoryState()
    }

    func installSynchronizedDrawing(
        _ drawing: PKDrawing,
        preservingHistory: Bool
    ) {
        // A page asset revision may arrive from autosave or CloudKit while PencilKit still owns an
        // in-flight stroke. The page view defers those revisions; keep this controller-level guard
        // as the final invariant against replacing a live transaction.
        guard !isUsingTool else { return }
#if DEBUG
        synchronizedDrawingInstallCount += 1
#endif
        guard preservingHistory else {
            installInitialDrawing(drawing)
            return
        }
        installCanvasDrawing(drawing)
        refreshHistoryState()
    }

    func updateTool(
        kind: CanvasToolKind,
        color: InkPaletteColor,
        width: Double,
        eraserSize: CanvasEraserSize,
        eraserMode: CanvasEraserMode
    ) {
        let previousToolKind = selectedToolKind
        selectedToolKind = kind
        if kind == .eraser {
            if previousToolKind != .eraser {
                // Erasing can mutate or split any stroke, so it is the one live tool that needs a
                // whole-page inverse. Capture it when the user selects the eraser, not on every
                // normal Pencil contact.
                eraserBaselineDrawing = self.drawing
            }
        } else {
            eraserBaselineDrawing = nil
        }
        if !kind.usesInkSettings {
            cancelShapeTracking()
        }
        canvasView.drawingGestureRecognizer.isEnabled = kind != .lasso && kind != .text

        switch kind {
        case .pen:
            // Values below PencilKit's supported monoline range are rendered by
            // reducing pixel coverage, which makes opaque ink look translucent.
            // Keep fine presets on the thinnest supported, fully opaque hairline.
            let opaqueHairlineWidth = max(
                CGFloat(width),
                PKInkingTool.InkType.monoline.validWidthRange.lowerBound
            )
            canvasView.tool = PKInkingTool(
                .monoline,
                color: color.uiColor.withAlphaComponent(1),
                width: opaqueHairlineWidth
            )
        case .fountainPen:
            canvasView.tool = PKInkingTool(
                .fountainPen,
                color: color.uiColor.withAlphaComponent(1),
                width: min(
                    max(CGFloat(width), PKInkingTool.InkType.fountainPen.validWidthRange.lowerBound),
                    PKInkingTool.InkType.fountainPen.validWidthRange.upperBound
                )
            )
        case .pencil:
            canvasView.tool = PKInkingTool(
                .pencil,
                color: color.uiColor.withAlphaComponent(0.92),
                width: min(
                    max(CGFloat(width), PKInkingTool.InkType.pencil.validWidthRange.lowerBound),
                    PKInkingTool.InkType.pencil.validWidthRange.upperBound
                )
            )
        case .marker:
            canvasView.tool = PKInkingTool(
                .marker,
                color: color.uiColor.withAlphaComponent(0.58),
                width: width
            )
        case .eraser:
            canvasView.tool = eraserMode == .stroke
                ? PKEraserTool(.vector)
                : PKEraserTool(.fixedWidthBitmap, width: eraserSize.width)
        case .lasso:
            canvasView.tool = PKLassoTool()
        case .text:
            // Text is handled by the page-object interaction layer. Keeping the
            // PencilKit recognizer disabled prevents an accidental ink stroke
            // while the text tool is visibly selected.
            canvasView.tool = PKLassoTool()
        }
    }

    func configureAnnotationInput(isEditable: Bool = true) {
        isAnnotationInputEditable = isEditable
        guard isEditable else {
            canvasView.drawingGestureRecognizer.isEnabled = false
            canvasView.drawingPolicy = .pencilOnly
            return
        }

        canvasView.drawingGestureRecognizer.isEnabled = true
        canvasView.drawingPolicy = Self.allowsFingerDrawing ? .anyInput : .pencilOnly
        canvasView.drawingGestureRecognizer.allowedTouchTypes = Self.allowsFingerDrawing ? [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ] : [
            NSNumber(value: UITouch.TouchType.pencil.rawValue)
        ]
    }

    func undo() {
        guard let action = undoActions.popLast(),
              let inverse = applyHistoryAction(action) else { return }
        redoActions.append(inverse)
        onDrawingChanged?(false)
        refreshHistoryState()
    }

    func redo() {
        guard let action = redoActions.popLast(),
              let inverse = applyHistoryAction(action) else { return }
        undoActions.append(inverse)
        trimUndoHistoryIfNeeded()
        onDrawingChanged?(false)
        refreshHistoryState()
    }

    func clear() {
        guard !self.drawing.strokes.isEmpty else { return }
        replaceDrawing(PKDrawing(), actionName: "清空画板")
    }

    func strokeIndices(inside polygon: [CGPoint]) -> Set<Int> {
        guard polygon.count >= 3 else { return [] }
        let polygonBounds = Self.boundingRect(for: polygon).insetBy(dx: -2, dy: -2)

        return Set(self.drawing.strokes.enumerated().compactMap { index, stroke in
            guard stroke.renderBounds.intersects(polygonBounds) else { return nil }

            if polygonContains(stroke.renderBounds.center, polygon: polygon) {
                return index
            }

            for point in stroke.path.interpolatedPoints(by: .distance(3)) {
                if polygonContains(point.location, polygon: polygon) {
                    return index
                }
            }
            return nil
        })
    }

    func boundsForStrokes(at indices: Set<Int>) -> CGRect? {
        let strokes = self.drawing.strokes
        let bounds = indices.reduce(into: CGRect.null) { result, index in
            guard strokes.indices.contains(index) else { return }
            result = result.union(strokes[index].renderBounds)
        }
        return bounds.isNull ? nil : bounds
    }

    func drawingForStrokes(at indices: Set<Int>, normalized: Bool = false) -> PKDrawing {
        let strokes = self.drawing.strokes
        let drawing = PKDrawing(strokes: indices.sorted().compactMap { index in
            strokes.indices.contains(index) ? strokes[index] : nil
        })
        guard normalized, !drawing.bounds.isNull else { return drawing }
        return drawing.transformed(
            using: CGAffineTransform(
                translationX: -drawing.bounds.minX,
                y: -drawing.bounds.minY
            )
        )
    }

    func deleteStrokes(at indices: Set<Int>) {
        guard !indices.isEmpty else { return }
        let retainedStrokes = self.drawing.strokes.enumerated().compactMap { index, stroke in
            indices.contains(index) ? nil : stroke
        }
        replaceDrawing(PKDrawing(strokes: retainedStrokes), actionName: "删除选中笔迹")
    }

    @discardableResult
    func duplicateStrokes(
        at indices: Set<Int>,
        offset: CGSize,
        within pageSize: CGSize?
    ) -> Set<Int> {
        guard
            !indices.isEmpty,
            let bounds = boundsForStrokes(at: indices)
        else { return [] }

        var translation = offset
        if let pageSize, bounds.maxX + translation.width > pageSize.width {
            translation.width = -abs(offset.width)
        }
        if let pageSize, bounds.maxY + translation.height > pageSize.height {
            translation.height = -abs(offset.height)
        }

        let copiedStrokes = drawingForStrokes(at: indices)
            .transformed(
                using: CGAffineTransform(
                    translationX: translation.width,
                    y: translation.height
                )
            )
            .strokes
        return appendStrokes(copiedStrokes, actionName: "复制选中笔迹")
    }

    @discardableResult
    func pasteDrawing(
        _ drawing: PKDrawing,
        centeredAt point: CGPoint,
        within pageSize: CGSize?
    ) -> Set<Int> {
        guard !drawing.strokes.isEmpty, !drawing.bounds.isNull else { return [] }

        let bounds = drawing.bounds
        var dx = point.x - bounds.midX
        var dy = point.y - bounds.midY
        let proposedBounds = bounds.offsetBy(dx: dx, dy: dy)

        if let pageSize {
            if proposedBounds.minX < 0 { dx -= proposedBounds.minX }
            if proposedBounds.maxX > pageSize.width { dx -= proposedBounds.maxX - pageSize.width }
            if proposedBounds.minY < 0 { dy -= proposedBounds.minY }
            if proposedBounds.maxY > pageSize.height { dy -= proposedBounds.maxY - pageSize.height }
        }

        let pastedStrokes = drawing
            .transformed(using: CGAffineTransform(translationX: dx, y: dy))
            .strokes
        return appendStrokes(pastedStrokes, actionName: "粘贴笔迹")
    }

    func beginTransformingStrokes(at indices: Set<Int>) {
        guard !indices.isEmpty else { return }
        strokeTransformSession = StrokeTransformSession(
            originalDrawing: self.drawing,
            strokeIndices: indices.sorted()
        )
    }

    func previewStrokeTransform(_ transform: CGAffineTransform) {
        guard let session = strokeTransformSession else { return }
        installCanvasDrawing(
            drawingByTransformingStrokes(in: session, using: transform)
        )
    }

    func commitStrokeTransform(_ transform: CGAffineTransform, actionName: String) {
        guard let session = strokeTransformSession else { return }
        let transformedDrawing = drawingByTransformingStrokes(in: session, using: transform)
        strokeTransformSession = nil

        guard transformedDrawing != session.originalDrawing else {
            installCanvasDrawing(session.originalDrawing)
            return
        }
        replaceDrawing(
            transformedDrawing,
            actionName: actionName,
            previousDrawing: session.originalDrawing
        )
    }

    func cancelStrokeTransform() {
        guard let session = strokeTransformSession else { return }
        strokeTransformSession = nil
        installCanvasDrawing(session.originalDrawing)
    }

    private func replaceDrawing(
        _ newDrawing: PKDrawing,
        actionName: String,
        previousDrawing: PKDrawing? = nil
    ) {
        let previousDrawing = previousDrawing ?? self.drawing
        guard newDrawing != previousDrawing else { return }
        recordUndoAction(.restoreDrawing(previousDrawing))
        installCanvasDrawing(newDrawing)
        onDrawingChanged?(false)
        refreshHistoryState()
        _ = actionName
    }

    private func appendStrokes(_ strokes: [PKStroke], actionName: String) -> Set<Int> {
        guard !strokes.isEmpty else { return [] }
        let firstIndex = self.drawing.strokes.count
        let newDrawing = PKDrawing(strokes: self.drawing.strokes + strokes)
        replaceDrawing(newDrawing, actionName: actionName)
        return Set(firstIndex..<(firstIndex + strokes.count))
    }

    private func installCanvasDrawing(
        _ drawing: PKDrawing,
        preservingShapeAuthority: Bool = false
    ) {
        if !preservingShapeAuthority {
            authoritativeSnappedDrawing = nil
        }
        isInstallingDrawing = true
        canvasView.drawing = canvasWorldOrigin == .zero ? drawing : drawing.transformed(
            using: CGAffineTransform(translationX: -canvasWorldOrigin.x, y: -canvasWorldOrigin.y)
        )
        knownStrokeCount = drawing.strokes.count
        if selectedToolKind == .eraser {
            eraserBaselineDrawing = drawing
        }
        isInstallingDrawing = false
    }

    private func drawingByTransformingStrokes(
        in session: StrokeTransformSession,
        using transform: CGAffineTransform
    ) -> PKDrawing {
        var strokes = session.originalDrawing.strokes
        let selectedStrokes = session.strokeIndices.compactMap { index in
            strokes.indices.contains(index) ? strokes[index] : nil
        }
        let transformedStrokes = PKDrawing(strokes: selectedStrokes)
            .transformed(using: transform)
            .strokes

        for (offset, index) in session.strokeIndices.enumerated()
        where strokes.indices.contains(index) && transformedStrokes.indices.contains(offset) {
            strokes[index] = transformedStrokes[offset]
        }
        return PKDrawing(strokes: strokes)
    }

    private func polygonContains(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        var isInside = false
        var previousIndex = polygon.count - 1

        for index in polygon.indices {
            let current = polygon[index]
            let previous = polygon[previousIndex]
            let crossesHorizontalRay = (current.y > point.y) != (previous.y > point.y)
            if crossesHorizontalRay {
                let intersectionX = (previous.x - current.x)
                    * (point.y - current.y)
                    / (previous.y - current.y)
                    + current.x
                if point.x < intersectionX {
                    isInside.toggle()
                }
            }
            previousIndex = index
        }
        return isInside
    }

    nonisolated private static func boundingRect(for points: [CGPoint]) -> CGRect {
        guard let firstPoint = points.first else { return .null }
        var minX = firstPoint.x
        var maxX = firstPoint.x
        var minY = firstPoint.y
        var maxY = firstPoint.y

        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func refreshHistoryState() {
        let nextCanUndo = !undoActions.isEmpty
        let nextCanRedo = !redoActions.isEmpty
        if canUndo != nextCanUndo {
            canUndo = nextCanUndo
        }
        if canRedo != nextCanRedo {
            canRedo = nextCanRedo
        }
    }

    private func recordUndoAction(_ action: DrawingHistoryAction) {
        undoActions.append(action)
        trimUndoHistoryIfNeeded()
        redoActions.removeAll()
    }

    private func trimUndoHistoryIfNeeded() {
        if undoActions.count > Self.maximumUndoDepth {
            undoActions.removeFirst(undoActions.count - Self.maximumUndoDepth)
        }
    }

    private func applyHistoryAction(_ action: DrawingHistoryAction) -> DrawingHistoryAction? {
        switch action {
        case .removeTrailingStrokes(let count):
            guard count > 0 else { return nil }
            let strokes = self.drawing.strokes
            guard strokes.count >= count else { return nil }
            let removed = Array(strokes.suffix(count))
            installCanvasDrawing(PKDrawing(strokes: Array(strokes.dropLast(count))))
            return .appendStrokes(removed)
        case .appendStrokes(let strokes):
            guard !strokes.isEmpty else { return nil }
            installCanvasDrawing(PKDrawing(strokes: self.drawing.strokes + strokes))
            return .removeTrailingStrokes(strokes.count)
        case .restoreDrawing(let drawing):
            let currentDrawing = self.drawing
            guard currentDrawing != drawing else { return nil }
            installCanvasDrawing(drawing)
            return .restoreDrawing(currentDrawing)
        }
    }

    private func beginToolInteraction() {
        toolInteractionEndWorkItem?.cancel()
        toolInteractionEndWorkItem = nil
        guard !isUsingTool else { return }

        if Self.allowsDeferredInkShapeRecognition {
            // Any opt-in shape analysis left by the preceding stroke is speculative. A new Pencil
            // contact wins immediately and cancels it before the worker reaches the geometry code.
            cancelShapeTracking()
        }

        // A snapped drawing remains authoritative after lift only to reject a late cancellation
        // callback from the gesture that produced it. A genuinely new Pencil contact starts a new
        // transaction and can safely release that guard.
        authoritativeSnappedDrawing = nil
        if selectedToolKind == .eraser, toolInteractionOriginDrawing == nil {
            toolInteractionOriginDrawing = eraserBaselineDrawing ?? self.drawing
        } else if selectedToolKind != .eraser {
            toolInteractionOriginDrawing = nil
        }
        toolInteractionDidChangeDrawing = false
        postLiftDrawingRetryCount = 0
        setToolInteractionActive(true)
        if Self.allowsDeferredInkShapeRecognition {
            beginShapeTracking()
        }
        onBecameActive?()
    }

    private func requestToolInteractionFinish() {
        // A delayed delegate end from the previous Pencil contact can arrive after the next one
        // has already begun on hardware. Never let that stale end release the new transaction.
        guard !hasActiveDrawingContact else { return }

        // Keep only the lift time. The completed stroke is deliberately not read here: even a
        // seemingly cheap `drawing.strokes.last` can materialize the complete PencilKit value and
        // block the first samples of the next stroke. Shape intent and geometry are inspected only
        // after the editor has remained fully idle.
        if shapeGestureOriginStrokeCount != nil, shapeGestureEndedAt == nil {
            shapeGestureEndedAt = Date()
        }

        // PencilKit's final drawing callback and its recognizer/delegate end callbacks are not
        // ordered consistently on hardware. Keeping the interaction active until the next main
        // turn makes the final canvas value authoritative before autosave or a deferred sync reload
        // is allowed to run.
        toolInteractionEndWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.finishShapeTrackingAfterPencilLift()
        }
        toolInteractionEndWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func finishToolInteractionNow() {
        toolInteractionEndWorkItem = nil
        guard isUsingTool,
              !hasActiveDrawingContact else { return }

        let didChangeDrawing = toolInteractionDidChangeDrawing
        if didChangeDrawing {
            if selectedToolKind.usesInkSettings {
                // One Pencil contact produces one PencilKit stroke. Store the inverse command;
                // the stroke itself is captured only if the user actually asks for Undo.
                recordUndoAction(.removeTrailingStrokes(1))
                knownStrokeCount += 1
            } else if selectedToolKind == .eraser,
                      let originDrawing = toolInteractionOriginDrawing {
                recordUndoAction(.restoreDrawing(originDrawing))
                let finalDrawing = self.drawing
                knownStrokeCount = finalDrawing.strokes.count
                eraserBaselineDrawing = finalDrawing
            }
        }
        toolInteractionOriginDrawing = nil
        toolInteractionDidChangeDrawing = false

        // This is presentation-only state. Clear it after Pencil-up, never at Pencil-down, so a
        // published accessibility change cannot invalidate SwiftUI while low-latency ink starts.
        if lastSnappedShapeKind != nil {
            lastSnappedShapeKind = nil
        }

        // Mark the page dirty, but do not materialize a complete PKDrawing here. The page captures
        // one immutable snapshot only after a sustained idle interval.
        if didChangeDrawing {
            onDrawingChanged?(selectedToolKind.usesInkSettings)
        }
        setToolInteractionActive(false)
        refreshHistoryState()
    }

    private func setToolInteractionActive(_ isActive: Bool) {
        guard isUsingTool != isActive else { return }
        isUsingTool = isActive
        onToolInteractionChanged?(isActive)
    }

    private var hasActiveDrawingContact: Bool {
        let drawingState = canvasView.drawingGestureRecognizer.state
        return drawingState == .began || drawingState == .changed
    }

    private func beginShapeTracking() {
        guard selectedToolKind.usesInkSettings,
              let tool = canvasView.tool as? PKInkingTool else { return }
        shapeGestureOriginStrokeCount = knownStrokeCount
        shapeGestureEndedAt = nil
        shapeSnapInkStyle = ShapeSnapInkStyle(
            inkType: tool.inkType,
            color: tool.color,
            width: tool.width
        )
    }

    private func finishShapeTrackingAfterPencilLift() {
        toolInteractionEndWorkItem = nil
        guard Self.allowsDeferredInkShapeRecognition else {
            // Production completes a normal Pencil transaction here. There is no delayed task,
            // whole-page read, path interpolation, haptic, or later drawing replacement.
            finishToolInteractionNow()
            return
        }
        // Real hardware and XCTest can deliver the final drawing delegate callback a few main
        // turns after both gesture/delegate end notifications. Keep the transaction open briefly
        // instead of classifying that late final stroke as a new interaction.
        if isUsingTool,
           !toolInteractionDidChangeDrawing,
           postLiftDrawingRetryCount < 4 {
            postLiftDrawingRetryCount += 1
            let workItem = DispatchWorkItem { [weak self] in
                self?.finishShapeTrackingAfterPencilLift()
            }
            toolInteractionEndWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: workItem)
            return
        }
        postLiftDrawingRetryCount = 0
        guard let originStrokeCount = shapeGestureOriginStrokeCount,
              let inkStyle = shapeSnapInkStyle,
              let gestureEndedAt = shapeGestureEndedAt,
              toolInteractionDidChangeDrawing else {
            cancelShapeTracking()
            finishToolInteractionNow()
            return
        }

        toolInteractionEndWorkItem?.cancel()
        toolInteractionEndWorkItem = nil
        let revision = shapeGestureRevision
        resetShapeTrackingState()

        // Commit the handwriting transaction before scheduling optional shape work. The next
        // stroke can now begin normally and will cancel the deferred recognition task.
        finishToolInteractionNow()
        shapeRecognitionTask?.cancel()
        shapeRecognitionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.shapeRecognitionIdleDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self,
                  !self.isUsingTool,
                  self.shapeGestureRevision == revision,
                  self.knownStrokeCount == originStrokeCount + 1 else { return }

            // This is the first path read for the completed contact, and it happens only after a
            // sustained editor-wide idle period. If the user writes another stroke, the task is
            // cancelled before this MainActor snapshot is captured.
            let currentStrokes = self.drawing.strokes
            guard currentStrokes.count == originStrokeCount + 1,
                  let roughStroke = currentStrokes.last else { return }
            let worker = Task.detached(priority: .background) {
                guard Self.stationaryTailDuration(
                    of: roughStroke,
                    gestureEndedAt: gestureEndedAt
                ) >= 0.62 else { return nil as ShapeSnapCandidate? }
                let points = roughStroke.path
                    .interpolatedPoints(by: .distance(3.5))
                    .map(\.location)
                guard !Task.isCancelled else { return nil as ShapeSnapCandidate? }
                return Self.recognizedShape(from: points)
            }
            let candidate = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            self.shapeRecognitionTask = nil
            guard !Task.isCancelled,
                  !self.isUsingTool,
                  self.shapeGestureRevision == revision,
                  let candidate else {
                return
            }
            self.commitSnappedShape(
                candidate,
                originStrokeCount: originStrokeCount,
                inkStyle: inkStyle
            )
        }
    }

    private func cancelShapeTracking() {
        shapeRecognitionTask?.cancel()
        shapeRecognitionTask = nil
        shapeGestureRevision &+= 1
        resetShapeTrackingState()
    }

    private func resetShapeTrackingState() {
        shapeGestureOriginStrokeCount = nil
        shapeGestureEndedAt = nil
        shapeSnapInkStyle = nil
    }

    /// Derives hold intent from PencilKit's completed immutable path. Some devices keep producing
    /// stationary control points while pressure changes; others stop appending points until lift.
    /// Measuring from the earliest final-position point to the actual gesture end handles both
    /// behaviours without observing or polling live Pencil samples.
    nonisolated private static func stationaryTailDuration(
        of stroke: PKStroke,
        gestureEndedAt: Date
    ) -> TimeInterval {
        let path = stroke.path
        guard let finalPoint = path.last else { return 0 }
        var stationaryStartOffset = finalPoint.timeOffset
        for point in path.reversed() {
            guard distance(point.location, finalPoint.location) < 4 else { break }
            stationaryStartOffset = point.timeOffset
        }
        let stationaryStartedAt = path.creationDate.addingTimeInterval(stationaryStartOffset)
        return max(0, gestureEndedAt.timeIntervalSince(stationaryStartedAt))
    }

    private func commitSnappedShape(
        _ candidate: ShapeSnapCandidate,
        originStrokeCount: Int,
        inkStyle: ShapeSnapInkStyle
    ) {
        guard let stroke = regularStroke(for: candidate, inkStyle: inkStyle) else {
            return
        }

        // PencilKit has already finished the rough stroke, so replacing it no longer requires
        // disabling its drawing recognizer or racing cancellation callbacks on real hardware.
        let currentStrokes = self.drawing.strokes
        guard !isUsingTool,
              currentStrokes.count == originStrokeCount + 1 else { return }
        let originStrokes = Array(currentStrokes.prefix(originStrokeCount))
        toolInteractionEndWorkItem?.cancel()
        toolInteractionEndWorkItem = nil
        let snappedDrawing = PKDrawing(strokes: originStrokes + [stroke])
        installCanvasDrawing(snappedDrawing)
        authoritativeSnappedDrawing = snappedDrawing
        lastSnappedShapeKind = candidate.kind
        knownStrokeCount = snappedDrawing.strokes.count
        onDrawingChanged?(true)
        refreshHistoryState()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    nonisolated private static func recognizedShape(
        from rawPoints: [CGPoint]
    ) -> ShapeSnapCandidate? {
        let points = deduplicatedPoints(rawPoints, minimumDistance: 1.5)
        guard points.count >= 2 else { return nil }
        let bounds = boundingRect(for: points)
        let diagonal = hypot(bounds.width, bounds.height)
        let length = pathLength(points)
        guard diagonal >= 22, length >= 24 else { return nil }

        let chord = distance(points[0], points[points.count - 1])
        let lineTolerance = max(3, diagonal * 0.045)
        let maximumLineError = points.map {
            distanceFromPoint($0, toSegmentFrom: points[0], to: points[points.count - 1])
        }.max() ?? .greatestFiniteMagnitude
        if chord >= diagonal * 0.72,
           length <= chord * 1.16,
           maximumLineError <= lineTolerance {
            return ShapeSnapCandidate(kind: .line, pathPoints: [points[0], points[points.count - 1]])
        }

        let closureTolerance = max(14, diagonal * 0.22)
        let tracedMostOfAClosedContour = length >= diagonal * 1.20
            && chord <= diagonal * 0.88
        guard chord <= closureTolerance || tracedMostOfAClosedContour,
              points.count >= 5 else { return nil }
        var closedPoints = points
        if distance(closedPoints[0], closedPoints[closedPoints.count - 1]) > 1.5 {
            closedPoints.append(closedPoints[0])
        } else {
            closedPoints[closedPoints.count - 1] = closedPoints[0]
        }

        let simplificationTolerance = max(4, diagonal * 0.055)
        var vertices = ramerDouglasPeucker(
            closedPoints,
            tolerance: simplificationTolerance
        )
        if vertices.count > 1,
           distance(vertices[0], vertices[vertices.count - 1]) <= closureTolerance {
            vertices.removeLast()
        }
        vertices = removingCollinearVertices(
            vertices,
            tolerance: simplificationTolerance * 0.75
        )

        if vertices.count == 3 {
            let triangle = interpolatedPolygon(vertices, closed: true, samplesPerEdge: 12)
            return ShapeSnapCandidate(kind: .triangle, pathPoints: triangle)
        }

        if vertices.count == 4, isRectangleLike(vertices) {
            let rectangleCorners = orientedRectangleCorners(
                for: points,
                guidedBy: vertices
            )
            let rectangle = interpolatedPolygon(
                rectangleCorners,
                closed: true,
                samplesPerEdge: 12
            )
            return ShapeSnapCandidate(kind: .rectangle, pathPoints: rectangle)
        }

        let ellipseError = ellipseFitError(points)
        if let ellipse = regularEllipsePoints(for: points),
           ellipseError <= 0.38 {
            return ShapeSnapCandidate(kind: .ellipse, pathPoints: ellipse)
        }

        return nil
    }

    private func regularStroke(
        for candidate: ShapeSnapCandidate,
        inkStyle: ShapeSnapInkStyle
    ) -> PKStroke? {
        guard candidate.pathPoints.count >= 2 else { return nil }
        let pointSize = CGSize(
            width: max(inkStyle.width, 1),
            height: max(inkStyle.width, 1)
        )
        let controlPoints = candidate.pathPoints.enumerated().map { index, point in
            PKStrokePoint(
                location: point,
                timeOffset: TimeInterval(index) * 0.012,
                size: pointSize,
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        return PKStroke(
            ink: PKInk(inkStyle.inkType, color: inkStyle.color),
            path: PKStrokePath(controlPoints: controlPoints, creationDate: Date())
        )
    }

    nonisolated private static func regularEllipsePoints(
        for points: [CGPoint]
    ) -> [CGPoint]? {
        guard points.count >= 5 else { return nil }
        let center = CGPoint(
            x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
            y: points.map(\.y).reduce(0, +) / CGFloat(points.count)
        )
        let covariance = points.reduce(into: (xx: CGFloat.zero, xy: CGFloat.zero, yy: CGFloat.zero)) {
            partial, point in
            let dx = point.x - center.x
            let dy = point.y - center.y
            partial.xx += dx * dx
            partial.xy += dx * dy
            partial.yy += dy * dy
        }
        let angle = 0.5 * atan2(2 * covariance.xy, covariance.xx - covariance.yy)
        let axis = CGVector(dx: cos(angle), dy: sin(angle))
        let normal = CGVector(dx: -axis.dy, dy: axis.dx)
        let projections = points.map { point -> (u: CGFloat, v: CGFloat) in
            let delta = CGVector(dx: point.x - center.x, dy: point.y - center.y)
            return (
                delta.dx * axis.dx + delta.dy * axis.dy,
                delta.dx * normal.dx + delta.dy * normal.dy
            )
        }
        guard let minU = projections.map(\.u).min(),
              let maxU = projections.map(\.u).max(),
              let minV = projections.map(\.v).min(),
              let maxV = projections.map(\.v).max() else { return nil }
        let radiusU = max((maxU - minU) / 2, 1)
        let radiusV = max((maxV - minV) / 2, 1)
        let adjustedCenter = CGPoint(
            x: center.x + axis.dx * ((minU + maxU) / 2) + normal.dx * ((minV + maxV) / 2),
            y: center.y + axis.dy * ((minU + maxU) / 2) + normal.dy * ((minV + maxV) / 2)
        )
        return (0...72).map { index in
            let theta = CGFloat(index) / 72 * 2 * .pi
            return CGPoint(
                x: adjustedCenter.x
                    + axis.dx * cos(theta) * radiusU
                    + normal.dx * sin(theta) * radiusV,
                y: adjustedCenter.y
                    + axis.dy * cos(theta) * radiusU
                    + normal.dy * sin(theta) * radiusV
            )
        }
    }

    nonisolated private static func ellipseFitError(_ points: [CGPoint]) -> CGFloat {
        let bounds = boundingRect(for: points)
        let radiusX = max(bounds.width / 2, 1)
        let radiusY = max(bounds.height / 2, 1)
        let center = bounds.center
        return points.map { point in
            let dx = (point.x - center.x) / radiusX
            let dy = (point.y - center.y) / radiusY
            return abs(sqrt(dx * dx + dy * dy) - 1)
        }.reduce(0, +) / CGFloat(max(points.count, 1))
    }

    nonisolated private static func isRectangleLike(_ vertices: [CGPoint]) -> Bool {
        guard vertices.count == 4 else { return false }
        var cornerScores: [CGFloat] = []
        for index in vertices.indices {
            let previous = vertices[(index + vertices.count - 1) % vertices.count]
            let current = vertices[index]
            let next = vertices[(index + 1) % vertices.count]
            let incoming = CGVector(dx: previous.x - current.x, dy: previous.y - current.y)
            let outgoing = CGVector(dx: next.x - current.x, dy: next.y - current.y)
            let denominator = max(
                hypot(incoming.dx, incoming.dy) * hypot(outgoing.dx, outgoing.dy),
                0.001
            )
            cornerScores.append(abs((incoming.dx * outgoing.dx + incoming.dy * outgoing.dy) / denominator))
        }
        return cornerScores.filter { $0 <= 0.42 }.count >= 3
    }

    nonisolated private static func orientedRectangleCorners(
        for points: [CGPoint],
        guidedBy vertices: [CGPoint]
    ) -> [CGPoint] {
        let edges = vertices.indices.map { index -> (vector: CGVector, length: CGFloat) in
            let next = vertices[(index + 1) % vertices.count]
            let vector = CGVector(
                dx: next.x - vertices[index].x,
                dy: next.y - vertices[index].y
            )
            return (vector, hypot(vector.dx, vector.dy))
        }
        let longest = edges.max(by: { $0.length < $1.length })?.vector
            ?? CGVector(dx: 1, dy: 0)
        let magnitude = max(hypot(longest.dx, longest.dy), 0.001)
        let axis = CGVector(dx: longest.dx / magnitude, dy: longest.dy / magnitude)
        let normal = CGVector(dx: -axis.dy, dy: axis.dx)
        let projected = points.map { point in
            (
                u: point.x * axis.dx + point.y * axis.dy,
                v: point.x * normal.dx + point.y * normal.dy
            )
        }
        let minU = projected.map(\.u).min() ?? 0
        let maxU = projected.map(\.u).max() ?? 0
        let minV = projected.map(\.v).min() ?? 0
        let maxV = projected.map(\.v).max() ?? 0
        func point(u: CGFloat, v: CGFloat) -> CGPoint {
            CGPoint(
                x: axis.dx * u + normal.dx * v,
                y: axis.dy * u + normal.dy * v
            )
        }
        return [
            point(u: minU, v: minV),
            point(u: maxU, v: minV),
            point(u: maxU, v: maxV),
            point(u: minU, v: maxV)
        ]
    }

    nonisolated private static func interpolatedPolygon(
        _ vertices: [CGPoint],
        closed: Bool,
        samplesPerEdge: Int
    ) -> [CGPoint] {
        guard vertices.count >= 2 else { return vertices }
        let edgeCount = closed ? vertices.count : vertices.count - 1
        var result: [CGPoint] = []
        for index in 0..<edgeCount {
            let start = vertices[index]
            let end = vertices[(index + 1) % vertices.count]
            for sample in 0..<samplesPerEdge {
                let progress = CGFloat(sample) / CGFloat(samplesPerEdge)
                result.append(
                    CGPoint(
                        x: start.x + (end.x - start.x) * progress,
                        y: start.y + (end.y - start.y) * progress
                    )
                )
            }
        }
        result.append(closed ? vertices[0] : vertices[vertices.count - 1])
        return result
    }

    nonisolated private static func ramerDouglasPeucker(
        _ points: [CGPoint],
        tolerance: CGFloat
    ) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let first = points[0]
        let last = points[points.count - 1]
        var maximumDistance: CGFloat = 0
        var splitIndex = 0
        for index in 1..<(points.count - 1) {
            let error = distanceFromPoint(points[index], toSegmentFrom: first, to: last)
            if error > maximumDistance {
                maximumDistance = error
                splitIndex = index
            }
        }
        guard maximumDistance > tolerance else { return [first, last] }
        let left = ramerDouglasPeucker(Array(points[0...splitIndex]), tolerance: tolerance)
        let right = ramerDouglasPeucker(Array(points[splitIndex...]), tolerance: tolerance)
        return Array(left.dropLast()) + right
    }

    nonisolated private static func removingCollinearVertices(
        _ input: [CGPoint],
        tolerance: CGFloat
    ) -> [CGPoint] {
        var vertices = input
        var changed = true
        while changed, vertices.count > 3 {
            changed = false
            for index in vertices.indices {
                let previous = vertices[(index + vertices.count - 1) % vertices.count]
                let next = vertices[(index + 1) % vertices.count]
                if distanceFromPoint(vertices[index], toSegmentFrom: previous, to: next) <= tolerance {
                    vertices.remove(at: index)
                    changed = true
                    break
                }
            }
        }
        return vertices
    }

    nonisolated private static func deduplicatedPoints(
        _ points: [CGPoint],
        minimumDistance: CGFloat
    ) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var result = [first]
        for point in points.dropFirst()
        where distance(result[result.count - 1], point) >= minimumDistance {
            result.append(point)
        }
        return result
    }

    nonisolated private static func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { result, pair in
            result + distance(pair.0, pair.1)
        }
    }

    nonisolated private static func distance(
        _ first: CGPoint,
        _ second: CGPoint
    ) -> CGFloat {
        hypot(second.x - first.x, second.y - first.y)
    }

    nonisolated private static func distanceFromPoint(
        _ point: CGPoint,
        toSegmentFrom start: CGPoint,
        to end: CGPoint
    ) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let squaredLength = dx * dx + dy * dy
        guard squaredLength > 0.0001 else { return distance(point, start) }
        let projection = min(
            max(((point.x - start.x) * dx + (point.y - start.y) * dy) / squaredLength, 0),
            1
        )
        return distance(
            point,
            CGPoint(x: start.x + projection * dx, y: start.y + projection * dy)
        )
    }

}

private struct ShapeSnapInkStyle {
    let inkType: PKInk.InkType
    let color: UIColor
    let width: CGFloat
}

private struct ShapeSnapCandidate: Sendable {
    let kind: PageShapeKind
    let pathPoints: [CGPoint]
}

/// PencilKit normally records its own responder-chain history while this controller records a
/// smaller delta history shared by ink, lasso, and shape replacement. A private, permanently
/// disabled manager avoids both duplicate page snapshots and the previous enable/disable cycle at
/// every Pencil contact; it also avoids disabling the window's undo manager for unrelated views.
private final class TiyiPencilCanvasView: PKCanvasView {
    private let pencilUndoManager: UndoManager = {
        let manager = UndoManager()
        manager.disableUndoRegistration()
        return manager
    }()

    override var undoManager: UndoManager? {
        pencilUndoManager
    }
}

private enum DrawingHistoryAction {
    case removeTrailingStrokes(Int)
    case appendStrokes([PKStroke])
    case restoreDrawing(PKDrawing)
}

private struct StrokeTransformSession {
    let originalDrawing: PKDrawing
    let strokeIndices: [Int]
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

extension CanvasController: PKCanvasViewDelegate {
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isInstallingDrawing else { return }

        // A late PencilKit delegate callback may follow the post-lift straightening transaction.
        // Until the next genuine interaction or synchronized install, the snapped drawing is the
        // authoritative value.
        if let authoritativeSnappedDrawing {
            if self.drawing != authoritativeSnappedDrawing {
                installCanvasDrawing(
                    authoritativeSnappedDrawing,
                    preservingShapeAuthority: true
                )
            }
            return
        }
        if isUsingTool {
            // PencilKit calls this for transient samples, often hundreds of times in one stroke.
            // Reading `self.drawing` here materializes an ever-growing page snapshot on the
            // main thread. Even querying recognizer state here is unnecessary: both PencilKit's
            // lifecycle delegate and the recognizer end event close the transaction. The completed
            // value is not captured until the page reaches deep idle.
            toolInteractionDidChangeDrawing = true
        } else {
            // Hardware can deliver the first drawing callback just before its lifecycle callback.
            // Enter the same lightweight transaction here without reading the whole drawing. If
            // the recognizer has already ended, finish on the next main run-loop turn.
            beginToolInteraction()
            toolInteractionDidChangeDrawing = true
            if !hasActiveDrawingContact {
                requestToolInteractionFinish()
            }
        }
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        beginToolInteraction()
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        requestToolInteractionFinish()
    }
}
