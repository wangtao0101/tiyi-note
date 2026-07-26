import PDFKit
import PencilKit
import SwiftUI
import UniformTypeIdentifiers

struct PDFDocumentReaderView: View {
    @ObservedObject var documentStore: DrawingDocumentStore
    let documentID: String
    @Binding var showsThumbnails: Bool

    let selectedTool: CanvasToolKind
    let selectedColor: InkPaletteColor
    let penWidth: Double
    let markerWidth: Double
    let eraserSize: CanvasEraserSize
    let onSelectLassoTool: () -> Void
    let onActiveCanvasChanged: (CanvasController, Int) -> Void

    @State private var currentPageIndex: Int
    @State private var requestedPageIndex: Int?
    @State private var visibleControllers: [Int: CanvasController] = [:]
    @State private var zoomScale: CGFloat = 1
    @GestureState private var pinchMagnification: CGFloat = 1

    private let minimumZoomScale: CGFloat = 0.65
    private let maximumZoomScale: CGFloat = 3

    init(
        documentStore: DrawingDocumentStore,
        documentID: String,
        showsThumbnails: Binding<Bool>,
        selectedTool: CanvasToolKind,
        selectedColor: InkPaletteColor,
        penWidth: Double,
        markerWidth: Double,
        eraserSize: CanvasEraserSize,
        initialPageIndex: Int,
        onSelectLassoTool: @escaping () -> Void,
        onActiveCanvasChanged: @escaping (CanvasController, Int) -> Void
    ) {
        self.documentStore = documentStore
        self.documentID = documentID
        _showsThumbnails = showsThumbnails
        self.selectedTool = selectedTool
        self.selectedColor = selectedColor
        self.penWidth = penWidth
        self.markerWidth = markerWidth
        self.eraserSize = eraserSize
        self.onSelectLassoTool = onSelectLassoTool
        self.onActiveCanvasChanged = onActiveCanvasChanged
        _currentPageIndex = State(initialValue: initialPageIndex)
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
        .background(TiyiNoteTheme.workspace)
    }

    private var pagesScrollView: some View {
        GeometryReader { geometry in
            let basePageWidth = min(max(geometry.size.width - 40, 280), 900)
            let effectiveZoomScale = clampedZoomScale(zoomScale * pinchMagnification)
            let pageWidth = basePageWidth * effectiveZoomScale
            let contentWidth = max(pageWidth + 40, geometry.size.width)

            ScrollViewReader { scrollProxy in
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    LazyVStack(spacing: 14) {
                        ForEach(0..<documentStore.pageCount(for: documentID), id: \.self) { pageIndex in
                            let logicalSize = documentStore.pageSize(at: pageIndex, in: documentID)
                            let pageHeight = pageWidth * logicalSize.height / max(logicalSize.width, 1)

                            PDFPageAnnotationView(
                                documentStore: documentStore,
                                documentID: documentID,
                                pageIndex: pageIndex,
                                logicalPageSize: logicalSize,
                                selectedTool: selectedTool,
                                selectedColor: selectedColor,
                                penWidth: penWidth,
                                markerWidth: markerWidth,
                                eraserSize: eraserSize,
                                onSelectLassoTool: onSelectLassoTool,
                                onReady: registerController,
                                onRelease: unregisterController
                            )
                            .frame(width: pageWidth, height: pageHeight)
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
                            .id(pageIndex)
                        }
                    }
                    .frame(width: contentWidth)
                    .padding(.vertical, 16)
                }
                .coordinateSpace(name: "pdfVerticalScroll")
                .simultaneousGesture(pinchToZoomGesture)
                .onPreferenceChange(PageOffsetPreferenceKey.self, perform: updateCurrentPage)
                .onAppear {
                    let initialPage = currentPageIndex
                    DispatchQueue.main.async {
                        scrollProxy.scrollTo(initialPage, anchor: .top)
                    }
                }
                .onChange(of: requestedPageIndex) { _, pageIndex in
                    guard let pageIndex else { return }
                    withAnimation(.easeInOut(duration: 0.28)) {
                        scrollProxy.scrollTo(pageIndex, anchor: .top)
                    }
                    DispatchQueue.main.async {
                        requestedPageIndex = nil
                    }
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
                        .accessibilityLabel("当前缩放 \(Int((effectiveZoomScale * 100).rounded()))%，点击恢复适页")

                        HStack(spacing: 6) {
                            Circle()
                                .fill(TiyiNoteTheme.selectionBlue)
                                .frame(width: 5, height: 5)
                            Text("\(currentPageIndex + 1) / \(documentStore.pageCount(for: documentID))")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .monospacedDigit()
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
                }
            }
        }
    }

