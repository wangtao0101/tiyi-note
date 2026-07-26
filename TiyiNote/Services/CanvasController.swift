import PencilKit
import SwiftUI

final class CanvasController: NSObject, ObservableObject {
    let canvasView: PKCanvasView

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var isUsingTool = false

    var onDrawingChanged: ((PKDrawing) -> Void)?
    var onBecameActive: (() -> Void)?

    private var isInstallingDrawing = false
    private var strokeTransformSession: StrokeTransformSession?

    override init() {
        let canvasView = PKCanvasView(frame: .zero)
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
        configureAnnotationInput()
        canvasView.tool = PKInkingTool(.monoline, color: InkPaletteColor.graphite.uiColor, width: 4)
    }

    var drawing: PKDrawing { canvasView.drawing }

    func installInitialDrawing(_ drawing: PKDrawing) {
        installCanvasDrawing(drawing)
        canvasView.undoManager?.removeAllActions()
        refreshHistoryState()
    }

    func updateTool(
        kind: CanvasToolKind,
        color: InkPaletteColor,
        width: Double,
        eraserSize: CanvasEraserSize
    ) {
        canvasView.drawingGestureRecognizer.isEnabled = kind != .lasso

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
        case .marker:
            canvasView.tool = PKInkingTool(
                .marker,
                color: color.uiColor.withAlphaComponent(0.58),
                width: width
            )
        case .eraser:
            canvasView.tool = PKEraserTool(
                .fixedWidthBitmap,
                width: eraserSize.width
            )
        case .lasso:
            canvasView.tool = PKLassoTool()
        }
    }

    func configureAnnotationInput() {
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
        canvasView.undoManager?.undo()
        refreshHistoryStateSoon()
    }

    func redo() {
        canvasView.undoManager?.redo()
        refreshHistoryStateSoon()
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
        canvasView.undoManager?.registerUndo(withTarget: self) { target in
            target.replaceDrawing(previousDrawing, actionName: actionName)
        }
        canvasView.undoManager?.setActionName(actionName)
        installCanvasDrawing(newDrawing)
        onDrawingChanged?(newDrawing)
        refreshHistoryStateSoon()
    }

    private func appendStrokes(_ strokes: [PKStroke], actionName: String) -> Set<Int> {
        guard !strokes.isEmpty else { return [] }
        let firstIndex = canvasView.drawing.strokes.count
        let newDrawing = PKDrawing(strokes: canvasView.drawing.strokes + strokes)
        replaceDrawing(newDrawing, actionName: actionName)
        return Set(firstIndex..<(firstIndex + strokes.count))
    }

    private func installCanvasDrawing(_ drawing: PKDrawing) {
        isInstallingDrawing = true
        canvasView.drawing = drawing
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
        canUndo = canvasView.undoManager?.canUndo ?? false
        canRedo = canvasView.undoManager?.canRedo ?? false
    }

    private func refreshHistoryStateSoon() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshHistoryState()
        }
    }
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
        onDrawingChanged?(canvasView.drawing)
        refreshHistoryStateSoon()
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        isUsingTool = true
        onBecameActive?()
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        isUsingTool = false
        refreshHistoryStateSoon()
    }
}
