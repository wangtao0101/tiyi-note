import CoreGraphics
import Foundation

/// A single contact with repeated back-and-forth sweeps or overlapping loops. Uses screen points,
/// while targets stay in stable page/world coordinates (including negative canvas coordinates).
/// This deliberately does not join separate strokes or infer words using handwriting recognition.
struct ScribbleEraseGesture {
    let bounds: CGRect
    private let origin: CGPoint
    private let displayScale: CGFloat
    private let sweepAreas: [CGPath]
    private let nearbySweepAreas: [CGPath]
    private let footprint: CGPath
    private let footprintEdge: CGPath

    fileprivate init(points: [CGPoint], passes: [ClosedRange<Int>], origin: CGPoint, displayScale: CGFloat) {
        self.origin = origin
        self.displayScale = displayScale
        let extent = ScribbleEraseRecognizer.bounds(passes.flatMap { Array(points[$0]) })
        let radius = max(6, min(14, hypot(extent.width, extent.height) * 0.065))
        let paths = passes.map { range -> CGPath in
            let path = CGMutablePath()
            path.addLines(between: Array(points[range]))
            return path
        }
        sweepAreas = paths.map { $0.copy(strokingWithWidth: radius * 2, lineCap: .round, lineJoin: .round, miterLimit: 10) }
        nearbySweepAreas = paths.map { $0.copy(strokingWithWidth: radius * 4, lineCap: .round, lineJoin: .round, miterLimit: 10) }
        footprint = ScribbleEraseRecognizer.footprint(passes.flatMap { Array(points[$0]) })
        footprintEdge = footprint.copy(strokingWithWidth: radius * 1.3, lineCap: .round, lineJoin: .round, miterLimit: 10)
        let padded = extent.insetBy(dx: -radius, dy: -radius)
        bounds = CGRect(x: origin.x + padded.minX / displayScale,
                        y: origin.y + padded.minY / displayScale,
                        width: padded.width / displayScale, height: padded.height / displayScale)
    }

    /// Length-weighted coverage of visible contours, never their bounding rectangle or interior.
    /// Requiring two different passes protects content merely crossed on the way to the scribble.
    func covers(_ contours: [[CGPoint]], minimumCoverage: CGFloat = 0.58) -> Bool {
        covers(contours, minimumCoverage: minimumCoverage, accepts: repeatedlyCovers)
    }

    /// A recognized scribble can sweep a glyph's top/bottom strokes only once.
    /// Count those sweeps when they belong to the local repeated motion, retaining the
    /// length threshold so crossing one small part of a long stroke never deletes it all.
    func coversHandwriting(_ contours: [[CGPoint]]) -> Bool {
        covers(contours, minimumCoverage: 0.58) { point in
            if repeatedlyCovers(point) { return true }
            guard footprint.contains(point) || footprintEdge.contains(point),
                  sweepAreas.contains(where: { $0.contains(point) }) else { return false }
            return nearbySweepAreas.lazy.filter { $0.contains(point) }.prefix(2).count == 2
        }
    }

    private func covers(_ contours: [[CGPoint]], minimumCoverage: CGFloat, accepts: (CGPoint) -> Bool) -> Bool {
        var covered: CGFloat = 0
        var total: CGFloat = 0
        for contour in contours where !contour.isEmpty {
            guard contour.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
            let points = contour.map { CGPoint(x: ($0.x - origin.x) * displayScale,
                                               y: ($0.y - origin.y) * displayScale) }
            if points.count == 1 {
                total += 1
                if accepts(points[0]) { covered += 1 }
            }
            for (start, end) in zip(points, points.dropFirst()) {
                let length = hypot(end.x - start.x, end.y - start.y)
                if length < 0.001 { continue }
                let count = max(1, min(512, Int(ceil(length / 3))))
                let weight = length / CGFloat(count)
                for index in 0..<count {
                    let t = (CGFloat(index) + 0.5) / CGFloat(count)
                    let point = CGPoint(x: start.x + (end.x - start.x) * t,
                                        y: start.y + (end.y - start.y) * t)
                    if accepts(point) { covered += weight }
                }
                total += length
            }
            // PencilKit dots can have multiple samples at the very same position.
            if points.count > 1, points.dropFirst().allSatisfy({ $0 == points[0] }) {
                total += 1
                if accepts(points[0]) { covered += 1 }
            }
        }
        return total > 0 && covered / total >= minimumCoverage
    }

    private func repeatedlyCovers(_ point: CGPoint) -> Bool {
        var hits = 0
        for area in sweepAreas where area.contains(point) {
            hits += 1
            if hits == 2 { return true }
        }
        return false
    }
}

