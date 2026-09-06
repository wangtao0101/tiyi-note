import Foundation
import CoreGraphics

enum HeldInkShapeKind: String, Sendable {
    case line, circle, ellipse, square, rectangle, triangle

    var title: String {
        switch self {
        case .line: "直线"
        case .circle: "圆形"
        case .ellipse: "椭圆"
        case .square: "正方形"
        case .rectangle: "矩形"
        case .triangle: "三角形"
        }
    }
}

struct HeldInkShape: Sendable {
    let kind: HeldInkShapeKind
    let points: [CGPoint]
}

/// Fits only the current contact. Uniform arc-length samples keep writing speed and a stationary
/// tail from biasing the fit. All error thresholds are relative to the contour's size.
enum HeldInkShapeRecognizer {
    static func recognize(_ input: [CGPoint], minimumExtent: CGFloat = 24) -> HeldInkShape? {
        guard input.count >= 2, input.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let bounds = bounds(of: input)
        let span = hypot(bounds.width, bounds.height)
        guard span >= minimumExtent else { return nil }
        let points = resample(input, count: 128)
        guard points.count >= 2 else { return nil }
        let length = pathLength(points)
        let first = points[0], last = points[points.count - 1]
        let chord = distance(first, last)

        if chord > span * 0.8, length < chord * 1.18 {
            let errors = points.map { segmentDistance($0, first, last) }
            if rms(errors) < span * 0.022, (errors.max() ?? span) < span * 0.055 {
                let center = mean(points)
                let angle = principalAngle(points, center: center)
                var axis = CGPoint(x: cos(angle), y: sin(angle))
                let alignment = sin(CGFloat.pi / 36) // Five degrees from a horizontal/vertical line.
                if abs(axis.y) < alignment { axis = CGPoint(x: 1, y: 0) }
                if abs(axis.x) < alignment { axis = CGPoint(x: 0, y: 1) }
                let a = dot(subtract(first, center), axis)
                let b = dot(subtract(last, center), axis)
                return HeldInkShape(kind: .line, points: [add(center, scale(axis, a)), add(center, scale(axis, b))])
            }
        }

        // A letter C, a retraced line, or an unfinished corner is not a closed shape.
        guard bounds.width > minimumExtent * 0.25, bounds.height > minimumExtent * 0.25,
              chord < span * 0.16, length > span * 1.65, length < span * 3.5 else { return nil }
        var closed = points
        closed[closed.count - 1] = closed[0]
        var vertices = simplify(closed, tolerance: span * 0.035)
        vertices.removeLast()
        var changed = true
        while changed, vertices.count > 3 {
            changed = false
            for index in vertices.indices {
                let before = vertices[(index + vertices.count - 1) % vertices.count]
                let after = vertices[(index + 1) % vertices.count]
                if segmentDistance(vertices[index], before, after) < span * 0.035 {
                    vertices.remove(at: index)
                    changed = true
                    break
                }
            }
        }
        let polygonLength = pathLength(vertices + vertices.prefix(1))
        let followsPolygon = length < polygonLength * 1.12
            && points.allSatisfy { point in
                (vertices.indices.map { segmentDistance(point, vertices[$0], vertices[($0 + 1) % vertices.count]) }
                    .min() ?? span) < span * 0.05
            }
        if vertices.count == 3, followsPolygon,
           polygonArea(vertices) > span * span * 0.12 {
            return HeldInkShape(kind: .triangle, points: polygonPoints(vertices))
        }
        if vertices.count == 4, followsPolygon, isRectangle(vertices) {
            let angles = vertices.indices.map { index in
                let edge = subtract(vertices[(index + 1) % 4], vertices[index])
                return atan2(edge.y, edge.x)
            }
            var angle = atan2(angles.map { sin(4 * $0) }.reduce(0, +),
                              angles.map { cos(4 * $0) }.reduce(0, +)) / 4
            if abs(angle) < .pi / 36 { angle = 0 }
            let box = orientedBounds(points, angle: angle)
            let ratio = box.radiusX / box.radiusY
            let isSquare = ratio > 0.80 && ratio < 1.25
            let radiusX = isSquare ? (box.radiusX + box.radiusY) / 2 : box.radiusX
            let radiusY = isSquare ? radiusX : box.radiusY
            let corners = [CGPoint(x: -radiusX, y: -radiusY), CGPoint(x: radiusX, y: -radiusY),
                           CGPoint(x: radiusX, y: radiusY), CGPoint(x: -radiusX, y: radiusY)]
                .map { transform($0, center: box.center, angle: angle) }
            return HeldInkShape(kind: isSquare ? .square : .rectangle, points: polygonPoints(corners))
        }

        let angle = principalAngle(points, center: mean(points))
        let box = orientedBounds(points, angle: angle)
        guard min(box.radiusX, box.radiusY) > span * 0.08 else { return nil }
        let ratio = box.radiusX / box.radiusY
        let isCircle = ratio > 0.86 && ratio < 1.16
        let radius = points.map { distance($0, box.center) }.reduce(0, +) / CGFloat(points.count)
        let radiusX = isCircle ? radius : box.radiusX
        let radiusY = isCircle ? radius : box.radiusY
        let radialErrors = points.map { point in
            let local = rotate(subtract(point, box.center), angle: -angle)
            return abs(hypot(local.x / radiusX, local.y / radiusY) - 1)
        }
        let circumference = .pi * (3 * (radiusX + radiusY)
            - sqrt((3 * radiusX + radiusY) * (radiusX + 3 * radiusY)))
        guard rms(radialErrors) < 0.085, (radialErrors.max() ?? 1) < 0.22,
              length > circumference * 0.83, length < circumference * 1.14 else { return nil }
        let curve = (0...96).map { index in
            let theta = CGFloat(index) / 96 * 2 * .pi
            return transform(CGPoint(x: cos(theta) * radiusX, y: sin(theta) * radiusY),
                             center: box.center, angle: angle)
        }
        return HeldInkShape(kind: isCircle ? .circle : .ellipse, points: curve)
    }

