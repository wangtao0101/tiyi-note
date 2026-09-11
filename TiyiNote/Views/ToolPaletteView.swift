import Foundation
import SwiftUI

enum ToolPaletteDockEdge: String, CaseIterable {
    case top
    case leading
    case bottom
    case trailing

    var isHorizontal: Bool {
        self == .top || self == .bottom
    }

    var accessibilityValue: String {
        switch self {
        case .top: "top"
        case .leading: "left"
        case .bottom: "bottom"
        case .trailing: "right"
        }
    }
}

/// The Goodnotes-style command row. Tool selection and document actions stay fixed; pen and
/// eraser variants open in secondary popovers, while quick colors and sizes stay in the dockable
/// palette over the canvas.
struct ToolPaletteView: View {
    private enum SecondarySettings {
        case pen
        case eraser
    }

    let activeController: CanvasController?
    @Binding var selectedTool: CanvasToolKind
    @Binding var selectedPenVariant: CanvasToolKind
    @Binding var eraserMode: CanvasEraserMode
    @Binding var isScribbleEraseEnabled: Bool
    @Binding var showsThumbnails: Bool

    @State private var secondarySettings: SecondarySettings?

    let onSearch: (() -> Void)?
    let onInsertImage: () -> Void
    let onInsertShape: (PageShapeKind) -> Void
    let hasActiveDocument: Bool
    let canClearPage: Bool
    let onDocumentAction: (DocumentOutputAction) -> Void
    let onClearPage: () -> Void

