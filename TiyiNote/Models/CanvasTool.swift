import PencilKit
import SwiftUI

enum CanvasToolKind: String, CaseIterable, Identifiable {
    case pen
    case fountainPen
    case pencil
    case marker
    case eraser
    case lasso
    case text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: "圆珠笔"
        case .fountainPen: "钢笔"
        case .pencil: "铅笔"
        case .marker: "荧光笔"
        case .eraser: "橡皮擦"
        case .lasso: "套索"
        case .text: "文本"
        }
    }

    var symbolName: String {
        switch self {
        case .pen: "pencil.tip"
        case .fountainPen: "pencil.and.scribble"
        case .pencil: "pencil"
        case .eraser: "eraser.fill"
        case .lasso: "lasso"
        case .marker: "highlighter"
        case .text: "textformat"
        }
    }

    var usesInkSettings: Bool {
        switch self {
        case .pen, .fountainPen, .pencil, .marker: true
        case .eraser, .lasso, .text: false
        }
    }

    /// These variants share the top-level pen tool. Highlighter uses its own width scale and is
    /// selected beside the pen-width presets in the floating palette.
    var isPenVariant: Bool {
        switch self {
        case .pen, .fountainPen, .pencil: true
        case .marker, .eraser, .lasso, .text: false
        }
    }
}

enum CanvasEraserMode: String, CaseIterable, Identifiable {
    case precision
    case stroke

    var id: String { rawValue }

    var title: String {
        switch self {
        case .precision: "精细"
        case .stroke: "整笔"
        }
    }
}

enum CanvasEraserSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "小"
        case .medium: "中"
        case .large: "大"
        }
    }

    var width: CGFloat {
        switch self {
        case .small: 18
        case .medium: 36
        case .large: 64
        }
    }

    var previewDiameter: CGFloat {
        switch self {
        case .small: 8
        case .medium: 14
        case .large: 21
        }
    }
}

enum InkPaletteColor: String, CaseIterable, Identifiable {
    case graphite
    case ocean
    case iris
    case coral
    case amber
    case forest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .graphite: "纯黑"
        case .ocean: "海洋蓝"
        case .iris: "鸢尾紫"
        case .coral: "珊瑚红"
        case .amber: "琥珀黄"
        case .forest: "森林绿"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .graphite: .black
        case .ocean: UIColor(red: 0.10, green: 0.37, blue: 0.80, alpha: 1)
        case .iris: UIColor(red: 0.38, green: 0.24, blue: 0.75, alpha: 1)
        case .coral: UIColor(red: 0.88, green: 0.27, blue: 0.24, alpha: 1)
        case .amber: UIColor(red: 0.94, green: 0.61, blue: 0.08, alpha: 1)
        case .forest: UIColor(red: 0.10, green: 0.54, blue: 0.37, alpha: 1)
        }
    }

    var color: Color { Color(uiColor: uiColor) }

    var rgbaHex: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "#%02X%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded()),
            Int((alpha * 255).rounded())
        )
    }

    static func nearest(to rgbaHex: String) -> Self {
        allCases.first {
            $0.rgbaHex.caseInsensitiveCompare(rgbaHex) == .orderedSame
        } ?? .graphite
    }
}
