import PencilKit

enum LineSelectionControls {
    /// Screen points, independent of line length, angle, zoom, or nib bounds.
    static let rotationHandleDistance: CGFloat = 28

    static func rotationHandle(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let center = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0.001 else { return CGPoint(x: center.x, y: center.y + rotationHandleDistance) }
        // Preserve the ordered endpoints' normal; choosing "down" on each frame
        // would flip the control to the other side when crossing a vertical line.
        return CGPoint(x: center.x - dy / length * rotationHandleDistance,
                       y: center.y + dx / length * rotationHandleDistance)
    }
}

/// Rendering and interaction share the same shape outline, including rotation and the minimum
/// visible stroke width. Hit tolerances are supplied in page coordinates by the current camera.
extension PageShapePayload {
    func vertexPoints(in bounds: CGRect, displayScale: CGFloat) -> [CGPoint]? {
        let expected: Int
        switch kind {
        case .line, .arrow: expected = 2
        case .triangle: expected = 3
        case .rectangle, .diamond: expected = 4
        case .ellipse: return nil
        }
        if let vertices, vertices.count == expected,
           vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) {
            return vertices.map { CGPoint(x: bounds.minX + $0.x * bounds.width,
                                          y: bounds.minY + $0.y * bounds.height) }
        }
        let inset = strokeWidth / 2
        let rect = bounds.insetBy(dx: min(inset, bounds.width / 2), dy: min(inset, bounds.height / 2))
        switch kind {
        case .line, .arrow:
            return [CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY)]
        case .triangle:
            return [CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY),
                    CGPoint(x: rect.minX, y: rect.maxY)]
        case .rectangle:
            return [rect.origin, CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        case .diamond:
            return [CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
                    CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)]
        case .ellipse: return nil
        }
    }

    func path(in bounds: CGRect, displayScale: CGFloat) -> CGPath {
        let scale = max(displayScale, 0.0001)
        let rect = bounds.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2)
        let path = CGMutablePath()
        if kind == .ellipse, let vertices, vertices.count >= 8,
           vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) {
            path.addLines(between: vertices.map { CGPoint(x: bounds.minX + $0.x * bounds.width,
                                                         y: bounds.minY + $0.y * bounds.height) })
            path.closeSubpath()
            return path
        }
        if let points = vertexPoints(in: bounds, displayScale: displayScale) {
            path.addLines(between: points)
            if points.count > 2 { path.closeSubpath() }
            if kind == .arrow {
                let a = points[0], b = points[1]
                let length = hypot(b.x - a.x, b.y - a.y)
                let head = vertices == nil ? min(rect.height * 0.35, length * 0.18, 18 / scale)
                    : min(length * 0.18, 18 / scale)
                if length > 0 {
                    let dx = (b.x - a.x) / length, dy = (b.y - a.y) / length
                    for sign: CGFloat in [-1, 1] {
                        path.move(to: b)
                        path.addLine(to: CGPoint(x: b.x - head * dx - sign * head * 0.72 * dy,
                                                y: b.y - head * dy + sign * head * 0.72 * dx))
                    }
                }
            }
            return path
        }
        path.addEllipse(in: rect)
        return path
    }
}

extension CanvasPageElement {
    func shapeVertices(displayScale: CGFloat) -> [CGPoint]? {
        guard case .shape(let shape) = payload else { return nil }
        return shape.vertexPoints(in: logicalBounds, displayScale: displayScale)?.map { $0.applying(rotationTransform) }
    }

    mutating func setShapeVertices(_ points: [CGPoint]) {
        guard case .shape(var shape) = payload, !points.isEmpty,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return }
        let xs = points.map(\.x), ys = points.map(\.y)
        let padding = max(4, CGFloat(shape.lineWidth) / 2)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!,
                            height: ys.max()! - ys.min()!).insetBy(dx: -padding, dy: -padding)
        shape.vertices = points.map { PageShapeVertex(x: ($0.x - bounds.minX) / bounds.width,
                                                     y: ($0.y - bounds.minY) / bounds.height) }
        logicalBounds = bounds
        rotationRadians = 0
        payload = .shape(shape)
    }

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
            width = shape.strokeWidth
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

