import SwiftUI
import UIKit

/// A camera over stable document coordinates. Moving or zooming never transforms the drawing.
struct CanvasViewport: Codable, Equatable {
    static let minimumZoomScale: CGFloat = 0.1
    static let maximumZoomScale: CGFloat = 3

    var center: CGPoint
    var zoomScale: CGFloat = 1

    init(referenceSize: CGSize) {
        center = CGPoint(x: referenceSize.width / 2, y: referenceSize.height / 2)
    }

    func displayScale(in size: CGSize, referenceSize: CGSize) -> CGFloat {
        let fittedScale = min(
            max(size.width - 64, 1) / max(referenceSize.width, 1),
            max(size.height - 32, 1) / max(referenceSize.height, 1)
        )
        return fittedScale * zoomScale
    }

    func logicalBounds(in size: CGSize, referenceSize: CGSize) -> CGRect {
        let scale = displayScale(in: size, referenceSize: referenceSize)
        let visibleSize = CGSize(width: size.width / scale, height: size.height / scale)
        return CGRect(
            x: center.x - visibleSize.width / 2,
            y: center.y - visibleSize.height / 2,
            width: visibleSize.width,
            height: visibleSize.height
        )
    }

    mutating func pan(by translation: CGPoint, in size: CGSize, referenceSize: CGSize) {
        let scale = displayScale(in: size, referenceSize: referenceSize)
        center.x -= translation.x / scale
        center.y -= translation.y / scale
    }

    mutating func zoom(by magnification: CGFloat, around anchor: CGPoint, in size: CGSize, referenceSize: CGSize) {
        guard magnification.isFinite, magnification > 0 else { return }
        let oldScale = displayScale(in: size, referenceSize: referenceSize)
        let anchorOffset = CGPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2)
        let logicalAnchor = CGPoint(
            x: center.x + anchorOffset.x / oldScale,
            y: center.y + anchorOffset.y / oldScale
        )
        zoomScale = min(max(zoomScale * magnification, Self.minimumZoomScale), Self.maximumZoomScale)
        let newScale = displayScale(in: size, referenceSize: referenceSize)
        center = CGPoint(
            x: logicalAnchor.x - anchorOffset.x / newScale,
            y: logicalAnchor.y - anchorOffset.y / newScale
        )
    }
}

enum CanvasNavigationChange {
    case pan(CGPoint)
    case zoom(CGFloat, anchor: CGPoint)
    case finished
}

/// PDF coordinates remain bounded by the paper. Canvas coordinates may be negative and extend
/// in every direction; the same projection is used by ink, objects, selection and text editing.
struct PageProjection {
    let logicalBounds: CGRect
    let isUnbounded: Bool

    init(pageSize: CGSize, viewport: CGRect?) {
        logicalBounds = viewport ?? CGRect(origin: .zero, size: pageSize)
        isUnbounded = viewport != nil
    }

    func logicalPoint(_ point: CGPoint, displaySize: CGSize) -> CGPoint {
        let result = CGPoint(
            x: logicalBounds.minX + point.x / max(displaySize.width, 1) * logicalBounds.width,
            y: logicalBounds.minY + point.y / max(displaySize.height, 1) * logicalBounds.height
        )
        guard !isUnbounded else { return result }
        return CGPoint(
            x: min(max(result.x, logicalBounds.minX), logicalBounds.maxX),
            y: min(max(result.y, logicalBounds.minY), logicalBounds.maxY)
        )
    }

    func displayPoint(_ point: CGPoint, displaySize: CGSize) -> CGPoint {
        CGPoint(
            x: (point.x - logicalBounds.minX) / max(logicalBounds.width, 1) * displaySize.width,
            y: (point.y - logicalBounds.minY) / max(logicalBounds.height, 1) * displaySize.height
        )
    }

