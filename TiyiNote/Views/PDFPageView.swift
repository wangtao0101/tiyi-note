import PDFKit
import SwiftUI

struct PDFPageView: UIViewRepresentable {
    let page: PDFPage?
    var cacheIdentity: String? = nil
    var isThumbnail = false
    var isRenderEnabled = true
    var queuePriority: Operation.QueuePriority = .normal
    weak var drawingActivitySource: DrawingDocumentStore?
    var allowsInitialRenderDuringHandwriting = true

    func makeUIView(context: Context) -> PDFPageRenderView {
        let view = PDFPageRenderView()
        view.cacheIdentity = cacheIdentity
        view.isThumbnail = isThumbnail
        view.isRenderEnabled = isRenderEnabled
        view.queuePriority = queuePriority
        view.allowsInitialRenderDuringHandwriting = allowsInitialRenderDuringHandwriting
        view.drawingActivitySource = drawingActivitySource
        view.page = page
        return view
    }

    func updateUIView(_ uiView: PDFPageRenderView, context: Context) {
        uiView.cacheIdentity = cacheIdentity
        uiView.isThumbnail = isThumbnail
        uiView.isRenderEnabled = isRenderEnabled
        uiView.queuePriority = queuePriority
        uiView.allowsInitialRenderDuringHandwriting = allowsInitialRenderDuringHandwriting
        uiView.drawingActivitySource = drawingActivitySource
        uiView.page = page
    }
}