/// PencilKit point footprints are ink-specific, not Core Graphics stroke widths.
/// Measure bounded cross-sections in the original renderer, away from line caps.
private enum NativeInkWidth {
    private static let cache: NSCache<NSData, NSNumber> = {
        let cache = NSCache<NSData, NSNumber>()
        cache.countLimit = 128
        cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()

    static func measure(_ stroke: PKStroke) -> CGFloat? {
        let samples = Array(stroke.path)
        guard samples.count >= 2 else { return nil }
        let transform = stroke.transform
        let points = samples.map { $0.location.applying(transform) }
        let alpha = stroke.ink.color.cgColor.alpha
        guard alpha > 0 else { return nil }
        var signature: [Double] = [Double(stroke.randomSeed), Double(alpha),
            Double(transform.a), Double(transform.b), Double(transform.c), Double(transform.d)]
        for (sample, point) in zip(samples, points) {
            signature += [Double(point.x - points[0].x), Double(point.y - points[0].y),
                Double(sample.size.width), Double(sample.size.height), Double(sample.opacity),
                Double(sample.force), Double(sample.azimuth), Double(sample.altitude), Double(sample.secondaryScale)]
        }
        var key = Data(stroke.ink.inkType.rawValue.utf8)
        signature.withUnsafeBytes { key.append(contentsOf: $0) }
        if let cached = cache.object(forKey: key as NSData) { return CGFloat(cached.doubleValue) }

        var distances = [CGFloat](repeating: 0, count: points.count)
        for index in 1..<points.count {
            distances[index] = distances[index - 1] + hypot(points[index].x - points[index - 1].x,
                                                           points[index].y - points[index - 1].y)
        }
        guard let length = distances.last, length > 0 else { return nil }
        let drawing = PKDrawing(strokes: [stroke])
        let transformScale = sqrt(transform.a * transform.a + transform.b * transform.b
            + transform.c * transform.c + transform.d * transform.d)
        let footprint = samples.map { max($0.size.width, $0.size.height) }.max() ?? 1
        let radius = min(128, max(8, footprint * transformScale * 2 + 4))
        var widths: [CGFloat] = []
        for fraction: CGFloat in [0.23, 0.47, 0.73] {
            let distance = length * fraction
            guard let index = (1..<points.count).first(where: { distances[$0] >= distance }),
                  distances[index] > distances[index - 1] else { continue }
            let a = points[index - 1], b = points[index]
            let t = (distance - distances[index - 1]) / (distances[index] - distances[index - 1])
            let center = CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y))
            let rotation = CGAffineTransform(translationX: -center.x, y: -center.y)
                .concatenating(CGAffineTransform(rotationAngle: -atan2(b.y - a.y, b.x - a.x)))
            let scale: CGFloat = 8
            let rect = CGRect(x: -2, y: -radius, width: 4, height: radius * 2)
            guard let image = drawing.transformed(using: rotation).image(from: rect, scale: scale).cgImage,
                  let width = crossSectionWidth(image, scale: scale, alpha: alpha) else { continue }
            widths.append(width)
        }
        guard !widths.isEmpty else { return nil }
        let result = max(0.001, widths.sorted()[widths.count / 2])
        cache.setObject(NSNumber(value: Double(result)), forKey: key as NSData, cost: key.count)
        return result
    }

    private static func crossSectionWidth(_ image: CGImage, scale: CGFloat, alpha: CGFloat) -> CGFloat? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        let columns = (width / 4)..<(width - width / 4)
        let coverage = (0..<height).map { y in
            columns.reduce(CGFloat.zero) { $0 + CGFloat(bytes[(y * width + $1) * 4 + 3]) / 255 }
                / CGFloat(columns.count) / alpha
        }
        // Ignore another edge of a small closed shape crossing the same crop.
        guard let center = coverage.indices.filter({ coverage[$0] > 0.005 })
            .min(by: { abs($0 - height / 2) < abs($1 - height / 2) }) else { return nil }
        var lower = center, upper = center
        while lower > 0, coverage[lower - 1] > 0.005 { lower -= 1 }
        while upper + 1 < height, coverage[upper + 1] > 0.005 { upper += 1 }
        guard lower > 0, upper + 1 < height else { return nil }
        return coverage[lower...upper].reduce(0, +) / scale
    }
}