    var body: some View {
        ZStack {
            Color.clear
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityIdentifier("annotation-tool-bar")

            GeometryReader { geometry in
                let horizontalPadding: CGFloat = 20
                let leadingControlsWidth: CGFloat = onSearch == nil ? 38 : 78
                let dividerWidth: CGFloat = 5
                let outerSpacing: CGFloat = 24
                let trailingActionCount = 2
                let trailingActionsWidth = CGFloat(trailingActionCount * 38)
                    + CGFloat(max(trailingActionCount - 1, 0))
                let centerWidth = max(
                    44,
                    geometry.size.width
                        - horizontalPadding
                        - leadingControlsWidth
                        - dividerWidth
                        - outerSpacing
                        - trailingActionsWidth
                )

                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        DocumentToolbarButton(
                            symbol: "rectangle.split.1x2",
                            title: showsThumbnails ? "关闭页面缩略图" : "打开页面缩略图",
                            isSelected: showsThumbnails
                        ) {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                showsThumbnails.toggle()
                            }
                        }

                        if let onSearch {
                            DocumentToolbarButton(
                                symbol: "magnifyingglass",
                                title: "搜索 PDF",
                                action: onSearch
                            )
                        }
                    }

                    DocumentToolbarDivider()

                    // Only the drawing-tool cluster is allowed to scroll. Keeping the document
                    // actions outside this scroll view guarantees that export and More stay
                    // visible at the trailing edge, matching Goodnotes. The old outer ScrollView
                    // contained flexible Spacers; under an unbounded horizontal proposal they could
                    // expand and push the trailing actions completely off screen.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 3) {
                            ToolButton(tool: .lasso, isSelected: selectedTool == .lasso) {
                                selectFirstLevelTool(.lasso)
                            }

                            ToolButton(
                                tool: resolvedPenVariant,
                                isSelected: selectedTool.usesInkSettings,
                                accessibilityTitle: selectedTool == .marker
                                    ? "笔，当前荧光笔"
                                    : "笔，当前\(resolvedPenVariant.title)",
                                accessibilityIdentifier: "tool-pen",
                                showsSecondaryIndicator: true,
                                action: handlePenButton
                            )
                            .popover(
                                isPresented: secondarySettingsBinding(for: .pen),
                                attachmentAnchor: .rect(.bounds),
                                arrowEdge: .top
                            ) {
                                PenVariantSettingsPopover(
                                    selection: resolvedPenVariant,
                                    isScribbleEraseEnabled: $isScribbleEraseEnabled,
                                    onSelect: selectPenVariant
                                )
                                .presentationCompactAdaptation(.popover)
                            }

                            ToolButton(
                                tool: .eraser,
                                isSelected: selectedTool == .eraser,
                                accessibilityTitle: "橡皮擦，当前\(eraserMode.title)",
                                showsSecondaryIndicator: true,
                                action: handleEraserButton
                            )
                            .popover(
                                isPresented: secondarySettingsBinding(for: .eraser),
                                attachmentAnchor: .rect(.bounds),
                                arrowEdge: .top
                            ) {
                                EraserModeSettingsPopover(
                                    selection: eraserMode,
                                    onSelect: selectEraserMode
                                )
                                .presentationCompactAdaptation(.popover)
                            }

                            ToolButton(tool: .text, isSelected: selectedTool == .text) {
                                selectFirstLevelTool(.text)
                            }

                            DocumentToolbarButton(
                                symbol: "photo",
                                title: "插入图片",
                                action: onInsertImage
                            )

                            Menu {
                                ForEach(PageShapeKind.allCases) { shape in
                                    Button {
                                        onInsertShape(shape)
                                    } label: {
                                        Label(shape.title, systemImage: shape.symbolName)
                                    }
                                }
                            } label: {
                                DocumentToolbarIcon(symbol: "square.on.circle")
                            }
                            .accessibilityLabel("插入图形")

                            CanvasHistoryControls(activeController: activeController)
                        }
                        // A finite viewport width centers this compact cluster on iPad while its
                        // intrinsic width still wins on a narrow window, where it becomes the only
                        // horizontally scrolling portion of the toolbar.
                        .frame(minWidth: centerWidth, alignment: .center)
                    }
                    .frame(width: centerWidth, height: 38)
                    .accessibilityIdentifier("tool-settings-scroll")

                    DocumentToolbarActions(
                        hasActiveDocument: hasActiveDocument,
                        canClearPage: canClearPage,
                        onDocumentAction: onDocumentAction,
                        onClearPage: onClearPage
                    )
                    .fixedSize(horizontal: true, vertical: false)
                }
                .frame(width: max(geometry.size.width - horizontalPadding, 0), height: geometry.size.height)
                .padding(.horizontal, horizontalPadding / 2)
            }
        }
        .frame(height: 48)
        .background(TiyiNoteTheme.documentToolbar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
        }
    }

    private var resolvedPenVariant: CanvasToolKind {
        selectedPenVariant.isPenVariant ? selectedPenVariant : .pen
    }

    private func secondarySettingsBinding(
        for settings: SecondarySettings
    ) -> Binding<Bool> {
        Binding(
            get: { secondarySettings == settings },
            set: { isPresented in
                if isPresented {
                    secondarySettings = settings
                } else if secondarySettings == settings {
                    secondarySettings = nil
                }
            }
        )
    }

    private func selectFirstLevelTool(_ tool: CanvasToolKind) {
        secondarySettings = nil
        withAnimation(.easeOut(duration: 0.16)) {
            selectedTool = tool
        }
    }

    private func handlePenButton() {
        if selectedTool.usesInkSettings {
            secondarySettings = secondarySettings == .pen ? nil : .pen
            return
        }
        secondarySettings = nil
        withAnimation(.easeOut(duration: 0.16)) {
            selectedTool = resolvedPenVariant
        }
    }

    private func handleEraserButton() {
        if selectedTool == .eraser {
            secondarySettings = secondarySettings == .eraser ? nil : .eraser
            return
        }
        secondarySettings = nil
        withAnimation(.easeOut(duration: 0.16)) {
            selectedTool = .eraser
        }
    }

    private func selectPenVariant(_ variant: CanvasToolKind) {
        guard variant.isPenVariant else { return }
        selectedPenVariant = variant
        selectedTool = variant
        secondarySettings = nil
    }

    private func selectEraserMode(_ mode: CanvasEraserMode) {
        eraserMode = mode
        selectedTool = .eraser
        secondarySettings = nil
    }

}

