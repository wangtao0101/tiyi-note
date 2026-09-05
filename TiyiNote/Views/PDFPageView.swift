import PDFKit
import SwiftUI

struct PDFPageView: UIViewRepresentable {
    let page: PDFPage?
    var queuePriority: Operation.QueuePriority = .normal
    weak var drawingActivitySource: DrawingDocumentStore?
    var allowsInitialRenderDuringHandwriting = true

    func makeUIView(context: Context) -> PDFPageRenderView {
        let view = PDFPageRenderView()
        view.queuePriority = queuePriority
        view.allowsInitialRenderDuringHandwriting = allowsInitialRenderDuringHandwriting
        view.drawingActivitySource = drawingActivitySource
        view.page = page
        return view
    }

    func updateUIView(_ uiView: PDFPageRenderView, context: Context) {
        uiView.queuePriority = queuePriority
        uiView.allowsInitialRenderDuringHandwriting = allowsInitialRenderDuringHandwriting
        uiView.drawingActivitySource = drawingActivitySource
        uiView.page = page
    }
}

/// A PDF page is static while PencilKit is drawing over it. Rendering the PDF synchronously from
/// `draw(_:)` made every newly visible or resized page compete with PencilKit on MainActor. This
/// view rasterizes on one background queue, caches the result, and only installs the finished image
/// on the main thread. A size debounce also prevents pinch zoom from starting a render per frame.
final class PDFPageRenderView: UIView {
    var queuePriority: Operation.QueuePriority = .normal
    var allowsInitialRenderDuringHandwriting = true {
        didSet {
            guard oldValue != allowsInitialRenderDuringHandwriting else { return }
            updateHandwritingState(isHandwritingSessionActive)
        }
    }
    weak var drawingActivitySource: DrawingDocumentStore? {
        didSet {
            guard oldValue !== drawingActivitySource else { return }
            updateHandwritingState(
                drawingActivitySource?.isDrawingInteractionActive == true
            )
        }
    }

    var page: PDFPage? {
        didSet {
            guard oldValue !== page else { return }
            debounceWorkItem?.cancel()
            debounceWorkItem = nil
            renderOperation?.cancel()
            renderOperation = nil
            renderGeneration &+= 1
            renderedRequest = nil
            scheduledRequest = nil
            pendingInstallation = nil
            scheduleRender()
        }
    }

    private struct RenderRequest: Equatable {
        let pageIdentity: ObjectIdentifier
        let pointWidth: Int
        let pointHeight: Int
        let pixelScaleTimes100: Int

        var cacheKey: NSString {
            "\(pageIdentity)-\(pointWidth)x\(pointHeight)@\(pixelScaleTimes100)" as NSString
        }
    }

    private struct PendingInstallation {
        let request: RenderRequest
        let generation: UInt64
        let image: UIImage
    }

