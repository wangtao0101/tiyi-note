import CoreGraphics
import Foundation

@main
struct ScribbleEraseRecognizerChecks {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name)
            checks += 1
        }
        let scribble = (0...7).map { CGPoint(x: $0.isMultiple(of: 2) ? 0 : 140, y: CGFloat($0) * 4 - 12) }
        let letter = [CGPoint(x: 60, y: -8), CGPoint(x: 74, y: 8), CGPoint(x: 80, y: -8)]
        let axis = [CGPoint(x: -500, y: 0), CGPoint(x: 600, y: 0)]
        for zoom: CGFloat in [0.1, 0.25, 1, 3, 8] {
            for angle: CGFloat in [0, .pi / 6, .pi / 2, .pi * 0.83] {
                func world(_ points: [CGPoint]) -> [CGPoint] {
                    points.map { CGPoint(x: ($0.x * cos(angle) - $0.y * sin(angle)) / zoom - 12000,
                                         y: ($0.x * sin(angle) + $0.y * cos(angle)) / zoom - 8000) }
                }
                let result = ScribbleEraseRecognizer.recognize(world(scribble), displayScale: zoom)
                check(result != nil, "recognize rotated scratch at \(zoom)")
                check(result?.covers([world(letter)]) == true, "erase covered handwriting at \(zoom)")
                check(result?.covers([world(axis)]) == false, "protect long crossed axis at \(zoom)")
                check(result?.covers([world([CGPoint(x: 70, y: 0)])]) == true, "erase covered dot")
                check(result?.covers([world([CGPoint(x: 5, y: -20)])]) == false, "a bounding box is not an erase area")
                let partial = [CGPoint(x: 20, y: 2), CGPoint(x: 90, y: 2), CGPoint(x: 90, y: 150)]
                check(result?.covers([world(partial)], minimumCoverage: 0.70) == false, "protect mostly uncovered shape")
            }
        }
        let line = (0...40).map { CGPoint(x: CGFloat($0) * 4, y: sin(CGFloat($0)) * 1.2) }
        let circle = (0...120).map { i in
            let t = CGFloat(i) / 120 * .pi * 2
            return CGPoint(x: 60 * cos(t), y: 60 * sin(t))
        }
        let repeatedCircle = (0...240).map { i in
            let t = CGFloat(i) / 240 * .pi * 8
            return CGPoint(x: 60 * cos(t), y: 60 * sin(t))
        }
        let sine = (0...240).map { i in
            let t = CGFloat(i) / 240
            return CGPoint(x: 240 * t, y: 35 * sin(t * .pi * 8))
        }
        let rejects: [(String, [CGPoint])] = [
            ("ordinary line", line), ("retraced underline", line + line.reversed()),
            ("single circle", circle), ("twice traced circle", circle + circle), ("sine graph", sine),
            ("letter w", [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 35), CGPoint(x: 20, y: 10), CGPoint(x: 30, y: 35), CGPoint(x: 40, y: 0)]),
            ("tiny pen jitter", scribble.map { CGPoint(x: $0.x * 0.06, y: $0.y * 0.06) }),
            ("one crossing", [CGPoint(x: -50, y: 0), CGPoint(x: 150, y: 0)]),
            ("invalid coordinate", scribble + [CGPoint(x: CGFloat.infinity, y: 0)])
        ]
        for (name, points) in rejects {
            check(ScribbleEraseRecognizer.recognize(points, displayScale: 1) == nil, "reject \(name)")
        }
        let loop = ScribbleEraseRecognizer.recognize(repeatedCircle, displayScale: 1)
        check(loop != nil, "repeated circular scribbling is an erase gesture")
        check(loop?.covers([circle]) == true, "erase ink repeatedly covered by circular scribbling")
        check(loop?.covers([[CGPoint(x: -10, y: 0), CGPoint(x: 10, y: 0)]]) == false,
              "circling around untouched ink must not erase the interior")
        let rounded = (0...96).map { i in
            let t = CGFloat(i) / 96
            return CGPoint(x: 50 * cos(t * .pi * 4), y: 8 * sin(t * .pi * 4) + t * 6)
        }
        check(ScribbleEraseRecognizer.recognize(rounded, displayScale: 1) != nil,
              "two rounded back-and-forth motions should work")
        let uneven = [CGPoint(x: 0, y: 0), CGPoint(x: 48, y: 4), CGPoint(x: 5, y: 9),
                      CGPoint(x: 42, y: 7), CGPoint(x: 1, y: 15)]
        check(ScribbleEraseRecognizer.recognize(uneven, displayScale: 1) != nil,
              "short uneven scratch without six perfect traversals")
        let repeatedW = (0...8).map { CGPoint(x: CGFloat($0) * 10, y: $0.isMultiple(of: 2) ? 0 : 35) }
        check(ScribbleEraseRecognizer.recognize(repeatedW, displayScale: 1) == nil,
              "writing WW across the page is not a scribble")

        // Only normalized erase gestures, with no document content, identifiers or timestamps.
        // Captured Pencil strokes reproduce the small rounded motion rejected by the first version.
        struct PencilSample: Decodable { let name: String; let points: [[Double]] }
        let samplesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ScribbleErasePencilSamples.json")
        let samples = try JSONDecoder().decode([PencilSample].self, from: Data(contentsOf: samplesURL))
        for sample in samples {
            for zoom: CGFloat in [0.1, 0.25, 1, 3, 8] {
                for angle: CGFloat in [0, .pi / 6, .pi / 2, .pi * 0.83] {
                    let points = sample.points.map { pair in
                        CGPoint(x: (pair[0] * cos(angle) - pair[1] * sin(angle)) / zoom - 12000,
                                y: (pair[0] * sin(angle) + pair[1] * cos(angle)) / zoom - 8000)
                    }
                    check(ScribbleEraseRecognizer.recognize(points, displayScale: zoom) != nil,
                          "\(sample.name) at \(zoom), rotated \(angle)")
                }
            }
        }
        check(ScribbleEraseRecognizer.recognize(scribble, displayScale: 0) == nil, "reject invalid scale")
        let gesture = ScribbleEraseRecognizer.recognize(scribble, displayScale: 1)!
        check(!gesture.covers([]), "empty content must retain ordinary ink")
        // A precision-erased stroke contributes only its surviving contours, not the gap between.
        check(!gesture.covers([[CGPoint(x: -30, y: 0), CGPoint(x: -20, y: 0)],
                               [CGPoint(x: 170, y: 0), CGPoint(x: 180, y: 0)]]), "protect masked gap")
        print("Scribble recognition and target coverage: \(checks) checks passed")
    }
}
