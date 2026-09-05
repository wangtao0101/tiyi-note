import Foundation
import PDFKit
import PencilKit
import SwiftUI
import UniformTypeIdentifiers

struct PDFDocumentReaderView: View {
    @ObservedObject var documentStore: DrawingDocumentStore
    let documentID: String
    @Binding var showsThumbnails: Bool
    @Binding var pageElementInsertionRequest: PageElementInsertionRequest?
    @Binding var externalPageRequest: Int?
    @Binding var searchHighlight: PDFSearchHighlight?

    let selectedTool: CanvasToolKind
    let selectedColor: InkPaletteColor
    let penWidth: Double
    let markerWidth: Double
    let eraserSize: CanvasEraserSize
    let eraserMode: CanvasEraserMode
    let isAnnotationEditingEnabled: Bool
    let onSelectLassoTool: () -> Void
    let onSelectTextTool: () -> Void
    let onActiveCanvasChanged: (CanvasController, Int) -> Void

    @State private var currentPageIndex: Int
    @State private var visiblePageID: String?
    @State private var pendingProgrammaticPageIndex: Int?
    @State private var visibleControllers: [Int: CanvasController] = [:]
    @State private var zoomScale: CGFloat = 1
    @State private var liveFingerPinchMagnification: CGFloat = 1
    @State private var canvasViewports: [String: CanvasViewport]

    private var isUnboundedCanvas: Bool {
        documentStore.document(withID: documentID)?.kind == .canvas
    }
    private let minimumZoomScale: CGFloat = 1
    private let maximumZoomScale: CGFloat = 3

    init(
        documentStore: DrawingDocumentStore,
        documentID: String,
        showsThumbnails: Binding<Bool>,
        pageElementInsertionRequest: Binding<PageElementInsertionRequest?>,
        externalPageRequest: Binding<Int?>,
        searchHighlight: Binding<PDFSearchHighlight?>,
        selectedTool: CanvasToolKind,
        selectedColor: InkPaletteColor,
        penWidth: Double,
        markerWidth: Double,
        eraserSize: CanvasEraserSize,
        eraserMode: CanvasEraserMode,
        isAnnotationEditingEnabled: Bool = true,
        initialPageIndex: Int,
        onSelectLassoTool: @escaping () -> Void,
        onSelectTextTool: @escaping () -> Void,
        onActiveCanvasChanged: @escaping (CanvasController, Int) -> Void
    ) {
        self.documentStore = documentStore
        self.documentID = documentID
        _showsThumbnails = showsThumbnails
        _pageElementInsertionRequest = pageElementInsertionRequest
        _externalPageRequest = externalPageRequest
        _searchHighlight = searchHighlight
        self.selectedTool = selectedTool
        self.selectedColor = selectedColor
        self.penWidth = penWidth
        self.markerWidth = markerWidth
        self.eraserSize = eraserSize
        self.eraserMode = eraserMode
        self.isAnnotationEditingEnabled = isAnnotationEditingEnabled
        self.onSelectLassoTool = onSelectLassoTool
        self.onSelectTextTool = onSelectTextTool
        self.onActiveCanvasChanged = onActiveCanvasChanged
        _currentPageIndex = State(initialValue: initialPageIndex)
        _visiblePageID = State(initialValue: documentStore.pageID(at: initialPageIndex, in: documentID))
        var viewports: [String: CanvasViewport] = [:]
        if documentStore.document(withID: documentID)?.kind == .canvas {
            for page in documentStore.pages(in: documentID) {
                viewports[page.id] = documentStore.canvasViewport(
                    forPageID: page.id,
                    in: documentID,
                    referenceSize: documentStore.pageSize(at: page.orderIndex, in: documentID)
                )
            }
        }
        _canvasViewports = State(initialValue: viewports)
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsThumbnails {
                PageThumbnailSidebar(
                    documentStore: documentStore,
                    documentID: documentID,
                    currentPageIndex: currentPageIndex,
                    onSelectPage: requestPage,
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            showsThumbnails = false
                        }
                    }
                )
                .transition(.move(edge: .leading).combined(with: .opacity))

