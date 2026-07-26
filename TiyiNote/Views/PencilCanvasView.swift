import PencilKit
import SwiftUI

struct PencilCanvasView: UIViewRepresentable {
    @ObservedObject var controller: CanvasController
    let logicalPageSize: CGSize
    let onFingerLongPress: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PageCanvasContainerView {
        let view = PageCanvasContainerView(
            canvasView: controller.canvasView,
            logicalPageSize: logicalPageSize
        )
        context.coordinator.installLongPressGesture(on: view)
        return view
    }

    func updateUIView(_ uiView: PageCanvasContainerView, context: Context) {
        context.coordinator.parent = self
        uiView.logicalPageSize = logicalPageSize
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PencilCanvasView

        init(parent: PencilCanvasView) {
            self.parent = parent
        }

        func installLongPressGesture(on view: UIView) {
            let gesture = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handleLongPress(_:))
            )
            gesture.minimumPressDuration = 0.52
            gesture.allowableMovement = 12
            gesture.cancelsTouchesInView = false
            gesture.delegate = self
#if targetEnvironment(simulator)
            gesture.allowedTouchTypes = [
                NSNumber(value: UITouch.TouchType.direct.rawValue),
                NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
            ]
#else
            gesture.allowedTouchTypes = [
                NSNumber(value: UITouch.TouchType.direct.rawValue)
            ]
#endif
            view.addGestureRecognizer(gesture)
        }

        @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let view = gesture.view else { return }
            parent.onFingerLongPress(gesture.location(in: view))
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

final class PageCanvasContainerView: UIView {
    let canvasView: PKCanvasView
    var logicalPageSize: CGSize {
        didSet { setNeedsLayout() }
    }

    init(canvasView: PKCanvasView, logicalPageSize: CGSize) {
        self.canvasView = canvasView
        self.logicalPageSize = logicalPageSize
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        addSubview(canvasView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard logicalPageSize.width > 0, logicalPageSize.height > 0 else { return }

        canvasView.transform = .identity
        canvasView.bounds = CGRect(origin: .zero, size: logicalPageSize)
        canvasView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        canvasView.contentSize = logicalPageSize
        canvasView.contentOffset = .zero

        let scaleX = bounds.width / logicalPageSize.width
        let scaleY = bounds.height / logicalPageSize.height
        canvasView.transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
    }
}