private struct PenVariantSettingsPopover: View {
    private static let variants: [CanvasToolKind] = [.pen, .fountainPen, .pencil]

    let selection: CanvasToolKind
    @Binding var isScribbleEraseEnabled: Bool
    let onSelect: (CanvasToolKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("笔")
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                Text(selection.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.52))
            }

            PenStrokePreview(variant: selection)
                .stroke(
                    Color.black.opacity(0.88),
                    style: StrokeStyle(
                        lineWidth: selection == .pencil ? 2.2 : 3.2,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(height: 58)
                .padding(.horizontal, 8)
                .background(Color.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 8) {
                ForEach(Self.variants) { variant in
                    PenVariantOption(
                        variant: variant,
                        isSelected: selection == variant,
                        action: { onSelect(variant) }
                    )
                }
            }

            Divider().overlay(Color.black.opacity(0.04))

            Toggle(isOn: $isScribbleEraseEnabled) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("涂抹删除")
                        .font(.system(size: 14, weight: .semibold))
                    Text("用笔连续来回划或绕圈涂抹，抬笔删除")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.black.opacity(0.52))
                }
            }
            .tint(TiyiNoteTheme.selectionBlue)
            .accessibilityIdentifier("scribble-erase-toggle")
        }
        .padding(16)
        .frame(width: 334)
        .foregroundStyle(Color.black)
        .presentationBackground(Color.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pen-variant-settings")
    }
}

private struct PenStrokePreview: Shape {
    let variant: CanvasToolKind

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let verticalBias: CGFloat = variant == .fountainPen ? 0.12 : 0
        path.move(to: CGPoint(x: rect.minX + 5, y: rect.midY + rect.height * 0.18))
        path.addCurve(
            to: CGPoint(x: rect.maxX - 5, y: rect.midY - rect.height * 0.10),
            control1: CGPoint(
                x: rect.minX + rect.width * 0.28,
                y: rect.minY + rect.height * (0.05 + verticalBias)
            ),
            control2: CGPoint(
                x: rect.minX + rect.width * 0.66,
                y: rect.maxY - rect.height * (0.02 + verticalBias)
            )
        )
        return path
    }
}

private struct PenVariantOption: View {
    let variant: CanvasToolKind
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: variant.symbolName)
                    .font(.system(size: 19, weight: .medium))
                    .frame(height: 22)
                Text(variant.title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(isSelected ? TiyiNoteTheme.selectionBlue : Color.black.opacity(0.72))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                isSelected
                    ? TiyiNoteTheme.selectionBlue.opacity(0.11)
                    : Color.black.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(variant.title)
        .accessibilityIdentifier("pen-variant-\(variant.rawValue)")
        .accessibilityValue(isSelected ? "selected" : "not-selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct EraserModeSettingsPopover: View {
    let selection: CanvasEraserMode
    let onSelect: (CanvasEraserMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("橡皮擦")
                .font(.system(size: 18, weight: .bold))

            Text("擦除方式")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.48))

            HStack(spacing: 9) {
                ForEach(CanvasEraserMode.allCases) { mode in
                    EraserModeOption(
                        mode: mode,
                        isSelected: selection == mode,
                        action: { onSelect(mode) }
                    )
                }
            }
        }
        .padding(16)
        .frame(width: 310)
        .foregroundStyle(Color.black)
        .presentationBackground(Color.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("eraser-mode-settings")
    }
}

private struct EraserModeOption: View {
    let mode: CanvasEraserMode
    let isSelected: Bool
    let action: () -> Void