                Rectangle()
                    .fill(TiyiNoteTheme.hairline)
                    .frame(width: 1)
            }

            pagesScrollView
        }
        .background(TiyiNoteTheme.documentWorkspace)
    }

    private var pagesScrollView: some View {
        GeometryReader { geometry in
            let effectiveZoomScale = isUnboundedCanvas
                ? canvasViewports[documentStore.pageID(at: currentPageIndex, in: documentID) ?? ""]?.zoomScale ?? 1
                : displayedZoomScale(zoomScale * liveFingerPinchMagnification)

            Group {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(documentStore.pages(in: documentID)) { pageMetadata in
                            pageViewport(
                                for: pageMetadata,
                                size: geometry.size,
                                scale: effectiveZoomScale
                            )
                            .id(pageMetadata.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
                .scrollPosition(id: $visiblePageID, anchor: .top)
                .accessibilityIdentifier("document-page-pager")
                .coordinateSpace(name: "pdfVerticalScroll")
                .onPreferenceChange(PageOffsetPreferenceKey.self, perform: updateCurrentPage)
                .onChange(of: externalPageRequest) { _, pageIndex in
                    guard let pageIndex,
                          (0..<documentStore.pageCount(for: documentID)).contains(pageIndex)
                    else { return }
                    requestPage(pageIndex)
                    externalPageRequest = nil
                }
                .overlay(alignment: .bottomTrailing) {
                    VStack(alignment: .trailing, spacing: 8) {
                        Button(action: resetZoom) {
                            HStack(spacing: 5) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("\(Int((effectiveZoomScale * 100).rounded()))%")
                                    .monospacedDigit()
                            }
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(
                                abs(effectiveZoomScale - 1) > 0.01
                                    ? TiyiNoteTheme.selectionForeground
                                    : TiyiNoteTheme.textSecondary
                            )
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(
                                abs(effectiveZoomScale - 1) > 0.01
                                    ? TiyiNoteTheme.selectionBackground
                                    : TiyiNoteTheme.chrome.opacity(0.90),
                                in: Capsule()
                            )
                            .overlay {
                                Capsule().stroke(
                                    abs(effectiveZoomScale - 1) > 0.01
                                        ? TiyiNoteTheme.selectionBorder
                                        : TiyiNoteTheme.hairline,
                                    lineWidth: 1
                                )
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("当前缩放 \(Int((effectiveZoomScale * 100).rounded()))%，\(isUnboundedCanvas ? "点击重置缩放" : "点击恢复适页")")
                        .accessibilityIdentifier("zoom-reset")

                        HStack(spacing: 6) {
                            Circle()
                                .fill(TiyiNoteTheme.selectionBlue)
                                .frame(width: 5, height: 5)
                            Text("\(currentPageIndex + 1) / \(documentStore.pageCount(for: documentID))")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .accessibilityIdentifier("document-page-counter")
                        }
                        .foregroundStyle(TiyiNoteTheme.textSecondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(TiyiNoteTheme.chrome.opacity(0.90), in: Capsule())
                        .overlay {
                            Capsule().stroke(TiyiNoteTheme.hairline, lineWidth: 1)
                        }
                        .allowsHitTesting(false)
                    }
                    .padding(14)
                    .padding(.bottom, geometry.safeAreaInsets.bottom)
                }
            }
        }
        // The scroll view extends under the home-indicator safe area. Measure that same viewport
        // for every page target, while keeping the floating controls above the safe-area inset.
        .ignoresSafeArea(.container, edges: .bottom)
        .clipped()
    }

    private func pageViewport(for pageMetadata: LibraryPage, size: CGSize, scale: CGFloat) -> some View {
        let pageIndex = documentStore.pageIndex(for: pageMetadata.id, in: documentID)
            ?? pageMetadata.orderIndex
        let logicalSize = documentStore.pageSize(at: pageIndex, in: documentID)
        let fittedScale = min(
            max(size.width - 64, 1) / max(logicalSize.width, 1),
            max(size.height - 32, 1) / max(logicalSize.height, 1)
        )
        let paperSize = CGSize(
            width: logicalSize.width * fittedScale * scale,
            height: logicalSize.height * fittedScale * scale
        )
        let viewport = isUnboundedCanvas
            ? canvasViewport(for: pageMetadata, referenceSize: logicalSize)
                .logicalBounds(in: size, referenceSize: logicalSize)
            : nil
        let pageView = PDFPageAnnotationView(
            documentStore: documentStore,
            documentID: documentID,
            pageID: pageMetadata.id,
            pageIndex: pageIndex,
            pageElementInsertionRequest: $pageElementInsertionRequest,
            searchHighlight: searchHighlight?.documentID == documentID
                && searchHighlight?.pageIndex == pageIndex ? searchHighlight : nil,
            allowsInitialPDFRenderDuringHandwriting: pageIndex == currentPageIndex,
            logicalPageSize: logicalSize,
            logicalViewport: viewport,
            canvasBackground: isUnboundedCanvas ? pageMetadata : nil,
            selectedTool: selectedTool,
            selectedColor: selectedColor,
            penWidth: penWidth,
            markerWidth: markerWidth,
            eraserSize: eraserSize,
            eraserMode: eraserMode,
            isAnnotationEditingEnabled: isAnnotationEditingEnabled,
            onSelectLassoTool: onSelectLassoTool,
            onSelectTextTool: onSelectTextTool,
            onFingerPinchChanged: updateFingerPinch,
            onFingerPinchEnded: finishFingerPinch,
            onFingerPinchCancelled: cancelFingerPinch,
            onCanvasNavigation: { change in
                updateCanvasViewport(change, for: pageMetadata, size: size, referenceSize: logicalSize)
            },
            onReady: registerController,
            onRelease: unregisterController
        )

        // Each paging target occupies exactly one viewport, including the space around the paper.
        // Zoom changes only this page's inner content, so adjacent pages cannot peek into a resting
        // viewport or move the paging boundary when their dimensions or orientations differ.
        return Group {
            if isUnboundedCanvas {
                pageView
            } else {
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    pageView
                        .frame(width: paperSize.width, height: paperSize.height)
                        .background {
                            ZStack(alignment: .leading) {
                                Color.white
                                Rectangle()
                                    .fill(Color.black.opacity(0.11))
                                    .frame(width: 1)
                                    .blur(radius: 1.8)
                                    .offset(x: -1.5)
                            }
                        }
                        .overlay {
                            Rectangle()
                                .stroke(Color.black.opacity(0.055), lineWidth: 0.5)
                                .allowsHitTesting(false)
                        }
                        .padding(.horizontal, 32)
                        .padding(.vertical, 16)
                        .frame(minWidth: size.width, minHeight: size.height)
                }
                .defaultScrollAnchor(.center)
                .scrollDisabled(scale <= 1)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .background {
            GeometryReader { pageGeometry in
                Color.clear.preference(
                    key: PageOffsetPreferenceKey.self,
                    value: [
                        pageIndex: pageGeometry.frame(in: .named("pdfVerticalScroll")).minY
                    ]
                )
            }
        }
    }

    private func canvasViewport(for page: LibraryPage, referenceSize: CGSize) -> CanvasViewport {
        canvasViewports[page.id] ?? documentStore.canvasViewport(
            forPageID: page.id, in: documentID, referenceSize: referenceSize
        )
    }

    private func updateCanvasViewport(_ change: CanvasNavigationChange, for page: LibraryPage, size: CGSize, referenceSize: CGSize) {
        var viewport = canvasViewport(for: page, referenceSize: referenceSize)
        switch change {
        case .pan(let translation):
            viewport.pan(by: translation, in: size, referenceSize: referenceSize)
        case .zoom(let magnification, let anchor):
            viewport.zoom(by: magnification, around: anchor, in: size, referenceSize: referenceSize)
        case .finished:
            documentStore.saveCanvasViewport(viewport, forPageID: page.id, in: documentID)
        }
        canvasViewports[page.id] = viewport
    }

    private func updateFingerPinch(_ magnification: CGFloat) {
        liveFingerPinchMagnification = max(magnification, 0.01)
    }

    private func finishFingerPinch(_ magnification: CGFloat) {
        let restingScale = clampedZoomScale(zoomScale * max(magnification, 0.01))
        withAnimation(.snappy(duration: 0.28, extraBounce: 0.08)) {
            zoomScale = restingScale
            liveFingerPinchMagnification = 1
        }
    }

    private func cancelFingerPinch() {
        withAnimation(.snappy(duration: 0.24, extraBounce: 0.06)) {
            liveFingerPinchMagnification = 1
        }
    }

    private func clampedZoomScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minimumZoomScale), maximumZoomScale)
    }

    /// Let the sheet follow a pinch beyond its limit with resistance, then return to that limit
    /// on release. Scale the overscroll floor with the document's minimum zoom.
    private func displayedZoomScale(_ proposedScale: CGFloat) -> CGFloat {
        if proposedScale < minimumZoomScale {
            let undershoot = minimumZoomScale - max(proposedScale, 0.01)
            return max(minimumZoomScale * 0.84, minimumZoomScale - undershoot * 0.22)
        }
        if proposedScale > maximumZoomScale {
            let overshoot = proposedScale - maximumZoomScale
            return min(3.18, maximumZoomScale + overshoot * 0.12)
        }
        return proposedScale
    }

    private func resetZoom() {
        if isUnboundedCanvas,
           let page = documentStore.pages(in: documentID).first(where: { $0.orderIndex == currentPageIndex }) {
            var viewport = canvasViewport(
                for: page, referenceSize: documentStore.pageSize(at: currentPageIndex, in: documentID)
            )
            viewport.zoomScale = 1
            canvasViewports[page.id] = viewport
            documentStore.saveCanvasViewport(viewport, forPageID: page.id, in: documentID)
            return
        }
        withAnimation(.easeInOut(duration: 0.22)) {
            zoomScale = 1
        }
    }

    private func requestPage(_ pageIndex: Int) {
        guard let pageID = documentStore.pageID(at: pageIndex, in: documentID) else { return }
        currentPageIndex = pageIndex
        pendingProgrammaticPageIndex = pageIndex
        documentStore.setLastViewedPage(pageIndex, for: documentID)
        withAnimation(.easeInOut(duration: 0.28)) {
            visiblePageID = pageID
        }
        if let controller = visibleControllers[pageIndex] {
            onActiveCanvasChanged(controller, pageIndex)
        }
    }

    private func updateCurrentPage(_ offsets: [Int: CGFloat]) {
        guard let closestPage = offsets.min(by: {
            abs($0.value) < abs($1.value)
        })?.key else { return }

        // Geometry reports the old visible page while an animated scroll is starting. Letting
        // that transient value win immediately made "add page" jump back to the prior page, so
        // consecutive additions were inserted in reverse order. Hold the requested page until
        // the scroll actually reaches it.
        if let pendingPage = pendingProgrammaticPageIndex {
            guard closestPage == pendingPage else { return }
            pendingProgrammaticPageIndex = nil
        }

        if closestPage != currentPageIndex {
            currentPageIndex = closestPage
            documentStore.setLastViewedPage(closestPage, for: documentID)
        }
        if let controller = visibleControllers[closestPage] {
            onActiveCanvasChanged(controller, closestPage)
        }
    }

    private func registerController(_ controller: CanvasController, for pageIndex: Int) {
        if visibleControllers[pageIndex] !== controller {
            visibleControllers[pageIndex] = controller
        }
        if pageIndex == currentPageIndex {
            onActiveCanvasChanged(controller, pageIndex)
        }
    }

    private func unregisterController(_ controller: CanvasController, for pageIndex: Int) {
        if visibleControllers[pageIndex] === controller {
            visibleControllers[pageIndex] = nil
        }
    }
}

private struct PendingDrawingPersistence: Sendable {
    let baseDrawing: PKDrawing
    let causalContext: CollaborationVersionVector
    var containsOnlyAppendedStrokes: Bool
    var generation: UInt64
}

/// Mutable persistence bookkeeping is deliberately kept outside SwiftUI observation. Updating an
/// `@State` with the latest whole drawing after every completed stroke used to invalidate the PDF,
/// object overlays, and canvas representable even though none of their visible state had changed.
@MainActor
private final class PageDrawingPersistenceState {
    var hasLoadedDrawing = false
    var loadedPageAssetRevision: UInt64 = 0
    var deferredPageAssetRevision: UInt64?
    var isDrawingDirty = false
    var needsSnapshotCompaction = false
    var submittedDrawing = PKDrawing()
    var collaborationContext = CollaborationVersionVector()
    var pendingDrawing: PendingDrawingPersistence?
    var persistenceTask: Task<Void, Never>?
    var persistenceScheduleID: UUID?
    var interactionReleaseTask: Task<Void, Never>?
    var lastToolInteractionEndedAt: TimeInterval?
    var globalInteractionObserverTask: Task<Void, Never>?
    var isInteractionSessionActive = false
    var drawingGeneration: UInt64 = 0
    let interactionID = UUID()
}

/// Owns a page's controller without forwarding the controller's history publications into the
/// complete PDF/page/object hierarchy. The toolbar history controls observe CanvasController
/// directly, so Undo and Redo still update immediately without rebuilding the page under the pen.
@MainActor
private final class PageCanvasControllerHolder: ObservableObject {
    let controller = CanvasController()
}

private struct PDFPageAnnotationView: View {
    /// Keeping a document open must not disable durability for the whole editing session. The page
    /// records only lightweight dirty state on Pencil-up, then captures and persists one immutable
    /// snapshot after a sustained editor-wide idle window. A new Pencil contact cancels every
    /// pending stage before it can install a result.
    private static let allowsInEditorDrawingPersistence = true

    /// No page is allowed to snapshot or diff PencilKit state until *all* visible canvases have
    /// been quiet for this long. A page-local timer is insufficient: a lazy neighbouring page can
    /// otherwise wake up and serialize its journal while the user is writing on the current page.
    private static var drawingHeavyWorkQuietWindow: TimeInterval {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let argumentIndex = arguments.firstIndex(of: "--drawing-persistence-idle-delay"),
           arguments.indices.contains(argumentIndex + 1),
           let override = TimeInterval(arguments[argumentIndex + 1]) {
            return max(0.1, override)
        }
#endif
        // Ten continuous seconds without a Pencil contact is the local durability boundary.
        return 10.0
    }

    private static func drawingPersistenceIdleDelay(
        containsOnlyAppendedStrokes: Bool
    ) -> TimeInterval {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let argumentIndex = arguments.firstIndex(of: "--drawing-persistence-idle-delay"),
           arguments.indices.contains(argumentIndex + 1),
           let override = TimeInterval(arguments[argumentIndex + 1]) {
            return max(0.1, override)
        }
#endif
        // Both incremental ink and whole-page mutations share the same user-visible durability
        // contract. Structural edits may take longer to prepare, but they begin only after the same
        // ten-second continuous-idle boundary.
        return drawingHeavyWorkQuietWindow
    }
    /// This short grace period groups nearby Pencil contacts into one interaction session. It does
    /// not start heavy work; the separate ten-second idle timer below does that. Keeping the gate
    /// active briefly also absorbs PencilKit's occasionally late end callbacks on real hardware.
    private static var drawingInteractionReleaseDelay: TimeInterval {
#if DEBUG
        // Persistence UI tests explicitly shorten the deep-idle window; keep their complete
        // release + save cycle deterministic without weakening production scheduling.
        if ProcessInfo.processInfo.arguments.contains("--drawing-persistence-idle-delay") {
            return 0.25
        }
#endif
        return 0.8
    }
#if DEBUG
    /// UI tests inspect the live stroke count through accessibility. A normal debug session must
    /// not invalidate the whole page hierarchy after every stroke just to refresh that test value.
    private static let updatesDrawingAccessibilityForUITesting = ProcessInfo.processInfo.arguments
        .contains("--text-interaction-ui-test")
#endif

    @Environment(\.scenePhase) private var scenePhase

    @ObservedObject var documentStore: DrawingDocumentStore
    let documentID: String
    let pageID: String
    let pageIndex: Int
    @Binding var pageElementInsertionRequest: PageElementInsertionRequest?
    let searchHighlight: PDFSearchHighlight?
    let allowsInitialPDFRenderDuringHandwriting: Bool
    let logicalPageSize: CGSize
    let logicalViewport: CGRect?
    let canvasBackground: LibraryPage?
    let selectedTool: CanvasToolKind
    let selectedColor: InkPaletteColor
    let penWidth: Double
    let markerWidth: Double
    let eraserSize: CanvasEraserSize
    let eraserMode: CanvasEraserMode
    let isAnnotationEditingEnabled: Bool
    let onSelectLassoTool: () -> Void
    let onSelectTextTool: () -> Void
    let onFingerPinchChanged: (CGFloat) -> Void
    let onFingerPinchEnded: (CGFloat) -> Void
    let onFingerPinchCancelled: () -> Void
    let onCanvasNavigation: (CanvasNavigationChange) -> Void
    let onReady: (CanvasController, Int) -> Void
    let onRelease: (CanvasController, Int) -> Void

    @StateObject private var controllerHolder = PageCanvasControllerHolder()
    @State private var drawingPersistence = PageDrawingPersistenceState()
    @State private var arePageElementsDirty = false
    @State private var pageElements: [CanvasPageElement] = []
    @State private var drawingAccessibilityGeneration: UInt64 = 0
    @State private var submittedPageElements: [CanvasPageElement] = []
    @State private var elementCollaborationContext = CollaborationVersionVector()
    @State private var requestedSelection: LassoSelectionRequest?
    @State private var editingTextElementID: UUID?
    @State private var textEditorBaseElement: CanvasPageElement?
    @State private var textEditorCollaborationContext: CollaborationVersionVector?
    @State private var textDraft = ""
    @State private var textFontDraft = PageTextFontPreset.system
    @State private var textFontSizeDraft = 22.0
    @State private var textBoldDraft = false
    @State private var textItalicDraft = false
    @State private var textUnderlinedDraft = false
    @State private var textColorHexDraft = InkPaletteColor.graphite.rgbaHex
    @State private var textAlignmentDraft = PageTextAlignment.leading
    @State private var textMoveOriginBounds: CGRect?
    @State private var textResizeOriginBounds: CGRect?
    @State private var croppingImageElementID: UUID?
    @State private var imageEditorBaseElement: CanvasPageElement?
    @State private var imageEditorCollaborationContext: CollaborationVersionVector?
    @State private var imageOpacityDraft = 1.0
    @State private var editingShapeElementID: UUID?
    @State private var shapeEditorBaseElement: CanvasPageElement?
    @State private var shapeEditorCollaborationContext: CollaborationVersionVector?
    @State private var shapeStrokeColorDraft = InkPaletteColor.graphite
    @State private var shapeFillEnabledDraft = false
    @State private var shapeFillColorDraft = InkPaletteColor.ocean
    @State private var shapeLineWidthDraft = 3.0
    @State private var shapeDashedDraft = false
    @State private var pasteMenuLocation: CGPoint?
    @State private var pasteFeedback: String?

    private var controller: CanvasController {
        controllerHolder.controller
    }

    private var projection: PageProjection {
        PageProjection(pageSize: logicalPageSize, viewport: logicalViewport)
    }

    /// The visible index can change after a page reorder. Every persistence operation resolves
    /// the current index from the stable page ID so a disappearing editor cannot save its state
    /// into the page that has just taken over its former index.
    private var resolvedPageIndex: Int {
        documentStore.pageIndex(for: pageID, in: documentID) ?? pageIndex
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let logicalViewport, let canvasBackground {
                    CanvasBackgroundView(viewport: logicalViewport, page: canvasBackground)
                    if canvasBackground.sourceKind == .pdf {
                        let bounds = displayRect(for: CGRect(origin: .zero, size: logicalPageSize), in: geometry.size)
                        PDFPageView(
                            page: documentStore.page(at: resolvedPageIndex, in: documentID),
                            drawingActivitySource: documentStore,
                            allowsInitialRenderDuringHandwriting: allowsInitialPDFRenderDuringHandwriting
                        )
                        .frame(width: bounds.width, height: bounds.height)
                        .position(x: bounds.midX, y: bounds.midY)
                    }
                } else {
                    PDFPageView(
                        page: documentStore.page(at: resolvedPageIndex, in: documentID),
                        drawingActivitySource: documentStore,
                        allowsInitialRenderDuringHandwriting: allowsInitialPDFRenderDuringHandwriting
                    )
                }

                if let searchHighlight,
                   let page = documentStore.page(at: resolvedPageIndex, in: documentID) {
                    let bounds = searchHighlightRect(
                        searchHighlight.pageBounds,
                        on: page,
                        in: geometry.size
                    )
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.yellow.opacity(0.32))
                        .overlay {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .stroke(Color.orange.opacity(0.82), lineWidth: 1.5)
                        }
                        .frame(width: max(bounds.width, 3), height: max(bounds.height, 3))
                        .position(x: bounds.midX, y: bounds.midY)
                        .allowsHitTesting(false)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("PDF 搜索命中")
                        .accessibilityIdentifier("pdf-search-highlight-\(pageIndex)")
                }

                ForEach(pageElements.sorted(by: pageElementSort)) { element in
                    let bounds = displayRect(for: element.logicalBounds, in: geometry.size)
                    PageElementView(
                        element: element,
                        displayScale: geometry.size.width / max(projection.logicalBounds.width, 1)
                    )
                        .accessibilityIdentifier(element.accessibilityIdentifier)
                        .accessibilityValue(element.accessibilityValue)
                        .frame(width: bounds.width, height: bounds.height)
                        .rotationEffect(.radians(element.rotationRadians))
                        .position(x: bounds.midX, y: bounds.midY)
                        .opacity(element.id == editingTextElementID ? 0 : 1)
                        .allowsHitTesting(false)
                }

                PencilCanvasView(
                    controller: controller,
                    logicalPageSize: logicalPageSize,
                    logicalViewport: logicalViewport,
                    isCurrentPage: allowsInitialPDFRenderDuringHandwriting,
                    onFingerLongPress: { point in
                        presentPasteMenu(at: point)
                    },
                    onFingerPinchChanged: onFingerPinchChanged,
                    onFingerPinchEnded: onFingerPinchEnded,
                    onFingerPinchCancelled: onFingerPinchCancelled,
                    onCanvasNavigation: onCanvasNavigation
                )
                .accessibilityLabel("第 \(pageIndex + 1) 页批注画布")
                .accessibilityIdentifier("page-canvas-\(pageIndex)")
                .accessibilityValue(canvasAccessibilityValue)
                .allowsHitTesting(isAnnotationEditingEnabled)

                LassoSelectionOverlay(
                    controller: controller,
                    page: documentStore.page(at: resolvedPageIndex, in: documentID),
                    logicalPageSize: logicalPageSize,
                    logicalViewport: logicalViewport,
                    canvasBackground: canvasBackground,
                    isActive: isAnnotationEditingEnabled
                        && (selectedTool == .lasso || selectedTool == .text),
                    allowsLassoCreation: selectedTool == .lasso,
                    isEditingText: editingTextElementID != nil,
                    pageElements: $pageElements,
                    requestedSelection: $requestedSelection,
                    onBeginInteraction: {
                        dismissPasteMenu()
                        onReady(controller, pageIndex)
                    },
                    onFingerLongPress: { point in
                        presentPasteMenu(at: point)
                    },
                    onPageElementsChanged: {
                        markPageElementsChanged()
                    },
                    onInsertTextElement: insertTextElement,
                    onSelectTextTool: onSelectTextTool,
                    onEditTextElement: beginEditingText,
                    onCropImageElement: beginCroppingImage,
                    onEditShapeElement: beginEditingShape
                )
                // Text editing and lasso selection are two different interaction
                // modes. Recreate the overlay when the tool changes so gesture and
                // selection state from the previous mode cannot survive invisibly
                // and reappear after a later tap.
                .id("page-interaction-\(pageID)-\(selectedTool.rawValue)")

                if editingTextElementID != nil {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: commitTextEdit)

                    inlineTextEditor(in: geometry.size)
                }

                if let pasteMenuLocation {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: dismissPasteMenu)

                    PagePasteMenu(
                        canPaste: TiyiAnnotationPasteboard.copiedContent != nil,
                        onPaste: {
                            pasteCopiedContent(at: pasteMenuLocation, in: geometry.size)
                        }
                    )
                    .position(pasteMenuPosition(for: pasteMenuLocation, in: geometry.size))
                }

                if let pasteFeedback {
                    Text(pasteFeedback)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TiyiNoteTheme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(TiyiNoteTheme.chrome.opacity(0.96), in: Capsule())
                        .overlay {
                            Capsule().stroke(TiyiNoteTheme.hairline, lineWidth: 1)
                        }
                        .position(x: geometry.size.width / 2, y: 30)
                        .allowsHitTesting(false)
                }
            }
        }
        .background(Color.white)
        .onAppear(perform: preparePageCanvas)
        .onDisappear(perform: releasePageCanvas)
        .onChange(of: selectedTool) { _, tool in
            applySelectedTool()
            if tool != .lasso {
                requestedSelection = nil
            }
            if tool != .text, editingTextElementID != nil {
                commitTextEdit()
            }
        }
        .onChange(of: selectedColor) { _, _ in applySelectedTool() }
        .onChange(of: penWidth) { _, _ in applySelectedTool() }
        .onChange(of: markerWidth) { _, _ in applySelectedTool() }
        .onChange(of: eraserSize) { _, _ in applySelectedTool() }
        .onChange(of: eraserMode) { _, _ in applySelectedTool() }
        .onChange(of: isAnnotationEditingEnabled) { _, _ in applySelectedTool() }
        .onChange(of: pageIndex) { oldIndex, newIndex in
            onRelease(controller, oldIndex)
            onReady(controller, newIndex)
        }
        .onChange(of: pageElementInsertionRequest?.id) { _, _ in
            consumePageElementInsertionRequest()
        }
        .onChange(of: scenePhase) { _, phase in
            // `.inactive` is a transient interruption, not a durable idle point. It is entered by
            // system overlays and app/window transitions while the user can return to the Pencil
            // within the next frame. Flushing here used to run collaboration materialization,
            // PKDrawing serialization, JSON encoding, and file replacement on MainActor; a real
            // device trace measured a 187 ms burst followed by a 461 ms microhang. Keep all of that
            // work out of the resumable writing path and reserve the synchronous durability flush
            // for an actual background transition (page/workspace dismissal has its own flush).
            guard phase == .background else { return }
            if editingTextElementID != nil {
                commitTextEdit()
            }
            persistPendingPageChanges()
        }
        .onChange(
            of: documentStore.pageAssetRevision(forPage: resolvedPageIndex, in: documentID)
        ) { _, revision in
            reloadRemotePageAssetsIfPossible(revision: revision)
        }
        .sheet(
            isPresented: Binding(
                get: { croppingImageElementID != nil },
                set: { if !$0 { cancelImageCrop() } }
            )
        ) {
            if let image = croppingImageElementID.flatMap(imageForElement) {
                PageImageCropEditorSheet(
                    image: image,
                    opacity: $imageOpacityDraft,
                    onCancel: cancelImageCrop,
                    onSave: commitImageCrop
                )
            }
        }
        .sheet(
            isPresented: Binding(
                get: { editingShapeElementID != nil },
                set: { if !$0 { cancelShapeEdit() } }
            )
        ) {
            PageShapeEditorSheet(
                strokeColor: $shapeStrokeColorDraft,
                fillEnabled: $shapeFillEnabledDraft,
                fillColor: $shapeFillColorDraft,
                lineWidth: $shapeLineWidthDraft,
                isDashed: $shapeDashedDraft,
                onCancel: cancelShapeEdit,
                onSave: commitShapeEdit
            )
        }
    }

    private func preparePageCanvas() {
        if !drawingPersistence.hasLoadedDrawing {
            let initialDrawing = documentStore.loadDrawing(
                forPage: resolvedPageIndex,
                in: documentID
            )
            let initialElements = documentStore.loadPageElements(
                forPage: resolvedPageIndex,
                in: documentID
            )
            controller.installInitialDrawing(initialDrawing)
            pageElements = initialElements
            drawingPersistence.submittedDrawing = initialDrawing
            submittedPageElements = initialElements
            let frontier = documentStore.collaborationFrontier(
                forPage: resolvedPageIndex,
                in: documentID
            )
            drawingPersistence.collaborationContext = frontier
            elementCollaborationContext = frontier
            drawingPersistence.loadedPageAssetRevision = documentStore.pageAssetRevision(
                forPage: resolvedPageIndex,
                in: documentID
            )
            drawingPersistence.isDrawingDirty = false
            drawingPersistence.needsSnapshotCompaction = false
            arePageElementsDirty = false
            drawingPersistence.hasLoadedDrawing = true
        }

        controller.onDrawingChanged = { [weak documentStore] containsOnlyAppendedStrokes in
            guard isAnnotationEditingEnabled, let documentStore else { return }
#if DEBUG
            if Self.updatesDrawingAccessibilityForUITesting {
                drawingAccessibilityGeneration &+= 1
            }
#endif
            queueDrawingPersistence(
                containsOnlyAppendedStrokes: containsOnlyAppendedStrokes,
                documentStore: documentStore
            )
        }
        controller.onToolInteractionChanged = { [weak documentStore] isUsingTool in
            guard let documentStore else { return }
            if isUsingTool {
                drawingPersistence.lastToolInteractionEndedAt = nil
                if !drawingPersistence.isInteractionSessionActive {
                    drawingPersistence.isInteractionSessionActive = true
                    documentStore.setDrawingInteractionActive(
                        true,
                        id: drawingPersistence.interactionID
                    )
                }
                cancelScheduledDrawingPersistence()
                return
            }
            scheduleDrawingInteractionRelease(documentStore: documentStore)
        }
        controller.onBecameActive = { [weak controller] in
            guard let controller else { return }
            onReady(controller, pageIndex)
        }
        drawingPersistence.globalInteractionObserverTask?.cancel()
        drawingPersistence.globalInteractionObserverTask = nil
        if Self.allowsInEditorDrawingPersistence {
            drawingPersistence.globalInteractionObserverTask = Task { @MainActor in
                for await notification in NotificationCenter.default.notifications(
                    named: .tiyiDrawingInteractionActivityChanged
                ) {
                    guard !Task.isCancelled,
                          let source = notification.object as? DrawingDocumentStore,
                          source === documentStore else { continue }
                    handleGlobalDrawingInteractionChange()
                }
            }
        }
        controller.configureAnnotationInput(isEditable: isAnnotationEditingEnabled)
        applySelectedTool()
        onReady(controller, pageIndex)
        consumePageElementInsertionRequest()
    }

    private var canvasAccessibilityValue: String {
        _ = drawingAccessibilityGeneration
        let value = "笔迹 \(controller.strokeCount)；"
            + "可撤销 \(controller.canUndo ? "是" : "否")；"
            + "吸附 \(controller.lastSnappedShapeKind?.title ?? "无")"
#if DEBUG
        // Geometry is test instrumentation, not user-facing accessibility. Reading PKDrawing here
        // in production made every unrelated SwiftUI refresh materialize the full page on MainActor.
        if Self.updatesDrawingAccessibilityForUITesting {
            return value
                + (logicalViewport.map {
                    String(format: "；视口 %.2f %.2f %.2f %.2f", $0.minX, $0.minY, $0.width, $0.height)
                } ?? "")
                + "；"
                + drawingGeometryAccessibilityValue
                + "；同步重载 \(controller.synchronizedDrawingInstallCount)"
        }
        return value
#else
        return value
#endif
    }

    private var drawingGeometryAccessibilityValue: String {
        let bounds = controller.drawing.bounds
        guard !bounds.isNull, !bounds.isInfinite else { return "范围 空" }
        return String(
            format: "范围 %.2f,%.2f,%.2f,%.2f",
            bounds.minX,
            bounds.minY,
            bounds.width,
            bounds.height
        )
    }

    private func releasePageCanvas() {
        if editingTextElementID != nil {
            commitTextEdit()
        }
        persistPendingPageChanges()
        cancelScheduledDrawingPersistence()
        drawingPersistence.interactionReleaseTask?.cancel()
        drawingPersistence.interactionReleaseTask = nil
        drawingPersistence.lastToolInteractionEndedAt = nil
        drawingPersistence.globalInteractionObserverTask?.cancel()
        drawingPersistence.globalInteractionObserverTask = nil
        drawingPersistence.isInteractionSessionActive = false
        documentStore.setEditorDrawingPersistencePending(
            false,
            id: drawingPersistence.interactionID
        )
        documentStore.setDrawingInteractionActive(false, id: drawingPersistence.interactionID)
        controller.onDrawingChanged = nil
        controller.onToolInteractionChanged = nil
        controller.onBecameActive = nil
        onRelease(controller, pageIndex)
    }

    private func applySelectedTool() {
        guard isAnnotationEditingEnabled else {
            controller.configureAnnotationInput(isEditable: false)
            return
        }
        let width = selectedTool == .marker ? markerWidth : penWidth
        controller.updateTool(
            kind: selectedTool,
            color: selectedColor,
            width: width,
            eraserSize: eraserSize,
            eraserMode: eraserMode
        )
    }

    private func markPageElementsChanged(
        causalContext: CollaborationVersionVector? = nil
    ) {
        guard isAnnotationEditingEnabled else { return }
        arePageElementsDirty = true
        elementCollaborationContext = documentStore.scheduleSave(
            pageElements,
            replacing: submittedPageElements,
            causalContext: causalContext ?? elementCollaborationContext,
            forPage: resolvedPageIndex,
            in: documentID
        )
        submittedPageElements = pageElements
    }

    /// A completed Pencil contact only marks the page dirty. In particular, it does not read or
    /// retain the complete `PKDrawing`; the immutable snapshot is captured once after deep idle.
    /// Page and scene transitions still flush synchronously so pending work is never abandoned.
    private func queueDrawingPersistence(
        containsOnlyAppendedStrokes: Bool,
        documentStore: DrawingDocumentStore
    ) {
        drawingPersistence.isDrawingDirty = true
        drawingPersistence.needsSnapshotCompaction = true
        drawingPersistence.drawingGeneration &+= 1
        documentStore.setEditorDrawingPersistencePending(
            true,
            id: drawingPersistence.interactionID
        )
        if var pendingDrawing = drawingPersistence.pendingDrawing {
            pendingDrawing.containsOnlyAppendedStrokes =
                pendingDrawing.containsOnlyAppendedStrokes && containsOnlyAppendedStrokes
            pendingDrawing.generation = drawingPersistence.drawingGeneration
            drawingPersistence.pendingDrawing = pendingDrawing
        } else {
            drawingPersistence.pendingDrawing = PendingDrawingPersistence(
                baseDrawing: drawingPersistence.submittedDrawing,
                causalContext: drawingPersistence.collaborationContext,
                containsOnlyAppendedStrokes: containsOnlyAppendedStrokes,
                generation: drawingPersistence.drawingGeneration
            )
        }

        // A normal Pencil callback ends here after marking a few scalar fields dirty. The complete
        // persistence pipeline is eligible only after the interaction gate has closed and the
        // editor-wide quiet window has elapsed. Page close, workspace exit, and scene backgrounding
        // remain immediate durable flush points.
        guard Self.allowsInEditorDrawingPersistence else {
            cancelScheduledDrawingPersistence()
            return
        }

        // Persistence regression tests use the same transaction boundaries with an explicitly
        // shortened idle window.
        guard !drawingPersistence.isInteractionSessionActive,
              !controller.isUsingTool else { return }
        scheduleDrawingPersistence(
            after: Self.drawingPersistenceIdleDelay(
                containsOnlyAppendedStrokes:
                    drawingPersistence.pendingDrawing?.containsOnlyAppendedStrokes == true
            ),
            documentStore: documentStore
        )
    }

    private func scheduleDrawingInteractionRelease(
        documentStore: DrawingDocumentStore
    ) {
        guard Self.allowsInEditorDrawingPersistence else {
            // Defensive fallback for a future build that explicitly disables in-editor checkpoints.
            drawingPersistence.lastToolInteractionEndedAt = nil
            drawingPersistence.interactionReleaseTask?.cancel()
            drawingPersistence.interactionReleaseTask = nil
            return
        }
        drawingPersistence.lastToolInteractionEndedAt = ProcessInfo.processInfo.systemUptime
        guard drawingPersistence.interactionReleaseTask == nil else { return }
        drawingPersistence.interactionReleaseTask = Task { @MainActor [weak documentStore] in
            while !Task.isCancelled {
                guard let interactionEndedAt = drawingPersistence.lastToolInteractionEndedAt else {
                    drawingPersistence.interactionReleaseTask = nil
                    return
                }
                let remaining = Self.drawingInteractionReleaseDelay
                    - (ProcessInfo.processInfo.systemUptime - interactionEndedAt)
                if remaining > 0 {
                    do {
                        try await Task.sleep(
                            nanoseconds: UInt64(remaining * 1_000_000_000)
                        )
                    } catch {
                        return
                    }
                    continue
                }
                guard drawingPersistence.lastToolInteractionEndedAt == interactionEndedAt,
                      !controller.isUsingTool,
                      drawingPersistence.isInteractionSessionActive,
                      let documentStore else { continue }

                drawingPersistence.interactionReleaseTask = nil
                drawingPersistence.lastToolInteractionEndedAt = nil
                drawingPersistence.isInteractionSessionActive = false
                documentStore.setDrawingInteractionActive(
                    false,
                    id: drawingPersistence.interactionID
                )
                if Self.allowsInEditorDrawingPersistence,
                   drawingPersistence.pendingDrawing != nil,
                   drawingPersistence.persistenceTask == nil {
                    scheduleDrawingPersistence(
                        after: Self.drawingPersistenceIdleDelay(
                            containsOnlyAppendedStrokes:
                                drawingPersistence.pendingDrawing?.containsOnlyAppendedStrokes
                                    == true
                        ),
                        documentStore: documentStore
                    )
                }
                if let revision = drawingPersistence.deferredPageAssetRevision {
                    drawingPersistence.deferredPageAssetRevision = nil
                    reloadRemotePageAssetsIfPossible(revision: revision)
                }
                return
            }
        }
    }

    private func scheduleDrawingPersistence(
        after delay: TimeInterval,
        documentStore: DrawingDocumentStore
    ) {
        cancelScheduledDrawingPersistence()
        let scheduleID = UUID()
        drawingPersistence.persistenceScheduleID = scheduleID
        drawingPersistence.persistenceTask = Task { @MainActor [weak documentStore] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(max(0, delay) * 1_000_000_000)
                )
            } catch {
                return
            }
            guard !Task.isCancelled,
                  drawingPersistence.persistenceScheduleID == scheduleID,
                  !controller.isUsingTool,
                  !drawingPersistence.isInteractionSessionActive,
                  let pendingState = drawingPersistence.pendingDrawing,
                  let documentStore else { return }

            // The lazy page stack may keep several page editors alive. A timer belonging to an
            // off-screen page must not begin a full drawing read while another page is receiving
            // Pencil input. Restart the complete quiet window after any page's latest contact.
            let globalQuietTimeRemaining = documentStore.drawingInteractionQuietTimeRemaining(
                within: Self.drawingHeavyWorkQuietWindow
            )
            guard !documentStore.isDrawingInteractionActive,
                  globalQuietTimeRemaining <= 0 else {
                drawingPersistence.persistenceTask = nil
                drawingPersistence.persistenceScheduleID = nil
                scheduleDrawingPersistence(
                    after: max(
                        Self.drawingPersistenceIdleDelay(
                            containsOnlyAppendedStrokes:
                                pendingState.containsOnlyAppendedStrokes
                        ),
                        globalQuietTimeRemaining
                    ),
                    documentStore: documentStore
                )
                return
            }

            // This is the first complete drawing read since the previous deep-idle save. Capturing
            // it on MainActor is required by PencilKit; every serialization and diff step below is
            // performed by a cancellable background task.
            let drawing = controller.drawing
            let capturedGeneration = pendingState.generation

            // `PKDrawing.dataRepresentation()` and per-stroke identity preparation both scale with
            // page complexity. They are safe on an immutable drawing value and must not occupy the
            // UI actor, even after the quiet timer has elapsed.
            let preparationTask = Task.detached(priority: .background) {
                DrawingDocumentStore.prepareDrawingPersistence(
                    drawing: drawing,
                    baseDrawing: pendingState.baseDrawing,
                    assumesOnlyAppendedStrokes:
                        pendingState.containsOnlyAppendedStrokes
                )
            }
            let preparedPersistenceResult = await withTaskCancellationHandler(
                operation: { await preparationTask.value },
                onCancel: { preparationTask.cancel() }
            )
            guard let preparedPersistence = preparedPersistenceResult else { return }
            guard let updatedContext = await documentStore.schedulePreparedDrawingSaveAfterIdle(
                drawing,
                replacing: pendingState.baseDrawing,
                causalContext: pendingState.causalContext,
                assumesOnlyAppendedStrokes:
                    pendingState.containsOnlyAppendedStrokes,
                preparedPersistence: preparedPersistence,
                forPage: resolvedPageIndex,
                in: documentID
            ),
            !Task.isCancelled,
            drawingPersistence.persistenceScheduleID == scheduleID,
            drawingPersistence.pendingDrawing?.generation == capturedGeneration,
            !controller.isUsingTool,
            !drawingPersistence.isInteractionSessionActive else { return }

            drawingPersistence.pendingDrawing = nil
            drawingPersistence.collaborationContext = updatedContext
            drawingPersistence.submittedDrawing = drawing
            documentStore.setEditorDrawingPersistencePending(
                false,
                id: drawingPersistence.interactionID
            )
            if !pendingState.containsOnlyAppendedStrokes {
                // Structural edits prepared a complete asset. Appended ink deliberately leaves
                // compaction for page close/background so it cannot race a later Pencil contact.
                drawingPersistence.needsSnapshotCompaction = false
            }
            drawingPersistence.persistenceTask = nil
            drawingPersistence.persistenceScheduleID = nil
        }
    }

    private func cancelScheduledDrawingPersistence() {
        drawingPersistence.persistenceTask?.cancel()
        drawingPersistence.persistenceTask = nil
        drawingPersistence.persistenceScheduleID = nil
    }

    private func handleGlobalDrawingInteractionChange() {
        guard Self.allowsInEditorDrawingPersistence else { return }
        guard drawingPersistence.pendingDrawing != nil else { return }
        if documentStore.isDrawingInteractionActive {
            // Cancelling the parent also cancels its detached preparation worker through the task's
            // cancellation handler. This is what keeps an old/off-screen page from stealing CPU
            // from the first few strokes on the active page.
            cancelScheduledDrawingPersistence()
            return
        }
        guard drawingPersistence.persistenceTask == nil else { return }
        scheduleDrawingPersistence(
            after: Self.drawingPersistenceIdleDelay(
                containsOnlyAppendedStrokes:
                    drawingPersistence.pendingDrawing?.containsOnlyAppendedStrokes == true
            ),
            documentStore: documentStore
        )
    }

    private func persistQueuedDrawingChange(
        preparedPersistence: PreparedDrawingPersistence? = nil,
        documentStore: DrawingDocumentStore
    ) {
        cancelScheduledDrawingPersistence()
        guard let pendingDrawing = drawingPersistence.pendingDrawing else { return }
        let drawing = controller.drawing
        drawingPersistence.pendingDrawing = nil
        drawingPersistence.collaborationContext = documentStore.scheduleSave(
            drawing,
            replacing: pendingDrawing.baseDrawing,
            causalContext: pendingDrawing.causalContext,
            assumesOnlyAppendedStrokes: pendingDrawing.containsOnlyAppendedStrokes,
            preparedPersistence: preparedPersistence,
            forPage: resolvedPageIndex,
            in: documentID
        )
        drawingPersistence.submittedDrawing = drawing
        drawingPersistence.needsSnapshotCompaction = false
        documentStore.setEditorDrawingPersistencePending(
            false,
            id: drawingPersistence.interactionID
        )
    }

    private func consumePageElementInsertionRequest() {
        guard let request = pageElementInsertionRequest,
              request.pageIndex == pageIndex,
              isAnnotationEditingEnabled else { return }

        if case .text = request.payload, selectedTool != .text {
            // The toolbar may have moved on before SwiftUI delivers this request.
            // Consuming it under lasso would create a selected text object with no
            // editor, producing the intermittent lasso box reported by users.
            pageElementInsertionRequest = nil
            return
        }

        // A second insertion action must finish the current editor first. Otherwise the
        // draft state is silently rebound to the new object while the previous text box
        // remains on the page, which makes repeated toolbar taps appear nondeterministic.
        if editingTextElementID != nil {
            commitTextEdit()
        }

        let bounds: CGRect
        switch request.payload {
        case .text(let payload):
            bounds = defaultTextElementBounds(for: payload)
        case .image(let payload):
            let imageSize = UIImage(data: payload.pngData)?.size ?? CGSize(width: 4, height: 3)
            let maximumSize = CGSize(
                width: logicalPageSize.width * 0.46,
                height: logicalPageSize.height * 0.36
            )
            let scale = min(
                maximumSize.width / max(imageSize.width, 1),
                maximumSize.height / max(imageSize.height, 1),
                1
            )
            bounds = CGRect(
                x: projection.logicalBounds.midX - imageSize.width * scale / 2,
                y: projection.logicalBounds.midY - imageSize.height * scale / 2,
                width: imageSize.width * scale,
                height: imageSize.height * scale
            )
        case .shape(let payload):
            bounds = centeredElementBounds(
                widthFraction: 0.34,
                heightFraction: payload.kind == .line || payload.kind == .arrow ? 0.06 : 0.22
            )
        }

        let payload: PageElementPayload
        switch request.payload {
        case .text(let value): payload = .text(value)
        case .image(let value): payload = .image(value)
        case .shape(let value): payload = .shape(value)
        }
        let element = CanvasPageElement(
            logicalBounds: bounds,
            zIndex: (pageElements.map(\.zIndex).max() ?? -1) + 1,
            payload: payload
        )
        pageElements.append(element)
        markPageElementsChanged()
        pageElementInsertionRequest = nil

        if case .text = element.payload, selectedTool == .text {
            // Text editing owns its own transform handles. Do not also create a
            // hidden lasso selection for the same object: a fast tool switch can
            // otherwise reveal that delayed selection after the editor commits.
            beginEditingText(element.id)
        } else {
            requestedSelection = LassoSelectionRequest(
                content: LassoSelectionContent(elementIDs: [element.id]),
                logicalBounds: element.logicalBounds
            )
        }
    }

    private func centeredElementBounds(
        widthFraction: CGFloat,
        heightFraction: CGFloat
    ) -> CGRect {
        let size = CGSize(
            width: max(48, logicalPageSize.width * widthFraction),
            height: max(36, logicalPageSize.height * heightFraction)
        )
        return CGRect(
            x: projection.logicalBounds.midX - size.width / 2,
            y: projection.logicalBounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func defaultTextElementBounds(for payload: PageTextPayload) -> CGRect {
        defaultTextElementBounds(
            for: payload,
            centeredAt: CGPoint(
                x: projection.logicalBounds.midX,
                y: projection.logicalBounds.midY
            )
        )
    }

    private func defaultTextElementBounds(
        for payload: PageTextPayload,
        centeredAt center: CGPoint
    ) -> CGRect {
        let fontSize = CGFloat(max(8, payload.fontSize))
        let estimatedTextWidth = CGFloat(max(payload.text.count, 1)) * fontSize + 32
        let size = CGSize(
            width: min(logicalPageSize.width * 0.34, max(132, estimatedTextWidth)),
            height: min(logicalPageSize.height * 0.08, max(48, fontSize * 2))
        )
        return projection.constrain(CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        ))
    }

    private func insertTextElement(at logicalPoint: CGPoint) {
        guard isAnnotationEditingEnabled,
              selectedTool == .text,
              editingTextElementID == nil else { return }

        let payload = PageTextPayload(
            text: "键入文本",
            colorHex: selectedColor.rgbaHex
        )
        let element = CanvasPageElement(
            logicalBounds: defaultTextElementBounds(
                for: payload,
                centeredAt: logicalPoint
            ),
            zIndex: (pageElements.map(\.zIndex).max() ?? -1) + 1,
            payload: .text(payload)
        )
        pageElements.append(element)
        markPageElementsChanged()
        beginEditingText(element.id)
    }

    @ViewBuilder
    private func inlineTextEditor(in displaySize: CGSize) -> some View {
        if let elementID = editingTextElementID,
           let element = pageElements.first(where: { $0.id == elementID })
                ?? textEditorBaseElement {
            let bounds = displayRect(for: element.logicalBounds, in: displaySize)
            let displayScale = displaySize.width / max(projection.logicalBounds.width, 1)

            InlinePageTextEditor(
                text: $textDraft,
                font: textFontDraft,
                fontSize: textFontSizeDraft,
                isBold: textBoldDraft,
                isItalic: textItalicDraft,
                isUnderlined: textUnderlinedDraft,
                colorHex: textColorHexDraft,
                alignment: textAlignmentDraft,
                displayScale: displayScale
            )
            .frame(width: bounds.width, height: bounds.height)
            .rotationEffect(.radians(element.rotationRadians))
            .position(x: bounds.midX, y: bounds.midY)

            InlineTextTransformHandles(
                displayBounds: bounds,
                canvasSize: displaySize,
                rotationRadians: CGFloat(element.rotationRadians),
                onMoveChanged: { translation in
                    updateEditingTextMove(
                        elementID,
                        translation: translation,
                        displaySize: displaySize
                    )
                },
                onMoveEnded: finishEditingTextMove,
                onResizeChanged: { translation in
                    updateEditingTextResize(
                        elementID,
                        translation: translation,
                        displaySize: displaySize
                    )
                },
                onResizeEnded: finishEditingTextResize
            )

            PageTextFormattingBar(
                font: $textFontDraft,
                fontSize: $textFontSizeDraft,
                isBold: $textBoldDraft,
                isItalic: $textItalicDraft,
                isUnderlined: $textUnderlinedDraft,
                colorHex: $textColorHexDraft,
                alignment: $textAlignmentDraft,
                onDone: commitTextEdit
            )
            .position(textFormattingBarPosition(for: bounds, in: displaySize))
        }
    }

    private func textFormattingBarPosition(for bounds: CGRect, in displaySize: CGSize) -> CGPoint {
        let halfBarWidth: CGFloat = 92
        let x = min(
            max(bounds.midX, halfBarWidth + 8),
            max(halfBarWidth + 8, displaySize.width - halfBarWidth - 8)
        )
        let y = bounds.minY >= 66
            ? bounds.minY - 34
            : min(displaySize.height - 30, bounds.maxY + 34)
        return CGPoint(x: x, y: y)
    }

    private func updateEditingTextMove(
        _ elementID: UUID,
        translation: CGSize,
        displaySize: CGSize
    ) {
        guard let index = pageElements.firstIndex(where: { $0.id == elementID }) else { return }
        let origin = textMoveOriginBounds ?? pageElements[index].logicalBounds
        if textMoveOriginBounds == nil { textMoveOriginBounds = origin }

        let logicalTranslation = projection.logicalTranslation(translation, displaySize: displaySize)
        let movedBounds = origin.offsetBy(
            dx: logicalTranslation.width,
            dy: logicalTranslation.height
        )
        pageElements[index].logicalBounds = projection.constrain(movedBounds)
    }

    private func finishEditingTextMove() {
        guard textMoveOriginBounds != nil else { return }
        textMoveOriginBounds = nil
        markPageElementsChanged()
    }

    private func updateEditingTextResize(
        _ elementID: UUID,
        translation: CGSize,
        displaySize: CGSize
    ) {
        guard let index = pageElements.firstIndex(where: { $0.id == elementID }) else { return }
        let origin = textResizeOriginBounds ?? pageElements[index].logicalBounds
        if textResizeOriginBounds == nil { textResizeOriginBounds = origin }

        let logicalTranslation = projection.logicalTranslation(translation, displaySize: displaySize)
        var resizedBounds = origin
        resizedBounds.size.width = min(
            max(48, origin.width + logicalTranslation.width),
            projection.isUnbounded ? .greatestFiniteMagnitude : logicalPageSize.width - origin.minX
        )
        resizedBounds.size.height = min(
            max(36, origin.height + logicalTranslation.height),
            projection.isUnbounded ? .greatestFiniteMagnitude : logicalPageSize.height - origin.minY
        )
        pageElements[index].logicalBounds = resizedBounds
    }

    private func finishEditingTextResize() {
        guard textResizeOriginBounds != nil else { return }
        textResizeOriginBounds = nil
        markPageElementsChanged()
    }

    private func beginEditingText(_ elementID: UUID) {
        guard let element = pageElements.first(where: { $0.id == elementID }),
              case .text(let payload) = element.payload else { return }
        // The editor owns the object exclusively. Discard any queued selection
        // request before exposing it so a lasso box cannot arrive a frame later.
        requestedSelection = nil
        textDraft = payload.text
        textFontDraft = PageTextFontPreset(storedName: payload.fontName)
        textFontSizeDraft = payload.fontSize
        textBoldDraft = payload.isBold
        textItalicDraft = payload.isItalic
        textUnderlinedDraft = payload.isUnderlined
        textColorHexDraft = payload.colorHex
        textAlignmentDraft = payload.alignment
        textEditorBaseElement = element
        textEditorCollaborationContext = elementCollaborationContext
        editingTextElementID = elementID
    }

    private func commitTextEdit() {
        guard let editingTextElementID,
              var element = pageElements.first(where: { $0.id == editingTextElementID })
                ?? textEditorBaseElement,
              case .text(var payload) = element.payload else { return }
        payload.text = textDraft
        payload.fontName = textFontDraft.rawValue
        payload.fontSize = textFontSizeDraft
        payload.isBold = textBoldDraft
        payload.isItalic = textItalicDraft
        payload.isUnderlined = textUnderlinedDraft
        payload.colorHex = textColorHexDraft
        payload.alignment = textAlignmentDraft
        element.payload = .text(payload)
        if let index = pageElements.firstIndex(where: { $0.id == editingTextElementID }) {
            pageElements[index] = element
        } else {
            // A remote concurrent delete remains remove-wins in the merge engine, but emitting the
            // stale editor's operation preserves this edited object as a recoverable conflict copy.
            pageElements.append(element)
        }
        let causalContext = textEditorCollaborationContext
        cancelTextEdit()
        markPageElementsChanged(causalContext: causalContext)
    }

    private func cancelTextEdit() {
        editingTextElementID = nil
        textEditorBaseElement = nil
        textEditorCollaborationContext = nil
        textMoveOriginBounds = nil
        textResizeOriginBounds = nil
    }

    private func beginCroppingImage(_ elementID: UUID) {
        guard imageForElement(elementID) != nil,
              let element = pageElements.first(where: { $0.id == elementID }),
              case .image(let payload) = element.payload else { return }
        imageOpacityDraft = payload.opacity
        imageEditorBaseElement = element
        imageEditorCollaborationContext = elementCollaborationContext
        croppingImageElementID = elementID
    }

    private func imageForElement(_ elementID: UUID) -> UIImage? {
        guard let element = pageElements.first(where: { $0.id == elementID }),
              case .image(let payload) = element.payload else { return nil }
        return UIImage(data: payload.pngData)
    }

    private func commitImageCrop(_ image: UIImage) {
        guard let croppingImageElementID,
              var element = pageElements.first(where: { $0.id == croppingImageElementID })
                ?? imageEditorBaseElement,
              case .image(var payload) = element.payload,
              let pngData = image.pngData() else { return }
        payload.pngData = pngData
        payload.opacity = min(max(imageOpacityDraft, 0.1), 1)
        element.payload = .image(payload)
        let width = element.logicalBounds.width
        element.logicalBounds.size.height = width * image.size.height / max(image.size.width, 1)
        if let index = pageElements.firstIndex(where: { $0.id == croppingImageElementID }) {
            pageElements[index] = element
        } else {
            pageElements.append(element)
        }
        let causalContext = imageEditorCollaborationContext
        cancelImageCrop()
        markPageElementsChanged(causalContext: causalContext)
    }

    private func cancelImageCrop() {
        croppingImageElementID = nil
        imageEditorBaseElement = nil
        imageEditorCollaborationContext = nil
    }

    private func beginEditingShape(_ elementID: UUID) {
        guard let element = pageElements.first(where: { $0.id == elementID }),
              case .shape(let payload) = element.payload else { return }
        shapeStrokeColorDraft = InkPaletteColor.nearest(to: payload.strokeColorHex)
        shapeFillEnabledDraft = payload.fillColorHex != nil
        shapeFillColorDraft = InkPaletteColor.nearest(to: payload.fillColorHex ?? "#1976D2FF")
        shapeLineWidthDraft = payload.lineWidth
        shapeDashedDraft = payload.isDashed
        shapeEditorBaseElement = element
        shapeEditorCollaborationContext = elementCollaborationContext
        editingShapeElementID = elementID
    }

    private func commitShapeEdit() {
        guard let editingShapeElementID,
              var element = pageElements.first(where: { $0.id == editingShapeElementID })
                ?? shapeEditorBaseElement,
              case .shape(var payload) = element.payload else { return }
        payload.strokeColorHex = shapeStrokeColorDraft.rgbaHex
        payload.fillColorHex = shapeFillEnabledDraft ? shapeFillColorDraft.rgbaHex : nil
        payload.lineWidth = min(max(shapeLineWidthDraft, 1), 20)
        payload.isDashed = shapeDashedDraft
        element.payload = .shape(payload)
        if let index = pageElements.firstIndex(where: { $0.id == editingShapeElementID }) {
            pageElements[index] = element
        } else {
            pageElements.append(element)
        }
        let causalContext = shapeEditorCollaborationContext
        cancelShapeEdit()
        markPageElementsChanged(causalContext: causalContext)
    }

    private func cancelShapeEdit() {
        editingShapeElementID = nil
        shapeEditorBaseElement = nil
        shapeEditorCollaborationContext = nil
    }

    /// Flushes only payloads produced by a real edit. Read-only pages and pages that were merely
    /// viewed never create empty annotation assets or alter CloudKit conflict timestamps.
    private func persistPendingPageChanges() {
        var scheduledSnapshotCompaction = false
        if drawingPersistence.pendingDrawing != nil {
            persistQueuedDrawingChange(documentStore: documentStore)
        } else if drawingPersistence.needsSnapshotCompaction {
            // A cheap append-only autosave may already have committed every logical stroke while
            // intentionally leaving the compact PKDrawing asset stale. Closing/backgrounding is
            // the safe point to refresh that asset without affecting live ink latency.
            documentStore.scheduleDrawingSnapshotCompaction(
                controller.drawing,
                causalContext: drawingPersistence.collaborationContext,
                forPage: resolvedPageIndex,
                in: documentID
            )
            drawingPersistence.needsSnapshotCompaction = false
            scheduledSnapshotCompaction = true
        }
        guard
            isAnnotationEditingEnabled,
            documentStore.document(withID: documentID) != nil,
            drawingPersistence.isDrawingDirty
                || arePageElementsDirty
                || scheduledSnapshotCompaction
        else { return }

        if documentStore.flushPendingSaves(forPage: resolvedPageIndex, in: documentID) {
            drawingPersistence.isDrawingDirty = false
            arePageElementsDirty = false
        }
    }

    /// A remote asset can land while this page is alive. Clean channels reload immediately;
    /// dirty channels retain the editor's visual base and later emit a delta against its original
    /// causal frontier. Operation replay then merges that delta with the downloaded edits.
    private func reloadRemotePageAssetsIfPossible(revision: UInt64) {
        guard drawingPersistence.hasLoadedDrawing,
              revision != drawingPersistence.loadedPageAssetRevision else { return }
        guard !controller.isUsingTool,
              !drawingPersistence.isInteractionSessionActive else {
            drawingPersistence.deferredPageAssetRevision = max(
                drawingPersistence.deferredPageAssetRevision ?? 0,
                revision
            )
            return
        }
        if let deferredRevision = drawingPersistence.deferredPageAssetRevision,
           revision >= deferredRevision {
            drawingPersistence.deferredPageAssetRevision = nil
        }

        let drawingHasPendingSave = drawingPersistence.pendingDrawing != nil
            || documentStore.hasPendingDrawingSave(
                forPage: resolvedPageIndex,
                in: documentID
            )
        let hasUnseenDrawingOperations = documentStore
            .hasUnseenDrawingCollaborationOperations(
                outside: drawingPersistence.collaborationContext,
                forPage: resolvedPageIndex,
                in: documentID
            )
        if !hasUnseenDrawingOperations {
            // A local debounce write, an echoed CKAsset, or our own immutable operations can all
            // advance the asset revision. The visible canvas already owns this exact edit. Even a
            // semantically identical `canvasView.drawing = ...` can clear PencilKit's active
            // render tiles on hardware, so acknowledge the save without touching the canvas.
            if !drawingHasPendingSave {
                drawingPersistence.isDrawingDirty = false
            }
        } else if !drawingPersistence.isDrawingDirty || !drawingHasPendingSave {
            let mergedDrawing = documentStore.loadDrawing(
                forPage: resolvedPageIndex,
                in: documentID
            )
            // A completed local autosave also advances the page asset revision.
            // Reinstalling an identical drawing here used to erase the just-created
            // undo history, making Undo disable itself immediately after every stroke.
            if mergedDrawing != controller.drawing {
                controller.installSynchronizedDrawing(
                    mergedDrawing,
                    preservingHistory: drawingPersistence.isDrawingDirty && !drawingHasPendingSave
                )
            }
            drawingPersistence.submittedDrawing = mergedDrawing
            drawingPersistence.collaborationContext = documentStore.collaborationFrontier(
                forPage: resolvedPageIndex,
                in: documentID
            )
            drawingPersistence.isDrawingDirty = false
        }

        let elementsHavePendingSave = documentStore.hasPendingImageAnnotationsSave(
            forPage: resolvedPageIndex,
            in: documentID
        )
        if !arePageElementsDirty || !elementsHavePendingSave {
            let mergedElements = documentStore.loadPageElements(
                forPage: resolvedPageIndex,
                in: documentID
            )
            pageElements = mergedElements
            submittedPageElements = mergedElements
            elementCollaborationContext = documentStore.collaborationFrontier(
                forPage: resolvedPageIndex,
                in: documentID
            )
            arePageElementsDirty = false
        }

        drawingPersistence.loadedPageAssetRevision = revision
    }

    private func presentPasteMenu(at point: CGPoint) {
        guard isAnnotationEditingEnabled else { return }
        onReady(controller, pageIndex)
        pasteFeedback = nil
        pasteMenuLocation = point
    }

    private func dismissPasteMenu() {
        pasteMenuLocation = nil
    }

    private func pasteCopiedContent(at displayPoint: CGPoint, in displaySize: CGSize) {
        guard isAnnotationEditingEnabled,
              let copiedContent = TiyiAnnotationPasteboard.copiedContent else { return }
        let logicalPoint = projection.logicalPoint(displayPoint, displaySize: displaySize)
        pasteMenuLocation = nil
        switch copiedContent {
        case .drawing(let drawing):
            let insertedIndices = controller.pasteDrawing(
                drawing,
                centeredAt: logicalPoint,
                within: projection.isUnbounded ? nil : logicalPageSize
            )
            guard
                !insertedIndices.isEmpty,
                let bounds = controller.boundsForStrokes(at: insertedIndices)
            else { return }
            requestedSelection = LassoSelectionRequest(
                content: LassoSelectionContent(strokeIndices: insertedIndices),
                logicalBounds: bounds
            )
        case .image(let image, let copiedSize):
            let maximumWidth = logicalPageSize.width * 0.78
            let maximumHeight = logicalPageSize.height * 0.78
            let scale = min(
                1,
                maximumWidth / max(copiedSize.width, 1),
                maximumHeight / max(copiedSize.height, 1)
            )
            let size = CGSize(
                width: copiedSize.width * scale,
                height: copiedSize.height * scale
            )
            let bounds = projection.constrain(CGRect(
                x: logicalPoint.x - size.width / 2,
                y: logicalPoint.y - size.height / 2,
                width: size.width,
                height: size.height
            ))
            guard let pngData = image.pngData() else { return }
            let element = CanvasPageElement(
                id: UUID(),
                logicalBounds: bounds,
                payload: .image(PageImagePayload(pngData: pngData))
            )
            pageElements.append(element)
            markPageElementsChanged()
            requestedSelection = LassoSelectionRequest(
                content: LassoSelectionContent(elementIDs: [element.id]),
                logicalBounds: element.logicalBounds
            )
        }
        onSelectLassoTool()
        showPasteFeedback("已粘贴")
    }

    private func showPasteFeedback(_ text: String) {
        pasteFeedback = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard pasteFeedback == text else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                pasteFeedback = nil
            }
        }
    }

    private func pasteMenuPosition(for point: CGPoint, in displaySize: CGSize) -> CGPoint {
        let x = min(max(point.x, 54), max(54, displaySize.width - 54))
        let y = point.y > 70 ? point.y - 44 : min(displaySize.height - 28, point.y + 44)
        return CGPoint(x: x, y: y)
    }

    private func displayRect(for logicalRect: CGRect, in displaySize: CGSize) -> CGRect {
        projection.displayRect(logicalRect, displaySize: displaySize)
    }

    private func searchHighlightRect(
        _ matchBounds: CGRect,
        on page: PDFPage,
        in displaySize: CGSize
    ) -> CGRect {
        let pageBounds = page.bounds(for: .mediaBox)
        let surfaceSize = projection.isUnbounded ? logicalPageSize : displaySize
        let scale = min(
            surfaceSize.width / max(pageBounds.width, 1),
            surfaceSize.height / max(pageBounds.height, 1)
        )
        let renderedSize = CGSize(
            width: pageBounds.width * scale,
            height: pageBounds.height * scale
        )
        let origin = CGPoint(
            x: (surfaceSize.width - renderedSize.width) / 2,
            y: (surfaceSize.height - renderedSize.height) / 2
        )
        let bounds = CGRect(
            x: origin.x + (matchBounds.minX - pageBounds.minX) * scale,
            y: origin.y + (pageBounds.maxY - matchBounds.maxY) * scale,
            width: matchBounds.width * scale,
            height: matchBounds.height * scale
        )
        return projection.isUnbounded ? displayRect(for: bounds, in: displaySize) : bounds
    }

    private func pageElementSort(_ lhs: CanvasPageElement, _ rhs: CanvasPageElement) -> Bool {
        if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private struct InlinePageTextEditor: View {
    @Binding var text: String
    let font: PageTextFontPreset
    let fontSize: Double
    let isBold: Bool
    let isItalic: Bool
    let isUnderlined: Bool
    let colorHex: String
    let alignment: PageTextAlignment
    let displayScale: CGFloat

    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("键入文本")
                    .font(editorFont)
                    .foregroundStyle(Color(uiColor: .tiyiColor(colorHex)).opacity(0.42))
                    .padding(.leading, 5)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .font(editorFont)
                .foregroundStyle(Color(uiColor: .tiyiColor(colorHex)))
                .underline(isUnderlined)
                .multilineTextAlignment(swiftUITextAlignment)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .focused($isFocused)
        }
        .background(Color.white.opacity(0.001))
        .overlay {
            Rectangle()
                .stroke(TiyiNoteTheme.lassoBlue, lineWidth: 1.25)
                .allowsHitTesting(false)
        }
        .accessibilityIdentifier("inline-text-editor")
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                isFocused = true
            }
        }
    }

    private var editorFont: Font {
        font.swiftUIFont(
            size: max(6, CGFloat(fontSize) * displayScale),
            isBold: isBold,
            isItalic: isItalic
        )
    }

    private var swiftUITextAlignment: TextAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