    private static func resample(_ input: [CGPoint], count: Int) -> [CGPoint] {
        let length = pathLength(input)
        guard length > 0 else { return [] }
        let step = length / CGFloat(count - 1)
        var output = [input[0]], travelled: CGFloat = 0, nextDistance = step
        for index in 1..<input.count {
            let a = input[index - 1], b = input[index], segmentLength = distance(a, b)
            guard segmentLength > 0 else { continue }
            while nextDistance <= travelled + segmentLength, output.count < count - 1 {
                output.append(add(a, scale(subtract(b, a), (nextDistance - travelled) / segmentLength)))
                nextDistance += step
            }
            travelled += segmentLength
        }
        output.append(input[input.count - 1])
        return output
    }

    private static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let first = points[0], last = points[points.count - 1]
        let farthest = (1..<points.count - 1).max {
            segmentDistance(points[$0], first, last) < segmentDistance(points[$1], first, last)
        }!
        guard segmentDistance(points[farthest], first, last) > tolerance else { return [first, last] }
        return Array(simplify(Array(points[...farthest]), tolerance: tolerance).dropLast())
            + simplify(Array(points[farthest...]), tolerance: tolerance)
    }

    private static func isRectangle(_ vertices: [CGPoint]) -> Bool {
        vertices.indices.allSatisfy { index in
            let a = subtract(vertices[(index + 3) % 4], vertices[index])
            let b = subtract(vertices[(index + 1) % 4], vertices[index])
            return abs(dot(a, b)) / max(hypot(a.x, a.y) * hypot(b.x, b.y), 0.001) < 0.33
        }
    }

    private static func polygonPoints(_ vertices: [CGPoint]) -> [CGPoint] {
        vertices.indices.flatMap { index in
            (0..<12).map { sample in
                add(vertices[index], scale(subtract(vertices[(index + 1) % vertices.count], vertices[index]), CGFloat(sample) / 12))
            }
        } + vertices.prefix(1)
    }

    private static func polygonArea(_ points: [CGPoint]) -> CGFloat {
        abs(points.indices.reduce(0) { sum, i in
            let next = points[(i + 1) % points.count]
            return sum + points[i].x * next.y - next.x * points[i].y
        }) / 2
    }

    private static func orientedBounds(_ points: [CGPoint], angle: CGFloat) -> (center: CGPoint, radiusX: CGFloat, radiusY: CGFloat) {
        let rect = bounds(of: points.map { rotate($0, angle: -angle) })
        return (rotate(CGPoint(x: rect.midX, y: rect.midY), angle: angle), rect.width / 2, rect.height / 2)
    }

    private static func principalAngle(_ points: [CGPoint], center: CGPoint) -> CGFloat {
        let sums = points.reduce(into: (xx: CGFloat.zero, xy: CGFloat.zero, yy: CGFloat.zero)) { sums, point in
            let delta = subtract(point, center)
            sums.xx += delta.x * delta.x
            sums.xy += delta.x * delta.y
            sums.yy += delta.y * delta.y
        }
        return atan2(2 * sums.xy, sums.xx - sums.yy) / 2
    }

    private static func bounds(of points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
    private static func mean(_ points: [CGPoint]) -> CGPoint {
        scale(points.reduce(.zero, add), 1 / CGFloat(points.count))
    }
    private static func rms(_ values: [CGFloat]) -> CGFloat { sqrt(values.map { $0 * $0 }.reduce(0, +) / CGFloat(values.count)) }
    private static func pathLength(_ points: [CGPoint]) -> CGFloat { zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) } }
    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private static func add(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    private static func subtract(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    private static func scale(_ a: CGPoint, _ value: CGFloat) -> CGPoint { CGPoint(x: a.x * value, y: a.y * value) }
    private static func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.x + a.y * b.y }
    private static func rotate(_ point: CGPoint, angle: CGFloat) -> CGPoint {
        CGPoint(x: point.x * cos(angle) - point.y * sin(angle), y: point.x * sin(angle) + point.y * cos(angle))
    }
    private static func transform(_ point: CGPoint, center: CGPoint, angle: CGFloat) -> CGPoint { add(center, rotate(point, angle: angle)) }
    private static func segmentDistance(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let edge = subtract(b, a)
        let amount = min(1, max(0, dot(subtract(point, a), edge) / max(dot(edge, edge), 0.00001)))
        return distance(point, add(a, scale(edge, amount)))
    }
}