    private var subtitle: String {
        switch mode {
        case .precision: "擦除触碰区域"
        case .stroke: "删除整条笔迹"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: mode == .precision ? "eraser" : "eraser.fill")
                    .font(.system(size: 19, weight: .medium))
                Text(mode.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.46))
            }
            .foregroundStyle(isSelected ? TiyiNoteTheme.selectionBlue : Color.black.opacity(0.72))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                isSelected
                    ? TiyiNoteTheme.selectionBlue.opacity(0.11)
                    : Color.black.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.title)
        .accessibilityIdentifier("eraser-mode-\(mode.rawValue)")
        .accessibilityValue(isSelected ? "selected" : "not-selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct ReadOnlyToolPaletteView: View {
    @Binding var showsThumbnails: Bool
    let onSearch: (() -> Void)?
    let hasActiveDocument: Bool
    let onDocumentAction: (DocumentOutputAction) -> Void

    var body: some View {
        ZStack {
            Color.clear
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityIdentifier("annotation-tool-bar")

            HStack(spacing: 4) {
                DocumentToolbarButton(
                    symbol: "rectangle.split.1x2",
                    title: showsThumbnails ? "关闭页面缩略图" : "打开页面缩略图",
                    isSelected: showsThumbnails
                ) {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        showsThumbnails.toggle()
                    }
                }

                if let onSearch {
                    DocumentToolbarButton(
                        symbol: "magnifyingglass",
                        title: "搜索 PDF",
                        action: onSearch
                    )
                }

                DocumentToolbarDivider()

                Label("只读", systemImage: "eye")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TiyiNoteTheme.documentChromeMuted)

                Spacer(minLength: 0)

                DocumentToolbarActions(
                    hasActiveDocument: hasActiveDocument,
                    canClearPage: false,
                    onDocumentAction: onDocumentAction,
                    onClearPage: {}
                )
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 48)
        .background(TiyiNoteTheme.documentToolbar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
        }
    }
}

/// Only these two toolbar buttons observe page history; handwriting does not invalidate the
/// complete toolbar or workspace when Undo becomes available.
private struct CanvasHistoryControls: View {
    let activeController: CanvasController?

    var body: some View {
        Group {
            if let activeController {
                ActiveCanvasHistoryButtons(controller: activeController)
            } else {
                CanvasHistoryButtons(
                    canUndo: false,
                    canRedo: false,
                    onUndo: {},
                    onRedo: {}
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("canvas-history-controls")
    }
}

private struct ActiveCanvasHistoryButtons: View {
    @ObservedObject var controller: CanvasController

    var body: some View {
        CanvasHistoryButtons(
            canUndo: controller.canUndo,
            canRedo: controller.canRedo,
            onUndo: controller.undo,
            onRedo: controller.redo
        )
    }
}

private struct CanvasHistoryButtons: View {
    let canUndo: Bool
    let canRedo: Bool
    let onUndo: () -> Void
    let onRedo: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            historyButton(
                symbol: "arrow.uturn.backward",
                title: "撤销",
                identifier: "canvas-undo-button",
                isEnabled: canUndo,
                action: onUndo
            )
            historyButton(
                symbol: "arrow.uturn.forward",
                title: "重做",
                identifier: "canvas-redo-button",
                isEnabled: canRedo,
                action: onRedo
            )
        }
    }

    private func historyButton(
        symbol: String,
        title: String,
        identifier: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        DocumentToolbarButton(symbol: symbol, title: title, isEnabled: isEnabled, action: action)
            .accessibilityIdentifier(identifier)
    }
}

/// A compact contextual palette modeled after Goodnotes' detachable pen palette. It remains
/// within the document viewport, follows the drag handle, then adopts the orientation of the
/// nearest edge when released.
struct DockableToolPaletteView: View {
    @Binding var selectedTool: CanvasToolKind
    let selectedPenVariant: CanvasToolKind
    @Binding var selectedColor: InkPaletteColor
    @Binding var penWidth: Double
    @Binding var markerWidth: Double
    @Binding var eraserSize: CanvasEraserSize
    @Binding var dockEdge: ToolPaletteDockEdge
    @Binding var dockProgress: Double

    var leadingContentInset: CGFloat = 0