private struct InlineTextTransformHandles: View {
    let displayBounds: CGRect
    let canvasSize: CGSize
    let rotationRadians: CGFloat
    let onMoveChanged: (CGSize) -> Void
    let onMoveEnded: () -> Void
    let onResizeChanged: (CGSize) -> Void
    let onResizeEnded: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Circle()
                .fill(TiyiNoteTheme.lassoBlue)
                .frame(width: 8, height: 8)
                .position(rotatedPosition(CGPoint(x: displayBounds.minX, y: displayBounds.midY)))
                .allowsHitTesting(false)

            Circle()
                .fill(TiyiNoteTheme.lassoBlue)
                .frame(width: 8, height: 8)
                .position(rotatedPosition(CGPoint(x: displayBounds.maxX, y: displayBounds.midY)))
                .allowsHitTesting(false)

            Capsule()
                .fill(TiyiNoteTheme.lassoBlue)
                .frame(width: 30, height: 5)
                .contentShape(Rectangle().inset(by: -12))
                .rotationEffect(.radians(rotationRadians))
                .position(rotatedPosition(CGPoint(x: displayBounds.midX, y: displayBounds.minY)))
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { onMoveChanged($0.translation) }
                        .onEnded { _ in onMoveEnded() }
                )
                .accessibilityLabel("拖动文字框")
                .accessibilityIdentifier("text-move-handle")

            Circle()
                .fill(TiyiNoteTheme.lassoBlue)
                .frame(width: 11, height: 11)
                .overlay {
                    Circle().stroke(Color.white, lineWidth: 1)
                }
                .contentShape(Circle().inset(by: -12))
                .position(
                    rotatedPosition(
                        CGPoint(x: displayBounds.maxX, y: displayBounds.maxY)
                    )
                )
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { onResizeChanged($0.translation) }
                        .onEnded { _ in onResizeEnded() }
                )
                .accessibilityLabel("调整文字框大小")
                .accessibilityIdentifier("text-resize-handle")
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    private func rotatedPosition(_ point: CGPoint) -> CGPoint {
        guard abs(rotationRadians) > 0.0001 else { return point }
        let center = displayBounds.midPoint
        let cosine = cos(rotationRadians)
        let sine = sin(rotationRadians)
        let dx = point.x - center.x
        let dy = point.y - center.y
        return CGPoint(
            x: center.x + cosine * dx - sine * dy,
            y: center.y + sine * dx + cosine * dy
        )
    }
}

