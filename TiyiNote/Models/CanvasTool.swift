import PencilKit
import SwiftUI

enum CanvasToolKind: String, CaseIterable, Identifiable {
    case pen
    case eraser
    case lasso
    case marker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: "钢笔"
        case .marker: "荧光笔"
        case .eraser: "橡皮擦"
        case .lasso: "套索"
        }
    }

    var symbolName: String {
        switch self {
        case .pen: "pencil.tip"
        case .eraser: "eraser.fill"
        case .lasso: "lasso"
        case .marker: "highlighter"
        }
    }

    var usesInkSettings: Bool {
        switch self {
        case .pen, .marker: true
        case .eraser, .lasso: false
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
}