    @GestureState private var dragTranslation = CGSize.zero
    @State private var measuredPaletteSize = CGSize(width: 48, height: 330)

    private let edgeInset: CGFloat = 12

    @State private var showsMarkerSettings = false

    private var quickColors: [InkPaletteColor] {
        [.graphite, .ocean, .coral]
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                palette(
                    in: geometry.size,
                    globalOrigin: geometry.frame(in: .global).origin
                )
                    .background {
                        GeometryReader { paletteGeometry in
                            Color.clear.preference(
                                key: DockablePaletteSizePreferenceKey.self,
                                value: paletteGeometry.size
                            )
                        }
                    }
                    .onPreferenceChange(DockablePaletteSizePreferenceKey.self) { size in
                        guard size.width > 0, size.height > 0 else { return }
                        measuredPaletteSize = size
                    }
                    .position(currentCenter(in: geometry.size))
                    .animation(.snappy(duration: 0.28), value: dockEdge)
                    .animation(.snappy(duration: 0.28), value: dockProgress)
            }
        }
    }

    private func palette(in containerSize: CGSize, globalOrigin: CGPoint) -> some View {
        let layout = dockEdge.isHorizontal
            ? AnyLayout(HStackLayout(spacing: 4))
            : AnyLayout(VStackLayout(spacing: 4))

        return layout {
            ToolContextBadge(tool: selectedTool)

            if selectedTool.usesInkSettings {
                ForEach(Array(widthPresets.enumerated()), id: \.offset) { index, width in
                    InkWidthPresetButton(
                        previewLevel: index,
                        isSelected: selectedTool.isPenVariant && abs(penWidth - width) < 0.05,
                        title: widthPresetTitle(at: index)
                    ) {
                        penWidth = width
                        selectedTool = selectedPenVariant.isPenVariant ? selectedPenVariant : .pen
                    }
                }

                Button {
                    if selectedTool == .marker {
                        showsMarkerSettings = true
                    } else {
                        selectedTool = .marker
                    }
                } label: {
                    HighlighterToolIcon()
                        .foregroundStyle(Color.white)
                        .frame(width: 38, height: 38)
                        .background(
                            selectedTool == .marker ? Color.white.opacity(0.20) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("荧光笔")
                .accessibilityIdentifier("tool-marker")
                .accessibilityValue(selectedTool == .marker ? "selected" : "not-selected")
                .popover(isPresented: $showsMarkerSettings) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("荧光笔粗细").font(.headline)
                        Slider(value: $markerWidth, in: 8...28, step: 1)
                            .accessibilityIdentifier("marker-width-slider")
                        Text("\(Int(markerWidth)) pt").monospacedDigit()
                    }
                    .padding(20)
                    .frame(width: 240)
                    .presentationCompactAdaptation(.popover)
                }

                DockPaletteDivider(isHorizontalPalette: dockEdge.isHorizontal)

                ForEach(quickColors) { color in
                    DockPaletteColorSwatch(
                        color: color,
                        isSelected: selectedColor == color
                    ) {
                        selectedColor = color
                    }
                }

                DockPaletteColorMenu(selection: $selectedColor)
            } else if selectedTool == .eraser {
                ForEach(CanvasEraserSize.allCases) { size in
                    DockPaletteEraserSizeButton(
                        size: size,
                        isSelected: eraserSize == size
                    ) {
                        eraserSize = size
                    }
                }
            } else if selectedTool == .text {
                DockPaletteDivider(isHorizontalPalette: dockEdge.isHorizontal)

                ForEach(quickColors) { color in
                    DockPaletteColorSwatch(
                        color: color,
                        isSelected: selectedColor == color
                    ) {
                        selectedColor = color
                    }
                }

                DockPaletteColorMenu(selection: $selectedColor)
            }

            DockPaletteDivider(isHorizontalPalette: dockEdge.isHorizontal)
            PaletteDragHandle()
                .highPriorityGesture(
                    dragGesture(in: containerSize, globalOrigin: globalOrigin)
                )
        }
        .padding(5)
        .glassEffect(
            .regular
                .tint(Color.black.opacity(0.48)),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.75)
        }
        // Native interactive glass continuously samples and refracts the document underneath in
        // response to nearby input. On a floating palette above a full-page transparent
        // PKCanvasView that turns every Pencil frame into a larger compositor transaction. The
        // palette remains native glass and draggable through its handle; only the unnecessary
        // live-interaction refraction and oversized off-screen shadow are removed from the ink
        // path.
        .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dockable-tool-palette")
        .accessibilityValue(dockEdge.accessibilityValue)
    }

    private var widthPresets: [Double] {
        [0.7, 2.2, 5]
    }

    private func widthPresetTitle(at index: Int) -> String {
        switch index {
        case 0: "细"
        case 1: "中"
        default: "粗"
        }
    }

    private func dragGesture(
        in containerSize: CGSize,
        globalOrigin: CGPoint
    ) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                snapPalette(
                    location: value.location,
                    predictedLocation: value.predictedEndLocation,
                    globalOrigin: globalOrigin,
                    in: containerSize
                )
            }
    }

    private func currentCenter(in containerSize: CGSize) -> CGPoint {
        let base = dockedCenter(in: containerSize)
        return clampedCenter(
            CGPoint(
                x: base.x + dragTranslation.width,
                y: base.y + dragTranslation.height
            ),
            in: containerSize
        )
    }

    private func dockedCenter(in containerSize: CGSize) -> CGPoint {
        let bounds = allowedCenterBounds(in: containerSize)
        let progress = CGFloat(min(max(dockProgress, 0), 1))
        switch dockEdge {
        case .top:
            return CGPoint(
                x: bounds.minX + (bounds.maxX - bounds.minX) * progress,
                y: bounds.minY
            )
        case .leading:
            return CGPoint(
                x: bounds.minX,
                y: bounds.minY + (bounds.maxY - bounds.minY) * progress
            )
        case .bottom:
            return CGPoint(
                x: bounds.minX + (bounds.maxX - bounds.minX) * progress,
                y: bounds.maxY
            )
        case .trailing:
            return CGPoint(
                x: bounds.maxX,
                y: bounds.minY + (bounds.maxY - bounds.minY) * progress
            )
        }
    }

    private func allowedCenterBounds(in containerSize: CGSize) -> CGRect {
        let halfWidth = measuredPaletteSize.width / 2
        let halfHeight = measuredPaletteSize.height / 2
        let contentMidX = (min(leadingContentInset, containerSize.width) + containerSize.width) / 2
        let minX = min(contentMidX, leadingContentInset + edgeInset + halfWidth)
        let maxX = max(minX, containerSize.width - edgeInset - halfWidth)
        let minY = min(containerSize.height / 2, edgeInset + halfHeight)
        let maxY = max(minY, containerSize.height - edgeInset - halfHeight)
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    private func clampedCenter(_ point: CGPoint, in containerSize: CGSize) -> CGPoint {
        let bounds = allowedCenterBounds(in: containerSize)
        return CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private func snapPalette(
        location: CGPoint,
        predictedLocation: CGPoint,
        globalOrigin: CGPoint,
        in containerSize: CGSize
    ) {
        // Resolve the destination from the actual release point, not from the palette center.
        // The handle sits at one end of the palette after top/bottom docking, so center-based
        // projection makes dragging from the bottom bar back to the left edge unreliable.
        let projected = CGPoint(
            x: location.x + (predictedLocation.x - location.x) * 0.12 - globalOrigin.x,
            y: location.y + (predictedLocation.y - location.y) * 0.12 - globalOrigin.y
        )
        let bounds = allowedCenterBounds(in: containerSize)
        let candidates: [(ToolPaletteDockEdge, CGFloat)] = [
            (.leading, abs(projected.x - leadingContentInset)),
            (.trailing, abs(containerSize.width - projected.x)),
            (.top, abs(projected.y)),
            (.bottom, abs(containerSize.height - projected.y))
        ]
        guard let nearestEdge = candidates.min(by: { $0.1 < $1.1 })?.0 else { return }

        let nextProgress: Double
        if nearestEdge.isHorizontal {
            let travel = max(bounds.maxX - bounds.minX, 1)
            let clampedX = min(max(projected.x, bounds.minX), bounds.maxX)
            nextProgress = Double((clampedX - bounds.minX) / travel)
        } else {
            let travel = max(bounds.maxY - bounds.minY, 1)
            let clampedY = min(max(projected.y, bounds.minY), bounds.maxY)
            nextProgress = Double((clampedY - bounds.minY) / travel)
        }

        withAnimation(.snappy(duration: 0.28, extraBounce: 0.04)) {
            dockProgress = min(max(nextProgress, 0), 1)
            dockEdge = nearestEdge
        }
    }
}

private struct DockablePaletteSizePreferenceKey: PreferenceKey {
    static var defaultValue = CGSize.zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
    }
}

