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
    let canvasView: PKCanvasView

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// Kept out of `ObservableObject` publishing on purpose. Publishing at Pencil-down forces the
    /// complete SwiftUI page hierarchy to recompute exactly when PencilKit needs the main thread.
    private(set) var isUsingTool = false
    @Published private(set) var lastSnappedShapeKind: HeldInkShapeKind?
#if DEBUG
    private(set) var synchronizedDrawingInstallCount = 0
    private(set) var heldShapePreviewCount = 0
    private(set) var heldShapeResumeCount = 0
#endif

    /// `true` means every edit since the previous callback only appended ink. The page view uses
    /// this hint to keep the collaboration save on its cheap append-only path without reading the
    /// complete `PKDrawing` after every Pencil lift.
    var onDrawingChanged: ((Bool) -> Void)?
    var onBecameActive: (() -> Void)?
    var onToolInteractionChanged: ((Bool) -> Void)?
    var pageElementsProvider: (() -> [CanvasPageElement])?
    var onPageElementsUpdated: (([CanvasPageElement], Bool) -> Void)?
    var onRequestContentSelection: ((Set<Int>, Set<UUID>) -> Void)?

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
    private var shapeSnapInkStyle: ShapeSnapInkStyle?
    private var scribbleAllowedForContact = false
    private var pendingScribbles: [PendingScribbleErase] = []
    private var completedInkContactCount = 0
    var isScribbleEraseEnabled = true
    private let heldInkRecognizer = HeldInkGestureRecognizer()
    private let shapeEraserRecognizer = ShapeEraserGestureRecognizer()
    private let fingerSelectionRecognizer = FingerContentTapGestureRecognizer()
    private var fingerSelectionTarget: (strokes: Set<Int>, elements: Set<UUID>)?
    private var erasedElements: [CanvasPageElement] = []
    private var eraserRadius: CGFloat = 9
    private var usesStrokeEraser = false
    private var heldShape: (drawing: PKDrawing, kind: HeldInkShapeKind)?
    private var shapePreview: UIImageView?
    private var originalCanvasMask: CALayer?
    private var isShapePreviewVisible = false
    private var authoritativeSnappedDrawing: PKDrawing?
    private var isAnnotationInputEditable = true
    var allowsPracticeFingerDrawing = false
    var allowsDirectDrawing: Bool { Self.allowsFingerDrawing || allowsPracticeFingerDrawing }

    override init() {
        let canvasView = TiyiPencilCanvasView(frame: .zero)
        self.canvasView = canvasView
        super.init()

        canvasView.delegate = self
        canvasView.addGestureRecognizer(fingerSelectionRecognizer)
        fingerSelectionRecognizer.canSelect = { [weak self] point in
            guard let self, self.isAnnotationInputEditable, self.selectedToolKind.usesInkSettings else { return false }
            let scale = max(self.canvasView.zoomScale, 0.0001)
            let worldPoint = CGPoint(x: point.x / scale + self.canvasWorldOrigin.x,
                                     y: point.y / scale + self.canvasWorldOrigin.y)
            if let element = self.pageElementsProvider?()
                .filter({ element in
                    guard case .shape = element.payload else { return false }
                    return element.hitArea(tolerance: 14 / scale, displayScale: scale, includesInterior: true).contains(worldPoint)
                })
                .sorted(by: { $0.zIndex == $1.zIndex ? $0.id.uuidString < $1.id.uuidString : $0.zIndex < $1.zIndex }).last {
                self.fingerSelectionTarget = ([], [element.id])
            } else if let stroke = self.strokeIndex(at: worldPoint, tolerance: 14 / scale, shapesOnly: true) {
                self.fingerSelectionTarget = ([stroke], [])
            } else {
                self.fingerSelectionTarget = nil
            }
            return self.fingerSelectionTarget != nil
        }
        fingerSelectionRecognizer.onSelect = { [weak self] in
            guard let self, let target = self.fingerSelectionTarget else { return }
            self.onRequestContentSelection?(target.strokes, target.elements)
            self.fingerSelectionTarget = nil
        }
        // Only a short finger contact over existing content waits for tap-vs-drag. Pencil and
        // blank-space contacts fail the tap recognizer immediately and keep the normal ink path.
        fingerSelectionRecognizer.drawingRecognizer = canvasView.drawingGestureRecognizer
        canvasView.addGestureRecognizer(shapeEraserRecognizer)
        shapeEraserRecognizer.canTrack = { [weak self] in
            guard let self else { return false }
            return self.isAnnotationInputEditable && self.selectedToolKind == .eraser
                && self.canvasView.drawingGestureRecognizer.isEnabled
        }
        shapeEraserRecognizer.onContactBegan = { [weak self] in self?.beginToolInteraction() }
        shapeEraserRecognizer.onSegment = { [weak self] start, end in self?.eraseShapes(from: start, to: end) }
        shapeEraserRecognizer.onContactEnded = { [weak self] in self?.requestToolInteractionFinish() }
        canvasView.addGestureRecognizer(heldInkRecognizer)
        heldInkRecognizer.canTrack = { [weak self] in
            guard let self else { return false }
            return self.isAnnotationInputEditable && self.selectedToolKind.usesInkSettings
                && self.canvasView.window != nil && self.canvasView.drawingGestureRecognizer.isEnabled
        }
        heldInkRecognizer.onContactBegan = { [weak self] in
            self?.beginToolInteraction()
            self?.beginShapeTracking()
        }
        heldInkRecognizer.onHold = { [weak self] points in self?.previewHeldShape(points) ?? false }
        heldInkRecognizer.onResume = { [weak self] in
            guard let self else { return }
#if DEBUG
            if self.isShapePreviewVisible { self.heldShapeResumeCount += 1 }
#endif
            self.discardShapePreview()
        }
        heldInkRecognizer.onContactEnded = { [weak self] points, cancelled in
            guard let self else { return }
            self.completedInkContactCount += 1
            if cancelled {
                self.pendingScribbles.removeAll()
                self.discardShapePreview()
            } else if self.scribbleAllowedForContact, self.isScribbleEraseEnabled,
                      self.selectedToolKind.isPenVariant, let index = self.shapeGestureOriginStrokeCount {
                let scale = max(self.canvasView.zoomScale, 0.0001)
                let worldPoints = points.map { CGPoint(x: $0.x + self.canvasWorldOrigin.x,
                                                       y: $0.y + self.canvasWorldOrigin.y) }
                if let gesture = ScribbleEraseRecognizer.recognize(worldPoints, displayScale: scale) {
                    self.pendingScribbles.append(PendingScribbleErase(gesture: gesture, strokeIndex: index, scale: scale))
                    self.discardShapePreview()
                }
            }
            self.requestToolInteractionFinish()
        }
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
        erasedElements.removeAll()
        toolInteractionEndWorkItem?.cancel()
        toolInteractionEndWorkItem = nil
        postLiftDrawingRetryCount = 0
        eraserBaselineDrawing = selectedToolKind == .eraser ? drawing : nil
        cancelHeldInkRecognition()
        completedInkContactCount = 0
        authoritativeSnappedDrawing = nil
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
        eraserRadius = eraserSize.width / 2
        usesStrokeEraser = eraserMode == .stroke
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
            cancelHeldInkRecognition()
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
        case .lasso, .text:
            // Both modes belong to our object interaction layer. Installing PKLassoTool also
            // activates PencilKit's separate selection recognizers and its Select All / Insert
            // Space menu, even with drawingGestureRecognizer disabled and responder actions off.
            canvasView.tool = PKInkingTool(.monoline, color: .clear, width: 1)
        }
        (canvasView as? TiyiPencilCanvasView)?.disableSystemEditingInteractions()
    }

    func configureAnnotationInput(isEditable: Bool = true) {
        isAnnotationInputEditable = isEditable
        if !isEditable { cancelHeldInkRecognition() }
        heldInkRecognizer.allowedTouchTypes = allowsDirectDrawing ? [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ] : [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        shapeEraserRecognizer.allowedTouchTypes = heldInkRecognizer.allowedTouchTypes
        guard isEditable else {
            canvasView.drawingGestureRecognizer.isEnabled = false
            canvasView.drawingPolicy = .pencilOnly
            return
        }

        canvasView.drawingGestureRecognizer.isEnabled = true
        canvasView.drawingPolicy = allowsDirectDrawing ? .anyInput : .pencilOnly
        canvasView.drawingGestureRecognizer.allowedTouchTypes = allowsDirectDrawing ? [
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

    func strokeIndices(inside polygon: [CGPoint], tolerance: CGFloat = 2) -> Set<Int> {
        guard polygon.count >= 3 else { return [] }
        let polygonBounds = Self.boundingRect(for: polygon).insetBy(dx: -tolerance, dy: -tolerance)
        let path = CGMutablePath()
        path.addLines(between: polygon)
        path.closeSubpath()
        let edge = path.copy(strokingWithWidth: tolerance * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)

        return Set(self.drawing.strokes.enumerated().compactMap { index, stroke in
            guard stroke.renderBounds.intersects(polygonBounds) else { return nil }

            if stroke.mask == nil, polygonContains(stroke.renderBounds.center, polygon: polygon) {
                return index
            }

            for points in CanvasHitGeometry.visiblePoints(in: stroke) {
                for point in points {
                    let location = point.location.applying(stroke.transform)
                    if path.contains(location) || edge.contains(location) {
                        return index
                    }
                }
            }
            return nil
        })
    }

    func strokeIndex(at point: CGPoint, tolerance: CGFloat, shapesOnly: Bool = false) -> Int? {
        var match: (index: Int, distance: CGFloat)?
        for (index, stroke) in drawing.strokes.enumerated() {
            guard let distance = CanvasHitGeometry.distance(to: point, stroke: stroke, tolerance: tolerance) else { continue }
            if shapesOnly {
                guard stroke.mask == nil,
                      HeldInkShapeRecognizer.recognize(CanvasHitGeometry.visiblePoints(in: stroke).flatMap {
                          $0.map { $0.location.applying(stroke.transform) }
                      }) != nil else { continue }
            }
            if match == nil || distance <= match!.distance { match = (index, distance) }
        }
        return match?.index
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
        case .restorePageContent(let drawing, let elements, let replacingIDs):
            let currentDrawing = drawing == nil ? nil : self.drawing
            let currentElements = pageElementsProvider?() ?? []
            let replacedElements = currentElements.filter { replacingIDs.contains($0.id) }
            if let drawing { installCanvasDrawing(drawing) }
            onPageElementsUpdated?(currentElements.filter { !replacingIDs.contains($0.id) } + elements, true)
            return .restorePageContent(drawing: currentDrawing, elements: replacedElements, replacingIDs: replacingIDs)
        }
    }

    private func eraseShapes(from localStart: CGPoint, to localEnd: CGPoint) {
        guard selectedToolKind == .eraser, isAnnotationInputEditable,
              let elements = pageElementsProvider?() else { return }
        let scale = max(canvasView.zoomScale, 0.0001)
        let radius = usesStrokeEraser ? 8 / scale : max(eraserRadius, 5 / scale)
        let start = CGPoint(x: localStart.x + canvasWorldOrigin.x, y: localStart.y + canvasWorldOrigin.y)
        let end = CGPoint(x: localEnd.x + canvasWorldOrigin.x, y: localEnd.y + canvasWorldOrigin.y)
        let hits = elements.filter { element in
            guard !element.isLocked, case .shape = element.payload else { return false }
            let area = element.hitArea(tolerance: radius, displayScale: scale, includesInterior: false)
            return CanvasHitGeometry.segment(from: start, to: end, intersects: area, step: radius / 2)
        }
        guard !hits.isEmpty else { return }
        erasedElements.append(contentsOf: hits)
        let ids = Set(hits.map(\.id))
        onPageElementsUpdated?(elements.filter { !ids.contains($0.id) }, false)
    }

    private func commitPendingInkContacts(_ finalDrawing: PKDrawing, committingHeldShape: Bool) {
        let nativeStrokes = finalDrawing.strokes
        // Count and physical stroke positions must agree before interpreting any contact as a
        // deletion. Cancelled or unexpected PencilKit mutations retain ordinary ink instead.
        let canErase = isAnnotationInputEditable && isScribbleEraseEnabled && selectedToolKind.isPenVariant
            && nativeStrokes.count == knownStrokeCount + completedInkContactCount
        let candidates = canErase ? Dictionary(pendingScribbles.map { ($0.strokeIndex, $0) },
                                                uniquingKeysWith: { first, _ in first }) : [:]
        var strokes = Array(nativeStrokes.prefix(knownStrokeCount))
        var elements = pageElementsProvider?() ?? []
        var didErase = false
        var didEraseElements = false
        // Native callbacks can batch several quick contacts. Replay their logical edits in order,
        // so a scribble cannot eat the next stroke and every contact keeps its own Undo step.
        for index in min(knownStrokeCount, nativeStrokes.count)..<nativeStrokes.count {
            var removedIndices: Set<Int> = []
            var removedElements: [CanvasPageElement] = []
            if let candidate = candidates[index] {
                let gesture = candidate.gesture, scale = candidate.scale
                removedIndices = Set(strokes.indices.filter { index in
                    let stroke = strokes[index]
                    guard gesture.bounds.intersects(stroke.renderBounds) else { return false }
                    let transformScale = max(hypot(stroke.transform.a, stroke.transform.b),
                                             hypot(stroke.transform.c, stroke.transform.d), 0.001)
                    let contours = CanvasHitGeometry.visiblePoints(in: stroke, spacing: 3 / (scale * transformScale))
                        .map { $0.map { $0.location.applying(stroke.transform) } }
                    return gesture.covers(contours)
                })
                removedElements = elements.filter { element in
                    guard !element.isLocked, case .shape = element.payload else { return false }
                    let path = element.interactionPath(displayScale: scale)
                    guard gesture.bounds.intersects(path.boundingBoxOfPath.insetBy(dx: -1 / scale, dy: -1 / scale)) else { return false }
                    return gesture.covers(CanvasHitGeometry.contours(in: path, spacing: 3 / scale), minimumCoverage: 0.70)
                }
            }
            if removedIndices.isEmpty && removedElements.isEmpty {
                strokes.append(nativeStrokes[index])
                recordUndoAction(.removeTrailingStrokes(1))
                continue
            }
            didErase = true
            let originalDrawing = PKDrawing(strokes: strokes)
            let removedIDs = Set(removedElements.map(\.id))
            if removedElements.isEmpty {
                recordUndoAction(.restoreDrawing(originalDrawing))
            } else {
                didEraseElements = true
                recordUndoAction(.restorePageContent(drawing: originalDrawing,
                                                    elements: removedElements, replacingIDs: removedIDs))
                elements.removeAll { removedIDs.contains($0.id) }
            }
            strokes = strokes.enumerated().compactMap { removedIndices.contains($0.offset) ? nil : $0.element }
        }
        if didErase || committingHeldShape {
            let remainingDrawing = PKDrawing(strokes: strokes)
            installCanvasDrawing(remainingDrawing)
            // A late PencilKit callback must not resurrect either erased content or the gesture.
            authoritativeSnappedDrawing = remainingDrawing
        } else {
            knownStrokeCount = nativeStrokes.count
        }
        if didEraseElements { onPageElementsUpdated?(elements, true) }
        onDrawingChanged?(!didErase)
    }

    private func beginToolInteraction() {
        toolInteractionEndWorkItem?.cancel()
        toolInteractionEndWorkItem = nil
        guard !isUsingTool else { return }

        discardShapePreview()

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
        completedInkContactCount = 0
        pendingScribbles.removeAll(keepingCapacity: true)
        erasedElements.removeAll(keepingCapacity: true)
        postLiftDrawingRetryCount = 0
        setToolInteractionActive(true)
        onBecameActive?()
    }

    private func requestToolInteractionFinish() {
        // A delayed delegate end from the previous Pencil contact can arrive after the next one
        // has already begun on hardware. Never let that stale end release the new transaction.
        guard !hasActiveDrawingContact else { return }

        // A held shape already has its final value. Close it at PencilKit's end callback, before
        // a rapid next contact can cancel the queued finish and merge two undo transactions.
        if heldShape != nil {
            toolInteractionEndWorkItem?.cancel()
            finishToolInteractionNow()
            return
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

        let didChangeDrawing = toolInteractionDidChangeDrawing || heldShape != nil
        if !pendingScribbles.isEmpty {
            // Ordinary writing never snapshots the complete drawing here. A geometric candidate
            // waits until all live contacts finish, then evaluates only their nearby content.
            let expectedCount = knownStrokeCount + completedInkContactCount
            let snappedShape = heldShape.flatMap { $0.drawing.strokes.count == expectedCount ? $0 : nil }
            let finalDrawing = snappedShape?.drawing ?? self.drawing
            if finalDrawing.strokes.count < knownStrokeCount + completedInkContactCount, postLiftDrawingRetryCount < 4 {
                postLiftDrawingRetryCount += 1
                let work = DispatchWorkItem { [weak self] in self?.finishShapeTrackingAfterPencilLift() }
                toolInteractionEndWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: work)
                return
            }
            if snappedShape != nil {
                // Keep the bitmap until the final ink renders, just like an isolated held shape.
                heldShape = nil
            } else {
                discardShapePreview()
            }
            commitPendingInkContacts(finalDrawing, committingHeldShape: snappedShape != nil)
            pendingScribbles.removeAll(keepingCapacity: true)
            completedInkContactCount = 0
            toolInteractionOriginDrawing = nil
            toolInteractionDidChangeDrawing = false
            shapeGestureOriginStrokeCount = nil
            shapeSnapInkStyle = nil
            scribbleAllowedForContact = false
            lastSnappedShapeKind = snappedShape?.kind
            setToolInteractionActive(false)
            refreshHistoryState()
            return
        }
        if didChangeDrawing {
            if selectedToolKind.usesInkSettings {
                // One Pencil contact produces one PencilKit stroke. Store the inverse command;
                // the stroke itself is captured only if the user actually asks for Undo.
                let count = max(1, completedInkContactCount)
                for _ in 0..<count { recordUndoAction(.removeTrailingStrokes(1)) }
                knownStrokeCount += count
            } else if selectedToolKind == .eraser, erasedElements.isEmpty,
                      let originDrawing = toolInteractionOriginDrawing {
                recordUndoAction(.restoreDrawing(originDrawing))
                let finalDrawing = self.drawing
                knownStrokeCount = finalDrawing.strokes.count
                eraserBaselineDrawing = finalDrawing
            }
        }
        if !erasedElements.isEmpty {
            recordUndoAction(.restorePageContent(
                drawing: didChangeDrawing ? toolInteractionOriginDrawing : nil,
                elements: erasedElements,
                replacingIDs: Set(erasedElements.map(\.id))
            ))
            onPageElementsUpdated?(pageElementsProvider?() ?? [], true)
            erasedElements.removeAll(keepingCapacity: true)
            if didChangeDrawing {
                let finalDrawing = self.drawing
                knownStrokeCount = finalDrawing.strokes.count
                eraserBaselineDrawing = finalDrawing
            }
        }
        toolInteractionOriginDrawing = nil
        toolInteractionDidChangeDrawing = false

        // The original PencilKit contact remained live under a rendering mask. Commit only after
        // it has ended, as the same single-stroke undo transaction. No gesture is cancelled.
        if let heldShape {
            // Keep the ready bitmap over the canvas until PencilKit has rendered the committed
            // drawing. Removing it at assignment time exposes PencilKit's empty replacement frame.
            self.heldShape = nil
            installCanvasDrawing(heldShape.drawing)
            authoritativeSnappedDrawing = heldShape.drawing
            lastSnappedShapeKind = heldShape.kind
        } else {
            discardShapePreview()
            if lastSnappedShapeKind != nil { lastSnappedShapeKind = nil }
        }
        shapeGestureOriginStrokeCount = nil
        shapeSnapInkStyle = nil

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
        return heldInkRecognizer.isTrackingContact || shapeEraserRecognizer.isTrackingContact
            || drawingState == .began || drawingState == .changed
    }

    private func beginShapeTracking() {
        scribbleAllowedForContact = isScribbleEraseEnabled && selectedToolKind.isPenVariant
        guard selectedToolKind.usesInkSettings,
              let tool = canvasView.tool as? PKInkingTool else { return }
        shapeGestureOriginStrokeCount = knownStrokeCount + completedInkContactCount
        shapeSnapInkStyle = ShapeSnapInkStyle(inkType: tool.inkType, color: tool.color, width: tool.width)
    }

    private func finishShapeTrackingAfterPencilLift() {
        toolInteractionEndWorkItem = nil
        guard !hasActiveDrawingContact else { return }
        // PencilKit may report its final drawing change after the lift callback. Keep the existing
        // transaction open for a few run-loop turns rather than treating it as another stroke.
        if isUsingTool, heldShape == nil, !toolInteractionDidChangeDrawing, postLiftDrawingRetryCount < 4 {
            postLiftDrawingRetryCount += 1
            let workItem = DispatchWorkItem { [weak self] in self?.finishShapeTrackingAfterPencilLift() }
            toolInteractionEndWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: workItem)
            return
        }
        finishToolInteractionNow()
    }

    /// Explicit saves may arrive between the final PencilKit drawing callback and its queued
    /// lift completion. Close that completed contact before the page serializes its checkpoint.
    func finishEndedInteractionForCheckpoint() {
        guard isUsingTool, !hasActiveDrawingContact,
              toolInteractionDidChangeDrawing || !erasedElements.isEmpty else { return }
        toolInteractionEndWorkItem?.cancel()
        finishShapeTrackingAfterPencilLift()
    }

    func cancelHeldInkRecognition() {
        pendingScribbles.removeAll()
        scribbleAllowedForContact = false
        heldInkRecognizer.cancelTracking()
        discardShapePreview()
        shapeGestureOriginStrokeCount = nil
        shapeSnapInkStyle = nil
    }

    private func previewHeldShape(_ localPoints: [CGPoint]) -> Bool {
        if scribbleAllowedForContact, isScribbleEraseEnabled,
           ScribbleEraseRecognizer.recognize(localPoints, displayScale: canvasView.zoomScale) != nil {
            return false
        }
        guard isUsingTool, heldInkRecognizer.isTrackingContact,
              let originCount = shapeGestureOriginStrokeCount,
              let style = shapeSnapInkStyle, let host = canvasView.superview,
              let candidate = HeldInkShapeRecognizer.recognize(
                localPoints, minimumExtent: 24 / max(canvasView.zoomScale, 0.001)
              ) else { return false }
        let worldPoints = candidate.points.map {
            CGPoint(x: $0.x + canvasWorldOrigin.x, y: $0.y + canvasWorldOrigin.y)
        }
        let stroke = regularStroke(points: worldPoints, inkStyle: style)
        // This is the first whole-page read for this intentional hold. Normal contacts never
        // materialize a PKDrawing here; the observer only retains bounded current-stroke samples.
        let existing = drawing.strokes
        guard existing.count >= originCount, existing.count <= originCount + 1 else { return false }
        let snapped = PKDrawing(strokes: Array(existing.prefix(originCount)) + [stroke])
        heldShape = (snapped, candidate.kind)
        // A second PKCanvasView renders its tiles asynchronously. Its first "finished" callback
        // can belong to the initial empty drawing, which briefly hides every existing stroke.
        // Rasterize only the visible ink synchronously, then swap a ready image in one transaction.
        let zoom = max(canvasView.zoomScale, 0.001)
        let visibleWorldRect = CGRect(
            x: canvasView.contentOffset.x / zoom + canvasWorldOrigin.x,
            y: canvasView.contentOffset.y / zoom + canvasWorldOrigin.y,
            width: canvasView.bounds.width / zoom,
            height: canvasView.bounds.height / zoom
        )
        let inkImage = snapped.image(from: visibleWorldRect, scale: zoom * canvasView.traitCollection.displayScale)
        let preview = UIImageView(image: inkImage)
        preview.frame = canvasView.frame
        preview.isOpaque = false
        preview.backgroundColor = .clear
        preview.overrideUserInterfaceStyle = .light
        preview.isUserInteractionEnabled = false
        preview.isAccessibilityElement = true
        preview.accessibilityIdentifier = "held-ink-shape-preview"
        preview.accessibilityLabel = "规整预览"
        preview.accessibilityValue = candidate.kind.title
        shapePreview = preview
        originalCanvasMask = canvasView.layer.mask
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.insertSubview(preview, aboveSubview: canvasView)
        canvasView.layer.mask = CALayer()
        isShapePreviewVisible = true
        CATransaction.commit()
#if DEBUG
        heldShapePreviewCount += 1
#endif
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return true
    }

    private func discardShapePreview() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let shapePreview {
            if isShapePreviewVisible { canvasView.layer.mask = originalCanvasMask }
            shapePreview.removeFromSuperview()
        }
        CATransaction.commit()
        isShapePreviewVisible = false
        shapePreview = nil
        originalCanvasMask = nil
        heldShape = nil
    }

    private func regularStroke(points: [CGPoint], inkStyle: ShapeSnapInkStyle) -> PKStroke {
        // Regular pen geometry has a uniform nib. PencilKit's pen control-point footprint
        // includes a two-point brush border; passing a thin toolbar width directly makes it
        // transparent. Textured pencil and highlighter strokes keep their original ink.
        let inkType: PKInk.InkType = inkStyle.inkType == .fountainPen ? .monoline : inkStyle.inkType
        let pointWidth = inkType == .monoline || inkType == .pen
            ? 2 + max(inkStyle.width, 1) / 2 : max(inkStyle.width, 1)
        let size = CGSize(width: pointWidth, height: pointWidth)
        var renderingPoints: [CGPoint] = []
        for (index, point) in points.enumerated() {
            renderingPoints.append(point)
            if index > 0, index < points.count - 1 {
                let a = CGPoint(x: point.x - points[index - 1].x, y: point.y - points[index - 1].y)
                let b = CGPoint(x: points[index + 1].x - point.x, y: points[index + 1].y - point.y)
                let lengths = hypot(a.x, a.y) * hypot(b.x, b.y)
                if lengths > 0, (a.x * b.x + a.y * b.y) / lengths < 0.8 {
                    // Repeated corner knots prevent PencilKit's spline from rounding a polygon.
                    renderingPoints.append(contentsOf: [point, point])
                }
            }
        }
        let controlPoints = renderingPoints.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: TimeInterval(index) * 0.012, size: size,
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(inkType, color: inkStyle.color),
                        path: PKStrokePath(controlPoints: controlPoints, creationDate: Date()))
    }


}