private struct PageTextFormattingBar: View {
    @Binding var font: PageTextFontPreset
    @Binding var fontSize: Double
    @Binding var isBold: Bool
    @Binding var isItalic: Bool
    @Binding var isUnderlined: Bool
    @Binding var colorHex: String
    @Binding var alignment: PageTextAlignment
    let onDone: () -> Void

    @State private var showsColorPalette = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                showsColorPalette = true
            } label: {
                Circle()
                    .fill(Color(uiColor: .tiyiColor(colorHex)))
                    .frame(width: 25, height: 25)
                    .overlay {
                        Circle().stroke(Color.primary.opacity(0.16), lineWidth: 1)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("文本颜色")
            .popover(isPresented: $showsColorPalette, arrowEdge: .bottom) {
                PageTextColorPalette(colorHex: $colorHex)
                    .presentationCompactAdaptation(.popover)
            }

            Menu {
                Menu("字体") {
                    ForEach(PageTextFontPreset.allCases) { preset in
                        Button {
                            font = preset
                        } label: {
                            if font == preset {
                                Label(preset.title, systemImage: "checkmark")
                            } else {
                                Text(preset.title)
                            }
                        }
                    }
                }
                Toggle("粗体", isOn: $isBold)
                Toggle("斜体", isOn: $isItalic)
                Toggle("下划线", isOn: $isUnderlined)
                Menu("对齐") {
                    alignmentButton("左对齐", symbol: "text.alignleft", value: .leading)
                    alignmentButton("居中", symbol: "text.aligncenter", value: .center)
                    alignmentButton("右对齐", symbol: "text.alignright", value: .trailing)
                }
            } label: {
                Text("格式")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TiyiNoteTheme.textPrimary)
                    .padding(.horizontal, 6)
                    .frame(height: 40)
            }
            .accessibilityLabel("文本格式")

            Menu {
                Button("减小字号") {
                    fontSize = max(8, fontSize - 1)
                }
                .disabled(fontSize <= 8)
                Button("增大字号") {
                    fontSize = min(144, fontSize + 1)
                }
                .disabled(fontSize >= 144)
                Divider()
                ForEach(Self.commonFontSizes, id: \.self) { size in
                    Button {
                        fontSize = size
                    } label: {
                        if Int(fontSize.rounded()) == Int(size) {
                            Label("\(Int(size))", systemImage: "checkmark")
                        } else {
                            Text("\(Int(size))")
                        }
                    }
                }
            } label: {
                Text("\(Int(fontSize.rounded()))")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(TiyiNoteTheme.textPrimary)
                    .frame(width: 38, height: 40)
            }
            .accessibilityLabel("字号 \(Int(fontSize.rounded()))")

            Rectangle()
                .fill(TiyiNoteTheme.hairline)
                .frame(width: 1, height: 22)
                .padding(.horizontal, 3)

            Button(action: onDone) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 28, height: 28)
                    .background(TiyiNoteTheme.lassoBlue, in: Circle())
                    .padding(.horizontal, 6)
                    .frame(height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("完成文本编辑")
            .accessibilityIdentifier("text-edit-done")
        }
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().stroke(TiyiNoteTheme.strongHairline, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.22), radius: 12, y: 5)
    }

    private static let commonFontSizes: [Double] = [
        8, 10, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64, 72, 96, 120, 144
    ]

    private func alignmentButton(
        _ title: String,
        symbol: String,
        value: PageTextAlignment
    ) -> some View {
        Button {
            alignment = value
        } label: {
            if alignment == value {
                Label(title, systemImage: "checkmark")
            } else {
                Label(title, systemImage: symbol)
            }
        }
    }
}

private struct PageTextColorPalette: View {
    @Binding var colorHex: String

    private let columns = Array(
        repeating: GridItem(.fixed(36), spacing: 12),
        count: 6
    )

    var body: some View {
        VStack(spacing: 16) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(PageTextColorPreset.all) { preset in
                    Button {
                        colorHex = preset.hex
                    } label: {
                        Circle()
                            .fill(Color(uiColor: .tiyiColor(preset.hex)))
                            .frame(width: 34, height: 34)
                            .overlay {
                                Circle().stroke(
                                    isSelected(preset)
                                        ? Color.primary.opacity(0.9)
                                        : Color.primary.opacity(0.16),
                                    lineWidth: isSelected(preset) ? 2.5 : 1
                                )
                            }
                            .padding(3)
                            .background {
                                if isSelected(preset) {
                                    Circle().fill(Color.primary.opacity(0.08))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.title)
                    .accessibilityValue(isSelected(preset) ? "selected" : "not-selected")
                    .accessibilityAddTraits(isSelected(preset) ? .isSelected : [])
                }
            }

            ColorPicker(
                selection: customColorBinding,
                supportsOpacity: false
            ) {
                Text("更多文本颜色")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        }
        .padding(18)
        .frame(width: 326)
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: { Color(uiColor: .tiyiColor(colorHex)) },
            set: { colorHex = UIColor($0).tiyiRGBAHex }
        )
    }

    private func isSelected(_ preset: PageTextColorPreset) -> Bool {
        colorHex.caseInsensitiveCompare(preset.hex) == .orderedSame
    }
}

private struct PageTextColorPreset: Identifiable {
    let title: String
    let hex: String
    var id: String { hex }

    static let all: [Self] = [
        Self(title: "白色", hex: "#FFFFFFFF"),
        Self(title: "灰色", hex: "#B8B8B8FF"),
        Self(title: "黑色", hex: "#000000FF"),
        Self(title: "薄荷绿", hex: "#5FD6C7FF"),
        Self(title: "粉色", hex: "#E74A91FF"),
        Self(title: "紫色", hex: "#7433F1FF"),
        Self(title: "红色", hex: "#F04438FF"),
        Self(title: "橙色", hex: "#F58A07FF"),
        Self(title: "黄色", hex: "#FFD24CFF"),
        Self(title: "绿色", hex: "#5DC466FF"),
        Self(title: "天蓝色", hex: "#52B8E8FF"),
        Self(title: "蓝色", hex: "#2F62E8FF")
    ]
}

private extension UIColor {
    var tiyiRGBAHex: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "#000000FF"
        }
        return String(
            format: "#%02X%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded()),
            Int((alpha * 255).rounded())
        )
    }
}

enum PageImageCropRenderer {
    static func crop(
        _ image: UIImage,
        leftTrim: CGFloat,
        rightTrim: CGFloat,
        topTrim: CGFloat,
        bottomTrim: CGFloat
    ) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let rect = CGRect(
            x: (width * leftTrim).rounded(),
            y: (height * topTrim).rounded(),
            width: max(1, (width * max(0.05, 1 - leftTrim - rightTrim)).rounded()),
            height: max(1, (height * max(0.05, 1 - topTrim - bottomTrim)).rounded())
        ).intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !rect.isNull, rect.width > 0, rect.height > 0,
              let cropped = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
    }
}

private struct PageImageCropEditorSheet: View {
    let image: UIImage
    @Binding var opacity: Double
    let onCancel: () -> Void
    let onSave: (UIImage) -> Void

