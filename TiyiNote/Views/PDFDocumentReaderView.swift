import PDFKit
import SwiftUI

struct PDFDocumentReaderView: View {
    @ObservedObject var documentStore: DrawingDocumentStore
    let documentID: String
    @Binding var showsThumbnails: Bool

    let selectedTool: CanvasToolKind
    let selectedColor: InkPaletteColor
    let penWidth: Double
    let markerWidth: Double
    let fingerDrawingEnabled: Bool
    let onActiveCanvasChanged: (CanvasController, Int) -> Void

    @State private var currentPageIndex: Int
    @State private var requestedPageIndex: Int?
    @State private var visibleControllers: [Int: CanvasController] = [:]

    init(
        documentStore: DrawingDocumentStore,
        documentID: String,
        showsThumbnails: Binding<Bool>,
        selectedTool: CanvasToolKind,
        selectedColor: InkPaletteColor,
        penWidth: Double,
        markerWidth: Double,
        fingerDrawingEnabled: Bool,
        initialPageIndex: Int,
        onActiveCanvasChanged: @escaping (CanvasController, Int) -> Void
    ) {
        self.documentStore = documentStore
        self.documentID = documentID
        _showsThumbnails = showsThumbnails
        self.selectedTool = selectedTool
        self.selectedColor = selectedColor
        self.penWidth = penWidth
        self.markerWidth = markerWidth
        self.fingerDrawingEnabled = fingerDrawingEnabled
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
            let pageWidth = min(max(geometry.size.width - 40, 280), 900)

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: true) {
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
                                fingerDrawingEnabled: fingerDrawingEnabled,
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
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .coordinateSpace(name: "pdfVerticalScroll")
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
                    HStack(spacing: 6) {
                        Circle()
                            .fill(TiyiNoteTheme.copper)
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
                    .padding(14)
                    .allowsHitTesting(false)
                }
            }
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
    let fingerDrawingEnabled: Bool
    let onReady: (CanvasController, Int) -> Void
    let onRelease: (CanvasController, Int) -> Void

    @StateObject private var controller = CanvasController()
    @State private var hasLoadedDrawing = false

    var body: some View {
        ZStack {
            PDFPageView(page: documentStore.page(at: pageIndex, in: documentID))
            PencilCanvasView(controller: controller, logicalPageSize: logicalPageSize)
                .accessibilityLabel("第 \(pageIndex + 1) 页批注画布")
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
        .onChange(of: fingerDrawingEnabled) { _, enabled in
            controller.setFingerDrawingEnabled(enabled)
        }
    }

    private func preparePageCanvas() {
        if !hasLoadedDrawing {
            controller.installInitialDrawing(
                documentStore.loadDrawing(forPage: pageIndex, in: documentID)
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
        controller.setFingerDrawingEnabled(fingerDrawingEnabled)
        applySelectedTool()
        onReady(controller, pageIndex)
    }

    private func releasePageCanvas() {
        documentStore.flush(controller.drawing, forPage: pageIndex, in: documentID)
        controller.onDrawingChanged = nil
        controller.onBecameActive = nil
        onRelease(controller, pageIndex)
    }

    private func applySelectedTool() {
        let width = selectedTool == .marker ? markerWidth : penWidth
        controller.updateTool(kind: selectedTool, color: selectedColor, width: width)
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
                VStack(alignment: .leading, spacing: 1) {
                    Text("PAGES")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(1.6)
                        .foregroundStyle(TiyiNoteTheme.copper)
                    Text("页面")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(TiyiNoteTheme.textPrimary)
                }
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