private struct PaletteDragHandle: View {
    var body: some View {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.72))
            .frame(width: 38, height: 38)
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel("移动工具栏")
            .accessibilityIdentifier("tool-palette-drag-handle")
            .accessibilityHint("拖动并松开，可吸附到屏幕上、左、下、右四边")
    }
}

private struct ToolContextBadge: View {
    let tool: CanvasToolKind

    var body: some View {
        Group {
            if tool == .marker {
                HighlighterToolIcon()
            } else {
                Image(systemName: tool.symbolName)
                    .font(.system(size: 16, weight: .semibold))
            }
        }
        .foregroundStyle(Color.white)
        .frame(width: 38, height: 38)
        .background(
            TiyiNoteTheme.selectionBlue.opacity(0.84),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .accessibilityHidden(true)
    }
}

private struct DockPaletteDivider: View {
    let isHorizontalPalette: Bool

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.16))
            .frame(
                width: isHorizontalPalette ? 1 : 26,
                height: isHorizontalPalette ? 26 : 1
            )
            .padding(isHorizontalPalette ? .horizontal : .vertical, 1)
    }
}

private struct InkWidthPresetButton: View {
    let previewLevel: Int
    let isSelected: Bool
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(Color.white)
                .frame(width: 20, height: CGFloat(2 + previewLevel * 2))
                .frame(width: 38, height: 38)
                .background(
                    isSelected ? Color.white.opacity(0.20) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)笔画")
        .accessibilityIdentifier("ink-width-preset-\(previewLevel)")
        .accessibilityValue(isSelected ? "selected" : "not-selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct DockPaletteColorSwatch: View {
    let color: InkPaletteColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color.color)
                .frame(width: 22, height: 22)
                .overlay {
                    Circle()
                        .stroke(Color.white, lineWidth: isSelected ? 2.5 : 0.8)
                }
                .shadow(color: .black.opacity(0.22), radius: 1, y: 1)
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color.title)
        .accessibilityIdentifier("ink-color-\(color.rawValue)")
        .accessibilityValue(isSelected ? "selected" : "not-selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct DockPaletteColorMenu: View {
    @Binding var selection: InkPaletteColor

    var body: some View {
        Menu {
            ForEach(InkPaletteColor.allCases) { color in
                Button {
                    selection = color
                } label: {
                    Label {
                        Text(color.title)
                    } icon: {
                        Image(
                            systemName: selection == color
                                ? "checkmark.circle.fill"
                                : "circle.fill"
                        )
                        .foregroundStyle(color.color)
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.88))
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.08), in: Circle())
                .contentShape(Rectangle())
        }
        .accessibilityLabel("更多颜色")
    }
}