    @State private var leftTrim: CGFloat = 0
    @State private var rightTrim: CGFloat = 0
    @State private var topTrim: CGFloat = 0
    @State private var bottomTrim: CGFloat = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 300)
                    .overlay {
                        GeometryReader { geometry in
                            Rectangle()
                                .path(in: CGRect(
                                    x: geometry.size.width * leftTrim,
                                    y: geometry.size.height * topTrim,
                                    width: geometry.size.width * max(0.05, 1 - leftTrim - rightTrim),
                                    height: geometry.size.height * max(0.05, 1 - topTrim - bottomTrim)
                                ))
                                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        }
                    }

                VStack(spacing: 10) {
                    cropSlider("左侧", value: $leftTrim, opposite: rightTrim)
                    cropSlider("右侧", value: $rightTrim, opposite: leftTrim)
                    cropSlider("顶部", value: $topTrim, opposite: bottomTrim)
                    cropSlider("底部", value: $bottomTrim, opposite: topTrim)
                    HStack {
                        Text("透明度")
                            .frame(width: 42, alignment: .leading)
                        Slider(value: $opacity, in: 0.1...1)
                            .accessibilityIdentifier("image-opacity")
                        Text("\(Int(opacity * 100))%")
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 20)

                Spacer(minLength: 0)
            }
            .padding(.top, 18)
            .navigationTitle("裁剪图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        if let cropped = PageImageCropRenderer.crop(
                            image,
                            leftTrim: leftTrim,
                            rightTrim: rightTrim,
                            topTrim: topTrim,
                            bottomTrim: bottomTrim
                        ) {
                            onSave(cropped)
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func cropSlider(
        _ title: String,
        value: Binding<CGFloat>,
        opposite: CGFloat
    ) -> some View {
        HStack {
            Text(title)
                .frame(width: 42, alignment: .leading)
            Slider(value: value, in: 0...max(0, 0.9 - opposite))
                .accessibilityIdentifier("image-crop-\(title)")
            Text("\(Int(value.wrappedValue * 100))%")
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
        .font(.system(size: 12, weight: .medium))
    }

}

private struct PageShapeEditorSheet: View {
    @Binding var strokeColor: InkPaletteColor
    @Binding var fillEnabled: Bool
    @Binding var fillColor: InkPaletteColor
    @Binding var lineWidth: Double
    @Binding var isDashed: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("线条") {
                    colorPicker(selection: $strokeColor)
                    HStack {
                        Text("粗细")
                        Slider(value: $lineWidth, in: 1...20, step: 0.5)
                            .accessibilityIdentifier("shape-line-width")
                        Text(String(format: "%.1f", lineWidth))
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                    Toggle("虚线", isOn: $isDashed)
                        .accessibilityIdentifier("shape-dashed")
                }
                Section("填充") {
                    Toggle("启用填充", isOn: $fillEnabled)
                        .accessibilityIdentifier("shape-fill-enabled")
                    if fillEnabled { colorPicker(selection: $fillColor) }
                }
            }
            .navigationTitle("图形样式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: onSave)
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func colorPicker(selection: Binding<InkPaletteColor>) -> some View {
        HStack(spacing: 14) {
            ForEach(InkPaletteColor.allCases) { candidate in
                Button {
                    selection.wrappedValue = candidate
                } label: {
                    Circle()
                        .fill(candidate.color)
                        .frame(width: 27, height: 27)
                        .overlay {
                            Circle().stroke(
                                selection.wrappedValue == candidate
                                    ? Color.accentColor
                                    : .secondary.opacity(0.35),
                                lineWidth: selection.wrappedValue == candidate ? 2.5 : 1
                            )
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(candidate.title)
            }
        }
    }
}

private struct PageElementView: View {
    let element: CanvasPageElement
    let displayScale: CGFloat

    @ViewBuilder
    var body: some View {
        switch element.payload {
        case .text(let payload):
            Text(payload.text)
                .font(
                    PageTextFontPreset(storedName: payload.fontName).swiftUIFont(
                        size: max(6, CGFloat(payload.fontSize) * displayScale),
                        isBold: payload.isBold,
                        isItalic: payload.isItalic
                    )
                )
                .foregroundStyle(Color(uiColor: .tiyiColor(payload.colorHex)))
                .underline(payload.isUnderlined)
                .multilineTextAlignment(payload.swiftUIAlignment)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: payload.frameAlignment)
                .clipped()
        case .image(let payload):
            if let image = UIImage(data: payload.pngData) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .opacity(payload.opacity)
            }
        case .shape(let payload):
            PageShapeElementView(payload: payload, displayScale: displayScale)
        }
    }
}

private struct PageShapeElementView: View {
    let payload: PageShapePayload
    let displayScale: CGFloat

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(
                dx: max(1, CGFloat(payload.lineWidth) * displayScale) / 2,
                dy: max(1, CGFloat(payload.lineWidth) * displayScale) / 2
            )
            var path = Path()
            switch payload.kind {
            case .line, .arrow:
                path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                if payload.kind == .arrow {
                    let head = min(rect.height * 0.35, rect.width * 0.18, 18)
                    path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
                    path.addLine(to: CGPoint(x: rect.maxX - head, y: rect.midY - head * 0.72))
                    path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
                    path.addLine(to: CGPoint(x: rect.maxX - head, y: rect.midY + head * 0.72))
                }
            case .rectangle:
                path.addRect(rect)
            case .ellipse:
                path.addEllipse(in: rect)
            case .triangle:
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.closeSubpath()
            case .diamond:
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
                path.closeSubpath()
            }

            if let fillHex = payload.fillColorHex,
               ![.line, .arrow].contains(payload.kind) {
                context.fill(path, with: .color(Color(uiColor: .tiyiColor(fillHex))))
            }
            context.stroke(
                path,
                with: .color(Color(uiColor: .tiyiColor(payload.strokeColorHex))),
                style: StrokeStyle(
                    lineWidth: max(1, CGFloat(payload.lineWidth) * displayScale),
                    lineCap: .round,
                    lineJoin: .round,
                    dash: payload.isDashed ? [7 * displayScale, 5 * displayScale] : []
                )
            )
        }
    }
}

private extension PageTextPayload {
    var swiftUIAlignment: TextAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var frameAlignment: Alignment {
        switch alignment {
        case .leading: .topLeading
        case .center: .top
        case .trailing: .topTrailing
        }
    }
}

private extension CanvasPageElement {
    var accessibilityIdentifier: String {
        switch payload {
        case .text:
            "page-element-text"
        case .image:
            "page-element-image"
        case .shape:
            "page-element-shape"
        }
    }

    var accessibilityValue: String {
        switch payload {
        case .text(let payload):
            [
                "字体 \(payload.fontName)",
                "字号 \(Int(payload.fontSize.rounded()))",
                "颜色 \(payload.colorHex)",
                payload.isBold ? "粗体" : nil,
                payload.isItalic ? "斜体" : nil,
                payload.isUnderlined ? "下划线" : nil,
                "对齐 \(payload.alignment.rawValue)",
                rotationAccessibilityValue
            ]
            .compactMap { $0 }
            .joined(separator: "；")
        case .image(let payload):
            "图片；透明度 \(Int((payload.opacity * 100).rounded()))%；\(rotationAccessibilityValue)"
        case .shape(let payload):
            [
                payload.kind.title,
                "线宽 \(String(format: "%.1f", payload.lineWidth))",
                payload.isDashed ? "虚线" : "实线",
                payload.fillColorHex == nil ? "无填充" : "有填充",
                rotationAccessibilityValue
            ]
            .joined(separator: "；")
        }
    }

    private var rotationAccessibilityValue: String {
        "旋转 \(Int((rotationRadians * 180 / .pi).rounded()))°"
    }
}

private extension PageTextFontPreset {
    func swiftUIFont(size: CGFloat, isBold: Bool, isItalic: Bool) -> Font {
        let design: Font.Design = switch self {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
        var font = Font.system(
            size: size,
            weight: isBold ? .bold : .regular,
            design: design
        )
        if isItalic { font = font.italic() }
        return font
    }

    func uiFont(size: CGFloat, isBold: Bool, isItalic: Bool) -> UIFont {
        var descriptor = UIFont.systemFont(ofSize: size).fontDescriptor
        let design: UIFontDescriptor.SystemDesign? = switch self {
        case .system: nil
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
        if let design, let designed = descriptor.withDesign(design) {
            descriptor = designed
        }
        var traits = descriptor.symbolicTraits
        if isBold { traits.insert(.traitBold) }
        if isItalic { traits.insert(.traitItalic) }
        if let styled = descriptor.withSymbolicTraits(traits) { descriptor = styled }
        return UIFont(descriptor: descriptor, size: size)
    }
}

private extension UIColor {
    static func tiyiColor(_ rawValue: String) -> UIColor {
        var hex = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard (hex.count == 6 || hex.count == 8),
              let value = UInt64(hex, radix: 16) else { return .black }
        let hasAlpha = hex.count == 8
        return UIColor(
            red: CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xff) / 255,
            green: CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xff) / 255,
            blue: CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xff) / 255,
            alpha: hasAlpha ? CGFloat(value & 0xff) / 255 : 1
        )
    }
}

private struct LassoSelectionContent {
    var strokeIndices: Set<Int> = []
    var elementIDs: Set<UUID> = []

    var isEmpty: Bool { strokeIndices.isEmpty && elementIDs.isEmpty }
}

private struct LassoSelectionRequest: Identifiable {
    let id = UUID()
    let content: LassoSelectionContent
    let logicalBounds: CGRect
}

private struct LassoSelectionOverlay: View {
    /// Selection mutations drive this overlay through its own state and bindings. Controller
    /// history publications are consumed by the toolbar's history controls, not by this layer.
    let controller: CanvasController
    let page: PDFPage?
    let logicalPageSize: CGSize
    let logicalViewport: CGRect?
    let canvasBackground: LibraryPage?
    let isActive: Bool
    let allowsLassoCreation: Bool
    let isEditingText: Bool
    @Binding var pageElements: [CanvasPageElement]
    @Binding var requestedSelection: LassoSelectionRequest?
    let onBeginInteraction: () -> Void
    let onFingerLongPress: (CGPoint) -> Void
    let onPageElementsChanged: () -> Void
    let onInsertTextElement: (CGPoint) -> Void
    let onSelectTextTool: () -> Void
    let onEditTextElement: (UUID) -> Void
    let onCropImageElement: (UUID) -> Void
    let onEditShapeElement: (UUID) -> Void

    @State private var liveLassoPath: [CGPoint] = []
    @State private var selection: LassoStrokeSelection?
    @State private var transformOriginSelection: LassoStrokeSelection?
    @State private var transformOriginElements: [UUID: CanvasPageElement] = [:]
    @State private var inputDragMode: LassoInputDragMode?
    @State private var inputDragStart: CGPoint?
    @State private var feedbackText: String?