enum ScribbleEraseRecognizer {
    static func recognize(_ input: [CGPoint], displayScale: CGFloat) -> ScribbleEraseGesture? {
        guard input.count >= 5, displayScale.isFinite, displayScale > 0,
              input.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), let origin = input.first else { return nil }
        var points: [CGPoint] = []
        for point in input {
            let screen = CGPoint(x: (point.x - origin.x) * displayScale,
                                 y: (point.y - origin.y) * displayScale)
            if let last = points.last, hypot(screen.x - last.x, screen.y - last.y) < 1 { continue }
            points.append(screen)
        }
        guard points.count >= 5 else { return nil }
        let extent = bounds(points)
        let span = hypot(extent.width, extent.height)
        let length = zip(points, points.dropFirst()).reduce(CGFloat.zero) {
            $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)
        }
        guard span >= 16, length >= span * 3 else { return nil }

        // Real Pencil scribbles often fill a small area with uneven circles. Split repeated
        // rotations into separate passes so merely circling around content never fills the
        // interior of the erase area. Circular motion needs more repetitions than directional sweeps.
        if length >= span * 5.5, let passes = loopPasses(points, around: CGPoint(x: extent.midX, y: extent.midY)) {
            return ScribbleEraseGesture(points: points, passes: passes, origin: origin, displayScale: displayScale)
        }

        // Try orientations instead of favouring horizontal motion. Projection hysteresis ignores
        // jitter. Sweeps must reverse along the dominant extent, not progress like writing WWW.
        for orientation in 0..<18 {
            let angle = CGFloat(orientation) * .pi / 18
            let projections = points.map { $0.x * cos(angle) + $0.y * sin(angle) }
            let range = (projections.max() ?? 0) - (projections.min() ?? 0)
            guard range >= max(16, span * 0.70) else { continue }
            let excursion = max(6, range * 0.42)
            var corners = [0]
            var direction = 0
            var extreme = 0
            for index in 1..<points.count {
                let delta = projections[index] - projections[extreme]
                if direction == 0 {
                    if abs(delta) >= excursion { direction = delta > 0 ? 1 : -1; extreme = index }
                } else if delta * CGFloat(direction) >= 0 {
                    extreme = index
                } else if abs(delta) >= excursion {
                    corners.append(extreme)
                    direction = -direction
                    extreme = index
                }
            }
            if abs(projections[points.count - 1] - projections[corners.last!]) >= excursion {
                corners.append(points.count - 1)
            }
            guard corners.count >= 5 else { continue }
            var vectors: [CGVector] = []
            var passes: [ClosedRange<Int>] = []
            var totalChord: CGFloat = 0
            var totalRunLength: CGFloat = 0
            var directPassCount = 0
            for (start, end) in zip(corners, corners.dropFirst()) {
                let a = points[start], b = points[end]
                let chord = hypot(b.x - a.x, b.y - a.y)
                var runLength: CGFloat = 0
                for index in start..<end {
                    let previous = points[index], next = points[index + 1]
                    runLength += hypot(next.x - previous.x, next.y - previous.y)
                }
                // A curved entry/exit should not veto the repeated motion in the middle.
                if chord < excursion || runLength > chord * 1.8 {
                    if passes.count >= 4 { break }
                    passes.removeAll(); vectors.removeAll()
                    totalChord = 0; totalRunLength = 0
                    directPassCount = 0
                    continue
                }
                passes.append(start...end)
                totalChord += chord
                totalRunLength += runLength
                if runLength <= chord * 1.5 { directPassCount += 1 }
                vectors.append(CGVector(dx: (b.x - a.x) / chord, dy: (b.y - a.y) / chord))
            }
            let reversals = zip(vectors, vectors.dropFirst()).filter {
                $0.dx * $1.dx + $0.dy * $1.dy < -0.25
            }.count
            guard passes.count >= 4, totalRunLength <= totalChord * 1.45,
                  directPassCount >= Int(ceil(CGFloat(passes.count) * 0.75)),
                  reversals >= max(3, Int(ceil(CGFloat(vectors.count - 1) * 0.75))) else { continue }
            return ScribbleEraseGesture(points: points, passes: passes, origin: origin, displayScale: displayScale)
        }
        return nil
    }

    private static func loopPasses(_ points: [CGPoint], around center: CGPoint) -> [ClosedRange<Int>]? {
        let angles = points.map { atan2($0.y - center.y, $0.x - center.x) }
        let turns = zip(angles, angles.dropFirst()).map { previous, next in
            atan2(sin(next - previous), cos(next - previous))
        }
        let rotation = turns.reduce(CGFloat.zero, +)
        let travel = turns.reduce(CGFloat.zero) { $0 + abs($1) }
        guard abs(rotation) >= 4.8 * .pi, abs(rotation) >= travel * 0.65 else { return nil }
        let direction: CGFloat = rotation > 0 ? 1 : -1
        var progress: CGFloat = 0
        var nextLoop: CGFloat = 2 * .pi
        var start = 0
        var passes: [ClosedRange<Int>] = []
        for (index, turn) in turns.enumerated() {
            progress += turn * direction
            if progress >= nextLoop {
                passes.append(start...(index + 1))
                start = index + 1
                nextLoop += 2 * .pi
            }
        }
        if start < points.count - 1 { passes.append(start...(points.count - 1)) }
        return passes.count >= 3 ? passes : nil
    }

    /// Convex envelope only limits edge tolerance; it never fills an untouched interior.
    /// Actual sweep contact and a second nearby pass are still required for every sample.
    fileprivate static func footprint(_ input: [CGPoint]) -> CGPath {
        let sorted = input.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        var points: [CGPoint] = []
        for point in sorted where points.last != point { points.append(point) }
        func half(_ points: [CGPoint]) -> [CGPoint] {
            var hull: [CGPoint] = []
            for point in points {
                while hull.count >= 2 {
                    let a = hull[hull.count - 2], b = hull[hull.count - 1]
                    let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
                    if cross > 0 { break }
                    hull.removeLast()
                }
                hull.append(point)
            }
            return hull
        }
        let vertices = Array(half(points).dropLast()) + half(points.reversed()).dropLast()
        let path = CGMutablePath()
        path.addLines(between: vertices)
        path.closeSubpath()
        return path
    }

    fileprivate static func bounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); minY = min(minY, point.y)
            maxX = max(maxX, point.x); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
