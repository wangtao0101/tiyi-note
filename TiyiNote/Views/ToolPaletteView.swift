import Foundation
import SwiftUI

struct ToolPaletteView: View {
    @Binding var selectedTool: CanvasToolKind
    @Binding var selectedColor: InkPaletteColor
    @Binding var penWidth: Double
    @Binding var markerWidth: Double
    @Binding var eraserSize: CanvasEraserSize
    @Binding var showsThumbnails: Bool

    let activeController: CanvasController?
    let onClear: () -> Void

    private var activeWidth: Binding<Double> {
        selectedTool == .marker ? $markerWidth : $penWidth
    }

    private var activeWidthLabel: String {
        let width = activeWidth.wrappedValue
        return width < 3
            ? String(format: "%.1f", width)
            : String(format: "%.0f", width)
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

                if selectedTool.usesInkSettings {
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
                            in: selectedTool == .marker ? 8...28 : 0.1...8,
                            step: selectedTool == .marker ? 1 : 0.1
                        )
                        .tint(TiyiNoteTheme.selectionBlue)
                        .frame(width: 104)

                        Text(activeWidthLabel)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(TiyiNoteTheme.selectionForeground)
                            .frame(width: 28, alignment: .trailing)
                    }

                    PaletteDivider()
                }

                if selectedTool == .eraser {
                    EraserSizePicker(selection: $eraserSize)
                    PaletteDivider()
                }

                if let activeController {
                    ActiveCanvasControls(
                        controller: activeController,
                        onClear: onClear
                    )
                } else {
                    InactiveCanvasControls(
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
            CommonCanvasControls(onClear: onClear)
        }
    }
}

private struct InactiveCanvasControls: View {
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ToolbarIconButton(symbol: "arrow.uturn.backward", title: "撤销", isEnabled: false) {}
            ToolbarIconButton(symbol: "arrow.uturn.forward", title: "重做", isEnabled: false) {}
            CommonCanvasControls(onClear: onClear)
        }
    }
}

private struct CommonCanvasControls: View {
    let onClear: () -> Void

    var body: some View {
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
            Group {
                if tool == .marker {
                    HighlighterToolIcon()
                } else {
                    Image(systemName: tool.symbolName)
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .foregroundStyle(isSelected ? TiyiNoteTheme.selectionForeground : TiyiNoteTheme.textSecondary)
            .frame(width: 38, height: 38)
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
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(SelectionButtonStyle(shape: .capsule, isSelected: isSelected))
        .accessibilityLabel(tool.title)
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

private struct EraserSizePicker: View {
    @Binding var selection: CanvasEraserSize

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CanvasEraserSize.allCases) { size in
                Button {
                    selection = size
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                selection == size
                                    ? TiyiNoteTheme.selectionBackground
                                    : Color.white.opacity(0.045)
                            )
                            .overlay {
                                Circle()
                                    .stroke(
                                        selection == size
                                            ? TiyiNoteTheme.selectionBorder
                                            : TiyiNoteTheme.textSecondary.opacity(0.72),
                                        lineWidth: selection == size ? 0.9 : 0.65
                                    )
                            }
                            .frame(width: size.previewDiameter, height: size.previewDiameter)
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(size.title)号橡皮擦")
                .accessibilityAddTraits(selection == size ? .isSelected : [])
            }
        }
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
                .frame(width: 21, height: 21)
                .overlay {
                    Circle()
                        .stroke(
                            isSelected
                                ? TiyiNoteTheme.selectionBorder
                                : (inkColor == .graphite
                                    ? Color.white.opacity(0.72)
                                    : Color.white.opacity(0.30)),
                            lineWidth: isSelected ? 2.2 : 1.2
                        )
                }
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
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
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(SelectionButtonStyle(shape: .roundedRectangle, isSelected: isHighlighted))
        .disabled(!isEnabled)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}

private struct SelectionButtonStyle: ButtonStyle {
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