    private var pinchToZoomGesture: some Gesture {
        MagnificationGesture(minimumScaleDelta: 0.01)
            .updating($pinchMagnification) { value, state, _ in
                state = value
            }
            .onEnded { value in
                zoomScale = clampedZoomScale(zoomScale * value)
            }
    }

    private func clampedZoomScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minimumZoomScale), maximumZoomScale)
    }

    private func resetZoom() {
        withAnimation(.easeInOut(duration: 0.22)) {
            zoomScale = 1
        }
    }

    private func requestPage(_ pageIndex: Int) {
        currentPageIndex = pageIndex
        documentStore.setLastViewedPage(pageIndex, for: documentID)
        requestedPageIndex = pageIndex
        if let controller = visibleControllers[pageIndex] {
            onActiveCanvasChanged(controller, pageIndex)
        }
    }

    private func updateCurrentPage(_ offsets: [Int: CGFloat]) {
        guard let closestPage = offsets.min(by: {
            abs($0.value - 16) < abs($1.value - 16)
        })?.key else { return }

        if closestPage != currentPageIndex {
            currentPageIndex = closestPage
            documentStore.setLastViewedPage(closestPage, for: documentID)
        }
        if let controller = visibleControllers[closestPage] {
            onActiveCanvasChanged(controller, closestPage)
        }
    }

    private func registerController(_ controller: CanvasController, for pageIndex: Int) {
        visibleControllers[pageIndex] = controller
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

private struct PDFPageAnnotationView: View {
    @ObservedObject var documentStore: DrawingDocumentStore
    let documentID: String
    let pageIndex: Int
    let logicalPageSize: CGSize
    let selectedTool: CanvasToolKind
    let selectedColor: InkPaletteColor
    let penWidth: Double
    let markerWidth: Double
    let eraserSize: CanvasEraserSize
    let onSelectLassoTool: () -> Void
    let onReady: (CanvasController, Int) -> Void
    let onRelease: (CanvasController, Int) -> Void

    @StateObject private var controller = CanvasController()
    @State private var hasLoadedDrawing = false
    @State private var imageAnnotations: [CanvasImageAnnotation] = []
    @State private var requestedSelection: LassoSelectionRequest?
    @State private var pasteMenuLocation: CGPoint?
    @State private var pasteFeedback: String?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                PDFPageView(page: documentStore.page(at: pageIndex, in: documentID))

                ForEach(imageAnnotations) { annotation in
                    let bounds = displayRect(for: annotation.logicalBounds, in: geometry.size)
                    Image(uiImage: annotation.image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: bounds.width, height: bounds.height)
                        .rotationEffect(.radians(Double(annotation.rotationRadians)))
                        .position(x: bounds.midX, y: bounds.midY)
                        .allowsHitTesting(false)
                }

                PencilCanvasView(
                    controller: controller,
                    logicalPageSize: logicalPageSize,
                    onFingerLongPress: { point in
                        presentPasteMenu(at: point)
                    }
                )
                .accessibilityLabel("第 \(pageIndex + 1) 页批注画布")

                LassoSelectionOverlay(
                    controller: controller,
                    page: documentStore.page(at: pageIndex, in: documentID),
                    logicalPageSize: logicalPageSize,
                    isActive: selectedTool == .lasso,
                    imageAnnotations: $imageAnnotations,
                    requestedSelection: $requestedSelection,
                    onBeginInteraction: {
                        dismissPasteMenu()
                        onReady(controller, pageIndex)
                    },
                    onFingerLongPress: { point in
                        presentPasteMenu(at: point)
                    },
                    onImageAnnotationsChanged: {
                        documentStore.scheduleSave(
                            imageAnnotations,
                            forPage: pageIndex,
                            in: documentID
                        )
                    }
                )

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
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(TiyiNoteTheme.strongHairline, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: Color.black.opacity(0.58), radius: 16, y: 7)
        .onAppear(perform: preparePageCanvas)
        .onDisappear(perform: releasePageCanvas)
        .onChange(of: selectedTool) { _, _ in applySelectedTool() }
        .onChange(of: selectedColor) { _, _ in applySelectedTool() }
        .onChange(of: penWidth) { _, _ in applySelectedTool() }
        .onChange(of: markerWidth) { _, _ in applySelectedTool() }
        .onChange(of: eraserSize) { _, _ in applySelectedTool() }
    }

    private func preparePageCanvas() {
        if !hasLoadedDrawing {
            controller.installInitialDrawing(
                documentStore.loadDrawing(forPage: pageIndex, in: documentID)
            )
            imageAnnotations = documentStore.loadImageAnnotations(
                forPage: pageIndex,
                in: documentID
            )
            hasLoadedDrawing = true
        }

        controller.onDrawingChanged = { [weak documentStore] drawing in
            documentStore?.scheduleSave(
                drawing,
                forPage: pageIndex,
                in: documentID
            )
        }
        controller.onBecameActive = { [weak controller] in
            guard let controller else { return }
            onReady(controller, pageIndex)
        }
        controller.configureAnnotationInput()
        applySelectedTool()
        onReady(controller, pageIndex)
    }

    private func releasePageCanvas() {
        documentStore.flush(controller.drawing, forPage: pageIndex, in: documentID)
        documentStore.flush(imageAnnotations, forPage: pageIndex, in: documentID)
        controller.onDrawingChanged = nil
        controller.onBecameActive = nil
        onRelease(controller, pageIndex)
    }

    private func applySelectedTool() {
        let width = selectedTool == .marker ? markerWidth : penWidth
        controller.updateTool(
            kind: selectedTool,
            color: selectedColor,
            width: width,
            eraserSize: eraserSize
        )
    }

    private func presentPasteMenu(at point: CGPoint) {
        onReady(controller, pageIndex)
        pasteFeedback = nil
        pasteMenuLocation = point
    }

    private func dismissPasteMenu() {
        pasteMenuLocation = nil
    }

    private func pasteCopiedContent(at displayPoint: CGPoint, in displaySize: CGSize) {
        guard let copiedContent = TiyiAnnotationPasteboard.copiedContent else { return }
        let logicalPoint = CGPoint(
            x: displayPoint.x / max(displaySize.width, 1) * logicalPageSize.width,
            y: displayPoint.y / max(displaySize.height, 1) * logicalPageSize.height
        )
        pasteMenuLocation = nil
        switch copiedContent {
        case .drawing(let drawing):
            let insertedIndices = controller.pasteDrawing(
                drawing,
                centeredAt: logicalPoint,
                within: logicalPageSize
            )
            guard
                !insertedIndices.isEmpty,
                let bounds = controller.boundsForStrokes(at: insertedIndices)
            else { return }
            requestedSelection = LassoSelectionRequest(
                content: .strokes(insertedIndices),
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
            let origin = CGPoint(
                x: min(max(logicalPoint.x - size.width / 2, 0), max(0, logicalPageSize.width - size.width)),
                y: min(max(logicalPoint.y - size.height / 2, 0), max(0, logicalPageSize.height - size.height))
            )
            let annotation = CanvasImageAnnotation(
                id: UUID(),
                image: image,
                logicalBounds: CGRect(origin: origin, size: size),
                rotationRadians: 0
            )
            imageAnnotations.append(annotation)
            documentStore.scheduleSave(
                imageAnnotations,
                forPage: pageIndex,
                in: documentID
            )
            requestedSelection = LassoSelectionRequest(
                content: .image(annotation.id),
                logicalBounds: annotation.logicalBounds
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
        CGRect(
            x: logicalRect.minX / max(logicalPageSize.width, 1) * displaySize.width,
            y: logicalRect.minY / max(logicalPageSize.height, 1) * displaySize.height,
            width: logicalRect.width / max(logicalPageSize.width, 1) * displaySize.width,
            height: logicalRect.height / max(logicalPageSize.height, 1) * displaySize.height
        )
    }
}

private enum LassoSelectionContent {
    case strokes(Set<Int>)
    case image(UUID)
}

private struct LassoSelectionRequest: Identifiable {
    let id = UUID()
    let content: LassoSelectionContent
    let logicalBounds: CGRect
}

private struct LassoSelectionOverlay: View {
    @ObservedObject var controller: CanvasController
    let page: PDFPage?
    let logicalPageSize: CGSize
    let isActive: Bool
    @Binding var imageAnnotations: [CanvasImageAnnotation]
    @Binding var requestedSelection: LassoSelectionRequest?
    let onBeginInteraction: () -> Void
    let onFingerLongPress: (CGPoint) -> Void
    let onImageAnnotationsChanged: () -> Void

    @State private var liveLassoPath: [CGPoint] = []
    @State private var selection: LassoStrokeSelection?
    @State private var transformOriginSelection: LassoStrokeSelection?
    @State private var inputDragMode: LassoInputDragMode?
    @State private var inputDragStart: CGPoint?
    @State private var feedbackText: String?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if isActive {
                    LassoInputView(
                        shouldBeginDrag: { point, touchType in
                            touchType != .direct
                                || selectionContains(point, displaySize: geometry.size)
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
                            dismissSelectionIfNeeded(at: point, displaySize: geometry.size)
                        },
                        onFingerLongPress: onFingerLongPress
                    )

                    lassoOutline(in: geometry.size)

                    if let selection, selection.presentation == .box {
                        selectionBox(for: selection, in: geometry.size)
                    }

                    if let selection {
                        LassoActionBar(
                            isShowingBox: selection.presentation == .box,
                            onShowBox: showSelectionBox,
                            onDelete: deleteSelection,
                            onDuplicate: duplicateSelection,
                            onCopy: copySelectionToPasteboard,
                            onScreenshot: screenshotSelection
                        )
                        .position(toolbarPosition(for: selection, in: geometry.size))
                    }

                    if let feedbackText, let selection {
                        Text(feedbackText)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TiyiNoteTheme.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(TiyiNoteTheme.chrome.opacity(0.96), in: Capsule())
                            .overlay {
                                Capsule().stroke(TiyiNoteTheme.hairline, lineWidth: 1)
                            }
                            .position(feedbackPosition(for: selection, in: geometry.size))
                            .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    }
                }
            }
            .coordinateSpace(name: LassoCoordinateSpace.page)
        }
        .allowsHitTesting(isActive)
        .onChange(of: isActive) { _, active in
            if !active {
                clearSelection()
            }
        }
        .onChange(of: requestedSelection?.id) { _, _ in
            guard let request = requestedSelection else { return }
            onBeginInteraction()
            selection = LassoStrokeSelection(
                content: request.content,
                logicalBounds: request.logicalBounds,
                lassoPath: [],
                presentation: .box,
                rotationRadians: 0
            )
            requestedSelection = nil
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
        if !liveLassoPath.isEmpty {
            return liveLassoPath
        }
        if selection?.presentation == .freeform {
            return selection?.lassoPath ?? []
        }
        return []
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
            .fill(TiyiNoteTheme.lassoBlue.opacity(0.035))
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

        Path { path in
            path.move(to: boxBottom)
            path.addLine(to: rotationAnchor)
        }
        .stroke(TiyiNoteTheme.lassoBlue.opacity(0.78), lineWidth: 1)
        .allowsHitTesting(false)

        ForEach(LassoResizeHandle.allCases) { handle in
            Circle()
                .fill(Color.white)
                .frame(width: 11, height: 11)
                .overlay {
                    Circle().stroke(TiyiNoteTheme.lassoBlue, lineWidth: 1.5)
                }
                .contentShape(Circle().inset(by: -10))
                .position(
                    handle.position(
                        in: displayBounds,
                        rotationRadians: selection.rotationRadians
                    )
                )
                .gesture(resizeSelectionGesture(handle: handle, displaySize: displaySize))
        }

        Circle()
            .fill(Color.white.opacity(0.96))
            .frame(width: 23, height: 23)
            .overlay {
                Circle().stroke(TiyiNoteTheme.lassoBlue, lineWidth: 1.25)
            }
            .overlay {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(TiyiNoteTheme.lassoBlue)
            }
            .contentShape(Circle().inset(by: -11))
            .position(rotationAnchor)
            .gesture(rotationSelectionGesture(displaySize: displaySize))
            .accessibilityLabel("旋转选中内容")
    }

    private func beginInputDrag(at displayPoint: CGPoint, displaySize: CGSize) {
        if let selection, selectionContains(displayPoint, displaySize: displaySize) {
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
        movedSelection.lassoPath = origin.lassoPath.map {
            CGPoint(
                x: $0.x + translation.width,
                y: $0.y + translation.height
            )
        }
        updateSelection(movedSelection)
        controller.previewStrokeTransform(transform)
    }

    private func beginLasso(at displayPoint: CGPoint, displaySize: CGSize) {
        onBeginInteraction()
        controller.cancelStrokeTransform()
        transformOriginSelection = nil
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
            return
        }

        let strokeIndices = controller.strokeIndices(inside: completedPath)
        if
            !strokeIndices.isEmpty,
            let bounds = controller.boundsForStrokes(at: strokeIndices)
        {
            selection = LassoStrokeSelection(
                content: .strokes(strokeIndices),
                logicalBounds: bounds,
                lassoPath: completedPath,
                presentation: .freeform,
                rotationRadians: 0
            )
            return
        }

        if let imageAnnotation = imageAnnotations.reversed().first(where: {
            polygonContains($0.logicalBounds.midPoint, polygon: completedPath)
        }) {
            selection = LassoStrokeSelection(
                content: .image(imageAnnotation.id),
                logicalBounds: imageAnnotation.logicalBounds,
                lassoPath: completedPath,
                presentation: .freeform,
                rotationRadians: imageAnnotation.rotationRadians
            )
            return
        }

        selection = nil
        showTransientFeedback("未选中内容")
    }

    private func showSelectionBox() {
        guard var selection else { return }
        selection.presentation = .box
        self.selection = selection
    }

    private func deleteSelection() {
        guard let selection else { return }
        switch selection.content {
        case .strokes(let indices):
            controller.deleteStrokes(at: indices)
        case .image(let imageID):
            imageAnnotations.removeAll { $0.id == imageID }
            onImageAnnotationsChanged()
        }
        clearSelection()
    }

    private func duplicateSelection() {
        guard let selection else { return }
        let offset = CGSize(width: 12, height: 12)
        switch selection.content {
        case .strokes(let indices):
            guard let originalBounds = controller.boundsForStrokes(at: indices) else { return }
            let copiedIndices = controller.duplicateStrokes(
                at: indices,
                offset: offset,
                within: logicalPageSize
            )
            guard
                !copiedIndices.isEmpty,
                let copiedBounds = controller.boundsForStrokes(at: copiedIndices)
            else { return }
            let dx = copiedBounds.minX - originalBounds.minX
            let dy = copiedBounds.minY - originalBounds.minY
            self.selection = LassoStrokeSelection(
                content: .strokes(copiedIndices),
                logicalBounds: selection.logicalBounds.offsetBy(dx: dx, dy: dy),
                lassoPath: selection.lassoPath.map {
                    CGPoint(x: $0.x + dx, y: $0.y + dy)
                },
                presentation: .box,
                rotationRadians: selection.rotationRadians
            )
        case .image(let imageID):
            guard let source = imageAnnotations.first(where: { $0.id == imageID }) else { return }
            let duplicate = CanvasImageAnnotation(
                id: UUID(),
                image: source.image,
                logicalBounds: source.logicalBounds.offsetBy(
                    dx: offset.width,
                    dy: offset.height
                ),
                rotationRadians: source.rotationRadians
            )
            imageAnnotations.append(duplicate)
            onImageAnnotationsChanged()
            self.selection = LassoStrokeSelection(
                content: .image(duplicate.id),
                logicalBounds: duplicate.logicalBounds,
                lassoPath: [],
                presentation: .box,
                rotationRadians: duplicate.rotationRadians
            )
        }
        showTransientFeedback("已复制一份")
    }

    private func copySelectionToPasteboard() {
        guard let selection else { return }
        switch selection.content {
        case .strokes(let indices):
            guard controller.boundsForStrokes(at: indices) != nil else { return }
            let normalizedDrawing = controller.drawingForStrokes(
                at: indices,
                normalized: true
            )
            TiyiAnnotationPasteboard.copy(normalizedDrawing)
        case .image(let imageID):
            guard let annotation = imageAnnotations.first(where: { $0.id == imageID }) else { return }
            TiyiAnnotationPasteboard.copy(
                annotation.image,
                logicalSize: annotation.logicalBounds.size
            )
        }
        showTransientFeedback("已拷贝，长按页面可粘贴")
    }

    private func screenshotSelection() {
        guard
            let selection,
            let page,
            let snapshot = LassoSnapshotRenderer.render(
                page: page,
                drawing: controller.drawing,
                imageAnnotations: imageAnnotations,
                cropRect: selection.axisAlignedBounds.insetBy(dx: -4, dy: -4),
                logicalPageSize: logicalPageSize
            )
        else { return }
        TiyiAnnotationPasteboard.copy(snapshot.image, logicalSize: snapshot.logicalSize)
        showTransientFeedback("截图已拷贝，长按页面可粘贴")
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
        inputDragMode = nil
        inputDragStart = nil
        feedbackText = nil
    }

    private func moveSelectionGesture(displaySize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(LassoCoordinateSpace.page))
            .onChanged { value in
                guard let selection else { return }
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
            }
            .onEnded { value in
                guard let selection else { return }
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
            }
            .onEnded { value in
                guard let selection else { return }
                let origin = transformOriginSelection ?? selection
                let translation = logicalTranslation(value.translation, displaySize: displaySize)
                let resizedSelection = resizedSelection(
                    origin,
                    handle: handle,
                    translation: translation
                )
                let transform = resizingTransform(from: origin, to: resizedSelection)
                updateSelection(resizedSelection)
                finishTransform(transform, actionName: "缩放选中笔迹")
            }
    }

    private func rotationSelectionGesture(displaySize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(LassoCoordinateSpace.page))
            .onChanged { value in
                guard let selection else { return }
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
            }
            .onEnded { value in
                guard let selection else { return }
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
        if case .strokes(let indices) = selection.content {
            controller.beginTransformingStrokes(at: indices)
        }
        return selection
    }

    private func finishTransform(_ transform: CGAffineTransform, actionName: String) {
        if let transformOriginSelection {
            switch transformOriginSelection.content {
            case .strokes:
                controller.commitStrokeTransform(transform, actionName: actionName)
            case .image:
                onImageAnnotationsChanged()
            }
        }
        transformOriginSelection = nil
    }

    private func updateSelection(_ selection: LassoStrokeSelection) {
        self.selection = selection
        guard case .image(let imageID) = selection.content else { return }
        guard let index = imageAnnotations.firstIndex(where: { $0.id == imageID }) else { return }
        imageAnnotations[index].logicalBounds = selection.logicalBounds
        imageAnnotations[index].rotationRadians = selection.rotationRadians
    }

    private func resizedSelection(
        _ selection: LassoStrokeSelection,
        handle: LassoResizeHandle,
        translation: CGSize
    ) -> LassoStrokeSelection {
        let minimumSize = max(8, logicalPageSize.width * 0.018)
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

        if selection.presentation == .freeform, selection.lassoPath.count >= 3 {
            return polygonContains(point, polygon: selection.lassoPath)
        }

        let center = selection.logicalBounds.midPoint
        let cosine = cos(-selection.rotationRadians)
        let sine = sin(-selection.rotationRadians)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let localPoint = CGPoint(
            x: center.x + cosine * dx - sine * dy,
            y: center.y + sine * dx + cosine * dy
        )
        let hitSlop = max(3, logicalPageSize.width * 0.006)
        return selection.logicalBounds.insetBy(dx: -hitSlop, dy: -hitSlop)
            .contains(localPoint)
    }

    private func rotationHandlePosition(
        for selection: LassoStrokeSelection,
        in displaySize: CGSize
    ) -> CGPoint {
        let bounds = displayRect(for: selection.logicalBounds, in: displaySize)
        return rotatedDisplayPoint(
            CGPoint(x: bounds.midX, y: bounds.maxY + 31),
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
        // In box mode rotation must not orbit the action bar. The unrotated
        // logical frame stays stable while the content and handles rotate.
        let toolbarBounds = selection.presentation == .box
            ? selection.logicalBounds
            : selection.axisAlignedBounds
        let bounds = displayRect(for: toolbarBounds, in: displaySize)
        let halfToolbarWidth: CGFloat = 174
        let x = min(max(bounds.midX, halfToolbarWidth + 8), displaySize.width - halfToolbarWidth - 8)
        let y: CGFloat
        if selection.presentation == .box {
            y = max(27, bounds.minY - 36)
        } else {
            let belowY = bounds.maxY + 46
            y = belowY + 24 < displaySize.height
                ? belowY
                : max(28, bounds.minY - 38)
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
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard feedbackText == text else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                feedbackText = nil
            }
        }
    }

    private func logicalPoint(for displayPoint: CGPoint, in displaySize: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(displayPoint.x / max(displaySize.width, 1) * logicalPageSize.width, 0), logicalPageSize.width),
            y: min(max(displayPoint.y / max(displaySize.height, 1) * logicalPageSize.height, 0), logicalPageSize.height)
        )
    }

    private func displayPoint(for logicalPoint: CGPoint, in displaySize: CGSize) -> CGPoint {
        CGPoint(
            x: logicalPoint.x / max(logicalPageSize.width, 1) * displaySize.width,
            y: logicalPoint.y / max(logicalPageSize.height, 1) * displaySize.height
        )
    }

    private func displayRect(for logicalRect: CGRect, in displaySize: CGSize) -> CGRect {
        let origin = displayPoint(for: logicalRect.origin, in: displaySize)
        return CGRect(
            x: origin.x,
            y: origin.y,
            width: logicalRect.width / max(logicalPageSize.width, 1) * displaySize.width,
            height: logicalRect.height / max(logicalPageSize.height, 1) * displaySize.height
        )
    }

    private func logicalTranslation(_ translation: CGSize, displaySize: CGSize) -> CGSize {
        CGSize(
            width: translation.width / max(displaySize.width, 1) * logicalPageSize.width,
            height: translation.height / max(displaySize.height, 1) * logicalPageSize.height
        )
    }
}