private struct ShapeSnapInkStyle {
    let inkType: PKInk.InkType
    let color: UIColor
    let width: CGFloat
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

    // Selection and clipboard actions belong to our lasso/text layers. Native PencilKit editing
    // can leave an invisible ink selection active after double-tap and consume subsequent writing.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }

    override func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
        super.addGestureRecognizer(gestureRecognizer)
        disableEditingGesture(gestureRecognizer)
    }

    override func addInteraction(_ interaction: UIInteraction) {
        guard !(interaction is UIEditMenuInteraction), !(interaction is UIContextMenuInteraction) else { return }
        super.addInteraction(interaction)
    }

    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        disableSystemEditingInteractions(in: subview)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        disableSystemEditingInteractions()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // PencilKit may recreate its content views/gestures after a tool or drawing replacement.
        // Check again before the next contact, including taps beneath our SwiftUI lasso handles.
        disableSystemEditingInteractions()
        return super.hitTest(point, with: event)
    }

    func disableSystemEditingInteractions() {
        disableSystemEditingInteractions(in: self)
    }

    private func disableSystemEditingInteractions(in view: UIView) {
        for interaction in view.interactions {
            if let menu = interaction as? UIEditMenuInteraction {
                menu.dismissMenu()
                view.removeInteraction(menu)
            } else if let menu = interaction as? UIContextMenuInteraction {
                menu.dismissMenu()
                view.removeInteraction(menu)
            }
        }
        for gesture in view.gestureRecognizers ?? [] { disableEditingGesture(gesture) }
        for subview in view.subviews { disableSystemEditingInteractions(in: subview) }
    }

    private func disableEditingGesture(_ gesture: UIGestureRecognizer) {
        // Restrict this to PencilKit's subtree. Our finger-to-lasso observer is a plain gesture
        // recognizer; the custom lasso/text views are siblings, so their controls remain active.
        if gesture is UITapGestureRecognizer || gesture is UILongPressGestureRecognizer {
            if gesture.isEnabled { gesture.isEnabled = false }
        }
    }
}

private struct PendingScribbleErase {
    let gesture: ScribbleEraseGesture
    let strokeIndex: Int
    let scale: CGFloat
}

private enum DrawingHistoryAction {
    case removeTrailingStrokes(Int)
    case appendStrokes([PKStroke])
    case restoreDrawing(PKDrawing)
    case restorePageContent(drawing: PKDrawing?, elements: [CanvasPageElement], replacingIDs: Set<UUID>)
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
    func canvasViewDidFinishRendering(_ canvasView: PKCanvasView) {
        guard canvasView === self.canvasView, shapePreview != nil, heldShape == nil,
              !heldInkRecognizer.isTrackingContact else { return }
        discardShapePreview()
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard canvasView === self.canvasView, !isInstallingDrawing else { return }

        // A late PencilKit delegate callback may follow the post-lift straightening transaction.
        // Until the next genuine interaction or synchronized install, the snapped drawing is the
        // authoritative value.
        if authoritativeSnappedDrawing != nil, hasActiveDrawingContact {
            beginToolInteraction()
        }
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
