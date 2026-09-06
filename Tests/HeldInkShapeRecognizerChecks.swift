import Foundation
import CoreGraphics

@main
struct HeldInkShapeRecognizerChecks {
    static func main() {
        var checks = 0
        func expect(_ name: String, _ kind: HeldInkShapeKind?, _ points: [CGPoint]) -> HeldInkShape? {
            let result = HeldInkShapeRecognizer.recognize(points)
            precondition(result?.kind == kind, "\(name): expected \(String(describing: kind)), got \(String(describing: result?.kind))")
            checks += 1
            return result
        }
        func curve(_ rx: CGFloat, _ ry: CGFloat, rotation: CGFloat = 0, turns: CGFloat = 1) -> [CGPoint] {
            (0...80).map { i in
                let t = CGFloat(i) / 80 * 2 * .pi * turns
                let jitter = 1 + 0.025 * sin(5 * t)
                let x = rx * cos(t) * jitter, y = ry * sin(t) * jitter
                return CGPoint(x: 200 + x * cos(rotation) - y * sin(rotation),
                               y: 180 + x * sin(rotation) + y * cos(rotation))
            }
        }
        func polygon(_ corners: [CGPoint]) -> [CGPoint] {
            corners.indices.flatMap { i in
                (0..<12).map { step in
                    let a = corners[i], b = corners[(i + 1) % corners.count]
                    let t = CGFloat(step) / 12
                    return CGPoint(x: a.x + (b.x - a.x) * t + sin(t * .pi * 3) * 1.5,
                                   y: a.y + (b.y - a.y) * t + sin(t * .pi * 4) * 1.5)
                }
            } + [corners[0]]
        }
        let roughLine = (0...30).map { CGPoint(x: CGFloat($0) * 10, y: 50 + sin(CGFloat($0) / 30 * .pi * 3) * 3) }
        let line = expect("rough horizontal", .line, roughLine)!
        precondition(abs(line.points[0].y - line.points[1].y) < 0.001)
        let circle = expect("rough circle", .circle, curve(70, 70))!
        let center = CGPoint(x: (circle.points.map(\.x).max()! + circle.points.map(\.x).min()!) / 2,
                             y: (circle.points.map(\.y).max()! + circle.points.map(\.y).min()!) / 2)
        let radii = circle.points.map { hypot($0.x - center.x, $0.y - center.y) }
        precondition(radii.max()! - radii.min()! < 0.1)
        _ = expect("ellipse", .ellipse, curve(110, 50))
        _ = expect("rotated ellipse", .ellipse, curve(110, 50, rotation: .pi / 5))
        let square = polygon([CGPoint(x: 10, y: 10), CGPoint(x: 130, y: 12), CGPoint(x: 129, y: 132), CGPoint(x: 11, y: 130)])
        let fittedSquare = expect("rough square", .square, square)!
        let sides = stride(from: 0, to: 48, by: 12).map { i in
            hypot(fittedSquare.points[i + 12].x - fittedSquare.points[i].x,
                  fittedSquare.points[i + 12].y - fittedSquare.points[i].y)
        }
        precondition(sides.max()! - sides.min()! < 0.001)
        _ = expect("rectangle", .rectangle, polygon([CGPoint(x: 0, y: 0), CGPoint(x: 220, y: 0), CGPoint(x: 220, y: 95), CGPoint(x: 0, y: 95)]))
        _ = expect("triangle", .triangle, polygon([CGPoint(x: 90, y: 0), CGPoint(x: 190, y: 150), CGPoint(x: 0, y: 150)]))
        for factor: CGFloat in [0.5, 3] {
            _ = expect("scaled translated circle", .circle, curve(70, 70).map { CGPoint(x: $0.x * factor - 6000, y: $0.y * factor - 4000) })
            _ = expect("scaled square", .square, square.map { CGPoint(x: $0.x * factor, y: $0.y * factor) })
        }
        _ = expect("dot", nil, [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)])
        _ = expect("open C", nil, curve(70, 70, turns: 0.72))
        _ = expect("double loop", nil, curve(70, 70, turns: 2))
        _ = expect("zigzag", nil, [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 20, y: 80), CGPoint(x: 140, y: 20), CGPoint(x: 60, y: 130)])
        _ = expect("out and back", nil, roughLine + roughLine.reversed())
        _ = expect("nonfinite", nil, [CGPoint(x: 0, y: 0), CGPoint(x: CGFloat.infinity, y: 0)])
        print("Held ink geometry: \(checks) checks passed")
    }
}