private struct LassoStrokeSelection {
    enum Presentation {
        case freeform
        case box
    }

    let content: LassoSelectionContent
    var logicalBounds: CGRect
    var lassoPath: [CGPoint]
    var presentation: Presentation
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
    let isShowingBox: Bool
    let onShowBox: () -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void
    let onCopy: () -> Void
    let onScreenshot: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            actionButton(
                title: "框选",
                symbol: "rectangle.dashed",
                tint: isShowingBox ? TiyiNoteTheme.lassoBlue : TiyiNoteTheme.textPrimary,
                action: onShowBox
            )
            actionButton(
                title: "删除",
                symbol: "trash",
                tint: TiyiNoteTheme.danger,
                action: onDelete
            )
            actionButton(
                title: "复制",
                symbol: "doc.on.doc",
                tint: TiyiNoteTheme.textPrimary,
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
        }
        .padding(5)
        .background(TiyiNoteTheme.chrome.opacity(0.97), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(TiyiNoteTheme.strongHairline, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.40), radius: 10, y: 4)
    }

    private func actionButton(
        title: String,
        symbol: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct LassoInputView: UIViewRepresentable {
    let shouldBeginDrag: (CGPoint, UITouch.TouchType) -> Bool
    let onBegan: (CGPoint) -> Void
    let onMoved: (CGPoint) -> Void
    let onEnded: (CGPoint) -> Void
    let onTap: (CGPoint) -> Void
    let onFingerLongPress: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
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

        view.addGestureRecognizer(lassoGesture)
        view.addGestureRecognizer(longPressGesture)
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
        imageAnnotations: [CanvasImageAnnotation],
        cropRect: CGRect,
        logicalPageSize: CGSize
    ) -> LassoSnapshot? {
        let pageRect = CGRect(origin: .zero, size: logicalPageSize)
        let cropRect = cropRect.intersection(pageRect).integral
        guard !cropRect.isNull, cropRect.width > 1, cropRect.height > 1 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: cropRect.size, format: format)
        let image = renderer.image { rendererContext in
            UIColor.white.setFill()
            rendererContext.fill(CGRect(origin: .zero, size: cropRect.size))

            let context = rendererContext.cgContext
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
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()

            for annotation in imageAnnotations
            where annotation.logicalBounds.intersects(cropRect) {
                context.saveGState()
                context.translateBy(
                    x: annotation.logicalBounds.midX - cropRect.minX,
                    y: annotation.logicalBounds.midY - cropRect.minY
                )
                context.rotate(by: annotation.rotationRadians)
                annotation.image.draw(in: CGRect(
                    x: -annotation.logicalBounds.width / 2,
                    y: -annotation.logicalBounds.height / 2,
                    width: annotation.logicalBounds.width,
                    height: annotation.logicalBounds.height
                ))
                context.restoreGState()
            }

            let annotationImage = drawing.image(from: cropRect, scale: format.scale)
            annotationImage.draw(in: CGRect(origin: .zero, size: cropRect.size))
        }
        return LassoSnapshot(image: image, logicalSize: cropRect.size)
    }
}

