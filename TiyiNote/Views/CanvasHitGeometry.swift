import PencilKit

/// Rendering and interaction share the same shape outline, including rotation and the minimum
/// visible stroke width. Hit tolerances are supplied in page coordinates by the current camera.
extension PageShapePayload {
    func path(in bounds: CGRect, displayScale: CGFloat) -> CGPath {
        let scale = max(displayScale, 0.0001)
        let rect = bounds.insetBy(dx: max(CGFloat(lineWidth), 1 / scale) / 2,
                                 dy: max(CGFloat(lineWidth), 1 / scale) / 2)
        let path = CGMutablePath()
        switch kind {
        case .line, .arrow:
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            if kind == .arrow {
                let head = min(rect.height * 0.35, rect.width * 0.18, 18 / scale)
                for sign: CGFloat in [-1, 1] {
                    path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
                    path.addLine(to: CGPoint(x: rect.maxX - head, y: rect.midY + sign * head * 0.72))
                }
            }
        case .rectangle:
            path.addRect(rect)
        case .ellipse:
            path.addEllipse(in: rect)
        case .triangle:
            path.addLines(between: [CGPoint(x: rect.midX, y: rect.minY),
                                   CGPoint(x: rect.maxX, y: rect.maxY),
                                   CGPoint(x: rect.minX, y: rect.maxY)])
            path.closeSubpath()
        case .diamond:
            path.addLines(between: [CGPoint(x: rect.midX, y: rect.minY),
                                   CGPoint(x: rect.maxX, y: rect.midY),
                                   CGPoint(x: rect.midX, y: rect.maxY),
                                   CGPoint(x: rect.minX, y: rect.midY)])
            path.closeSubpath()
        }
        return path
    }
}

extension CanvasPageElement {
    private var rotationTransform: CGAffineTransform {
        CGAffineTransform(translationX: logicalBounds.midX, y: logicalBounds.midY)
            .rotated(by: rotationRadians)
            .translatedBy(x: -logicalBounds.midX, y: -logicalBounds.midY)
    }

    func interactionPath(displayScale: CGFloat) -> CGPath {
        let path: CGPath
        if case .shape(let shape) = payload {
            path = shape.path(in: logicalBounds, displayScale: displayScale)
        } else {
            path = CGPath(rect: logicalBounds, transform: nil)
        }
        var transform = rotationTransform
        return path.copy(using: &transform) ?? path
    }

    func hitArea(tolerance: CGFloat, displayScale: CGFloat, includesInterior: Bool) -> CGPath {
        let path = interactionPath(displayScale: displayScale)
        var width: CGFloat = 0
        var fillsInterior = includesInterior
        if case .shape(let shape) = payload {
            width = max(CGFloat(shape.lineWidth), 1 / max(displayScale, 0.0001))
            fillsInterior = (includesInterior || shape.fillColorHex != nil)
                && shape.kind != .line && shape.kind != .arrow
        }
        let edge = path.copy(strokingWithWidth: max(width + tolerance * 2, 0.01),
                             lineCap: .round, lineJoin: .round, miterLimit: 10)
        // A stroked path winds opposite to some filled outlines. Appending both paths cancels
        // their overlap and leaves an unselectable band inside text and shape edges.
        return fillsInterior ? path.union(edge) : edge
    }

    func intersectsLasso(_ polygon: [CGPoint], tolerance: CGFloat, displayScale: CGFloat) -> Bool {
        guard polygon.count >= 3 else { return false }
        let lasso = CGMutablePath()
        lasso.addLines(between: polygon)
        lasso.closeSubpath()
        if lasso.contains(CGPoint(x: logicalBounds.midX, y: logicalBounds.midY)) { return true }
        let area = hitArea(tolerance: tolerance, displayScale: displayScale, includesInterior: true)
        // Walk the lasso's complete closing segment too. A small loop crossing only a shape edge
        // should select it even when the shape's center is outside the loop.
        return polygon.indices.contains { index in
            CanvasHitGeometry.segment(from: polygon[index], to: polygon[(index + 1) % polygon.count],
                                      intersects: area, step: max(tolerance, 1 / displayScale))
        }
    }
}

enum CanvasHitGeometry {
    static func segment(from start: CGPoint, to end: CGPoint, intersects area: CGPath, step: CGFloat) -> Bool {
        let bounds = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                            width: abs(end.x - start.x), height: abs(end.y - start.y))
            .insetBy(dx: -step, dy: -step)
        guard area.boundingBoxOfPath.intersects(bounds) else { return false }
        let count = max(1, Int(ceil(hypot(end.x - start.x, end.y - start.y) / max(step, 0.01))))
        return (0...count).contains { index in
            let fraction = CGFloat(index) / CGFloat(count)
            return area.contains(CGPoint(x: start.x + (end.x - start.x) * fraction,
                                         y: start.y + (end.y - start.y) * fraction))
        }
    }

    static func visiblePoints(in stroke: PKStroke) -> [[PKStrokePoint]] {
        guard !stroke.path.isEmpty else { return [] }
        let ranges = stroke.mask == nil
            ? [CGFloat(0)...CGFloat(stroke.path.count - 1)] : stroke.maskedPathRanges
        return ranges.map { Array(stroke.path.interpolatedPoints(in: $0, by: .distance(3))) }
    }

    static func distance(to point: CGPoint, stroke: PKStroke, tolerance: CGFloat) -> CGFloat? {
        guard stroke.renderBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return nil }
        let scale = max(hypot(stroke.transform.a, stroke.transform.b), hypot(stroke.transform.c, stroke.transform.d))
        var nearest = CGFloat.greatestFiniteMagnitude
        for samples in visiblePoints(in: stroke) {
            let points = samples.map { $0.location.applying(stroke.transform) }
            for index in points.indices {
                let radius = max(samples[index].size.width, samples[index].size.height) * scale / 2
                let start = index == 0 ? points[index] : points[index - 1]
                nearest = min(nearest, distance(point, toSegmentFrom: start, to: points[index]) - radius)
            }
            // Closed ink shapes can also be picked from their interior. Erased/masked ink must
            // only hit its remaining visible segments, never the old closed contour.
            if stroke.mask == nil, points.count >= 4, let first = points.first, let last = points.last,
               hypot(first.x - last.x, first.y - last.y) <= max(6, tolerance / 2) {
                let path = CGMutablePath()
                path.addLines(between: points)
                path.closeSubpath()
                if path.contains(point) { nearest = min(nearest, 0) }
            }
        }
        return nearest <= tolerance ? max(nearest, 0) : nil
    }

    private static func distance(_ point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        let fraction = lengthSquared > 0
            ? min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared, 0), 1) : 0
        return hypot(point.x - start.x - fraction * dx, point.y - start.y - fraction * dy)
    }
}