    private var projection: PageProjection {
        PageProjection(pageSize: logicalPageSize, viewport: logicalViewport)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if isActive {
                    LassoInputView(
                        shouldBeginDrag: { point, touchType in
                            shouldBeginInputDrag(
                                at: point,
                                touchType: touchType,
                                displaySize: geometry.size
                            )
                        },
                        onBegan: { point in
                            beginInputDrag(at: point, displaySize: geometry.size)
                        },
                        onMoved: { point in
                            updateInputDrag(to: point, displaySize: geometry.size)
                        },
                        onEnded: { point in
                            finishInputDrag(at: point, displaySize: geometry.size)
                        },
                        onTap: { point in
                            handleTap(at: point, displaySize: geometry.size)
                        },
                        onDoubleTap: { point in
                            // A double tap must not silently change the meaning of the
                            // active tool. Reusing the single-tap path keeps repeated
                            // taps deterministic: lasso always selects, text always edits.
                            handleTap(at: point, displaySize: geometry.size)
                        },
                        onFingerLongPress: onFingerLongPress
                    )

                    if allowsLassoCreation {
                        lassoOutline(in: geometry.size)
                    }

                    if allowsLassoCreation,
                       let selection,
                       !isEditingText {
                        selectionBox(for: selection, in: geometry.size)
                    }

                    if allowsLassoCreation, let selection, !isEditingText {
                        LassoActionBar(
                            canEditText: selectedEditableTextID != nil,
                            canCropImage: selectedCroppableImageID != nil,
                            canEditShape: selectedEditableShapeID != nil,
                            canModifySelection: !selectionContainsLockedElement,
                            hasSelectedElements: !selection.content.elementIDs.isEmpty,
                            canGroup: canGroupSelection,
                            canUngroup: canUngroupSelection,
                            isLocked: selectionContainsLockedElement,
                            onEditText: editSelectedText,
                            onCropImage: cropSelectedImage,
                            onEditShape: editSelectedShape,
                            onDelete: deleteSelection,
                            onDuplicate: duplicateSelection,
                            onCopy: copySelectionToPasteboard,
                            onScreenshot: screenshotSelection,
                            onToggleLock: toggleSelectionLock,
                            onBringToFront: bringSelectionToFront,
                            onSendToBack: sendSelectionToBack,
                            onGroup: groupSelection,
                            onUngroup: ungroupSelection
                        )
                        .position(toolbarPosition(for: selection, in: geometry.size))
                    }

                    if let feedbackText {
                        Text(feedbackText)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TiyiNoteTheme.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(TiyiNoteTheme.chrome.opacity(0.96), in: Capsule())
                            .overlay {
                                Capsule().stroke(TiyiNoteTheme.hairline, lineWidth: 1)
                            }
                            .position(
                                selection.map {
                                    feedbackPosition(for: $0, in: geometry.size)
                                } ?? CGPoint(x: geometry.size.width / 2, y: 30)
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.94)))
                            .accessibilityIdentifier("lasso-feedback")
                    }
                }
            }
            .coordinateSpace(name: LassoCoordinateSpace.page)
        }
        .allowsHitTesting(isActive)
        .onChange(of: isActive) { _, active in
            if !active {
                clearSelection()
            } else {
                consumeRequestedSelectionIfPossible()
            }
        }
        .onAppear(perform: consumeRequestedSelectionIfPossible)
        .onChange(of: requestedSelection?.id) { _, _ in
            consumeRequestedSelectionIfPossible()
        }
        .onChange(of: isEditingText) { _, editing in
            if editing {
                clearSelection()
            } else {
                clearTextSelectionAfterEditing()
            }
        }
        .onChange(of: allowsLassoCreation) { _, canDrawLasso in
            if canDrawLasso {
                // Committing a text editor and activating lasso happen in adjacent
                // SwiftUI updates. Clear its hidden text selection immediately so a
                // selection box cannot flash for one frame during the transition.
                clearTextSelectionAfterEditing()
                consumeRequestedSelectionIfPossible()
            }
        }
    }

    private func consumeRequestedSelectionIfPossible() {
        guard isActive,
              allowsLassoCreation,
              !isEditingText,
              let request = requestedSelection else { return }
        onBeginInteraction()
        let content = expandedContentForGroups(request.content)
        selection = LassoStrokeSelection(
            content: content,
            logicalBounds: logicalBounds(
                for: content,
                fallback: request.logicalBounds
            ),
            rotationRadians: 0
        )
        requestedSelection = nil
    }

    private func handleTap(at displayPoint: CGPoint, displaySize: CGSize) {
        if allowsLassoCreation {
            if !selectionContains(displayPoint, displaySize: displaySize),
               !selectElement(at: displayPoint, displaySize: displaySize) {
                dismissSelectionIfNeeded(at: displayPoint, displaySize: displaySize)
            }
        } else if !editTextElement(at: displayPoint, displaySize: displaySize) {
            clearSelection()
            onBeginInteraction()
            onInsertTextElement(
                logicalPoint(for: displayPoint, in: displaySize)
            )
        }
    }

    private func shouldBeginInputDrag(
        at displayPoint: CGPoint,
        touchType: UITouch.TouchType,
        displaySize: CGSize
    ) -> Bool {
        guard allowsLassoCreation else { return false }
        if selectionContains(displayPoint, displaySize: displaySize) {
            return true
        }
        // On a physical iPad a finger keeps navigating the page while Apple Pencil
        // creates a new lasso. Simulator drawing uses direct touches as Pencil input;
        // navigation tests opt into the same Pencil-only policy as the physical iPad.
        return CanvasController.allowsFingerDrawing || touchType != .direct
    }

    private func clearTextSelectionAfterEditing() {
        guard let selection,
              selection.content.strokeIndices.isEmpty,
              selection.content.elementIDs.count == 1,
              let elementID = selection.content.elementIDs.first,
              let element = pageElements.first(where: { $0.id == elementID }),
              case .text = element.payload else {
            return
        }
        clearSelection()
    }

    private var selectedEditableTextID: UUID? {
        guard let selection,
              selection.content.strokeIndices.isEmpty,
              selection.content.elementIDs.count == 1,
              let elementID = selection.content.elementIDs.first,
              let element = pageElements.first(where: { $0.id == elementID }),
              !element.isLocked,
              case .text = element.payload else { return nil }
        return elementID
    }

    private var selectedCroppableImageID: UUID? {
        guard let selection,
              selection.content.strokeIndices.isEmpty,
              selection.content.elementIDs.count == 1,
              let elementID = selection.content.elementIDs.first,
              let element = pageElements.first(where: { $0.id == elementID }),
              !element.isLocked,
              case .image = element.payload else { return nil }
        return elementID
    }

    private var selectedEditableShapeID: UUID? {
        guard let selection,
              selection.content.strokeIndices.isEmpty,
              selection.content.elementIDs.count == 1,
              let elementID = selection.content.elementIDs.first,
              let element = pageElements.first(where: { $0.id == elementID }),
              !element.isLocked,
              case .shape = element.payload else { return nil }
        return elementID
    }

    private var selectionContainsLockedElement: Bool {
        guard let selection else { return false }
        return pageElements.contains {
            selection.content.elementIDs.contains($0.id) && $0.isLocked
        }
    }

    private var canGroupSelection: Bool {
        guard let selection,
              !selectionContainsLockedElement,
              selection.content.elementIDs.count >= 2 else { return false }
        let groups = Set(pageElements.compactMap { element -> UUID? in
            selection.content.elementIDs.contains(element.id) ? element.groupID : nil
        })
        return groups.count != 1
            || pageElements.contains {
                selection.content.elementIDs.contains($0.id) && $0.groupID == nil
            }
    }

    private var canUngroupSelection: Bool {
        guard let selection, !selectionContainsLockedElement else { return false }
        return pageElements.contains {
            selection.content.elementIDs.contains($0.id) && $0.groupID != nil
        }
    }

    @ViewBuilder
    private func lassoOutline(in displaySize: CGSize) -> some View {
        let logicalPath = currentOutlinePath

        if logicalPath.count > 1 {
            Path { path in
                path.move(to: displayPoint(for: logicalPath[0], in: displaySize))
                for point in logicalPath.dropFirst() {
                    path.addLine(to: displayPoint(for: point, in: displaySize))
                }
            }
            .stroke(
                TiyiNoteTheme.lassoBlue,
                style: StrokeStyle(
                    lineWidth: 1.15,
                    lineCap: .round,
                    lineJoin: .round,
                    dash: [4, 3]
                )
            )
            .allowsHitTesting(false)
        }
    }

    private var currentOutlinePath: [CGPoint] {
        liveLassoPath
    }

    @ViewBuilder
    private func selectionBox(
        for selection: LassoStrokeSelection,
        in displaySize: CGSize
    ) -> some View {
        let displayBounds = displayRect(for: selection.logicalBounds, in: displaySize)
        let rotation = Angle.radians(Double(selection.rotationRadians))
        let rotationAnchor = rotationHandlePosition(for: selection, in: displaySize)
        let boxBottom = rotatedDisplayPoint(
            CGPoint(x: displayBounds.midX, y: displayBounds.maxY),
            around: CGPoint(x: displayBounds.midX, y: displayBounds.midY),
            radians: selection.rotationRadians
        )

        Rectangle()
            .fill(Color.clear)
            .frame(width: displayBounds.width, height: displayBounds.height)
            .overlay {
                Rectangle()
                    .stroke(TiyiNoteTheme.lassoBlue, lineWidth: 1.15)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .rotationEffect(rotation)
            .position(x: displayBounds.midX, y: displayBounds.midY)
            .gesture(moveSelectionGesture(displaySize: displaySize))
            .accessibilityIdentifier("lasso-selection-box")

        if selectionContainsLockedElement {
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 25, height: 25)
                .background(TiyiNoteTheme.lassoBlue, in: Circle())
                .position(x: displayBounds.midX, y: displayBounds.midY)
                .allowsHitTesting(false)
        }

        Path { path in
            path.move(to: boxBottom)
            path.addLine(to: rotationAnchor)
        }
        .stroke(TiyiNoteTheme.lassoBlue.opacity(0.78), lineWidth: 1)
        .allowsHitTesting(false)

        if !selectionContainsLockedElement {
            ForEach(LassoResizeHandle.allCases) { handle in
                Circle()
                    .fill(Color.white)
                    .frame(width: 9, height: 9)
                    .overlay {
                        Circle().stroke(TiyiNoteTheme.lassoBlue, lineWidth: 1.35)
                    }
                    .contentShape(Circle().inset(by: -12))
                    .position(
                        handle.position(
                            in: displayBounds,
                            rotationRadians: selection.rotationRadians
                        )
                    )
                    .gesture(resizeSelectionGesture(handle: handle, displaySize: displaySize))
                    .accessibilityLabel("调整选中内容大小")
                    .accessibilityIdentifier("lasso-resize-\(handle.rawValue)")
            }

            Circle()
                .fill(Color.white)
                .frame(width: 15, height: 15)
                .overlay {
                    Circle().stroke(TiyiNoteTheme.lassoBlue, lineWidth: 1.35)
                }
                .overlay {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(TiyiNoteTheme.lassoBlue)
                }
                .contentShape(Circle().inset(by: -15))
                .position(rotationAnchor)
                .gesture(rotationSelectionGesture(displaySize: displaySize))
                .accessibilityLabel("旋转选中内容")
                .accessibilityIdentifier("lasso-rotation-handle")
        }
    }

    private func beginInputDrag(at displayPoint: CGPoint, displaySize: CGSize) {
        if let selection, selectionContains(displayPoint, displaySize: displaySize) {
            guard !selectionContainsLockedElement else {
                showTransientFeedback("对象已锁定，请先解锁")
                return
            }
            onBeginInteraction()
            controller.cancelStrokeTransform()
            transformOriginSelection = nil
            liveLassoPath = []
            feedbackText = nil
            inputDragMode = .movingSelection
            inputDragStart = logicalPoint(for: displayPoint, in: displaySize)
            _ = beginTransformIfNeeded(for: selection)
            return
        }

        inputDragMode = .drawingLasso
        inputDragStart = nil
        beginLasso(at: displayPoint, displaySize: displaySize)
    }

    private func updateInputDrag(to displayPoint: CGPoint, displaySize: CGSize) {
        switch inputDragMode {
        case .movingSelection:
            updateFreeformSelectionMove(to: displayPoint, displaySize: displaySize)
        case .drawingLasso:
            extendLasso(to: displayPoint, displaySize: displaySize)
        case nil:
            break
        }
    }

    private func finishInputDrag(at displayPoint: CGPoint, displaySize: CGSize) {
        switch inputDragMode {
        case .movingSelection:
            updateFreeformSelectionMove(to: displayPoint, displaySize: displaySize)
            if let origin = transformOriginSelection, let moved = selection {
                let translation = CGSize(
                    width: moved.logicalBounds.midX - origin.logicalBounds.midX,
                    height: moved.logicalBounds.midY - origin.logicalBounds.midY
                )
                finishTransform(
                    CGAffineTransform(
                        translationX: translation.width,
                        y: translation.height
                    ),
                    actionName: "移动选中笔迹"
                )
            }
        case .drawingLasso:
            finishLasso(at: displayPoint, displaySize: displaySize)
        case nil:
            break
        }
        inputDragMode = nil
        inputDragStart = nil
    }

    private func updateFreeformSelectionMove(
        to displayPoint: CGPoint,
        displaySize: CGSize
    ) {
        guard
            let origin = transformOriginSelection,
            let inputDragStart
        else { return }

        let current = logicalPoint(for: displayPoint, in: displaySize)
        let translation = CGSize(
            width: current.x - inputDragStart.x,
            height: current.y - inputDragStart.y
        )
        let transform = CGAffineTransform(
            translationX: translation.width,
            y: translation.height
        )
        var movedSelection = origin
        movedSelection.logicalBounds = origin.logicalBounds.offsetBy(
            dx: translation.width,
            dy: translation.height
        )
        updateSelection(movedSelection)
        controller.previewStrokeTransform(transform)
        previewElementTransform(transform)
    }

    private func beginLasso(at displayPoint: CGPoint, displaySize: CGSize) {
        onBeginInteraction()
        controller.cancelStrokeTransform()
        transformOriginSelection = nil
        transformOriginElements = [:]
        selection = nil
        feedbackText = nil
        liveLassoPath = [logicalPoint(for: displayPoint, in: displaySize)]
    }

    private func extendLasso(to displayPoint: CGPoint, displaySize: CGSize) {
        let point = logicalPoint(for: displayPoint, in: displaySize)
        guard let previous = liveLassoPath.last else {
            liveLassoPath = [point]
            return
        }
        guard hypot(point.x - previous.x, point.y - previous.y) >= 0.65 else { return }
        liveLassoPath.append(point)
    }

    private func finishLasso(at displayPoint: CGPoint, displaySize: CGSize) {
        extendLasso(to: displayPoint, displaySize: displaySize)
        let completedPath = liveLassoPath
        liveLassoPath = []

        guard completedPath.count >= 3 else {
            selection = nil
            showTransientFeedback("未选中内容")
            return
        }

        let strokeIndices = controller.strokeIndices(inside: completedPath)
        let directlySelectedElementIDs = Set(pageElements.compactMap { element in
            polygonContains(element.logicalBounds.midPoint, polygon: completedPath)
                ? element.id
                : nil
        })
        let content = expandedContentForGroups(LassoSelectionContent(
            strokeIndices: strokeIndices,
            elementIDs: directlySelectedElementIDs
        ))
        guard !content.isEmpty else {
            selection = nil
            showTransientFeedback("未选中内容")
            return
        }

        var bounds = controller.boundsForStrokes(at: strokeIndices) ?? .null
        for element in pageElements where content.elementIDs.contains(element.id) {
            bounds = bounds.union(element.logicalBounds)
        }
        guard !bounds.isNull else { return }
        let singleElement = strokeIndices.isEmpty && content.elementIDs.count == 1
            ? pageElements.first(where: { content.elementIDs.contains($0.id) })
            : nil
        selection = LassoStrokeSelection(
            content: content,
            logicalBounds: bounds,
            rotationRadians: CGFloat(singleElement?.rotationRadians ?? 0)
        )
    }

    private func editSelectedText() {
        guard let elementID = selectedEditableTextID else { return }
        clearSelection()
        onSelectTextTool()
        onEditTextElement(elementID)
    }

    @discardableResult
    private func selectElement(at displayPoint: CGPoint, displaySize: CGSize) -> Bool {
        let logicalPoint = logicalPoint(for: displayPoint, in: displaySize)
        let matchingElements = pageElements
            .filter { elementContains(logicalPoint, element: $0) }
            .sorted { lhs, rhs in
                if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        guard let element = matchingElements.last else { return false }

        onBeginInteraction()
        controller.cancelStrokeTransform()
        let content = expandedContentForGroups(
            LassoSelectionContent(elementIDs: [element.id])
        )
        let singleElement = content.elementIDs.count == 1 ? element : nil
        selection = LassoStrokeSelection(
            content: content,
            logicalBounds: logicalBounds(
                for: content,
                fallback: element.logicalBounds
            ),
            rotationRadians: CGFloat(singleElement?.rotationRadians ?? 0)
        )
        return true
    }

    @discardableResult
    private func editTextElement(at displayPoint: CGPoint, displaySize: CGSize) -> Bool {
        let logicalPoint = logicalPoint(for: displayPoint, in: displaySize)
        let editableTextElements = pageElements
            .filter({ element in
                guard !element.isLocked, case .text = element.payload else { return false }
                return elementContains(logicalPoint, element: element)
            })
            .sorted { lhs, rhs in
                if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        guard let element = editableTextElements.last else {
            return false
        }

        onBeginInteraction()
        clearSelection()
        onSelectTextTool()
        onEditTextElement(element.id)
        return true
    }

    private func elementContains(_ point: CGPoint, element: CanvasPageElement) -> Bool {
        let radians = -CGFloat(element.rotationRadians)
        guard abs(radians) > 0.0001 else {
            return element.logicalBounds.insetBy(dx: -4, dy: -4).contains(point)
        }
        let center = element.logicalBounds.midPoint
        let cosine = cos(radians)
        let sine = sin(radians)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let unrotatedPoint = CGPoint(
            x: center.x + cosine * dx - sine * dy,
            y: center.y + sine * dx + cosine * dy
        )
        return element.logicalBounds.insetBy(dx: -4, dy: -4).contains(unrotatedPoint)
    }

    private func cropSelectedImage() {
        guard let elementID = selectedCroppableImageID else { return }
        onCropImageElement(elementID)
    }

    private func editSelectedShape() {
        guard let elementID = selectedEditableShapeID else { return }
        onEditShapeElement(elementID)
    }

    private func deleteSelection() {
        guard let selection else { return }
        guard !selectionContainsLockedElement else {
            showTransientFeedback("对象已锁定，请先解锁")
            return
        }
        if !selection.content.strokeIndices.isEmpty {
            controller.deleteStrokes(at: selection.content.strokeIndices)
        }
        if !selection.content.elementIDs.isEmpty {
            pageElements.removeAll { selection.content.elementIDs.contains($0.id) }
            onPageElementsChanged()
        }
        clearSelection()
    }

    private func duplicateSelection() {
        guard let selection else { return }
        guard !selectionContainsLockedElement else {
            showTransientFeedback("对象已锁定，请先解锁")
            return
        }
        var offset = CGSize(width: 12, height: 12)
        if !projection.isUnbounded, selection.axisAlignedBounds.maxX + offset.width > logicalPageSize.width {
            offset.width = -abs(offset.width)
        }
        if !projection.isUnbounded, selection.axisAlignedBounds.maxY + offset.height > logicalPageSize.height {
            offset.height = -abs(offset.height)
        }

        var copiedStrokeIndices: Set<Int> = []
        if !selection.content.strokeIndices.isEmpty {
            let copiedIndices = controller.duplicateStrokes(
                at: selection.content.strokeIndices,
                offset: offset,
                within: projection.isUnbounded ? nil : logicalPageSize
            )
            copiedStrokeIndices = copiedIndices
        }

        var copiedElementIDs: Set<UUID> = []
        var duplicatedGroupIDs: [UUID: UUID] = [:]
        var nextZIndex = (pageElements.map(\.zIndex).max() ?? -1) + 1
        let selectedElements = pageElements
            .filter { selection.content.elementIDs.contains($0.id) }
            .sorted {
                if $0.zIndex != $1.zIndex { return $0.zIndex < $1.zIndex }
                return $0.id.uuidString < $1.id.uuidString
            }
        let duplicatedElements = selectedElements.map { element -> CanvasPageElement in
            let duplicateGroupID = element.groupID.map { originalGroupID in
                if let existing = duplicatedGroupIDs[originalGroupID] { return existing }
                let generated = UUID()
                duplicatedGroupIDs[originalGroupID] = generated
                return generated
            }
            let duplicate = CanvasPageElement(
                id: UUID(),
                logicalBounds: element.logicalBounds.offsetBy(
                    dx: offset.width,
                    dy: offset.height
                ),
                rotationRadians: element.rotationRadians,
                zIndex: nextZIndex,
                isLocked: element.isLocked,
                groupID: duplicateGroupID,
                payload: element.payload
            )
            nextZIndex += 1
            copiedElementIDs.insert(duplicate.id)
            return duplicate
        }
        if !duplicatedElements.isEmpty {
            pageElements.append(contentsOf: duplicatedElements)
            onPageElementsChanged()
        }
        guard !copiedStrokeIndices.isEmpty || !copiedElementIDs.isEmpty else { return }
        self.selection = LassoStrokeSelection(
            content: LassoSelectionContent(
                strokeIndices: copiedStrokeIndices,
                elementIDs: copiedElementIDs
            ),
            logicalBounds: selection.logicalBounds.offsetBy(
                dx: offset.width,
                dy: offset.height
            ),
            rotationRadians: selection.rotationRadians
        )
        showTransientFeedback("已复制一份")
    }

    private func toggleSelectionLock() {
        guard let selection, !selection.content.elementIDs.isEmpty else { return }
        let shouldLock = !selectionContainsLockedElement
        var changed = false
        for index in pageElements.indices
        where selection.content.elementIDs.contains(pageElements[index].id) {
            guard pageElements[index].isLocked != shouldLock else { continue }
            pageElements[index].isLocked = shouldLock
            changed = true
        }
        guard changed else { return }
        onPageElementsChanged()
        showTransientFeedback(shouldLock ? "已锁定对象" : "已解锁对象")
    }

    private func bringSelectionToFront() {
        guard let selection,
              !selectionContainsLockedElement,
              !selection.content.elementIDs.isEmpty else { return }
        let selected = selectedElementIndices(in: selection)
        var nextZIndex = (pageElements.map(\.zIndex).max() ?? -1) + 1
        for index in selected {
            pageElements[index].zIndex = nextZIndex
            nextZIndex += 1
        }
        onPageElementsChanged()
        showTransientFeedback("已移到最前")
    }

    private func sendSelectionToBack() {
        guard let selection,
              !selectionContainsLockedElement,
              !selection.content.elementIDs.isEmpty else { return }
        let selected = selectedElementIndices(in: selection)
        var nextZIndex = (pageElements.map(\.zIndex).min() ?? 0) - selected.count
        for index in selected {
            pageElements[index].zIndex = nextZIndex
            nextZIndex += 1
        }
        onPageElementsChanged()
        showTransientFeedback("已移到最后")
    }

    private func groupSelection() {
        guard let selection, canGroupSelection else { return }
        let groupID = UUID()
        var changed = false
        for index in pageElements.indices
        where selection.content.elementIDs.contains(pageElements[index].id) {
            pageElements[index].groupID = groupID
            changed = true
        }
        guard changed else { return }
        onPageElementsChanged()
        showTransientFeedback("已组合对象")
    }

    private func ungroupSelection() {
        guard let selection, canUngroupSelection else { return }
        var changed = false
        for index in pageElements.indices
        where selection.content.elementIDs.contains(pageElements[index].id) {
            guard pageElements[index].groupID != nil else { continue }
            pageElements[index].groupID = nil
            changed = true
        }
        guard changed else { return }
        onPageElementsChanged()
        showTransientFeedback("已取消组合")
    }

    private func selectedElementIndices(
        in selection: LassoStrokeSelection
    ) -> [Array<CanvasPageElement>.Index] {
        pageElements.indices
            .filter { selection.content.elementIDs.contains(pageElements[$0].id) }
            .sorted {
                let lhs = pageElements[$0]
                let rhs = pageElements[$1]
                if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    private func expandedContentForGroups(
        _ content: LassoSelectionContent
    ) -> LassoSelectionContent {
        let selectedGroups = Set(pageElements.compactMap { element -> UUID? in
            content.elementIDs.contains(element.id) ? element.groupID : nil
        })
        guard !selectedGroups.isEmpty else { return content }
        var expanded = content
        expanded.elementIDs.formUnion(pageElements.compactMap { element in
            element.groupID.map(selectedGroups.contains) == true ? element.id : nil
        })
        return expanded
    }

    private func logicalBounds(
        for content: LassoSelectionContent,
        fallback: CGRect
    ) -> CGRect {
        var bounds = controller.boundsForStrokes(at: content.strokeIndices) ?? .null
        for element in pageElements where content.elementIDs.contains(element.id) {
            bounds = bounds.union(element.logicalBounds)
        }
        return bounds.isNull ? fallback : bounds
    }

    private func copySelectionToPasteboard() {
        guard let selection else { return }
        if selection.content.elementIDs.isEmpty,
           !selection.content.strokeIndices.isEmpty {
            let normalizedDrawing = controller.drawingForStrokes(
                at: selection.content.strokeIndices,
                normalized: true
            )
            TiyiAnnotationPasteboard.copy(normalizedDrawing)
        } else if selection.content.strokeIndices.isEmpty,
                  selection.content.elementIDs.count == 1,
                  let element = pageElements.first(where: {
                      selection.content.elementIDs.contains($0.id)
                  }),
                  case .image(let payload) = element.payload,
                  let image = UIImage(data: payload.pngData) {
            TiyiAnnotationPasteboard.copy(
                image,
                logicalSize: element.logicalBounds.size
            )
        } else {
            copySelectionSnapshot(selection)
        }
        showTransientFeedback("已拷贝，长按页面可粘贴")
    }

    private func screenshotSelection() {
        guard let selection else { return }
        copySelectionSnapshot(selection)
        showTransientFeedback("截图已拷贝，长按页面可粘贴")
    }

    private func copySelectionSnapshot(_ selection: LassoStrokeSelection) {
        guard let page,
              let snapshot = LassoSnapshotRenderer.render(
                  page: page,
                  drawing: controller.drawing,
                  pageElements: pageElements,
                  cropRect: selection.axisAlignedBounds.insetBy(dx: -4, dy: -4),
                  logicalPageSize: logicalPageSize,
                  canvasBackground: canvasBackground
              ) else { return }
        TiyiAnnotationPasteboard.copy(snapshot.image, logicalSize: snapshot.logicalSize)
    }

    private func dismissSelectionIfNeeded(at displayPoint: CGPoint, displaySize: CGSize) {
        guard let selection else { return }
        let selectionBounds = displayRect(for: selection.axisAlignedBounds, in: displaySize)
            .insetBy(dx: -8, dy: -8)
        guard !selectionBounds.contains(displayPoint) else { return }
        clearSelection()
    }

    private func clearSelection() {
        controller.cancelStrokeTransform()
        liveLassoPath = []
        selection = nil
        transformOriginSelection = nil
        transformOriginElements = [:]
        inputDragMode = nil
        inputDragStart = nil
        feedbackText = nil
    }

    private func moveSelectionGesture(displaySize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(LassoCoordinateSpace.page))
            .onChanged { value in
                guard let selection else { return }
                guard !selectionContainsLockedElement else { return }
                let origin = beginTransformIfNeeded(for: selection)
                let translation = logicalTranslation(value.translation, displaySize: displaySize)
                let transform = CGAffineTransform(
                    translationX: translation.width,
                    y: translation.height
                )
                var movedSelection = origin
                movedSelection.logicalBounds = origin.logicalBounds.offsetBy(
                    dx: translation.width,
                    dy: translation.height
                )
                updateSelection(movedSelection)
                controller.previewStrokeTransform(transform)
                previewElementTransform(transform)
            }
            .onEnded { value in
                guard let selection else { return }
                guard !selectionContainsLockedElement else { return }
                let origin = transformOriginSelection ?? selection
                let translation = logicalTranslation(value.translation, displaySize: displaySize)
                let transform = CGAffineTransform(
                    translationX: translation.width,
                    y: translation.height
                )
                var movedSelection = origin
                movedSelection.logicalBounds = origin.logicalBounds.offsetBy(
                    dx: translation.width,
                    dy: translation.height
                )
                updateSelection(movedSelection)
                previewElementTransform(transform)
                finishTransform(transform, actionName: "移动选中笔迹")
            }
    }

    private func resizeSelectionGesture(
        handle: LassoResizeHandle,
        displaySize: CGSize
    ) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(LassoCoordinateSpace.page))
            .onChanged { value in
                guard let selection else { return }
                guard !selectionContainsLockedElement else { return }
                let origin = beginTransformIfNeeded(for: selection)
                let translation = logicalTranslation(value.translation, displaySize: displaySize)
                let resizedSelection = resizedSelection(
                    origin,
                    handle: handle,
                    translation: translation
                )
                let transform = resizingTransform(from: origin, to: resizedSelection)
                updateSelection(resizedSelection)
                controller.previewStrokeTransform(transform)
                previewElementTransform(transform)
            }
            .onEnded { value in
                guard let selection else { return }
                guard !selectionContainsLockedElement else { return }
                let origin = transformOriginSelection ?? selection
                let translation = logicalTranslation(value.translation, displaySize: displaySize)
                let resizedSelection = resizedSelection(
                    origin,
                    handle: handle,
                    translation: translation
                )
                let transform = resizingTransform(from: origin, to: resizedSelection)
                updateSelection(resizedSelection)
                previewElementTransform(transform)
                finishTransform(transform, actionName: "缩放选中笔迹")
            }
    }

    private func rotationSelectionGesture(displaySize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(LassoCoordinateSpace.page))
            .onChanged { value in
                guard let selection else { return }
                guard !selectionContainsLockedElement else { return }
                let origin = beginTransformIfNeeded(for: selection)
                let delta = rotationDelta(
                    from: value.startLocation,
                    to: value.location,
                    around: displayPoint(for: origin.logicalBounds.midPoint, in: displaySize)
                )
                var rotatedSelection = origin
                rotatedSelection.rotationRadians = normalizedAngle(
                    origin.rotationRadians + delta
                )
                updateSelection(rotatedSelection)
                controller.previewStrokeTransform(
                    rotationTransform(delta, around: origin.logicalBounds.midPoint)
                )
                previewElementTransform(
                    rotationTransform(delta, around: origin.logicalBounds.midPoint)
                )
            }
            .onEnded { value in
                guard let selection else { return }
                guard !selectionContainsLockedElement else { return }
                let origin = transformOriginSelection ?? selection
                let delta = rotationDelta(
                    from: value.startLocation,
                    to: value.location,
                    around: displayPoint(for: origin.logicalBounds.midPoint, in: displaySize)
                )
                var rotatedSelection = origin
                rotatedSelection.rotationRadians = normalizedAngle(
                    origin.rotationRadians + delta
                )
                updateSelection(rotatedSelection)
                previewElementTransform(
                    rotationTransform(delta, around: origin.logicalBounds.midPoint)
                )
                finishTransform(
                    rotationTransform(delta, around: origin.logicalBounds.midPoint),
                    actionName: "旋转选中笔迹"
                )
            }
    }

    private func beginTransformIfNeeded(
        for selection: LassoStrokeSelection
    ) -> LassoStrokeSelection {
        if let transformOriginSelection {
            return transformOriginSelection
        }
        transformOriginSelection = selection
        if !selection.content.strokeIndices.isEmpty {
            controller.beginTransformingStrokes(at: selection.content.strokeIndices)
        }
        transformOriginElements = Dictionary(uniqueKeysWithValues: pageElements.compactMap {
            selection.content.elementIDs.contains($0.id) ? ($0.id, $0) : nil
        })
        return selection
    }

    private func previewElementTransform(_ transform: CGAffineTransform) {
        guard !transformOriginElements.isEmpty else { return }
        for (elementID, origin) in transformOriginElements {
            guard let index = pageElements.firstIndex(where: { $0.id == elementID }) else { continue }
            let center = origin.logicalBounds.midPoint
            let radians = CGFloat(origin.rotationRadians)
            let horizontalPoint = CGPoint(
                x: center.x + cos(radians) * origin.logicalBounds.width / 2,
                y: center.y + sin(radians) * origin.logicalBounds.width / 2
            )
            let verticalPoint = CGPoint(
                x: center.x - sin(radians) * origin.logicalBounds.height / 2,
                y: center.y + cos(radians) * origin.logicalBounds.height / 2
            )
            let transformedCenter = center.applying(transform)
            let transformedHorizontal = horizontalPoint.applying(transform)
            let transformedVertical = verticalPoint.applying(transform)
            let horizontalVector = CGPoint(
                x: transformedHorizontal.x - transformedCenter.x,
                y: transformedHorizontal.y - transformedCenter.y
            )
            let verticalVector = CGPoint(
                x: transformedVertical.x - transformedCenter.x,
                y: transformedVertical.y - transformedCenter.y
            )
            let width = max(8, hypot(horizontalVector.x, horizontalVector.y) * 2)
            let height = max(8, hypot(verticalVector.x, verticalVector.y) * 2)
            pageElements[index].logicalBounds = CGRect(
                x: transformedCenter.x - width / 2,
                y: transformedCenter.y - height / 2,
                width: width,
                height: height
            )
            pageElements[index].rotationRadians = Double(
                atan2(horizontalVector.y, horizontalVector.x)
            )
        }
    }

    private func finishTransform(_ transform: CGAffineTransform, actionName: String) {
        if let transformOriginSelection {
            if !transformOriginSelection.content.strokeIndices.isEmpty {
                controller.commitStrokeTransform(transform, actionName: actionName)
            }
            if !transformOriginSelection.content.elementIDs.isEmpty {
                onPageElementsChanged()
            }
        }
        transformOriginSelection = nil
        transformOriginElements = [:]
    }

    private func updateSelection(_ selection: LassoStrokeSelection) {
        self.selection = selection
    }

    private func resizedSelection(
        _ selection: LassoStrokeSelection,
        handle: LassoResizeHandle,
        translation: CGSize
    ) -> LassoStrokeSelection {
        let minimumSize = max(8, projection.logicalBounds.width * 0.018)
        let cosine = cos(selection.rotationRadians)
        let sine = sin(selection.rotationRadians)
        let localTranslation = CGSize(
            width: cosine * translation.width + sine * translation.height,
            height: -sine * translation.width + cosine * translation.height
        )
        let width = max(
            minimumSize,
            selection.logicalBounds.width + handle.horizontalSign * localTranslation.width
        )
        let height = max(
            minimumSize,
            selection.logicalBounds.height + handle.verticalSign * localTranslation.height
        )
        let localCenterShift = CGPoint(
            x: handle.horizontalSign * (width - selection.logicalBounds.width) / 2,
            y: handle.verticalSign * (height - selection.logicalBounds.height) / 2
        )
        let worldCenterShift = CGPoint(
            x: cosine * localCenterShift.x - sine * localCenterShift.y,
            y: sine * localCenterShift.x + cosine * localCenterShift.y
        )
        let oldCenter = selection.logicalBounds.midPoint
        var resizedSelection = selection
        resizedSelection.logicalBounds = CGRect(
            x: oldCenter.x + worldCenterShift.x - width / 2,
            y: oldCenter.y + worldCenterShift.y - height / 2,
            width: width,
            height: height
        )
        return resizedSelection
    }

    private func resizingTransform(
        from source: LassoStrokeSelection,
        to destination: LassoStrokeSelection
    ) -> CGAffineTransform {
        guard source.logicalBounds.width > 0, source.logicalBounds.height > 0 else {
            return .identity
        }
        let scaleX = destination.logicalBounds.width / source.logicalBounds.width
        let scaleY = destination.logicalBounds.height / source.logicalBounds.height
        let cosine = cos(source.rotationRadians)
        let sine = sin(source.rotationRadians)
        let a = cosine * cosine * scaleX + sine * sine * scaleY
        let b = cosine * sine * (scaleX - scaleY)
        let c = b
        let d = sine * sine * scaleX + cosine * cosine * scaleY
        let sourceCenter = source.logicalBounds.midPoint
        let destinationCenter = destination.logicalBounds.midPoint
        return CGAffineTransform(
            a: a,
            b: b,
            c: c,
            d: d,
            tx: destinationCenter.x - a * sourceCenter.x - c * sourceCenter.y,
            ty: destinationCenter.y - b * sourceCenter.x - d * sourceCenter.y
        )
    }

    private func rotationTransform(_ radians: CGFloat, around center: CGPoint) -> CGAffineTransform {
        let cosine = cos(radians)
        let sine = sin(radians)
        return CGAffineTransform(
            a: cosine,
            b: sine,
            c: -sine,
            d: cosine,
            tx: center.x - cosine * center.x + sine * center.y,
            ty: center.y - sine * center.x - cosine * center.y
        )
    }

    private func rotationDelta(from start: CGPoint, to end: CGPoint, around center: CGPoint) -> CGFloat {
        normalizedAngle(
            atan2(end.y - center.y, end.x - center.x)
                - atan2(start.y - center.y, start.x - center.x)
        )
    }

    private func normalizedAngle(_ radians: CGFloat) -> CGFloat {
        var value = radians
        while value > .pi { value -= 2 * .pi }
        while value < -.pi { value += 2 * .pi }
        return value
    }

    private func polygonContains(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var isInside = false
        var previousIndex = polygon.count - 1
        for index in polygon.indices {
            let current = polygon[index]
            let previous = polygon[previousIndex]
            if (current.y > point.y) != (previous.y > point.y) {
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

    private func selectionContains(_ displayPoint: CGPoint, displaySize: CGSize) -> Bool {
        guard let selection else { return false }
        let point = logicalPoint(for: displayPoint, in: displaySize)

        let center = selection.logicalBounds.midPoint
        let cosine = cos(-selection.rotationRadians)
        let sine = sin(-selection.rotationRadians)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let localPoint = CGPoint(
            x: center.x + cosine * dx - sine * dy,
            y: center.y + sine * dx + cosine * dy
        )
        let hitSlop = max(3, projection.logicalBounds.width * 0.006)
        return selection.logicalBounds.insetBy(dx: -hitSlop, dy: -hitSlop)
            .contains(localPoint)
    }

    private func rotationHandlePosition(
        for selection: LassoStrokeSelection,
        in displaySize: CGSize
    ) -> CGPoint {
        let bounds = displayRect(for: selection.logicalBounds, in: displaySize)
        return rotatedDisplayPoint(
            CGPoint(x: bounds.midX, y: bounds.maxY + 20),
            around: bounds.midPoint,
            radians: selection.rotationRadians
        )
    }

    private func rotatedDisplayPoint(
        _ point: CGPoint,
        around center: CGPoint,
        radians: CGFloat
    ) -> CGPoint {
        let cosine = cos(radians)
        let sine = sin(radians)
        let dx = point.x - center.x
        let dy = point.y - center.y
        return CGPoint(
            x: center.x + cosine * dx - sine * dy,
            y: center.y + sine * dx + cosine * dy
        )
    }

    private func toolbarPosition(
        for selection: LassoStrokeSelection,
        in displaySize: CGSize
    ) -> CGPoint {
        let bounds = displayRect(for: selection.axisAlignedBounds, in: displaySize)
        let halfToolbarWidth: CGFloat = selectedEditableTextID != nil
            || selectedCroppableImageID != nil
            || selectedEditableShapeID != nil
            ? 150
            : 128
        let x = min(
            max(bounds.midX, halfToolbarWidth + 8),
            displaySize.width - halfToolbarWidth - 8
        )
        let toolbarHalfHeight: CGFloat = 22
        let gap: CGFloat = 8
        let y: CGFloat
        if bounds.minY >= toolbarHalfHeight * 2 + gap * 2 {
            y = bounds.minY - toolbarHalfHeight - gap
        } else if displaySize.height - bounds.maxY >= toolbarHalfHeight * 2 + gap * 2 {
            y = bounds.maxY + toolbarHalfHeight + gap
        } else {
            y = min(
                max(bounds.midY, toolbarHalfHeight + gap),
                displaySize.height - toolbarHalfHeight - gap
            )
        }
        return CGPoint(x: x, y: y)
    }

    private func feedbackPosition(
        for selection: LassoStrokeSelection,
        in displaySize: CGSize
    ) -> CGPoint {
        let toolbar = toolbarPosition(for: selection, in: displaySize)
        return CGPoint(x: toolbar.x, y: max(18, toolbar.y - 42))
    }

    private func showTransientFeedback(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) {
            feedbackText = text
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard feedbackText == text else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                feedbackText = nil
            }
        }
    }

    private func logicalPoint(for displayPoint: CGPoint, in displaySize: CGSize) -> CGPoint {
        projection.logicalPoint(displayPoint, displaySize: displaySize)
    }

    private func displayPoint(for logicalPoint: CGPoint, in displaySize: CGSize) -> CGPoint {
        projection.displayPoint(logicalPoint, displaySize: displaySize)
    }

    private func displayRect(for logicalRect: CGRect, in displaySize: CGSize) -> CGRect {
        projection.displayRect(logicalRect, displaySize: displaySize)
    }

    private func logicalTranslation(_ translation: CGSize, displaySize: CGSize) -> CGSize {
        projection.logicalTranslation(translation, displaySize: displaySize)
    }
}