private struct DockPaletteEraserSizeButton: View {
    let size: CanvasEraserSize
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color.white.opacity(isSelected ? 0.96 : 0.72))
                .frame(width: size.previewDiameter, height: size.previewDiameter)
                .frame(width: 38, height: 38)
                .background(
                    isSelected ? TiyiNoteTheme.selectionBlue.opacity(0.82) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(size.title)号橡皮擦")
        .accessibilityIdentifier("eraser-size-\(size.rawValue)")
        .accessibilityValue(isSelected ? "selected" : "not-selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ToolButton: View {
    let tool: CanvasToolKind
    let isSelected: Bool
    var accessibilityTitle: String? = nil
    var accessibilityIdentifier: String? = nil
    var showsSecondaryIndicator = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if tool == .marker {
                    HighlighterToolIcon()
                } else {
                    DocumentToolbarGlyph(symbol: tool.symbolName)
                }
            }
            .foregroundStyle(
                isSelected
                    ? TiyiNoteTheme.documentChrome
                    : TiyiNoteTheme.documentChromeForeground
            )
            .frame(width: 38, height: 38)
            .background(
                isSelected ? TiyiNoteTheme.documentToolSelection : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(alignment: .bottomTrailing) {
                if showsSecondaryIndicator {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(
                            isSelected
                                ? TiyiNoteTheme.documentChrome.opacity(0.72)
                                : TiyiNoteTheme.documentChromeMuted
                        )
                        .padding(4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(DocumentToolbarPressedStyle(isSelected: isSelected))
        .accessibilityLabel(accessibilityTitle ?? tool.title)
        .accessibilityIdentifier(accessibilityIdentifier ?? "tool-\(tool.rawValue)")
        .accessibilityValue(isSelected ? "selected" : "not-selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct HighlighterToolIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 1.5)
                .frame(width: 8, height: 17)
                .rotationEffect(.degrees(38))
                .offset(y: -1)
            Capsule()
                .frame(width: 18, height: 2.5)
                .opacity(0.72)
                .offset(y: 8)
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

private struct DocumentToolbarButton: View {
    let symbol: String
    let title: String
    var isEnabled = true
    var isSelected = false
    var tint = TiyiNoteTheme.documentChromeForeground
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DocumentToolbarIcon(
                symbol: symbol,
                isEnabled: isEnabled,
                isSelected: isSelected,
                tint: tint
            )
        }
        .buttonStyle(DocumentToolbarPressedStyle(isSelected: isSelected))
        .disabled(!isEnabled)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Fit symbols by their visible shape, so text-baseline metrics cannot shift individual icons.
private struct DocumentToolbarGlyph: View {
    let symbol: String

    // These compound symbols include unequal internal bearings around the badge/arrow.
    // Match their visible 20-point outline to the circle and the leading toolbar icons.
    private var outlineHeight: CGFloat {
        switch symbol {
        case "square.and.arrow.up": 21
        default: 20
        }
    }

    private var opticalOffsetY: CGFloat {
        switch symbol {
        case "square.and.arrow.up": -0.5
        default: 0
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .frame(width: 20, height: outlineHeight)
            .offset(y: opticalOffsetY)
            .frame(width: 20, height: 20)
            .font(.system(size: 16, weight: .semibold))
    }
}

struct DocumentToolbarIcon: View {
    let symbol: String
    var isEnabled = true
    var isSelected = false
    var tint = TiyiNoteTheme.documentChromeForeground

    var body: some View {
        DocumentToolbarGlyph(symbol: symbol)
            .foregroundStyle(
                isEnabled
                    ? (isSelected ? TiyiNoteTheme.documentChrome : tint)
                    : TiyiNoteTheme.documentChromeMuted.opacity(0.46)
            )
            .frame(width: 38, height: 38)
            .background(
                isSelected ? TiyiNoteTheme.documentToolSelection : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(Rectangle())
    }
}

struct DocumentToolbarPressedStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? Color.white.opacity(isSelected ? 0.12 : 0.10)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

private struct DocumentToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.16))
            .frame(width: 1, height: 26)
            .padding(.horizontal, 2)
    }
}
