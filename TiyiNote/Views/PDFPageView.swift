import PDFKit
import SwiftUI

struct PDFPageView: UIViewRepresentable {
    let page: PDFPage?

    func makeUIView(context: Context) -> PDFPageRenderView {
        let view = PDFPageRenderView()
        view.page = page
        return view
    }

    func updateUIView(_ uiView: PDFPageRenderView, context: Context) {
        uiView.page = page
    }
}

final class PDFPageRenderView: UIView {
    var page: PDFPage? {
        didSet {
            if oldValue !== page {
                setNeedsDisplay()
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        isOpaque = true
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard
            let page,
            let context = UIGraphicsGetCurrentContext()
        else { return }

        UIColor.white.setFill()
        context.fill(bounds)

        let pageBounds = page.bounds(for: .mediaBox)
        let scale = min(bounds.width / pageBounds.width, bounds.height / pageBounds.height)
        let renderedSize = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)
        let origin = CGPoint(
            x: (bounds.width - renderedSize.width) / 2,
            y: (bounds.height - renderedSize.height) / 2
        )

        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y + renderedSize.height)
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
    }
}