private struct LassoStrokeSelection {
    let content: LassoSelectionContent
    var logicalBounds: CGRect
    var rotationRadians: CGFloat

    var axisAlignedBounds: CGRect {
        guard abs(rotationRadians) > 0.0001 else { return logicalBounds }
        let center = logicalBounds.midPoint
        let cosine = cos(rotationRadians)
        let sine = sin(rotationRadians)
        let corners = [
            logicalBounds.origin,
            CGPoint(x: logicalBounds.maxX, y: logicalBounds.minY),
            CGPoint(x: logicalBounds.minX, y: logicalBounds.maxY),
            CGPoint(x: logicalBounds.maxX, y: logicalBounds.maxY)
        ].map { point in
            let dx = point.x - center.x
            let dy = point.y - center.y
            return CGPoint(
                x: center.x + cosine * dx - sine * dy,
                y: center.y + sine * dx + cosine * dy
            )
        }
        let minX = corners.map { $0.x }.min() ?? logicalBounds.minX
        let maxX = corners.map { $0.x }.max() ?? logicalBounds.maxX
        let minY = corners.map { $0.y }.min() ?? logicalBounds.minY
        let maxY = corners.map { $0.y }.max() ?? logicalBounds.maxY
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

private enum LassoInputDragMode {
    case drawingLasso
    case movingSelection
}

private enum LassoCoordinateSpace {
    static let page = "tiyi.lasso.page"
}

private enum LassoResizeHandle: String, CaseIterable, Identifiable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    var horizontalSign: CGFloat {
        switch self {
        case .topLeft, .bottomLeft: -1
        case .topRight, .bottomRight: 1
        }
    }

    var verticalSign: CGFloat {
        switch self {
        case .topLeft, .topRight: -1
        case .bottomLeft, .bottomRight: 1
        }
    }

    func position(in rect: CGRect, rotationRadians: CGFloat) -> CGPoint {
        let point = CGPoint(
            x: horizontalSign < 0 ? rect.minX : rect.maxX,
            y: verticalSign < 0 ? rect.minY : rect.maxY
        )
        let center = rect.midPoint
        let cosine = cos(rotationRadians)
        let sine = sin(rotationRadians)
        let dx = point.x - center.x
        let dy = point.y - center.y
        return CGPoint(
            x: center.x + cosine * dx - sine * dy,
            y: center.y + sine * dx + cosine * dy
        )
    }
}

private struct LassoActionBar: View {
    let canEditText: Bool
    let canCropImage: Bool
    let canEditShape: Bool
    let canModifySelection: Bool
    let hasSelectedElements: Bool
    let canGroup: Bool
    let canUngroup: Bool
    let isLocked: Bool
    let onEditText: () -> Void
    let onCropImage: () -> Void
    let onEditShape: () -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void
    let onCopy: () -> Void
    let onScreenshot: () -> Void
    let onToggleLock: () -> Void
    let onBringToFront: () -> Void
    let onSendToBack: () -> Void
    let onGroup: () -> Void
    let onUngroup: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            if canEditText {
                actionButton(
                    title: "编辑",
                    symbol: "pencil",
                    tint: TiyiNoteTheme.textPrimary,
                    action: onEditText
                )
            }
            if canCropImage {
                actionButton(
                    title: "裁剪",
                    symbol: "crop",
                    tint: TiyiNoteTheme.textPrimary,
                    action: onCropImage
                )
            }
            if canEditShape {
                actionButton(
                    title: "样式",
                    symbol: "paintpalette",
                    tint: TiyiNoteTheme.textPrimary,
                    action: onEditShape
                )
            }
            actionButton(
                title: "删除",
                symbol: "trash",
                tint: canModifySelection ? TiyiNoteTheme.danger : TiyiNoteTheme.textTertiary,
                isEnabled: canModifySelection,
                action: onDelete
            )
            actionButton(
                title: "复制",
                symbol: "doc.on.doc",
                tint: canModifySelection ? TiyiNoteTheme.textPrimary : TiyiNoteTheme.textTertiary,
                isEnabled: canModifySelection,
                action: onDuplicate
            )
            actionButton(
                title: "拷贝",
                symbol: "doc.on.clipboard",
                tint: TiyiNoteTheme.textPrimary,
                action: onCopy
            )
            actionButton(
                title: "截图",
                symbol: "camera.viewfinder",
                tint: TiyiNoteTheme.textPrimary,
                action: onScreenshot
            )
            if hasSelectedElements {
                Menu {
                    Button(action: onToggleLock) {
                        Label(isLocked ? "解锁" : "锁定", systemImage: isLocked ? "lock.open" : "lock")
                    }
                    Button(action: onBringToFront) {
                        Label("移到最前", systemImage: "square.3.layers.3d.top.filled")
                    }
                    .disabled(!canModifySelection)
                    Button(action: onSendToBack) {
                        Label("移到最后", systemImage: "square.3.layers.3d.bottom.filled")
                    }
                    .disabled(!canModifySelection)
                    Divider()
                    Button(action: onGroup) {
                        Label("组合", systemImage: "square.3.layers.3d")
                    }
                    .disabled(!canGroup)
                    Button(action: onUngroup) {
                        Label("取消组合", systemImage: "square.2.layers.3d")
                    }
                    .disabled(!canUngroup)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isLocked ? "lock.fill" : "ellipsis.circle")
                            .font(.system(size: 12, weight: .semibold))
                        Text("对象")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(TiyiNoteTheme.textPrimary)
                    .padding(.horizontal, 9)
                    .frame(height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("对象操作")
            }
        }
        .padding(4)
        .background(
            TiyiNoteTheme.chrome.opacity(0.97),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(TiyiNoteTheme.strongHairline, lineWidth: 1)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("对象操作栏")
                .accessibilityIdentifier("selection-action-bar")
        }
        .shadow(color: Color.black.opacity(0.28), radius: 7, y: 3)
    }

    private func actionButton(
        title: String,
        symbol: String,
        tint: Color,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }
}

private struct LassoInputView: UIViewRepresentable {
    let shouldBeginDrag: (CGPoint, UITouch.TouchType) -> Bool
    let onBegan: (CGPoint) -> Void
    let onMoved: (CGPoint) -> Void
    let onEnded: (CGPoint) -> Void
    let onTap: (CGPoint) -> Void
    let onDoubleTap: (CGPoint) -> Void
    let onFingerLongPress: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = LassoInputContainerView(frame: .zero)
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true

        let lassoGesture = LassoPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLassoGesture(_:))
        )
        lassoGesture.minimumNumberOfTouches = 1
        lassoGesture.maximumNumberOfTouches = 1
        lassoGesture.cancelsTouchesInView = true
        lassoGesture.delegate = context.coordinator
#if targetEnvironment(simulator)
        lassoGesture.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]
#else
        lassoGesture.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue)
        ]
#endif

        let longPressGesture = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPressGesture.minimumPressDuration = 0.52
        longPressGesture.allowableMovement = 12
        longPressGesture.cancelsTouchesInView = false
        longPressGesture.delegate = context.coordinator
#if targetEnvironment(simulator)
        longPressGesture.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]
#else
        longPressGesture.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
#endif

        let doubleTapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTapGesture.numberOfTapsRequired = 2
        doubleTapGesture.cancelsTouchesInView = false
        doubleTapGesture.delegate = context.coordinator
        doubleTapGesture.require(toFail: longPressGesture)
        doubleTapGesture.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]

        let tapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = context.coordinator
        tapGesture.require(toFail: longPressGesture)
        tapGesture.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]
        tapGesture.require(toFail: doubleTapGesture)

        view.addGestureRecognizer(lassoGesture)
        view.lassoGestureRecognizer = lassoGesture
        view.addGestureRecognizer(longPressGesture)
        view.addGestureRecognizer(doubleTapGesture)
        view.addGestureRecognizer(tapGesture)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: LassoInputView

        init(parent: LassoInputView) {
            self.parent = parent
        }

        @objc func handleLassoGesture(_ gesture: UIPanGestureRecognizer) {
            let location = gesture.location(in: gesture.view)
            switch gesture.state {
            case .began:
                parent.onBegan(location)
            case .changed:
                parent.onMoved(location)
            case .ended, .cancelled, .failed:
                parent.onEnded(location)
            default:
                break
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            parent.onTap(gesture.location(in: gesture.view))
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            parent.onDoubleTap(gesture.location(in: gesture.view))
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began else { return }
            parent.onFingerLongPress(gesture.location(in: gesture.view))
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            otherGestureRecognizer is UIPinchGestureRecognizer
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let panGesture = gestureRecognizer as? LassoPanGestureRecognizer else {
                return true
            }
            return parent.shouldBeginDrag(
                panGesture.location(in: panGesture.view),
                panGesture.initialTouchType
            )
        }
    }
}

private final class LassoInputContainerView: UIView {
    weak var lassoGestureRecognizer: UIGestureRecognizer?
    private weak var coordinatedScrollView: UIScrollView?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil,
              coordinatedScrollView == nil,
              let lassoGestureRecognizer else { return }

        var ancestor = superview
        var scrollView: UIScrollView?
        while let view = ancestor {
            if let candidate = view as? UIScrollView {
                scrollView = candidate
                break
            }
            ancestor = view.superview
        }
        guard let scrollView else { return }

        // The page lives inside a two-axis ScrollView. Without an explicit
        // failure relationship its pan recognizer wins Simulator/XCTest drags
        // before the page lasso has a chance to inspect the input type.
        scrollView.panGestureRecognizer.require(toFail: lassoGestureRecognizer)
        coordinatedScrollView = scrollView
    }
}

private final class LassoPanGestureRecognizer: UIPanGestureRecognizer {
    private(set) var initialTouchType: UITouch.TouchType = .direct

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let firstTouch = touches.first {
            initialTouchType = firstTouch.type
        }
        super.touchesBegan(touches, with: event)
    }
}

private struct PagePasteMenu: View {
    let canPaste: Bool
    let onPaste: () -> Void

    var body: some View {
        Button(action: onPaste) {
            HStack(spacing: 7) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 13, weight: .semibold))
                Text("粘贴")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(canPaste ? TiyiNoteTheme.textPrimary : TiyiNoteTheme.textTertiary)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(TiyiNoteTheme.chrome.opacity(0.98), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(TiyiNoteTheme.strongHairline, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.42), radius: 9, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(!canPaste)
        .accessibilityLabel("粘贴最近拷贝的内容")
    }
}

private enum TiyiCopiedAnnotationContent {
    case drawing(PKDrawing)
    case image(UIImage, logicalSize: CGSize)
}

private struct TiyiClipboardImageArchive: Codable {
    let pngData: Data
    let logicalWidth: Double
    let logicalHeight: Double
}

private enum TiyiAnnotationPasteboard {
    static let drawingType = "com.tiyi.note.pkdrawing"
    static let imageType = "com.tiyi.note.annotation-image"

    static var copiedContent: TiyiCopiedAnnotationContent? {
        if
            let data = UIPasteboard.general.data(forPasteboardType: drawingType),
            let drawing = try? PKDrawing(data: data)
        {
            return .drawing(drawing)
        }
        if
            let data = UIPasteboard.general.data(forPasteboardType: imageType),
            let archive = try? JSONDecoder().decode(TiyiClipboardImageArchive.self, from: data),
            let image = UIImage(data: archive.pngData)
        {
            return .image(
                image,
                logicalSize: CGSize(
                    width: CGFloat(archive.logicalWidth),
                    height: CGFloat(archive.logicalHeight)
                )
            )
        }
        return nil
    }

    static func copy(_ drawing: PKDrawing) {
        guard !drawing.strokes.isEmpty else { return }
        var item: [String: Any] = [drawingType: drawing.dataRepresentation()]
        let bounds = drawing.bounds.insetBy(dx: -2, dy: -2)
        let image = drawing.image(from: bounds, scale: 2)
        if let pngData = image.pngData() {
            item[UTType.png.identifier] = pngData
        }
        UIPasteboard.general.setItems([item])
    }