private struct PageThumbnailSidebar: View {
    @ObservedObject var documentStore: DrawingDocumentStore
    let documentID: String
    let currentPageIndex: Int
    let onSelectPage: (Int) -> Void
    let onClose: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("页面")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(TiyiNoteTheme.textPrimary)
                Spacer()
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

            HStack(spacing: 0) {
                Image(systemName: "doc")
                Spacer()
                Image(systemName: "list.bullet")
                Spacer()
                Image(systemName: "bookmark")
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(TiyiNoteTheme.textSecondary)
            .padding(.horizontal, 32)
            .frame(height: 38)
            .background(TiyiNoteTheme.surface, in: Capsule())
            .overlay {
                Capsule().stroke(TiyiNoteTheme.hairline, lineWidth: 1)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            ScrollView(.vertical, showsIndicators: true) {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(0..<documentStore.pageCount(for: documentID), id: \.self) { pageIndex in
                        PageThumbnailCard(
                            image: documentStore.thumbnail(
                                forPage: pageIndex,
                                in: documentID,
                                size: CGSize(width: 220, height: 310)
                            ),
                            pageIndex: pageIndex,
                            isSelected: pageIndex == currentPageIndex
                        ) {
                            onSelectPage(pageIndex)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 24)
            }
        }
        .frame(width: 292)
        .background(TiyiNoteTheme.sidebar)
    }
}

private struct PageThumbnailCard: View {
    let image: UIImage?
    let pageIndex: Int
    let isSelected: Bool
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
                            isSelected ? TiyiNoteTheme.selectionBorder : TiyiNoteTheme.hairline,
                            lineWidth: isSelected ? 3 : 1
                        )
                }

                Text("\(pageIndex + 1)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? TiyiNoteTheme.selectionForeground : TiyiNoteTheme.textSecondary)
            }
            .padding(6)
            .background(
                isSelected ? TiyiNoteTheme.selectionBackground : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isSelected ? TiyiNoteTheme.selectionBorder : Color.clear,
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("第 \(pageIndex + 1) 页")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
