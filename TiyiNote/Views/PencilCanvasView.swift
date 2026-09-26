import PencilKit
import SwiftUI

struct PencilCanvasView: UIViewRepresentable {
    /// The page owns this reference and the toolbar history controls observe its published
    /// state. The representable itself only embeds the stable PKCanvasView; subscribing here would
    /// make SwiftUI revisit the UIKit bridge when Undo first becomes available during handwriting.
    let controller: CanvasController
    let logicalPageSize: CGSize
    let logicalViewport: CGRect?
    let isCurrentPage: Bool
    var pagesNavigateFromSidebarOnly: Bool = false
    var usesContinuousPDFScrolling: Bool = false
    var isAnnotationEditingEnabled: Bool = true
    let onFingerPinchChanged: (CGFloat) -> Void
    let onFingerPinchEnded: (CGFloat) -> Void
    let onFingerPinchCancelled: () -> Void
    let onCanvasNavigation: (CanvasNavigationChange) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PageCanvasContainerView {
        controller.configureAnnotationInput(isEditable: isAnnotationEditingEnabled)
        let view = PageCanvasContainerView(
            controller: controller,
            logicalPageSize: logicalPageSize,
            logicalViewport: logicalViewport
        )
        view.suppressesFingerPaging = pagesNavigateFromSidebarOnly
        view.usesContinuousPDFScrolling = usesContinuousPDFScrolling
        let coordinator = context.coordinator
        view.onNavigationAncestorFound = { [weak coordinator, weak view] pager in
            guard let view else { return }
            coordinator?.configureCanvasNavigation(on: pager, container: view)
        }
        return view
    }

    func updateUIView(_ uiView: PageCanvasContainerView, context: Context) {
        context.coordinator.parent = self
        controller.configureAnnotationInput(isEditable: isAnnotationEditingEnabled)
        if uiView.logicalPageSize != logicalPageSize {
            uiView.logicalPageSize = logicalPageSize
        }
        uiView.logicalViewport = logicalViewport
        uiView.suppressesFingerPaging = pagesNavigateFromSidebarOnly
        uiView.usesContinuousPDFScrolling = usesContinuousPDFScrolling
        uiView.configureAncestorNavigation()
    }