    static func copy(_ image: UIImage, logicalSize: CGSize) {
        guard let pngData = image.pngData() else { return }
        let archive = TiyiClipboardImageArchive(
            pngData: pngData,
            logicalWidth: Double(logicalSize.width),
            logicalHeight: Double(logicalSize.height)
        )
        guard let archiveData = try? JSONEncoder().encode(archive) else { return }
        UIPasteboard.general.setItems([[
            imageType: archiveData,
            UTType.png.identifier: pngData
        ]])
    }
}

private struct LassoSnapshot {
    let image: UIImage
    let logicalSize: CGSize
}

private enum LassoSnapshotRenderer {
    static func render(
        page: PDFPage,
        drawing: PKDrawing,
        pageElements: [CanvasPageElement],
        cropRect: CGRect,
        logicalPageSize: CGSize,
        canvasBackground: LibraryPage? = nil
    ) -> LassoSnapshot? {
        let pageRect = CGRect(origin: .zero, size: logicalPageSize)
        let cropRect = (canvasBackground == nil ? cropRect.intersection(pageRect) : cropRect).integral
        guard !cropRect.isNull, cropRect.width > 1, cropRect.height > 1 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = canvasBackground == nil ? 2 : min(2, 4096 / max(cropRect.width, cropRect.height))
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: cropRect.size, format: format)
        let image = renderer.image { rendererContext in
            UIColor.white.setFill()
            rendererContext.fill(CGRect(origin: .zero, size: cropRect.size))

            let context = rendererContext.cgContext
            if let canvasBackground {
                context.saveGState()
                context.translateBy(x: -cropRect.minX, y: -cropRect.minY)
                CanvasBackgroundRenderer.draw(
                    in: context,
                    bounds: cropRect,
                    style: canvasBackground.backgroundStyle ?? .blank,
                    color: canvasBackground.backgroundColor ?? .white
                )
                context.restoreGState()
            }
            let pageBounds = page.bounds(for: .mediaBox)
            let pageScale = min(
                logicalPageSize.width / max(pageBounds.width, 1),
                logicalPageSize.height / max(pageBounds.height, 1)
            )
            let renderedSize = CGSize(
                width: pageBounds.width * pageScale,
                height: pageBounds.height * pageScale
            )
            let pageOrigin = CGPoint(
                x: (logicalPageSize.width - renderedSize.width) / 2,
                y: (logicalPageSize.height - renderedSize.height) / 2
            )

            context.saveGState()
            context.translateBy(x: -cropRect.minX, y: -cropRect.minY)
            context.translateBy(x: pageOrigin.x, y: pageOrigin.y + renderedSize.height)
            context.scaleBy(x: pageScale, y: -pageScale)
            context.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
            if canvasBackground == nil || canvasBackground?.sourceKind == .pdf {
                page.draw(with: .mediaBox, to: context)
            }
            context.restoreGState()

            for element in pageElements.sorted(by: {
                if $0.zIndex != $1.zIndex { return $0.zIndex < $1.zIndex }
                return $0.id.uuidString < $1.id.uuidString
            }) where element.logicalBounds.intersects(cropRect) {
                context.saveGState()
                context.translateBy(
                    x: element.logicalBounds.midX - cropRect.minX,
                    y: element.logicalBounds.midY - cropRect.minY
                )
                context.rotate(by: CGFloat(element.rotationRadians))
                draw(element, in: context)
                context.restoreGState()
            }

            let annotationImage = drawing.image(from: cropRect, scale: format.scale)
            annotationImage.draw(in: CGRect(origin: .zero, size: cropRect.size))
        }
        return LassoSnapshot(image: image, logicalSize: cropRect.size)
    }

    private static func draw(_ element: CanvasPageElement, in context: CGContext) {
        let rect = CGRect(
            x: -element.logicalBounds.width / 2,
            y: -element.logicalBounds.height / 2,
            width: element.logicalBounds.width,
            height: element.logicalBounds.height
        )
        switch element.payload {
        case .image(let payload):
            guard let image = UIImage(data: payload.pngData) else { return }
            image.draw(in: rect, blendMode: .normal, alpha: payload.opacity)
        case .text(let payload):
            let paragraph = NSMutableParagraphStyle()
            switch payload.alignment {
            case .leading: paragraph.alignment = .left
            case .center: paragraph.alignment = .center
            case .trailing: paragraph.alignment = .right
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: PageTextFontPreset(storedName: payload.fontName).uiFont(
                    size: CGFloat(payload.fontSize),
                    isBold: payload.isBold,
                    isItalic: payload.isItalic
                ),
                .foregroundColor: UIColor.tiyiColor(payload.colorHex),
                .paragraphStyle: paragraph
            ]
            if payload.isUnderlined {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            NSString(string: payload.text).draw(
                with: rect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil
            )
        case .shape(let payload):
            drawShape(payload, in: rect, context: context)
        }
    }

    private static func drawShape(
        _ payload: PageShapePayload,
        in rect: CGRect,
        context: CGContext
    ) {
        context.setStrokeColor(UIColor.tiyiColor(payload.strokeColorHex).cgColor)
        context.setLineWidth(CGFloat(payload.lineWidth))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineDash(
            phase: 0,
            lengths: payload.isDashed ? [7, 5] : []
        )
        if let fillHex = payload.fillColorHex {
            context.setFillColor(UIColor.tiyiColor(fillHex).cgColor)
        } else {
            context.setFillColor(UIColor.clear.cgColor)
        }

        switch payload.kind {
        case .line, .arrow:
            context.move(to: CGPoint(x: rect.minX, y: rect.midY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            if payload.kind == .arrow {
                let head = min(rect.height * 0.35, rect.width * 0.18, 18)
                context.move(to: CGPoint(x: rect.maxX, y: rect.midY))
                context.addLine(to: CGPoint(x: rect.maxX - head, y: rect.midY - head * 0.72))
                context.move(to: CGPoint(x: rect.maxX, y: rect.midY))
                context.addLine(to: CGPoint(x: rect.maxX - head, y: rect.midY + head * 0.72))
            }
            context.strokePath()
        case .rectangle:
            context.addRect(rect.insetBy(dx: payload.lineWidth / 2, dy: payload.lineWidth / 2))
            context.drawPath(using: payload.fillColorHex == nil ? .stroke : .fillStroke)
        case .ellipse:
            context.addEllipse(in: rect.insetBy(dx: payload.lineWidth / 2, dy: payload.lineWidth / 2))
            context.drawPath(using: payload.fillColorHex == nil ? .stroke : .fillStroke)
        case .triangle:
            context.move(to: CGPoint(x: rect.midX, y: rect.minY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            context.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            context.closePath()
            context.drawPath(using: payload.fillColorHex == nil ? .stroke : .fillStroke)
        case .diamond:
            context.move(to: CGPoint(x: rect.midX, y: rect.minY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            context.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            context.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            context.closePath()
            context.drawPath(using: payload.fillColorHex == nil ? .stroke : .fillStroke)
        }
    }
}

private struct PageThumbnailSidebar: View {
    @ObservedObject var documentStore: DrawingDocumentStore
    let documentID: String
    let currentPageIndex: Int
    let onSelectPage: (Int) -> Void
    let onClose: () -> Void

    @State private var filter: PageSidebarFilter = .all
    @State private var isSelecting = false
    @State private var selectedPageIDs: Set<String> = []
    @State private var draggingPageID: String?
    @State private var pendingDeletionPageIDs: Set<String> = []
    @State private var showsDeleteConfirmation = false
    @State private var errorMessage: String?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var orderedPages: [LibraryPage] {
        documentStore.pages(in: documentID)
    }

    private var deletedPages: [LibraryPage] {
        documentStore.deletedPages(in: documentID)
    }

    private var visiblePages: [LibraryPage] {
        switch filter {
        case .all: orderedPages
        case .bookmarked: orderedPages.filter(\.isBookmarked)
        case .deleted: deletedPages
        }
    }

    private var currentPageID: String? {
        guard orderedPages.indices.contains(currentPageIndex) else { return orderedPages.first?.id }
        return orderedPages[currentPageIndex].id
    }

    private var actionPageIDs: Set<String> {
        if isSelecting, !selectedPageIDs.isEmpty { return selectedPageIDs }
        return currentPageID.map { [$0] } ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("页面")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(TiyiNoteTheme.textPrimary)
                Spacer()

                Menu {
                    Button("空白页", systemImage: "doc") {
                        insertPage(style: .blank)
                    }
                    Button("横线纸", systemImage: "line.3.horizontal") {
                        insertPage(style: .ruled)
                    }
                    Button("方格纸", systemImage: "square.grid.3x3") {
                        insertPage(style: .grid)
                    }
                    Button("点阵纸", systemImage: "circle.grid.3x3") {
                        insertPage(style: .dotted)
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TiyiNoteTheme.selectionForeground)
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("新建页面")
                .accessibilityIdentifier("page-add-menu")

                Button(isSelecting ? "完成" : "选择") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isSelecting.toggle()
                        if !isSelecting { selectedPageIDs.removeAll() }
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(TiyiNoteTheme.selectionForeground)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TiyiNoteTheme.textSecondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭页面缩略图")
            }
            .padding(.horizontal, 16)
            .frame(height: 54)

            HStack(spacing: 8) {
                ForEach(PageSidebarFilter.allCases) { item in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            filter = item
                        }
                    } label: {
                        Label(item.title, systemImage: item.symbolName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(
                                filter == item
                                    ? TiyiNoteTheme.selectionForeground
                                    : TiyiNoteTheme.textSecondary
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                filter == item
                                    ? TiyiNoteTheme.selectionBackground
                                    : Color.clear,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("page-filter-\(item.rawValue)")
                    .accessibilityValue(filter == item ? "selected" : "not-selected")
                    .accessibilityAddTraits(filter == item ? .isSelected : [])
                }
            }
            .padding(4)
            .background(TiyiNoteTheme.surface, in: Capsule())
            .overlay {
                Capsule().stroke(TiyiNoteTheme.hairline, lineWidth: 1)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            ScrollView(.vertical, showsIndicators: true) {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(visiblePages) { page in
                        let pageIndex = orderedPages.firstIndex(where: { $0.id == page.id })
                            ?? page.orderIndex
                        PageThumbnailCard(
                            image: filter == .deleted
                                ? documentStore.thumbnail(
                                    forDeletedPage: page,
                                    size: CGSize(width: 220, height: 310)
                                )
                                : nil,
                            pdfPage: filter == .deleted
                                ? nil
                                : documentStore.page(at: pageIndex, in: documentID),
                            drawingActivitySource: documentStore,
                            pageIndex: pageIndex,
                            isCurrent: filter != .deleted && pageIndex == currentPageIndex,
                            isSelected: selectedPageIDs.contains(page.id),
                            isBookmarked: page.isBookmarked,
                            rotation: page.rotation,
                            backgroundStyle: page.backgroundStyle,
                            isSelecting: isSelecting
                        ) {
                            select(page, at: pageIndex)
                        }
                        .onDrag {
                            draggingPageID = page.id
                            return NSItemProvider(object: page.id as NSString)
                        }
                        .onDrop(
                            of: [UTType.text],
                            delegate: PageReorderDropDelegate(
                                draggingPageID: $draggingPageID,
                                destinationPageID: page.id,
                                onMove: movePage
                            )
                        )
                        .contextMenu {
                            if filter == .deleted {
                                Button("恢复页面", systemImage: "arrow.uturn.backward") {
                                    restorePages([page.id])
                                }
                            } else {
                                Button("复制页面", systemImage: "plus.square.on.square") {
                                    duplicatePage(page.id)
                                }
                                Button("顺时针旋转", systemImage: "rotate.right") {
                                    rotatePages([page.id], clockwise: true)
                                }
                                Button(
                                    page.isBookmarked ? "取消书签" : "添加书签",
                                    systemImage: page.isBookmarked ? "bookmark.slash" : "bookmark"
                                ) {
                                    setBookmark([page.id], isBookmarked: !page.isBookmarked)
                                }
                                Divider()
                                Button("删除页面", systemImage: "trash", role: .destructive) {
                                    requestDelete([page.id])
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 24)
            }

            if isSelecting {
                selectionActionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: 292)
        .background(TiyiNoteTheme.sidebar)
        .confirmationDialog(
            "删除 \(pendingDeletionPageIDs.count) 页？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive, action: deletePendingPages)
                .accessibilityIdentifier("page-confirm-delete")
            Button("取消", role: .cancel) {}
        } message: {
            Text("页面会进入本页回收站，并通过协作历史同步；可稍后恢复。")
        }
        .alert("页面操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
        .onChange(of: (orderedPages + deletedPages).map(\.id)) { _, pageIDs in
            selectedPageIDs.formIntersection(pageIDs)
        }
        .onChange(of: filter) { _, _ in
            selectedPageIDs.removeAll()
            isSelecting = false
        }
    }

    private var selectionActionBar: some View {
        HStack(spacing: 4) {
            if filter == .deleted {
                pageActionButton("恢复", symbol: "arrow.uturn.backward") {
                    restorePages(selectedPageIDs)
                }
                .disabled(selectedPageIDs.isEmpty)
            } else {
                pageActionButton("复制", symbol: "plus.square.on.square") {
                    guard let pageID = selectedPageIDs.first else { return }
                    duplicatePage(pageID)
                }
                .disabled(selectedPageIDs.count != 1)

                pageActionButton("旋转", symbol: "rotate.right") {
                    rotatePages(selectedPageIDs, clockwise: true)
                }
                .disabled(selectedPageIDs.isEmpty)

                pageActionButton("书签", symbol: "bookmark") {
                    let shouldBookmark = orderedPages
                        .filter { selectedPageIDs.contains($0.id) }
                        .contains { !$0.isBookmarked }
                    setBookmark(selectedPageIDs, isBookmarked: shouldBookmark)
                }
                .disabled(selectedPageIDs.isEmpty)

                pageActionButton("删除", symbol: "trash", role: .destructive) {
                    requestDelete(selectedPageIDs)
                }
                .disabled(selectedPageIDs.isEmpty)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .background(TiyiNoteTheme.chrome)
        .overlay(alignment: .top) {
            Rectangle().fill(TiyiNoteTheme.hairline).frame(height: 1)
        }
    }

    private func pageActionButton(
        _ title: String,
        symbol: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(role == .destructive ? Color.red : TiyiNoteTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("page-action-\(title)")
    }

    private func select(_ page: LibraryPage, at pageIndex: Int) {
        if isSelecting || filter == .deleted {
            if filter == .deleted { isSelecting = true }
            if !selectedPageIDs.insert(page.id).inserted {
                selectedPageIDs.remove(page.id)
            }
        } else {
            onSelectPage(pageIndex)
        }
    }

    private func insertPage(style: CanvasBackgroundStyle) {
        do {
            let page = try documentStore.insertTemplatePage(
                after: currentPageID,
                in: documentID,
                style: style,
                color: .white
            )
            navigate(to: page.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func duplicatePage(_ pageID: String) {
        do {
            let page = try documentStore.duplicatePage(pageID, in: documentID)
            selectedPageIDs = [page.id]
            navigate(to: page.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rotatePages(_ pageIDs: Set<String>, clockwise: Bool) {
        do {
            for pageID in orderedPages.map(\.id) where pageIDs.contains(pageID) {
                try documentStore.rotatePage(pageID, clockwise: clockwise, in: documentID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setBookmark(_ pageIDs: Set<String>, isBookmarked: Bool) {
        do {
            for pageID in pageIDs {
                try documentStore.setPageBookmark(
                    pageID,
                    isBookmarked: isBookmarked,
                    in: documentID
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func requestDelete(_ pageIDs: Set<String>) {
        guard !pageIDs.isEmpty else { return }
        guard pageIDs.count < orderedPages.count else {
            errorMessage = "文稿至少需要保留一页。"
            return
        }
        pendingDeletionPageIDs = pageIDs
        showsDeleteConfirmation = true
    }

    private func deletePendingPages() {
        do {
            let oldCurrentID = currentPageID
            try documentStore.deletePages(pendingDeletionPageIDs, in: documentID)
            selectedPageIDs.subtract(pendingDeletionPageIDs)
            pendingDeletionPageIDs.removeAll()
            let remaining = documentStore.pages(in: documentID)
            if let oldCurrentID,
               let newIndex = remaining.firstIndex(where: { $0.id == oldCurrentID }) {
                onSelectPage(newIndex)
            } else if !remaining.isEmpty {
                onSelectPage(min(currentPageIndex, remaining.count - 1))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restorePages(_ pageIDs: Set<String>) {
        do {
            try documentStore.restoreDeletedPages(pageIDs, in: documentID)
            selectedPageIDs.subtract(pageIDs)
            if documentStore.deletedPages(in: documentID).isEmpty {
                filter = .all
                isSelecting = false
            }
            if let restoredID = pageIDs.sorted().first {
                navigate(to: restoredID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func movePage(_ sourcePageID: String, _ destinationPageID: String) -> Bool {
        guard sourcePageID != destinationPageID,
              let destinationIndex = orderedPages.firstIndex(where: {
                  $0.id == destinationPageID
              }) else { return false }
        do {
            try documentStore.movePage(sourcePageID, to: destinationIndex, in: documentID)
            navigate(to: sourcePageID)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func navigate(to pageID: String) {
        guard let index = documentStore.pageIndex(for: pageID, in: documentID) else { return }
        onSelectPage(index)
    }
}

private enum PageSidebarFilter: String, CaseIterable, Identifiable {
    case all
    case bookmarked
    case deleted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .bookmarked: "书签"
        case .deleted: "回收站"
        }
    }

    var symbolName: String {
        switch self {
        case .all: "square.grid.2x2"
        case .bookmarked: "bookmark"
        case .deleted: "trash"
        }
    }
}

private struct PageReorderDropDelegate: DropDelegate {
    @Binding var draggingPageID: String?
    let destinationPageID: String
    let onMove: (String, String) -> Bool

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let sourcePageID = draggingPageID else { return false }
        defer { draggingPageID = nil }
        return onMove(sourcePageID, destinationPageID)
    }

    func dropExited(info: DropInfo) {}
}

private struct PageThumbnailCard: View {
    let image: UIImage?
    let pdfPage: PDFPage?
    let drawingActivitySource: DrawingDocumentStore?
    let pageIndex: Int
    let isCurrent: Bool
    let isSelected: Bool
    let isBookmarked: Bool
    let rotation: Int
    let backgroundStyle: CanvasBackgroundStyle?
    let isSelecting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                    } else if let pdfPage {
                        // Live page thumbnails share the background raster cache with the main
                        // page. PDFKit no longer blocks MainActor while the sidebar is visible.
                        PDFPageView(
                            page: pdfPage,
                            queuePriority: .low,
                            drawingActivitySource: drawingActivitySource,
                            allowsInitialRenderDuringHandwriting: false
                        )
                    } else {
                        Rectangle()
                            .fill(TiyiNoteTheme.surfaceRaised)
                            .overlay {
                                Image(systemName: "doc")
                                    .foregroundStyle(TiyiNoteTheme.textTertiary)
                            }
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(0.70, contentMode: .fit)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(
                            isCurrent || isSelected
                                ? TiyiNoteTheme.selectionBorder
                                : TiyiNoteTheme.hairline,
                            lineWidth: isCurrent || isSelected ? 3 : 1
                        )
                }
                .overlay(alignment: .topTrailing) {
                    if isBookmarked {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TiyiNoteTheme.selectionBlue)
                            .padding(6)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(
                                isSelected
                                    ? TiyiNoteTheme.selectionBlue
                                    : TiyiNoteTheme.textSecondary
                            )
                            .background(Color.white, in: Circle())
                            .padding(6)
                    }
                }

                Text("\(pageIndex + 1)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(
                        isCurrent || isSelected
                            ? TiyiNoteTheme.selectionForeground
                            : TiyiNoteTheme.textSecondary
                    )
            }
            .padding(6)
            .background(
                isCurrent || isSelected ? TiyiNoteTheme.selectionBackground : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isCurrent || isSelected ? TiyiNoteTheme.selectionBorder : Color.clear,
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("第 \(pageIndex + 1) 页")
        .accessibilityIdentifier("page-thumbnail-\(pageIndex)")
        .accessibilityValue(
            [
                isCurrent ? "current" : nil,
                isSelected ? "selected" : nil,
                isBookmarked ? "bookmarked" : nil,
                backgroundStyle.map { "template-\($0.rawValue)" },
                "rotation-\(rotation)"
            ]
            .compactMap { $0 }
            .joined(separator: ",")
        )
        .accessibilityAddTraits(isCurrent || isSelected ? .isSelected : [])
    }
}

private struct PageOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

private extension CGRect {
    var midPoint: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
