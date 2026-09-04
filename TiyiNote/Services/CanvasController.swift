import PencilKit
import SwiftUI

final class CanvasController: NSObject, ObservableObject {
    let canvasView: PKCanvasView

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var isUsingTool = false
    @Published private(set) var lastSnappedShapeKind: PageShapeKind?
#if DEBUG
    private(set) var synchronizedDrawingInstallCount = 0
#endif

    var onDrawingChanged: ((PKDrawing) -> Void)?
    var onBecameActive: (() -> Void)?

    private var isInstallingDrawing = false
    private var strokeTransformSession: StrokeTransformSession?
    private var toolInteractionOriginDrawing: PKDrawing?
    private var toolInteractionEndWorkItem: DispatchWorkItem?
    private var undoDrawings: [PKDrawing] = []
    private var redoDrawings: [PKDrawing] = []
    private var lastObservedDrawing = PKDrawing()
    private var pendingUntrackedOriginDrawing: PKDrawing?
    private var pendingUntrackedHistoryWorkItem: DispatchWorkItem?
    private var selectedToolKind = CanvasToolKind.pen
    private var shapeGestureOriginDrawing: PKDrawing?
    private var shapeGesturePoints: [CGPoint] = []
    private var shapeSnapInkStyle: ShapeSnapInkStyle?
    private var shapeHoldWorkItem: DispatchWorkItem?
    private var shapeSnapCommitWorkItem: DispatchWorkItem?
    private var pendingShapeSnap: PendingShapeSnap?
    private var authoritativeSnappedDrawing: PKDrawing?
    private var committedShapeSnapAwaitingTouchEnd = false
    private var shapeTouchHasEnded = false
    private var isCommittingShapeSnap = false
    private var shapeTrackingGestureRecognizer: UILongPressGestureRecognizer?
    private var isAnnotationInputEditable = true

    override init() {
        let canvasView = PKCanvasView(frame: .zero)
        self.canvasView = canvasView
        super.init()

        canvasView.delegate = self
        canvasView.drawingGestureRecognizer.addTarget(
            self,
            action: #selector(handleDrawingGesture(_:))
        )
        let shapeTrackingGesture = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleShapeTrackingGesture(_:))
        )
        shapeTrackingGesture.minimumPressDuration = 0
        shapeTrackingGesture.allowableMovement = .greatestFiniteMagnitude
        shapeTrackingGesture.cancelsTouchesInView = false
        shapeTrackingGesture.delegate = self
#if targetEnvironment(simulator)
        shapeTrackingGesture.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]
#else
        shapeTrackingGesture.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.pencil.rawValue)
        ]
#endif
        canvasView.addGestureRecognizer(shapeTrackingGesture)
        shapeTrackingGestureRecognizer = shapeTrackingGesture
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

    var drawing: PKDrawing { canvasView.drawing }

    func installInitialDrawing(_ drawing: PKDrawing) {
        installCanvasDrawing(drawing)
        canvasView.undoManager?.removeAllActions()
        undoDrawings.removeAll()
        redoDrawings.removeAll()
        toolInteractionOriginDrawing = nil
        toolInteractionEndWorkItem?.cancel()
        toolInteractionEndWorkItem = nil
        pendingUntrackedOriginDrawing = nil
        pendingUntrackedHistoryWorkItem?.cancel()
        pendingUntrackedHistoryWorkItem = nil
        shapeSnapCommitWorkItem?.cancel()
        shapeSnapCommitWorkItem = nil
        pendingShapeSnap = nil
        authoritativeSnappedDrawing = nil
        committedShapeSnapAwaitingTouchEnd = false
        shapeTouchHasEnded = false
        isCommittingShapeSnap = false
        isUsingTool = false
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
        selectedToolKind = kind
        shapeTrackingGestureRecognizer?.isEnabled = kind.usesInkSettings
            && isAnnotationInputEditable
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
        shapeTrackingGestureRecognizer?.isEnabled = isEditable && selectedToolKind.usesInkSettings
        guard isEditable else {
            canvasView.drawingGestureRecognizer.isEnabled = false
            canvasView.drawingPolicy = .pencilOnly
            return
        }

        canvasView.drawingGestureRecognizer.isEnabled = true
#if targetEnvironment(simulator)
        // Keep mouse drawing available while developing in Simulator.
        canvasView.drawingPolicy = .anyInput
        canvasView.drawingGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]
