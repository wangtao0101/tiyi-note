import SwiftUI

struct ToolPaletteView: View {
    @Binding var selectedTool: CanvasToolKind
    @Binding var selectedColor: InkPaletteColor
    @Binding var penWidth: Double
    @Binding var markerWidth: Double
    @Binding var fingerDrawingEnabled: Bool
    @Binding var showsThumbnails: Bool

    let activeController: CanvasController?
    let onClear: () -> Void

    private var activeWidth: Binding<Double> {
        selectedTool == .marker ? $markerWidth : $penWidth
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ToolbarIconButton(
                    symbol: "rectangle.split.1x2",
                    title: showsThumbnails ? "关闭页面缩略图" : "打开页面缩略图",
                    isHighlighted: showsThumbnails
                ) {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        showsThumbnails.toggle()
                    }
                }

                PaletteDivider()

                HStack(spacing: 5) {
                    ForEach(CanvasToolKind.allCases) { tool in
                        ToolButton(tool: tool, isSelected: selectedTool == tool) {
                            withAnimation(.easeOut(duration: 0.16)) {
                                selectedTool = tool
                            }
                        }
                    }
                }

                PaletteDivider()

                if selectedTool != .eraser {
                    HStack(spacing: 8) {
                        ForEach(InkPaletteColor.allCases) { inkColor in
                            ColorSwatch(
                                inkColor: inkColor,
                                isSelected: selectedColor == inkColor
                            ) {
                                selectedColor = inkColor
                            }
                        }
                    }

                    PaletteDivider()

                    HStack(spacing: 8) {
                        Image(systemName: "line.diagonal")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TiyiNoteTheme.textSecondary)

                        Slider(
                            value: activeWidth,
                            in: selectedTool == .marker ? 8...28 : 1.5...12
                        )
                        .tint(TiyiNoteTheme.copper)
                        .frame(width: 104)

                        Text("\(Int(activeWidth.wrappedValue))")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(TiyiNoteTheme.copperBright)
                            .frame(width: 22, alignment: .trailing)
                    }

                    PaletteDivider()
                }

                if let activeController {
                    ActiveCanvasControls(
                        controller: activeController,
                        fingerDrawingEnabled: $fingerDrawingEnabled,
                        onClear: onClear
                    )
                } else {
                    InactiveCanvasControls(
                        fingerDrawingEnabled: $fingerDrawingEnabled,
                        onClear: onClear
                    )
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 58)
        .background(TiyiNoteTheme.toolbar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TiyiNoteTheme.hairline)
                .frame(height: 1)
        }
    }
}

private struct ActiveCanvasControls: View {
    @ObservedObject var controller: CanvasController
    @Binding var fingerDrawingEnabled: Bool
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ToolbarIconButton(
                symbol: "arrow.uturn.backward",
                title: "撤销",
                isEnabled: controller.canUndo,
                action: controller.undo
            )
            ToolbarIconButton(
                symbol: "arrow.uturn.forward",
                title: "重做",
                isEnabled: controller.canRedo,
                action: controller.redo
            )
            CommonCanvasControls(
                fingerDrawingEnabled: $fingerDrawingEnabled,
                onClear: onClear
            )
        }
    }
}

private struct InactiveCanvasControls: View {
    @Binding var fingerDrawingEnabled: Bool
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ToolbarIconButton(symbol: "arrow.uturn.backward", title: "撤销", isEnabled: false) {}
            ToolbarIconButton(symbol: "arrow.uturn.forward", title: "重做", isEnabled: false) {}
            CommonCanvasControls(
                fingerDrawingEnabled: $fingerDrawingEnabled,
                onClear: onClear
            )
        }
    }
}

private struct CommonCanvasControls: View {
    @Binding var fingerDrawingEnabled: Bool
    let onClear: () -> Void

    var body: some View {
        ToolbarIconButton(
            symbol: fingerDrawingEnabled ? "hand.draw.fill" : "hand.draw",
            title: fingerDrawingEnabled ? "关闭手指书写" : "开启手指书写",
            isHighlighted: fingerDrawingEnabled
        ) {
            fingerDrawingEnabled.toggle()
        }
        ToolbarIconButton(
            symbol: "trash",
            title: "清空当前页批注",
            tint: TiyiNoteTheme.danger,
            action: onClear
        )
    }
}

private struct ToolButton: View {
    let tool: CanvasToolKind
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tool.symbolName)
                    .font(.system(size: 16, weight: .semibold))
                if isSelected {
                    Text(tool.title)
                        .font(.system(size: 13, weight: .semibold))
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .foregroundStyle(isSelected ? TiyiNoteTheme.selectionForeground : TiyiNoteTheme.textSecondary)
            .padding(.horizontal, isSelected ? 13 : 10)
            .frame(height: 38)
            .background {
                Capsule()
                    .fill(isSelected ? TiyiNoteTheme.selectionBackground : Color.clear)
            }
            .overlay {
                Capsule()
                    .stroke(
                        isSelected ? TiyiNoteTheme.selectionBorder : Color.clear,
                        lineWidth: 1
                    )
            }
            .contentShape(Capsule())
        }
        .buttonStyle(SmokedCopperButtonStyle(shape: .capsule, isSelected: isSelected))
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ColorSwatch: View {
    let inkColor: InkPaletteColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(inkColor.color)
                .frame(width: 22, height: 22)
                .overlay {
                    Circle()
                        .stroke(TiyiNoteTheme.selectionForeground, lineWidth: 2)
                        .padding(2)
                        .opacity(isSelected ? 1 : 0)
                }
                .overlay {
                    Circle()
                        .stroke(TiyiNoteTheme.selectionBorder, lineWidth: 2)
                        .padding(-3)
                        .opacity(isSelected ? 1 : 0)
                }
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(inkColor.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ToolbarIconButton: View {
    let symbol: String
    let title: String
    var isEnabled = true
    var isHighlighted = false
    var tint = TiyiNoteTheme.textPrimary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(
                    isEnabled
                        ? (isHighlighted ? TiyiNoteTheme.selectionForeground : tint)
                        : TiyiNoteTheme.textTertiary.opacity(0.48)
                )
                .frame(width: 38, height: 38)
                .background(
                    isHighlighted ? TiyiNoteTheme.selectionBackground : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            isHighlighted ? TiyiNoteTheme.selectionBorder : Color.clear,
                            lineWidth: 1
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(SmokedCopperButtonStyle(shape: .roundedRectangle, isSelected: isHighlighted))
        .disabled(!isEnabled)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}

private struct SmokedCopperButtonStyle: ButtonStyle {
    enum Shape {
        case capsule
        case roundedRectangle
    }

    let shape: Shape
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if configuration.isPressed {
                    switch shape {
                    case .capsule:
                        Capsule().fill(TiyiNoteTheme.selectionPressed)
                    case .roundedRectangle:
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(TiyiNoteTheme.selectionPressed)
                    }
                }
            }
            .brightness(configuration.isPressed && isSelected ? 0.035 : 0)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

private struct PaletteDivider: View {
    var body: some View {
        Rectangle()
            .fill(TiyiNoteTheme.hairline)
            .frame(width: 1, height: 28)
            .padding(.horizontal, 2)
    }
}