enum CanvasHitGeometry {
    /// Styling a recognized stroke promotes its existing contour to an editable
    /// shape. Native handwriting remains untouched until the user saves a style.
    static func editableShape(from stroke: PKStroke) -> CanvasPageElement? {
        guard stroke.mask == nil,
              let fitted = HeldInkShapeRecognizer.recognize(stroke.path.map {
                  $0.location.applying(stroke.transform)
              }, minimumExtent: 8) else { return nil }
        let kind: PageShapeKind
        let points: [CGPoint]
        switch fitted.kind {
        case .line:
            kind = .line
            points = [stroke.path[0].location.applying(stroke.transform),
                      stroke.path[stroke.path.count - 1].location.applying(stroke.transform)]
        case .triangle:
            kind = .triangle
            points = editableVertices(in: stroke) ?? [fitted.points[0], fitted.points[12], fitted.points[24]]
        case .rectangle, .square:
            kind = .rectangle
            let samples = stroke.path.map { $0.location.applying(stroke.transform) }
            points = stride(from: 0, to: fitted.points.count - 1, by: 12).map { i in
                samples.min { hypot($0.x - fitted.points[i].x, $0.y - fitted.points[i].y)
                    < hypot($1.x - fitted.points[i].x, $1.y - fitted.points[i].y) } ?? fitted.points[i]
            }
        case .circle, .ellipse:
            kind = .ellipse
            points = stroke.path.map { $0.location.applying(stroke.transform) }
        }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        stroke.ink.color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let color = String(format: "#%02X%02X%02X%02X", Int((red * 255).rounded()),
                           Int((green * 255).rounded()), Int((blue * 255).rounded()), Int((alpha * 255).rounded()))
        guard let width = NativeInkWidth.measure(stroke) else { return nil }
        var element = CanvasPageElement(logicalBounds: stroke.renderBounds,
            payload: .shape(PageShapePayload(kind: kind, strokeColorHex: color, lineWidth: Double(width))))
        element.setShapeVertices(points)
        return element
    }

    static func editableVertices(in stroke: PKStroke) -> [CGPoint]? {
        guard stroke.mask == nil,
              let shape = HeldInkShapeRecognizer.recognize(
                stroke.path.map { $0.location.applying(stroke.transform) }, minimumExtent: 8) else { return nil }
        switch shape.kind {
        case .line:
            return [stroke.path[0].location.applying(stroke.transform),
                    stroke.path[stroke.path.count - 1].location.applying(stroke.transform)]
        case .triangle:
            // The fitter emits twelve samples per straight edge plus the closure.
            // Anchor each fitted corner to an actual knot. Refitting after a drag
            // must not nudge the two untouched corners or the closing knot.
            let samples = stroke.path.map { $0.location.applying(stroke.transform) }
            return stride(from: 0, to: shape.points.count - 1, by: 12).map { index in
                let corner = shape.points[index]
                return samples.min {
                    hypot($0.x - corner.x, $0.y - corner.y) < hypot($1.x - corner.x, $1.y - corner.y)
                } ?? corner
            }
        default: return nil
        }
    }