#else
        // On iPad, fingers navigate the document; only Apple Pencil can annotate.
        canvasView.drawingPolicy = .pencilOnly
        canvasView.drawingGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.pencil.rawValue)
        ]
#endif
    }

    func undo() {
        guard let previousDrawing = undoDrawings.popLast() else { return }
        redoDrawings.append(canvasView.drawing)
        installCanvasDrawing(previousDrawing)
        onDrawingChanged?(previousDrawing)
        refreshHistoryState()
    }

    func redo() {
        guard let nextDrawing = redoDrawings.popLast() else { return }
        undoDrawings.append(canvasView.drawing)
        installCanvasDrawing(nextDrawing)
        onDrawingChanged?(nextDrawing)
        refreshHistoryState()
    }

    func clear() {
        guard !canvasView.drawing.strokes.isEmpty else { return }
        replaceDrawing(PKDrawing(), actionName: "清空画板")
    }

    func strokeIndices(inside polygon: [CGPoint]) -> Set<Int> {
        guard polygon.count >= 3 else { return [] }
        let polygonBounds = boundingRect(for: polygon).insetBy(dx: -2, dy: -2)

        return Set(canvasView.drawing.strokes.enumerated().compactMap { index, stroke in
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
        let strokes = canvasView.drawing.strokes
        let bounds = indices.reduce(into: CGRect.null) { result, index in
            guard strokes.indices.contains(index) else { return }
            result = result.union(strokes[index].renderBounds)
        }
        return bounds.isNull ? nil : bounds
    }

    func drawingForStrokes(at indices: Set<Int>, normalized: Bool = false) -> PKDrawing {
        let strokes = canvasView.drawing.strokes
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
        let retainedStrokes = canvasView.drawing.strokes.enumerated().compactMap { index, stroke in
            indices.contains(index) ? nil : stroke
        }
        replaceDrawing(PKDrawing(strokes: retainedStrokes), actionName: "删除选中笔迹")
    }

    @discardableResult
    func duplicateStrokes(
        at indices: Set<Int>,
        offset: CGSize,
        within pageSize: CGSize
    ) -> Set<Int> {
        guard
            !indices.isEmpty,
            let bounds = boundsForStrokes(at: indices)
        else { return [] }

        var translation = offset
        if bounds.maxX + translation.width > pageSize.width {
            translation.width = -abs(offset.width)
        }
        if bounds.maxY + translation.height > pageSize.height {
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
        within pageSize: CGSize
    ) -> Set<Int> {
        guard !drawing.strokes.isEmpty, !drawing.bounds.isNull else { return [] }

        let bounds = drawing.bounds
        var dx = point.x - bounds.midX
        var dy = point.y - bounds.midY
        let proposedBounds = bounds.offsetBy(dx: dx, dy: dy)

        if proposedBounds.minX < 0 { dx -= proposedBounds.minX }
        if proposedBounds.maxX > pageSize.width { dx -= proposedBounds.maxX - pageSize.width }
        if proposedBounds.minY < 0 { dy -= proposedBounds.minY }
        if proposedBounds.maxY > pageSize.height { dy -= proposedBounds.maxY - pageSize.height }

        let pastedStrokes = drawing
            .transformed(using: CGAffineTransform(translationX: dx, y: dy))
            .strokes
        return appendStrokes(pastedStrokes, actionName: "粘贴笔迹")
    }

    func beginTransformingStrokes(at indices: Set<Int>) {
        guard !indices.isEmpty else { return }
        strokeTransformSession = StrokeTransformSession(
            originalDrawing: canvasView.drawing,
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
        let previousDrawing = previousDrawing ?? canvasView.drawing
        guard newDrawing != previousDrawing else { return }
        recordUndoDrawing(previousDrawing)
        installCanvasDrawing(newDrawing)
        onDrawingChanged?(newDrawing)
        refreshHistoryState()
        _ = actionName
    }

    private func appendStrokes(_ strokes: [PKStroke], actionName: String) -> Set<Int> {
        guard !strokes.isEmpty else { return [] }
        let firstIndex = canvasView.drawing.strokes.count
        let newDrawing = PKDrawing(strokes: canvasView.drawing.strokes + strokes)
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
        canvasView.drawing = drawing
        lastObservedDrawing = drawing
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

    private func boundingRect(for points: [CGPoint]) -> CGRect {
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
        let nextCanUndo = !undoDrawings.isEmpty
        let nextCanRedo = !redoDrawings.isEmpty
        if canUndo != nextCanUndo {
            canUndo = nextCanUndo
        }
        if canRedo != nextCanRedo {
            canRedo = nextCanRedo
        }
    }

    private func recordUndoDrawing(_ drawing: PKDrawing) {
        undoDrawings.append(drawing)
        redoDrawings.removeAll()
    }

    private func beginToolInteraction() {
        toolInteractionEndWorkItem?.cancel()
        toolInteractionEndWorkItem = nil
        guard !isUsingTool else { return }

        // A snapped drawing remains authoritative after lift only to reject a late cancellation
        // callback from the gesture that produced it. A genuinely new Pencil contact starts a new
        // transaction and can safely release that guard.
        authoritativeSnappedDrawing = nil
        if toolInteractionOriginDrawing == nil {
            toolInteractionOriginDrawing = pendingUntrackedOriginDrawing ?? lastObservedDrawing
        }
        pendingUntrackedOriginDrawing = nil
        pendingUntrackedHistoryWorkItem?.cancel()
        pendingUntrackedHistoryWorkItem = nil
        isUsingTool = true
        onBecameActive?()
    }

    private func requestToolInteractionFinish() {
        // A delayed delegate end from the previous Pencil contact can arrive after the next one
        // has already begun on hardware. Never let that stale end release the new transaction.
        guard !hasActiveDrawingContact,
              pendingShapeSnap == nil,
              !isCommittingShapeSnap,
              !committedShapeSnapAwaitingTouchEnd else { return }

        // PencilKit's final drawing callback and its recognizer/delegate end callbacks are not
        // ordered consistently on hardware. Keeping the interaction active until the next main
        // turn makes the final canvas value authoritative before autosave or a deferred sync reload
        // is allowed to run.
        toolInteractionEndWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.finishToolInteractionNow()
        }
        toolInteractionEndWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func finishToolInteractionNow() {
        toolInteractionEndWorkItem = nil
        guard isUsingTool,
              !hasActiveDrawingContact,
              pendingShapeSnap == nil,
              !isCommittingShapeSnap,
              !committedShapeSnapAwaitingTouchEnd else { return }

        // PencilKit can report an eraser drawing change before it reports the
        // corresponding tool lifecycle callback. In that ordering the fallback
        // observer already captured the pre-erase drawing, but the end callback
        // used to cancel it without recording an undo entry.
        let originDrawing = toolInteractionOriginDrawing ?? pendingUntrackedOriginDrawing
        let finalDrawing = canvasView.drawing
        let didChangeDrawing = originDrawing.map { $0 != finalDrawing } ?? false
        if let origin = originDrawing,
           didChangeDrawing {
            recordUndoDrawing(origin)
        }
        lastObservedDrawing = finalDrawing
        pendingUntrackedOriginDrawing = nil
        pendingUntrackedHistoryWorkItem?.cancel()
        pendingUntrackedHistoryWorkItem = nil
        toolInteractionOriginDrawing = nil

        // Persist one complete stroke, never PencilKit's transient samples. Besides reducing work,
        // this prevents a 650 ms materialized snapshot from being reinstalled while the same Pencil
        // contact is still producing that stroke.
        if didChangeDrawing {
            onDrawingChanged?(finalDrawing)
        }
        isUsingTool = false
        refreshHistoryState()
    }

    private var hasActiveDrawingContact: Bool {
        let drawingState = canvasView.drawingGestureRecognizer.state
        if drawingState == .began || drawingState == .changed {
            return true
        }
        guard let shapeState = shapeTrackingGestureRecognizer?.state else { return false }
        return shapeState == .began || shapeState == .changed
    }

    @objc private func handleDrawingGesture(_ gesture: UIGestureRecognizer) {
        switch gesture.state {
        case .began:
            beginToolInteraction()
        case .ended, .cancelled, .failed:
            requestToolInteractionFinish()
        default:
            break
        }
    }

    @objc private func handleShapeTrackingGesture(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            shapeTouchHasEnded = false
            beginToolInteraction()
            beginShapeTracking(at: gesture.location(in: canvasView))
        case .changed:
            continueShapeTracking(at: gesture.location(in: canvasView))
        case .ended, .cancelled, .failed:
            shapeTouchHasEnded = true
            cancelShapeTracking()
            canvasView.drawingGestureRecognizer.isEnabled = isAnnotationInputEditable
                && selectedToolKind != .lasso
                && selectedToolKind != .text
            if committedShapeSnapAwaitingTouchEnd {
                finishCommittedShapeSnapInteraction()
            } else if pendingShapeSnap == nil {
                requestToolInteractionFinish()
            }
        default:
            break
        }
    }

    private func beginShapeTracking(at point: CGPoint) {
        cancelShapeTracking()
        lastSnappedShapeKind = nil
        guard selectedToolKind.usesInkSettings,
              let tool = canvasView.tool as? PKInkingTool else { return }
        shapeGestureOriginDrawing = canvasView.drawing
        shapeGesturePoints = [point]
        shapeSnapInkStyle = ShapeSnapInkStyle(
            inkType: tool.inkType,
            color: tool.color,
            width: tool.width
        )
    }

    private func continueShapeTracking(at point: CGPoint) {
        guard shapeGestureOriginDrawing != nil,
              let previous = shapeGesturePoints.last else { return }
        let movement = hypot(point.x - previous.x, point.y - previous.y)
        guard movement >= 1.5 else { return }
        shapeGesturePoints.append(point)
        shapeHoldWorkItem?.cancel()

        guard shapeGesturePoints.count >= 2,
              pathLength(shapeGesturePoints) >= 24 else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.shapeGestureOriginDrawing != nil else { return }
            let candidate = self.recognizedShape(from: self.shapeGesturePoints)
            guard let candidate else { return }
            self.commitSnappedShape(candidate)
        }
        shapeHoldWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.68, execute: workItem)
    }

    private func cancelShapeTracking() {
        shapeHoldWorkItem?.cancel()
        shapeHoldWorkItem = nil
        shapeGestureOriginDrawing = nil
        shapeGesturePoints.removeAll(keepingCapacity: true)
        shapeSnapInkStyle = nil
    }

    private func commitSnappedShape(_ candidate: ShapeSnapCandidate) {
        guard let originDrawing = shapeGestureOriginDrawing,
              let inkStyle = shapeSnapInkStyle,
              let stroke = regularStroke(for: candidate, inkStyle: inkStyle),
              pendingShapeSnap == nil,
              !committedShapeSnapAwaitingTouchEnd
        else { return }

        shapeHoldWorkItem?.cancel()
        shapeHoldWorkItem = nil
        toolInteractionEndWorkItem?.cancel()
        toolInteractionEndWorkItem = nil
        isCommittingShapeSnap = true

        let snappedDrawing = PKDrawing(strokes: originDrawing.strokes + [stroke])
        pendingShapeSnap = PendingShapeSnap(
            originDrawing: originDrawing,
            drawing: snappedDrawing,
            kind: candidate.kind
        )

        // Cancelling PencilKit removes the rough in-progress stroke while the Pencil is still
        // touching the screen. Hardware may deliver the resulting cancellation callbacks after
        // this setter returns, so install the straightened stroke on the next main turn instead of
        // racing those callbacks in the same stack frame.
        canvasView.drawingGestureRecognizer.isEnabled = false
        let workItem = DispatchWorkItem { [weak self] in
            self?.finalizePendingShapeSnap()
        }
        shapeSnapCommitWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func finalizePendingShapeSnap() {
        shapeSnapCommitWorkItem = nil
        guard let pendingShapeSnap else {
            isCommittingShapeSnap = false
            return
        }

        installCanvasDrawing(pendingShapeSnap.drawing)
        authoritativeSnappedDrawing = pendingShapeSnap.drawing
        if pendingShapeSnap.originDrawing != pendingShapeSnap.drawing {
            recordUndoDrawing(pendingShapeSnap.originDrawing)
        }
        toolInteractionOriginDrawing = nil
        pendingUntrackedOriginDrawing = nil
        pendingUntrackedHistoryWorkItem?.cancel()
        pendingUntrackedHistoryWorkItem = nil
        lastSnappedShapeKind = pendingShapeSnap.kind
        committedShapeSnapAwaitingTouchEnd = true
        self.pendingShapeSnap = nil
        isCommittingShapeSnap = false
        refreshHistoryState()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        shapeGestureOriginDrawing = nil
        shapeGesturePoints.removeAll(keepingCapacity: true)
        shapeSnapInkStyle = nil

        if shapeTouchHasEnded {
            finishCommittedShapeSnapInteraction()
        }
    }

    private func finishCommittedShapeSnapInteraction() {
        guard committedShapeSnapAwaitingTouchEnd,
              let snappedDrawing = authoritativeSnappedDrawing else { return }
        committedShapeSnapAwaitingTouchEnd = false
        lastObservedDrawing = snappedDrawing
        onDrawingChanged?(snappedDrawing)
        isUsingTool = false
        refreshHistoryState()
    }

    private func recognizedShape(from rawPoints: [CGPoint]) -> ShapeSnapCandidate? {
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

    private func regularEllipsePoints(for points: [CGPoint]) -> [CGPoint]? {
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

    private func ellipseFitError(_ points: [CGPoint]) -> CGFloat {
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

    private func isRectangleLike(_ vertices: [CGPoint]) -> Bool {
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

    private func orientedRectangleCorners(
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

    private func interpolatedPolygon(
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

    private func ramerDouglasPeucker(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
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

    private func removingCollinearVertices(
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

    private func deduplicatedPoints(
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

    private func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { result, pair in
            result + distance(pair.0, pair.1)
        }
    }

    private func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        hypot(second.x - first.x, second.y - first.y)
    }

    private func distanceFromPoint(
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

    private func observeUntrackedDrawingChange(
        from previousDrawing: PKDrawing,
        to drawing: PKDrawing
    ) {
        guard toolInteractionOriginDrawing == nil else { return }
        if pendingUntrackedOriginDrawing == nil {
            pendingUntrackedOriginDrawing = previousDrawing
        }
        pendingUntrackedHistoryWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.toolInteractionOriginDrawing == nil,
                  let origin = self.pendingUntrackedOriginDrawing else { return }
            self.pendingUntrackedOriginDrawing = nil
            self.pendingUntrackedHistoryWorkItem = nil
            let finalDrawing = self.canvasView.drawing
            if origin != finalDrawing {
                self.recordUndoDrawing(origin)
                self.onDrawingChanged?(finalDrawing)
            }
            self.lastObservedDrawing = finalDrawing
            self.refreshHistoryState()
        }
        pendingUntrackedHistoryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: workItem)
        _ = drawing
    }
}

private struct ShapeSnapInkStyle {
    let inkType: PKInk.InkType
    let color: UIColor
    let width: CGFloat
}

private struct ShapeSnapCandidate {
    let kind: PageShapeKind
    let pathPoints: [CGPoint]
}

private struct PendingShapeSnap {
    let originDrawing: PKDrawing
    let drawing: PKDrawing
    let kind: PageShapeKind
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

extension CanvasController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

extension CanvasController: PKCanvasViewDelegate {
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isInstallingDrawing else { return }

        // Disabling PencilKit's recognizer to replace a held rough stroke can produce one last
        // stale drawing callback on real Pencil hardware. Until the next genuine interaction or a
        // synchronized install, the snapped drawing is the transaction's authoritative value.
        if let authoritativeSnappedDrawing {
            if canvasView.drawing != authoritativeSnappedDrawing {
                installCanvasDrawing(
                    authoritativeSnappedDrawing,
                    preservingShapeAuthority: true
                )
            }
            return
        }
        guard pendingShapeSnap == nil, !isCommittingShapeSnap else { return }

        let previousDrawing = lastObservedDrawing
        lastObservedDrawing = canvasView.drawing
        if !isUsingTool {
            observeUntrackedDrawingChange(
                from: previousDrawing,
                to: canvasView.drawing
            )
        }
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        beginToolInteraction()
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        requestToolInteractionFinish()
    }
}