    static func dismantleUIView(_ uiView: PageCanvasContainerView, coordinator: Coordinator) {
        uiView.controller.cancelHeldInkRecognition()
        coordinator.removeCanvasNavigation()
        uiView.onNavigationAncestorFound = nil
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PencilCanvasView
        private weak var navigationHost: UIView?
        private weak var canvasContainer: UIView?
        private var canvasPan: UIPanGestureRecognizer?
        private var canvasPinch: UIPinchGestureRecognizer?

        init(parent: PencilCanvasView) {
            self.parent = parent
        }

        func configureCanvasNavigation(on host: UIView, container: UIView) {
            guard parent.isCurrentPage && !parent.usesContinuousPDFScrolling else {
                removeCanvasNavigation()
                return
            }
            canvasContainer = container
            let minimumTouches = parent.pagesNavigateFromSidebarOnly ? parent.controller.navigationTouchCount : 2
            if navigationHost === host {
                canvasPan?.minimumNumberOfTouches = minimumTouches
                return
            }
            removeCanvasNavigation()
            canvasContainer = container
            navigationHost = host
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleCanvasPan(_:)))
            pan.minimumNumberOfTouches = minimumTouches
            pan.maximumNumberOfTouches = 2
            pan.allowedScrollTypesMask = .all
            let pinch = UIPinchGestureRecognizer(
                target: self,
                action: parent.logicalViewport == nil ? #selector(handleFingerPinch(_:)) : #selector(handleCanvasPinch(_:))
            )
            let gestures: [UIGestureRecognizer] = parent.logicalViewport == nil ? [pinch] : [pan, pinch]
            for gesture in gestures {
                gesture.allowedTouchTypes = [
                    NSNumber(value: UITouch.TouchType.direct.rawValue),
                    NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
                ]
                gesture.cancelsTouchesInView = false
                gesture.delaysTouchesBegan = false
                gesture.delaysTouchesEnded = false
                gesture.delegate = self
                host.addGestureRecognizer(gesture)
            }
            canvasPan = parent.logicalViewport == nil ? nil : pan
            canvasPinch = pinch
        }

        func removeCanvasNavigation() {
            if let canvasPan { navigationHost?.removeGestureRecognizer(canvasPan) }
            if let canvasPinch { navigationHost?.removeGestureRecognizer(canvasPinch) }
            canvasPan = nil
            canvasPinch = nil
            navigationHost = nil
            canvasContainer = nil
        }

        @objc private func handleCanvasPan(_ gesture: UIPanGestureRecognizer) {
            guard let canvasContainer else { return }
            if gesture.state == .began || gesture.state == .changed || gesture.state == .ended {
                let translation = gesture.translation(in: canvasContainer)
                gesture.setTranslation(.zero, in: canvasContainer)
                if translation != .zero { parent.onCanvasNavigation(.pan(translation)) }
            }
            if gesture.state == .ended || gesture.state == .cancelled {
                parent.onCanvasNavigation(.finished)
            }
        }

        @objc private func handleCanvasPinch(_ gesture: UIPinchGestureRecognizer) {
            guard let canvasContainer else { return }
            if gesture.state == .began || gesture.state == .changed || gesture.state == .ended {
                let magnification = gesture.scale
                gesture.scale = 1
                parent.onCanvasNavigation(.zoom(magnification, anchor: gesture.location(in: canvasContainer)))
            }
            if gesture.state == .ended || gesture.state == .cancelled {
                parent.onCanvasNavigation(.finished)
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === canvasPan || gestureRecognizer === canvasPinch {
                return !parent.controller.isUsingTool || parent.controller.allowsDirectDrawing
            }
            return true
        }


        @objc private func handleFingerPinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began, .changed:
                parent.onFingerPinchChanged(gesture.scale)
            case .ended:
                parent.onFingerPinchEnded(gesture.scale)
            case .cancelled, .failed:
                parent.onFingerPinchCancelled()
            default:
                break
            }
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
    private struct LayoutConfiguration: Equatable {
        let boundsSize: CGSize
        let logicalPageSize: CGSize
        let logicalViewport: CGRect?
    }

    let controller: CanvasController
    var canvasView: PKCanvasView { controller.canvasView }
    private var appliedLayoutConfiguration: LayoutConfiguration?
    var logicalPageSize: CGSize {
        didSet {
            guard logicalPageSize != oldValue else { return }
            appliedLayoutConfiguration = nil
            setNeedsLayout()
        }
    }
    var logicalViewport: CGRect? {
        didSet {
            guard logicalViewport != oldValue else { return }
            appliedLayoutConfiguration = nil
            setNeedsLayout()
        }
    }
    var onNavigationAncestorFound: ((UIView) -> Void)?
    var suppressesFingerPaging = false
    var usesContinuousPDFScrolling = false

    init(controller: CanvasController, logicalPageSize: CGSize, logicalViewport: CGRect?) {
        self.controller = controller
        self.logicalPageSize = logicalPageSize
        self.logicalViewport = logicalViewport
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
        guard bounds.width > 0,
              bounds.height > 0,
              logicalPageSize.width > 0,
              logicalPageSize.height > 0 else { return }

        let visibleSize = logicalViewport?.size ?? logicalPageSize
        let scaleX = bounds.width / visibleSize.width
        let scaleY = bounds.height / visibleSize.height
        let targetScale = min(scaleX, scaleY)
        let configuration = LayoutConfiguration(
            boundsSize: bounds.size,
            logicalPageSize: logicalPageSize,
            logicalViewport: logicalViewport
        )
        guard appliedLayoutConfiguration != configuration else { return }
        appliedLayoutConfiguration = configuration

        // PKCanvasView is itself a UIScrollView and has a native tiled zoom path. Scaling its
        // complete layer with CGAffineTransform forces Core Animation to composite the transparent
        // live-ink surface as one transformed layer on every Pencil sample. Keep the view at its
        // displayed size and express the logical-page mapping through PencilKit's own zoom scale.
        // Do not compare/reset live UIScrollView properties on every layout pass: PencilKit may
        // adjust those internally while rendering a stroke, and writing zoomScale back at that
        // moment causes an expensive tile/layout transaction under the Pencil.
        canvasView.transform = .identity
        // The page/container owns all camera gestures. PencilKit's own recognizer can otherwise
        // apply a second zoom after our viewport layout, especially on an empty drawing.
        canvasView.pinchGestureRecognizer?.isEnabled = false
        canvasView.bouncesZoom = false
        canvasView.frame = bounds
        canvasView.minimumZoomScale = min(0.05, targetScale)
        canvasView.maximumZoomScale = max(10, targetScale)
        let localViewport = logicalViewport.map { controller.prepareUnboundedViewport($0) }
        // UIScrollView.contentSize is expressed AFTER zoom. Set the zoom first, then
        // the scaled extent; otherwise UIKit multiplies an unscaled replacement by
        // newZoom / oldZoom and the writable tiles can end before the visible camera.
        canvasView.zoomScale = targetScale
        if let viewport = localViewport {
            // PencilKit's writable tile space must be positive. The controller translates this
            // local origin at editing/persistence boundaries; the camera stays in world space.
            canvasView.contentInsetAdjustmentBehavior = .never
            canvasView.contentSize = CGSize(
                width: max(logicalPageSize.width - controller.canvasWorldOrigin.x, viewport.maxX + viewport.width) * targetScale,
                height: max(logicalPageSize.height - controller.canvasWorldOrigin.y, viewport.maxY + viewport.height) * targetScale
            )
            canvasView.contentInset = .zero
        } else {
            canvasView.contentSize = CGSize(width: logicalPageSize.width * targetScale,
                                            height: logicalPageSize.height * targetScale)
        }
        canvasView.showsHorizontalScrollIndicator = false
        canvasView.showsVerticalScrollIndicator = false
        canvasView.contentOffset = localViewport.map {
            CGPoint(x: $0.minX * targetScale, y: $0.minY * targetScale)
        } ?? .zero
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }

        // SwiftUI may finish installing its private scroll view one run-loop turn after this page
        // enters the window. Coordinate both now and once more after that installation completes.
        configureAncestorNavigation()
        DispatchQueue.main.async { [weak self] in
            self?.configureAncestorNavigation()
        }
    }

    func configureAncestorNavigation() {
        let allowedNavigationTouches = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]
        var ancestor = superview
        var contentHost: UIView = self
        var hasConfiguredPagePan = false
        while let view = ancestor {
            if let scrollView = view as? UIScrollView, scrollView !== canvasView {
                // Continuous PDFs have one document scroll surface, including when zoomed.
                // Other bounded workspaces nest a two-finger paper pan inside a one-finger pager.
                // Simulator mouse drawing still uses one contact, so that development input mode
                // reserves it for ink. Pencil-only tests exercise the shipping navigation policy.
                let isPagePan = !usesContinuousPDFScrolling && logicalViewport == nil && !hasConfiguredPagePan
                let touchCount = isPagePan ? 2 : controller.navigationTouchCount
                scrollView.panGestureRecognizer.allowedTouchTypes = allowedNavigationTouches
                scrollView.panGestureRecognizer.minimumNumberOfTouches = touchCount
                scrollView.panGestureRecognizer.maximumNumberOfTouches = touchCount
                if !isPagePan {
                    // A handout page is an infinite world. Fingers move its camera; only the
                    // page sidebar changes chapters. Keep the pager for programmatic selection.
                    if suppressesFingerPaging { scrollView.panGestureRecognizer.isEnabled = false }
                    scrollView.isDirectionalLockEnabled = !usesContinuousPDFScrolling
                    if !suppressesFingerPaging, (touchCount == 1 || logicalViewport != nil),
                       scrollView.gestureRecognizers?.contains(where: {
                           $0 is PageMultiTouchPagingGuard
                       }) != true {
                        scrollView.addGestureRecognizer(PageMultiTouchPagingGuard(pager: scrollView))
                    }
                    for guardGesture in scrollView.gestureRecognizers ?? [] where guardGesture is PageMultiTouchPagingGuard {
                        guardGesture.isEnabled = !suppressesFingerPaging && touchCount == 1
                    }
                    // Keep camera gestures inside the scroll content. HostingScrollView owns
                    // and arbitrates its own recognizers; the content host also covers objects
                    // and text overlays without joining that private recognizer lifecycle.
                    onNavigationAncestorFound?(contentHost)
                    break
                }
                hasConfiguredPagePan = true
            }
            contentHost = view
            ancestor = view.superview
        }
    }
}