    /// Move locations along their original edge, preserving the native nib,
    /// pressure and transform. Scaling the entire PKStroke would thicken the ink.
    static func movingVertices(in stroke: PKStroke, from old: [CGPoint], to new: [CGPoint]) -> PKStroke {
        guard old.count >= 2, old.count == new.count else { return stroke }
        let edgeCount = old.count == 2 ? 1 : old.count
        let inverse = stroke.transform.inverted()
        let points = stroke.path.map { sample -> PKStrokePoint in
            let p = sample.location.applying(stroke.transform)
            var distance = CGFloat.infinity, delta = CGPoint.zero
            for i in 0..<edgeCount {
                let j = (i + 1) % old.count
                let dx = old[j].x - old[i].x, dy = old[j].y - old[i].y
                let lengthSquared = dx * dx + dy * dy
                let t = lengthSquared > 0 ? min(1, max(0, ((p.x - old[i].x) * dx + (p.y - old[i].y) * dy) / lengthSquared)) : 0
                let d = hypot(p.x - old[i].x - t * dx, p.y - old[i].y - t * dy)
                if d < distance {
                    distance = d
                    delta = CGPoint(x: (1 - t) * (new[i].x - old[i].x) + t * (new[j].x - old[j].x),
                                    y: (1 - t) * (new[i].y - old[i].y) + t * (new[j].y - old[j].y))
                }
            }
            let location = CGPoint(x: p.x + delta.x, y: p.y + delta.y).applying(inverse)
            return PKStrokePoint(location: location, timeOffset: sample.timeOffset, size: sample.size,
                                 opacity: sample.opacity, force: sample.force, azimuth: sample.azimuth,
                                 altitude: sample.altitude, secondaryScale: sample.secondaryScale, threshold: sample.threshold)
        }
        return PKStroke(ink: stroke.ink, path: PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate),
                        transform: stroke.transform, mask: stroke.mask, randomSeed: stroke.randomSeed)
    }

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

    static func visiblePoints(in stroke: PKStroke, spacing: CGFloat = 3) -> [[PKStrokePoint]] {
        guard !stroke.path.isEmpty else { return [] }
        let ranges = stroke.mask == nil
            ? [CGFloat(0)...CGFloat(stroke.path.count - 1)] : stroke.maskedPathRanges
        return ranges.map { Array(stroke.path.interpolatedPoints(in: $0, by: .distance(max(spacing, 0.1)))) }
    }

    /// Flatten the actual transformed outline for coverage tests. Treating a shape's bounding box
    /// or filled interior as its contour would erase an entire diagram when shading its centre.
    static func contours(in path: CGPath, spacing: CGFloat) -> [[CGPoint]] {
        var result: [[CGPoint]] = []
        var current: [CGPoint] = []
        func finish() {
            if !current.isEmpty { result.append(current) }
            current = []
        }
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                finish()
                current = [element.points[0]]
            case .addLineToPoint:
                current.append(element.points[0])
            case .addQuadCurveToPoint, .addCurveToPoint:
                guard let start = current.last else { return }
                let a = element.points[0]
                let b = element.points[1]
                let end = element.type == .addCurveToPoint ? element.points[2] : b
                let polygonLength = hypot(a.x - start.x, a.y - start.y)
                    + hypot(b.x - a.x, b.y - a.y) + hypot(end.x - b.x, end.y - b.y)
                let count = max(4, min(256, Int(ceil(polygonLength / max(spacing, 0.1)))))
                for index in 1...count {
                    let t = CGFloat(index) / CGFloat(count), u = 1 - t
                    if element.type == .addQuadCurveToPoint {
                        current.append(CGPoint(x: u * u * start.x + 2 * u * t * a.x + t * t * end.x,
                                               y: u * u * start.y + 2 * u * t * a.y + t * t * end.y))
                    } else {
                        current.append(CGPoint(x: u * u * u * start.x + 3 * u * u * t * a.x + 3 * u * t * t * b.x + t * t * t * end.x,
                                               y: u * u * u * start.y + 3 * u * u * t * a.y + 3 * u * t * t * b.y + t * t * t * end.y))
                    }
                }
            case .closeSubpath:
                if let first = current.first { current.append(first) }
                finish()
            @unknown default: break
            }
        }
        finish()
        return result
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