    private static let renderQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.tiyi.note.pdf-page-raster"
        // PDF rasterization is visual refinement. It must always yield to PencilKit's
        // user-interactive render path on real hardware.
        queue.qualityOfService = .background
        // PDFKit shares internal document state. Serial rendering avoids lock contention while the
        // editor is also searching or inspecting page metadata on MainActor.
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.name = "com.tiyi.note.pdf-page-raster-cache"
        cache.totalCostLimit = 72 * 1_024 * 1_024
        cache.countLimit = 24
        return cache
    }()

    private let imageView = UIImageView()
    private var renderGeneration: UInt64 = 0
    private var renderedRequest: RenderRequest?
    /// Covers both the short layout debounce and the queued/running raster operation. UIKit can
    /// ask a representable to lay out several times before the first PDF raster is ready. Comparing
    /// only with `renderedRequest` made every one of those identical layouts cancel and enqueue the
    /// same expensive `PDFPage.draw`, leaving cancelled work behind PencilKit. One request may be
    /// outstanding at a time.
    private var scheduledRequest: RenderRequest?
    private var debounceWorkItem: DispatchWorkItem?
    private var renderOperation: Operation?
    private var pendingInstallation: PendingInstallation?
    private var isHandwritingSessionActive = false
    private var needsRenderAfterHandwriting = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        isOpaque = true

        imageView.backgroundColor = .white
        imageView.isOpaque = true
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(drawingInteractionActivityChanged(_:)),
            name: .tiyiDrawingInteractionActivityChanged,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        debounceWorkItem?.cancel()
        renderOperation?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        scheduleRender()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            debounceWorkItem?.cancel()
            debounceWorkItem = nil
            renderOperation?.cancel()
            renderOperation = nil
            scheduledRequest = nil
        } else {
            scheduleRender()
        }
    }

    @objc private func drawingInteractionActivityChanged(_ notification: Notification) {
        guard let store = notification.object as? DrawingDocumentStore else { return }
        guard drawingActivitySource == nil || drawingActivitySource === store else { return }
        updateHandwritingState(store.isDrawingInteractionActive)
    }

    private func updateHandwritingState(_ isActive: Bool) {
        isHandwritingSessionActive = isActive
        guard !isHandwritingSessionActive else {
            if page != nil, bounds.width >= 2, bounds.height >= 2 {
                needsRenderAfterHandwriting = true
            }
            if imageView.image != nil || !allowsInitialRenderDuringHandwriting {
                debounceWorkItem?.cancel()
                debounceWorkItem = nil
                // Cancellation prevents queued refinement work from starting. PDFKit cannot
                // interrupt a page.draw already in progress, but background QoS makes that
                // exceptional tail yield to live ink. A page that has no first raster yet is
                // allowed to finish once so its printed content does not disappear under ink.
                renderOperation?.cancel()
                renderOperation = nil
                scheduledRequest = nil
            }
            return
        }
        if let pendingInstallation {
            self.pendingInstallation = nil
            install(
                pendingInstallation.image,
                for: pendingInstallation.request,
                generation: pendingInstallation.generation
            )
        }
        if needsRenderAfterHandwriting {
            needsRenderAfterHandwriting = false
            scheduleRender()
        }
    }

    private func scheduleRender() {
        guard window != nil,
              let page,
              bounds.width >= 2,
              bounds.height >= 2 else { return }

        let displayScale = window?.screen.scale ?? traitCollection.displayScale
        let renderScale = Self.cappedRenderScale(displayScale, for: bounds.size)
        let request = RenderRequest(
            pageIdentity: ObjectIdentifier(page),
            pointWidth: Int(bounds.width.rounded()),
            pointHeight: Int(bounds.height.rounded()),
            pixelScaleTimes100: Int((renderScale * 100).rounded())
        )
        guard request != renderedRequest,
              request != scheduledRequest else { return }

        renderGeneration &+= 1
        let generation = renderGeneration
        debounceWorkItem?.cancel()
        renderOperation?.cancel()
        scheduledRequest = request

        if let cached = Self.imageCache.object(forKey: request.cacheKey) {
            install(cached, for: request, generation: generation)
            return
        }
        guard !isHandwritingSessionActive
                || (imageView.image == nil && allowsInitialRenderDuringHandwriting) else {
            scheduledRequest = nil
            needsRenderAfterHandwriting = true
            return
        }

        let pointSize = CGSize(width: request.pointWidth, height: request.pointHeight)
        let workItem = DispatchWorkItem { [weak self, page] in
            guard let self,
                  self.scheduledRequest == request,
                  generation == self.renderGeneration else { return }
            self.debounceWorkItem = nil
            let operation = BlockOperation()
            operation.qualityOfService = .background
            operation.queuePriority = self.queuePriority
            operation.addExecutionBlock { [weak self, weak operation, page] in
                guard operation?.isCancelled == false else { return }
                let image = autoreleasepool {
                    Self.render(page: page, size: pointSize, scale: renderScale)
                }
                guard operation?.isCancelled == false else { return }
                guard let image else {
                    DispatchQueue.main.async { [weak self, weak operation] in
                        guard operation?.isCancelled == false else { return }
                        self?.finishFailedRender(for: request, generation: generation)
                    }
                    return
                }
                Self.imageCache.setObject(
                    image,
                    forKey: request.cacheKey,
                    cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4)
                )
                DispatchQueue.main.async { [weak self, weak operation] in
                    guard operation?.isCancelled == false else { return }
                    self?.acceptRenderedImage(image, for: request, generation: generation)
                }
            }
            self.renderOperation = operation
            Self.renderQueue.addOperation(operation)
        }
        debounceWorkItem = workItem
        // A resize can emit several layout passes. Waiting two display frames coalesces them while
        // still presenting a first-time page almost immediately.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035, execute: workItem)
    }

    private func acceptRenderedImage(
        _ image: UIImage,
        for request: RenderRequest,
        generation: UInt64
    ) {
        guard generation == renderGeneration else { return }
        // Replacing a large backing image can itself cause a Core Animation commit. Keep the
        // current raster stable during handwriting; a first render is installed so the paper never
        // remains blank beneath the ink.
        if isHandwritingSessionActive, imageView.image != nil {
            pendingInstallation = PendingInstallation(
                request: request,
                generation: generation,
                image: image
            )
            return
        }
        install(image, for: request, generation: generation)
    }

    private func finishFailedRender(
        for request: RenderRequest,
        generation: UInt64
    ) {
        guard generation == renderGeneration,
              scheduledRequest == request else { return }
        scheduledRequest = nil
        renderOperation = nil
    }

    private func install(
        _ image: UIImage,
        for request: RenderRequest,
        generation: UInt64
    ) {
        guard generation == renderGeneration else { return }
        imageView.image = image
        renderedRequest = request
        scheduledRequest = nil
        renderOperation = nil
    }

    private static func cappedRenderScale(_ displayScale: CGFloat, for size: CGSize) -> CGFloat {
        let safeDisplayScale = max(displayScale, 1)
        let requestedPixels = max(
            size.width * size.height * safeDisplayScale * safeDisplayScale,
            1
        )
        let maximumPixels: CGFloat = 7_000_000
        guard requestedPixels > maximumPixels else { return safeDisplayScale }
        return max(1, safeDisplayScale * sqrt(maximumPixels / requestedPixels))
    }

    private static func render(page: PDFPage, size: CGSize, scale: CGFloat) -> UIImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { rendererContext in
            let context = rendererContext.cgContext
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: size))

            let pageBounds = page.bounds(for: .mediaBox)
            guard pageBounds.width > 0, pageBounds.height > 0 else { return }
            let renderedScale = min(
                size.width / pageBounds.width,
                size.height / pageBounds.height
            )
            let renderedSize = CGSize(
                width: pageBounds.width * renderedScale,
                height: pageBounds.height * renderedScale
            )
            let origin = CGPoint(
                x: (size.width - renderedSize.width) / 2,
                y: (size.height - renderedSize.height) / 2
            )

            context.saveGState()
            context.translateBy(x: origin.x, y: origin.y + renderedSize.height)
            context.scaleBy(x: renderedScale, y: -renderedScale)
            context.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
        }
    }
}
