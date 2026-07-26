import PencilKit
import SwiftUI

struct PencilCanvasView: UIViewRepresentable {
    @ObservedObject var controller: CanvasController
    let logicalPageSize: CGSize

    func makeUIView(context: Context) -> PageCanvasContainerView {
        PageCanvasContainerView(
            canvasView: controller.canvasView,
            logicalPageSize: logicalPageSize
        )
    }

    func updateUIView(_ uiView: PageCanvasContainerView, context: Context) {
        uiView.logicalPageSize = logicalPageSize
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