    func displayRect(_ rect: CGRect, displaySize: CGSize) -> CGRect {
        CGRect(
            origin: displayPoint(rect.origin, displaySize: displaySize),
            size: CGSize(
                width: rect.width / max(logicalBounds.width, 1) * displaySize.width,
                height: rect.height / max(logicalBounds.height, 1) * displaySize.height
            )
        )
    }

    func logicalTranslation(_ translation: CGSize, displaySize: CGSize) -> CGSize {
        CGSize(
            width: translation.width / max(displaySize.width, 1) * logicalBounds.width,
            height: translation.height / max(displaySize.height, 1) * logicalBounds.height
        )
    }

    func constrain(_ rect: CGRect) -> CGRect {
        guard !isUnbounded else { return rect }
        return CGRect(
            x: min(max(rect.minX, logicalBounds.minX), max(logicalBounds.minX, logicalBounds.maxX - rect.width)),
            y: min(max(rect.minY, logicalBounds.minY), max(logicalBounds.minY, logicalBounds.maxY - rect.height)),
            width: rect.width,
            height: rect.height
        )
    }
}

struct CanvasBackgroundView: View {
    let viewport: CGRect
    let page: LibraryPage

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cgContext in
                let scale = size.width / max(viewport.width, 1)
                cgContext.scaleBy(x: scale, y: scale)
                cgContext.translateBy(x: -viewport.minX, y: -viewport.minY)
                CanvasBackgroundRenderer.draw(
                    in: cgContext,
                    bounds: viewport,
                    style: page.backgroundStyle ?? .blank,
                    color: page.backgroundColor ?? .white
                )
            }
        }
        .allowsHitTesting(false)
    }
}

enum CanvasBackgroundRenderer {
    static func draw(in context: CGContext, bounds: CGRect, style: CanvasBackgroundStyle, color: CanvasBackgroundColor) {
        let background: UIColor = switch color {
        case .white: UIColor(white: 0.985, alpha: 1)
        case .ivory: UIColor(red: 0.965, green: 0.945, blue: 0.88, alpha: 1)
        case .yellow: UIColor(red: 0.99, green: 0.95, blue: 0.68, alpha: 1)
        case .blue: UIColor(red: 0.86, green: 0.94, blue: 0.99, alpha: 1)
        case .green: UIColor(red: 0.87, green: 0.96, blue: 0.88, alpha: 1)
        case .dark: UIColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1)
        }
        context.setFillColor(background.cgColor)
        context.fill(bounds)
        guard style != .blank else { return }
        let guide = color == .dark
            ? UIColor.white.withAlphaComponent(0.22)
            : UIColor(red: 0.35, green: 0.45, blue: 0.58, alpha: 0.22)
        context.setStrokeColor(guide.cgColor)
        context.setFillColor(guide.cgColor)
        context.setLineWidth(1)
        // Keep far-zoomed exports bounded by output resolution, not the size of the world.
        let scale = max(hypot(context.ctm.a, context.ctm.b), 0.000001)
        let spacing: CGFloat = 32 * max(1, ceil(4 / (32 * scale)))
        let firstX = floor(bounds.minX / spacing) * spacing
        let firstY = floor(bounds.minY / spacing) * spacing
        if style == .dotted {
            for x in stride(from: firstX, through: bounds.maxX, by: spacing) {
                for y in stride(from: firstY, through: bounds.maxY, by: spacing) {
                    context.addEllipse(in: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3))
                }
            }
            context.fillPath()
        } else {
            if style == .grid {
                for x in stride(from: firstX, through: bounds.maxX, by: spacing) {
                    context.move(to: CGPoint(x: x, y: bounds.minY))
                    context.addLine(to: CGPoint(x: x, y: bounds.maxY))
                }
            }
            for y in stride(from: firstY, through: bounds.maxY, by: spacing) {
                context.move(to: CGPoint(x: bounds.minX, y: y))
                context.addLine(to: CGPoint(x: bounds.maxX, y: y))
            }
            context.strokePath()
        }
    }
}