/// `maximumNumberOfTouches = 1` only controls whether a pan can begin. Once a finger has
/// started paging, adding a second finger does not stop that pan. Observe the entire contact
/// sequence on the pager (including the margins) and suspend only its pan until every finger
/// lifts. A pinch recognizer ends as soon as either finger lifts, which is too early to unlock.
private final class PageMultiTouchPagingGuard: UIGestureRecognizer {
    private weak var pager: UIScrollView?
    private var activeTouches: Set<UITouch> = []
    private var initialContentOffset: CGPoint?
    private var isPagingLocked = false
    private var shouldRestorePan = false

    init(pager: UIScrollView) {
        self.pager = pager
        super.init(target: nil, action: nil)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    // This observer never competes with PencilKit, page-object gestures, pinching, or page panning.
    // It must also survive an already-recognized single-finger pan to see the second contact.
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if activeTouches.isEmpty {
            initialContentOffset = pager?.contentOffset
        }
        activeTouches.formUnion(touches)
        guard activeTouches.count > 1, !isPagingLocked, let pager else { return }

        isPagingLocked = true
        shouldRestorePan = pager.panGestureRecognizer.isEnabled
        pager.panGestureRecognizer.isEnabled = false
        if let initialContentOffset {
            // Cancel any tentative page drag that began before the second finger arrived.
            pager.setContentOffset(initialContentOffset, animated: false)
        }
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if isPagingLocked {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finishTouches(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finishTouches(touches)
    }

    override func reset() {
        restorePaging()
        activeTouches.removeAll()
        initialContentOffset = nil
        isPagingLocked = false
        super.reset()
    }

    private func finishTouches(_ touches: Set<UITouch>) {
        activeTouches.subtract(touches)
        guard activeTouches.isEmpty else { return }
        restorePaging()
        state = isPagingLocked ? .ended : .failed
    }

    private func restorePaging() {
        if shouldRestorePan {
            pager?.panGestureRecognizer.isEnabled = true
            shouldRestorePan = false
        }
    }
}

/// The continuous document owns one pinch recognizer. A page may become partially visible or
/// leave the lazy stack during a zoom, so its lifecycle cannot own the document's gesture.
struct PDFContinuousPinchBridge: UIViewRepresentable {
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat) -> Void
    var onCancelled: () -> Void
    var canBegin: () -> Bool

    func makeUIView(context: Context) -> PinchHost {
        let view = PinchHost()
        view.isUserInteractionEnabled = false
        view.onChanged = onChanged
        view.onEnded = onEnded
        view.onCancelled = onCancelled
        view.canBegin = canBegin
        return view
    }

    func updateUIView(_ view: PinchHost, context: Context) {
        view.onChanged = onChanged
        view.onEnded = onEnded
        view.onCancelled = onCancelled
        view.canBegin = canBegin
        view.installGesture()
    }

    static func dismantleUIView(_ view: PinchHost, coordinator: ()) {
        view.removeGesture()
    }

    final class PinchHost: UIView, UIGestureRecognizerDelegate {
        var onChanged: ((CGFloat) -> Void)?
        var onEnded: ((CGFloat) -> Void)?
        var onCancelled: (() -> Void)?
        var canBegin: (() -> Bool)?
        private weak var gestureHost: UIView?
        private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))

        override func didMoveToWindow() {
            super.didMoveToWindow()
            installGesture()
            DispatchQueue.main.async { [weak self] in self?.installGesture() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            installGesture()
        }

        func installGesture() {
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    guard gestureHost !== scrollView else { return }
                    removeGesture()
                    pinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                               NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
                    pinch.cancelsTouchesInView = false
                    pinch.delegate = self
                    scrollView.addGestureRecognizer(pinch)
                    gestureHost = scrollView
                    return
                }
                ancestor = view.superview
            }
        }

        func removeGesture() {
            gestureHost?.removeGestureRecognizer(pinch)
            gestureHost = nil
        }

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began, .changed: onChanged?(gesture.scale)
            case .ended: onEnded?(gesture.scale)
            case .cancelled, .failed: onCancelled?()
            default: break
            }
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            canBegin?() ?? true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
