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
        canvasView.drawingPolicy = .pencilOnly
        canvasView.tool = PKInkingTool(.pen, color: InkPaletteColor.graphite.uiColor, width: 4)
    }

    var drawing: PKDrawing { canvasView.drawing }

    func installInitialDrawing(_ drawing: PKDrawing) {
        isInstallingDrawing = true
        canvasView.drawing = drawing
        canvasView.undoManager?.removeAllActions()
        isInstallingDrawing = false
        refreshHistoryState()
    }

    func updateTool(kind: CanvasToolKind, color: InkPaletteColor, width: Double) {
        switch kind {
        case .pen:
            canvasView.tool = PKInkingTool(.pen, color: color.uiColor, width: width)
        case .marker:
            canvasView.tool = PKInkingTool(
                .marker,
                color: color.uiColor.withAlphaComponent(0.58),
                width: width
            )
        case .eraser:
            canvasView.tool = PKEraserTool(.vector)
        }
    }

    func setFingerDrawingEnabled(_ isEnabled: Bool) {
        canvasView.drawingPolicy = isEnabled ? .anyInput : .pencilOnly
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

    private func replaceDrawing(_ newDrawing: PKDrawing, actionName: String) {
        let previousDrawing = canvasView.drawing
        canvasView.undoManager?.registerUndo(withTarget: self) { target in
            target.replaceDrawing(previousDrawing, actionName: actionName)
        }
        canvasView.undoManager?.setActionName(actionName)
        canvasView.drawing = newDrawing
        onDrawingChanged?(newDrawing)
        refreshHistoryStateSoon()
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