/// A PDF page is static while PencilKit is drawing over it. Rendering the PDF synchronously from
/// `draw(_:)` made every newly visible or resized page compete with PencilKit on MainActor. This
/// view rasterizes on one background queue, caches the result, and only installs the finished image
/// on the main thread. Fixed paper resolution lets resizing and zooming reuse the same raster.
final class PDFPageRenderView: UIView {
    var cacheIdentity: String? {
        didSet { if oldValue != cacheIdentity { invalidateRaster() } }
    }
    var isThumbnail = false {
        didSet { if oldValue != isThumbnail { invalidateRaster() } }
    }
    var isRenderEnabled = true {
        didSet {
            guard oldValue != isRenderEnabled else { return }
            if isRenderEnabled { scheduleRender() }
            else {
                debounceWorkItem?.cancel(); renderOperation?.cancel()
                scheduledRequest = nil
                renderGeneration &+= 1
                pendingInstallation = nil
            }
        }
    }
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
            // PDFPage only weakly references its document. Keep it alive while mounted,
            // including when the store evicts other decoded page documents during scrolling.
            pageDocument = page?.document
            invalidateRaster()
        }
    }

    private var pageDocument: PDFDocument?

    private func invalidateRaster() {
        debounceWorkItem?.cancel(); debounceWorkItem = nil
        renderOperation?.cancel(); renderOperation = nil
        renderGeneration &+= 1
        renderedRequest = nil; scheduledRequest = nil; pendingInstallation = nil
        imageView.image = nil
        scheduleRender()
    }

    private struct RenderRequest: Equatable {
        let identity: String
        let isThumbnail: Bool
        var cacheKey: NSString { "\(identity)|\(isThumbnail ? "thumbnail" : "page")" as NSString }
    }

    private struct PendingInstallation {
        let request: RenderRequest
        let generation: UInt64
        let image: UIImage
    }

    private static let renderQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.tiyi.note.pdf-page-raster"
        // Visible pages take priority; handwriting gates and cancellation below protect live ink.
        queue.qualityOfService = .userInitiated
        // PDFKit shares internal document state. Serial rendering avoids lock contention while the
        // editor is also searching or inspecting page metadata on MainActor.
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.name = "com.tiyi.note.pdf-page-raster-cache"
        cache.totalCostLimit = 144 * 1_024 * 1_024
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
        guard isRenderEnabled, window != nil,
              let page,
              bounds.width >= 2,
              bounds.height >= 2 else { return }

        let request = RenderRequest(
            identity: cacheIdentity ?? "transient-\(ObjectIdentifier(page))",
            isThumbnail: isThumbnail
        )
        guard request != renderedRequest,
              request != scheduledRequest else { return }

        renderGeneration &+= 1
        let generation = renderGeneration
        debounceWorkItem?.cancel()
        renderOperation?.cancel()
        scheduledRequest = request

        if let cached = Self.imageCache.object(forKey: request.cacheKey) {
            if let identity = cacheIdentity {
                DispatchQueue.global(qos: .utility).async { PDFRasterDiskCache.shared.touch(identity) }
            }
            install(cached, for: request, generation: generation)
            return
        }
        guard !isHandwritingSessionActive
                || (imageView.image == nil && allowsInitialRenderDuringHandwriting) else {
            scheduledRequest = nil
            needsRenderAfterHandwriting = true
            return
        }

        let persistentIdentity = cacheIdentity
        let retainedDocument = pageDocument
        let workItem = DispatchWorkItem { [weak self, page] in
            guard let self,
                  self.scheduledRequest == request,
                  generation == self.renderGeneration else { return }
            self.debounceWorkItem = nil
            let operation = BlockOperation()
            operation.qualityOfService = self.isThumbnail ? .utility : .userInitiated
            operation.queuePriority = self.queuePriority
            operation.addExecutionBlock { [weak self, weak operation, page] in
                guard operation?.isCancelled == false else { return }
                let image = autoreleasepool {
                    withExtendedLifetime(retainedDocument) {
                        Self.cachedRaster(page: page, request: request, persistentIdentity: persistentIdentity)
                    }
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
        // Give visible full pages a head start over newly appearing sidebar thumbnails.
        DispatchQueue.main.asyncAfter(deadline: .now() + (isThumbnail ? 0.12 : 0), execute: workItem)
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

    /// Fixed 300-DPI paper raster (A4 ≈ 8.7 MP), independent of window size and zoom.
    /// Oversize sheets have a 12 MP allocation ceiling; sidebar rasters use a 440px long edge.
    static func rasterSize(for page: PDFPage, isThumbnail: Bool) -> CGSize {
        let size = page.bounds(for: .mediaBox).size
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = isThumbnail ? 440 / max(size.width, size.height)
            : min(300 / 72, sqrt(12_000_000 / (size.width * size.height)))
        return CGSize(width: ceil(size.width * scale), height: ceil(size.height * scale))
    }

    private static func cachedRaster(page: PDFPage, request: RenderRequest, persistentIdentity: String?) -> UIImage? {
        if let image = imageCache.object(forKey: request.cacheKey) { return image }
        let variant: PDFRasterDiskCache.Variant = request.isThumbnail ? .thumbnail : .page
        if let identity = persistentIdentity,
           let data = PDFRasterDiskCache.shared.data(for: identity, variant: variant),
           let image = UIImage(data: data) {
            return image.preparingForDisplay() ?? image
        }
        guard let image = render(page: page, size: rasterSize(for: page, isThumbnail: request.isThumbnail), scale: 1) else { return nil }
        if let identity = persistentIdentity, let data = image.jpegData(compressionQuality: 0.92) {
            PDFRasterDiskCache.shared.store(data, for: identity, variant: variant)
        }
        return image
    }

    /// Prefetch only immediate neighbours; cancellation removes work when the reading target changes.
    static func prefetch(page: PDFPage, identity: String) -> Operation {
        let operation = BlockOperation()
        operation.qualityOfService = .utility
        operation.queuePriority = .veryLow
        let request = RenderRequest(identity: identity, isThumbnail: false)
        let retainedDocument = page.document
        operation.addExecutionBlock { [weak operation] in
            guard operation?.isCancelled == false else { return }
            autoreleasepool {
                let image = withExtendedLifetime(retainedDocument) {
                    cachedRaster(page: page, request: request, persistentIdentity: identity)
                }
                guard let image else { return }
                imageCache.setObject(image, forKey: request.cacheKey,
                    cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0))
            }
        }
        renderQueue.addOperation(operation)
        return operation
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
