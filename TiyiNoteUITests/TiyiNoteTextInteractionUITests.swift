import XCTest
import ObjectiveC
import UIKit

final class TiyiNoteTextInteractionUITests: XCTestCase {
    func testHeldInkPreservesSelectedInkStyle() throws {
        let app = launchIsolatedApp(prefix: "shape-hold-style")
        let canvas = app.descendants(matching: .any)["page-canvas-0"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        func style() throws -> [String] {
            let value = try XCTUnwrap(canvas.value as? String)
            let field = try XCTUnwrap(value.components(separatedBy: "；").first { $0.hasPrefix("墨迹 ") })
            let parts = String(field.dropFirst(3)).components(separatedBy: ",")
            XCTAssertEqual(parts.count, 8)
            return parts
        }
        let variants = [("pen", "com.apple.ink.monoline"),
                        ("fountainPen", "com.apple.ink.fountainpen"),
                        ("pencil", "com.apple.ink.pencil"), ("marker", "com.apple.ink.marker")]
        var finalStyle: [String] = []
        for (variant, inkType) in variants {
            for preset in variant == "marker" ? [0] : [0, 1, 2] {
                if variant == "marker" { app.buttons["tool-marker"].tap() }
                else {
                    app.buttons["tool-pen"].tap()
                    app.buttons["pen-variant-\(variant)"].tap()
                    app.buttons["ink-width-preset-\(preset)"].tap()
                }
                app.buttons[preset == 1 ? "ink-color-coral" : "ink-color-ocean"].tap()
                var native: [String] = []
                for held in [false, true] {
                    let frame = canvas.frame
                    let y = frame.minY + frame.height * (held ? 0.5 : 0.3)
                    let points = (0...12).map { i in
                        CGPoint(x: frame.minX + frame.width * (0.25 + CGFloat(i) / 12 * 0.45), y: y)
                    }
                    try synthesizeTouchPath(points, on: canvas, in: app, holdBeforeLift: held ? 1.15 : 0.04)
                    waitForValue("笔迹 \(held ? 2 : 1)", of: canvas)
                    let actual = try style()
                    XCTAssertEqual(actual[0], inkType)
                    if !held { native = actual; continue }
                    waitForValueContaining("吸附 直线", of: canvas)
                    // Compare real PencilKit freehand and held strokes at the same settings.
                    // The old implementation changed the steel nib, scaled point sizes, and
                    // replaced the pencil's native opacity with 1.
                    XCTAssertEqual(Array(actual.prefix(5)), Array(native.prefix(5)), "\(variant) color/type")
                    for index in 5...7 {
                        XCTAssertEqual(try XCTUnwrap(Double(actual[index])),
                                       try XCTUnwrap(Double(native[index])), accuracy: 0.05,
                                       "\(variant) preset \(preset), nib component \(index)")
                    }
                    finalStyle = actual
                    if preset == 0 {
                        let image = XCTAttachment(screenshot: canvas.screenshot())
                        image.name = "\(variant): native above, straightened below"
                        image.lifetime = .keepAlways
                        add(image)
                    }
                }
                if variant != "marker" {
                    app.buttons["撤销"].tap()
                    waitForValue("笔迹 1", of: canvas)
                    app.buttons["撤销"].tap()
                    waitForValue("笔迹 0", of: canvas)
                }
            }
        }
        app.buttons["home-button"].tap()
        app.terminate()
        app.launchArguments.append("--reuse-text-interaction-ui-test-workspace")
        app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 8))
        waitForValue("笔迹 2", of: canvas)
        XCTAssertEqual(try style(), finalStyle, "Saved held ink must retain its appearance")
    }

    func testRecordedRoundedPencilScribblesEraseAndPersistInNoteAndPractice() throws {
        struct PencilSample: Decodable { let name: String; let points: [[Double]] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ScribbleErasePencilSamples", withExtension: "json"))
        let samples = try JSONDecoder().decode([PencilSample].self, from: Data(contentsOf: url))
        for prefix in ["scribble-rounded-pencil", "practice-sidebar-scribble-rounded-pencil"] {
            let app = launchIsolatedApp(prefix: prefix)
            let canvas = app.descendants(matching: .any)["page-canvas-0"]
            XCTAssertTrue(canvas.waitForExistence(timeout: 5))
            // Default-enabled, with the same compact looping strokes which failed on the iPad.
            let center = CGPoint(x: canvas.frame.midX, y: canvas.frame.minY + canvas.frame.height * 0.3)
            let word = [CGPoint(x: center.x - 8, y: center.y - 5),
                        CGPoint(x: center.x, y: center.y + 5), CGPoint(x: center.x + 8, y: center.y - 5)]
            for sample in [samples[4], samples[7]] {
                try synthesizeTouchPath(word, on: canvas, in: app, holdBeforeLift: 0.04)
                waitForValue("笔迹 1", of: canvas)
                let originalGeometry = drawingGeometryValue(of: canvas)
                let maxX = sample.points.map { $0[0] }.max()!
                let maxY = sample.points.map { $0[1] }.max()!
                let scratch = sample.points.enumerated().map { index, pair in
                    (point: CGPoint(x: center.x + (pair[0] - maxX / 2) * 0.65,
                                    y: center.y + (pair[1] - maxY / 2) * 0.65),
                     offset: Double(index) / Double(sample.points.count - 1) * 1.2)
                }
                try synthesizeTouchPaths([SynthesizedTouchPath(samples: scratch, liftOffset: 1.24)], on: canvas, in: app)
                waitForValue("笔迹 0", of: canvas)
                app.buttons["撤销"].tap()
                waitForValue("笔迹 1", of: canvas)
                XCTAssertEqual(drawingGeometryValue(of: canvas), originalGeometry, sample.name)
                app.buttons["重做"].tap()
                waitForValue("笔迹 0", of: canvas)
            }
            // A single oval over old ink is still an ordinary drawing, even when the paths touch.
            try synthesizeTouchPath(word, on: canvas, in: app, holdBeforeLift: 0.04)
            waitForValue("笔迹 1", of: canvas)
            let circle = (0...48).map { index in
                let angle = CGFloat(index) / 48 * .pi * 2
                return (point: CGPoint(x: center.x + 14 * cos(angle), y: center.y + 10 * sin(angle)),
                        offset: Double(index) / 48 * 0.6)
            }
            try synthesizeTouchPaths([SynthesizedTouchPath(samples: circle, liftOffset: 0.64)], on: canvas, in: app)
            waitForValue("笔迹 2", of: canvas)
            let geometry = drawingGeometryValue(of: canvas)
            app.buttons[prefix.hasPrefix("practice") ? "practice-exit" : "home-button"].tap()
            app.terminate()
            app.launchArguments.append("--reuse-text-interaction-ui-test-workspace")
            app.launch()
            XCTAssertTrue(canvas.waitForExistence(timeout: 5))
            waitForValue("笔迹 2", of: canvas)
            XCTAssertEqual(drawingGeometryValue(of: canvas), geometry)
            app.terminate()
        }
    }

    func testScribbleEraseIsOneUndoAndPersistsInNoteAndPractice() throws {
        for prefix in ["scribble-ink", "practice-sidebar-scribble-ink"] {
            let app = launchIsolatedApp(prefix: prefix)
            let canvas = app.descendants(matching: .any)["page-canvas-0"]
            XCTAssertTrue(canvas.waitForExistence(timeout: 5))
            setScribbleErase(true, in: app)
            let center = CGPoint(x: canvas.frame.midX, y: canvas.frame.minY + canvas.frame.height * 0.3)
            let word = [CGPoint(x: center.x - 28, y: center.y - 5),
                        CGPoint(x: center.x, y: center.y + 6),
                        CGPoint(x: center.x + 28, y: center.y - 5)]
            try synthesizeTouchPath(word, on: canvas, in: app, holdBeforeLift: 0.04)
            waitForValue("笔迹 1", of: canvas)
            let originalGeometry = drawingGeometryValue(of: canvas)
            let scratch = scribblePoints(in: CGRect(x: center.x - 80, y: center.y - 18, width: 160, height: 36))
            try synthesizeTouchPath(scratch, on: canvas, in: app, holdBeforeLift: 0.04)
            waitForValue("笔迹 0", of: canvas)
            XCTAssertEqual(app.buttons["tool-pen"].value as? String, "selected")
            app.buttons["撤销"].tap()
            waitForValue("笔迹 1", of: canvas)
            XCTAssertEqual(drawingGeometryValue(of: canvas), originalGeometry, "Undo must restore old ink without the scribble")
            app.buttons["重做"].tap()
            waitForValue("笔迹 0", of: canvas)
            // A new contact releases the late-callback guard and remains editable after erasing.
            try synthesizeTouchPath(word.map { CGPoint(x: $0.x, y: $0.y + 100) }, on: canvas, in: app, holdBeforeLift: 0.04)
            waitForValue("笔迹 1", of: canvas)
            let nextGeometry = drawingGeometryValue(of: canvas)
            app.buttons[prefix.hasPrefix("practice") ? "practice-exit" : "home-button"].tap()
            app.terminate()
            app.launchArguments.append("--reuse-text-interaction-ui-test-workspace")
            app.launch()
            XCTAssertTrue(canvas.waitForExistence(timeout: 5))
            waitForValue("笔迹 1", of: canvas)
            XCTAssertEqual(drawingGeometryValue(of: canvas), nextGeometry)
            app.terminate()
        }
    }

    func testScribbleSettingHighlighterAndOrdinaryDrawingNeverErase() throws {
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        // Note is read-only on iPhone; practice is the supported phone handwriting surface.
        let app = launchIsolatedApp(prefix: isPhone ? "practice-sidebar-scribble-settings" : "scribble-settings")
        let canvas = app.descendants(matching: .any)["page-canvas-0"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        setScribbleErase(false, in: app)
        let center = CGPoint(x: canvas.frame.midX, y: canvas.frame.minY + canvas.frame.height * 0.28)
        let line = [CGPoint(x: center.x - 35, y: center.y), CGPoint(x: center.x + 35, y: center.y)]
        let scratch = scribblePoints(in: CGRect(x: center.x - 80, y: center.y - 18, width: 160, height: 36))
        try synthesizeTouchPath(line, on: canvas, in: app, holdBeforeLift: 0.04)
        waitForValue("笔迹 1", of: canvas)
        try synthesizeTouchPath(scratch, on: canvas, in: app, holdBeforeLift: 0.04)
        waitForValue("笔迹 2", of: canvas)
        app.buttons["撤销"].tap()
        waitForValue("笔迹 1", of: canvas)
        setScribbleErase(true, in: app)
        app.buttons["tool-marker"].tap()
        try synthesizeTouchPath(scratch, on: canvas, in: app, holdBeforeLift: 0.04)
        waitForValue("笔迹 2", of: canvas)
        app.buttons["撤销"].tap()
        waitForValue("笔迹 1", of: canvas)
        setScribbleErase(true, in: app)
        let wave = (0...32).map { i in
            CGPoint(x: center.x - 100 + CGFloat(i) * 6.25, y: center.y + 25 * sin(CGFloat(i) / 32 * .pi * 6))
        }
        try synthesizeTouchPath(wave, on: canvas, in: app, holdBeforeLift: 0.04)
        waitForValue("笔迹 2", of: canvas)
        app.buttons["撤销"].tap()
        waitForValue("笔迹 1", of: canvas)
        try synthesizeTouchPath(scratch.map { CGPoint(x: $0.x, y: $0.y + 140) }, on: canvas, in: app, holdBeforeLift: 0.04)
        waitForValue("笔迹 2", of: canvas)
        app.buttons["撤销"].tap()
        waitForValue("笔迹 1", of: canvas)
        setScribbleErase(false, in: app)
        app.buttons[isPhone ? "practice-exit" : "home-button"].tap()
        app.terminate()
        app.launchArguments.append("--reuse-text-interaction-ui-test-workspace")
        app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        app.buttons["tool-pen"].tap()
        let toggle = app.switches["scribble-erase-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        XCTAssertEqual(toggle.value as? String, "0")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Scribble to erase in pen settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        app.buttons["pen-variant-pen"].tap()
    }

    func testScribbleEraseProtectsLockedAndPartlyCoveredShapesAndGroupsInkUndo() throws {
        let app = launchIsolatedApp(prefix: "scribble-shapes")
        let canvas = app.descendants(matching: .any)["page-canvas-0"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        setScribbleErase(true, in: app)
        insertShape(named: "矩形", in: app, settingsScroll: app.scrollViews["tool-settings-scroll"])
        let shapes = app.descendants(matching: .any).matching(identifier: "page-element-shape")
        let frame = shapes.firstMatch.frame
        app.buttons["对象操作"].tap()
        app.buttons["锁定"].tap()
        app.buttons["tool-pen"].tap()
        let wholeShape = scribblePoints(in: frame.insetBy(dx: -12, dy: -8))
        try synthesizeTouchPath(wholeShape, on: canvas, in: app, holdBeforeLift: 0.04)
        waitForValue("笔迹 1", of: canvas)
        XCTAssertEqual(shapes.count, 1)
        app.buttons["撤销"].tap()
        waitForValue("笔迹 0", of: canvas)
        app.buttons["tool-lasso"].tap()
        shapes.firstMatch.tap()
        app.buttons["对象操作"].tap()
        app.buttons["解锁"].tap()
        app.buttons["tool-pen"].tap()
        let edge = scribblePoints(in: CGRect(x: frame.midX - 60, y: frame.minY - 16, width: 120, height: 32))
        try synthesizeTouchPath(edge, on: canvas, in: app, holdBeforeLift: 0.04)
        waitForValue("笔迹 1", of: canvas)
        XCTAssertEqual(shapes.count, 1, "A small scribble must not erase a whole large shape")
        app.buttons["撤销"].tap()
        waitForValue("笔迹 0", of: canvas)
        let heldLine = (0...8).map { index in
            CGPoint(x: frame.minX + 30 + (frame.width - 60) * CGFloat(index) / 8, y: frame.midY)
        }
        try synthesizeTouchPath(heldLine, on: canvas, in: app, holdBeforeLift: 1.1)
        waitForValue("笔迹 1", of: canvas)
        waitForValueContaining("吸附 直线", of: canvas)
        let originalGeometry = drawingGeometryValue(of: canvas)
        try synthesizeTouchPath(wholeShape, on: canvas, in: app, holdBeforeLift: 0.8)
        waitForValue("笔迹 0", of: canvas)
        waitUntil(timeout: 3) { shapes.count == 0 }
        app.buttons["撤销"].tap()
        waitForValue("笔迹 1", of: canvas)
        XCTAssertEqual(shapes.count, 1)
        XCTAssertEqual(drawingGeometryValue(of: canvas), originalGeometry)
        app.buttons["重做"].tap()
        waitForValue("笔迹 0", of: canvas)
        XCTAssertEqual(shapes.count, 0)
        insertShape(named: "直线", in: app, settingsScroll: app.scrollViews["tool-settings-scroll"])
        let lineFrame = shapes.firstMatch.frame
        app.buttons["tool-pen"].tap()
        let lineScratch = scribblePoints(in: CGRect(x: lineFrame.minX - 12, y: lineFrame.midY - 18,
                                                    width: lineFrame.width + 24, height: 36))
        try synthesizeTouchPath(lineScratch, on: canvas, in: app, holdBeforeLift: 0.04)
        waitUntil(timeout: 3) { shapes.count == 0 }
        waitForValue("笔迹 0", of: canvas)
    }

    func testScribbleEraseAtTenPercentOutsideTheQuestionKeepsTheBackground() throws {
        let app = launchIsolatedApp(prefix: "practice-sidebar-scribble-zoom")
        let canvas = app.descendants(matching: .any)["page-canvas-0"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        setScribbleErase(true, in: app)
        try pinchCanvas(canvas, scale: 0.05, in: app)
        waitUntil(timeout: 3) { app.buttons["zoom-reset"].label.contains("10%") }
        let center = CGPoint(x: canvas.frame.minX + canvas.frame.width * 0.3,
                             y: canvas.frame.minY + canvas.frame.height * 0.25)
        let line = [CGPoint(x: center.x - 35, y: center.y), CGPoint(x: center.x + 35, y: center.y)]
        try synthesizeTouchPath(line, on: canvas, in: app, holdBeforeLift: 0.04)
        waitForValue("笔迹 1", of: canvas)
        XCTAssertLessThan(try drawingBounds(of: canvas).minX, 0)
        XCTAssertLessThan(try drawingBounds(of: canvas).minY, 0)
        let geometry = drawingGeometryValue(of: canvas)
        let scratch = scribblePoints(in: CGRect(x: center.x - 80, y: center.y - 18, width: 160, height: 36))
        try synthesizeTouchPath(scratch, on: canvas, in: app, holdBeforeLift: 0.04)
        waitForValue("笔迹 0", of: canvas)
        app.buttons["撤销"].tap()
        waitForValue("笔迹 1", of: canvas)
        XCTAssertEqual(drawingGeometryValue(of: canvas), geometry)
        app.buttons["重做"].tap()
        waitForValue("笔迹 0", of: canvas)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Practice after scribble erasure at 10 percent"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(app.buttons["practice-question-menu"].label.contains("第 1 题"))
    }

    private func setScribbleErase(_ enabled: Bool, in app: XCUIApplication) {
        let toggle = app.switches["scribble-erase-toggle"]
        if !toggle.exists {
            app.buttons["tool-pen"].tap()
            if !toggle.waitForExistence(timeout: 1) { app.buttons["tool-pen"].tap() }
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        if (toggle.value as? String == "1") != enabled {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        XCTAssertEqual(toggle.value as? String, enabled ? "1" : "0")
        app.buttons["pen-variant-pen"].tap()
    }

    func testScribbleEraseImmediatelyFollowedByWritingKeepsSeparateUndoSteps() throws {
        let app = launchIsolatedApp(prefix: "scribble-rapid-next-contact")
        let canvas = app.descendants(matching: .any)["page-canvas-0"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        setScribbleErase(true, in: app)
        let center = CGPoint(x: canvas.frame.midX, y: canvas.frame.minY + canvas.frame.height * 0.3)
        let original = [CGPoint(x: center.x - 30, y: center.y - 5),
                        CGPoint(x: center.x, y: center.y + 5), CGPoint(x: center.x + 30, y: center.y - 5)]
        try synthesizeTouchPath(original, on: canvas, in: app, holdBeforeLift: 0.04)
        waitForValue("笔迹 1", of: canvas)
        let originalGeometry = drawingGeometryValue(of: canvas)
        let scratch = scribblePoints(in: CGRect(x: center.x - 80, y: center.y - 18, width: 160, height: 36))
        let samples = scratch.enumerated().map { (point: $0.element, offset: Double($0.offset) * 0.06) }
        let lift = samples.last!.offset + 0.04
        let next = original.enumerated().map {
            (point: CGPoint(x: $0.element.x, y: $0.element.y + 120), offset: lift + 0.04 + Double($0.offset) * 0.06)
        }
        try synthesizeTouchPaths([SynthesizedTouchPath(samples: samples, liftOffset: lift),
                                  SynthesizedTouchPath(samples: next, liftOffset: next.last!.offset + 0.04)],
                                 on: canvas, in: app)
        waitForValue("笔迹 1", of: canvas)
        XCTAssertNotEqual(drawingGeometryValue(of: canvas), originalGeometry)
        app.buttons["撤销"].tap()
        waitForValue("笔迹 0", of: canvas)
        app.buttons["撤销"].tap()
        waitForValue("笔迹 1", of: canvas)
        XCTAssertEqual(drawingGeometryValue(of: canvas), originalGeometry)

        // Two erasures interleaved with two new strokes can share one native callback batch too.
        let secondEraseStart = next.last!.offset + 0.08
        let secondErase = scratch.enumerated().map {
            (point: CGPoint(x: $0.element.x, y: $0.element.y + 120), offset: secondEraseStart + Double($0.offset) * 0.06)
        }
        let finalStart = secondErase.last!.offset + 0.08
        let finalWord = original.enumerated().map {
            (point: CGPoint(x: $0.element.x, y: $0.element.y + 240), offset: finalStart + Double($0.offset) * 0.06)
        }
        try synthesizeTouchPaths([
            SynthesizedTouchPath(samples: samples, liftOffset: lift),
            SynthesizedTouchPath(samples: next, liftOffset: next.last!.offset + 0.04),
            SynthesizedTouchPath(samples: secondErase, liftOffset: secondErase.last!.offset + 0.04),
            SynthesizedTouchPath(samples: finalWord, liftOffset: finalWord.last!.offset + 0.04)
        ], on: canvas, in: app)
        waitForValue("笔迹 1", of: canvas)
        for count in [0, 1, 0, 1] {
            app.buttons["撤销"].tap()
            waitForValue("笔迹 \(count)", of: canvas)
        }
        XCTAssertEqual(drawingGeometryValue(of: canvas), originalGeometry)

        // A held shape in the next contact still snaps, even if the earlier erase is pending.
        let heldSamples = (0...8).map { index in
            (point: CGPoint(x: center.x - 60 + CGFloat(index) * 15, y: center.y + 120),
             offset: lift + 0.04 + Double(index) * 0.06)
        }
        try synthesizeTouchPaths([
            SynthesizedTouchPath(samples: samples, liftOffset: lift),
            SynthesizedTouchPath(samples: heldSamples, liftOffset: heldSamples.last!.offset + 1.1)
        ], on: canvas, in: app)
        waitForValue("笔迹 1", of: canvas)
        waitForValueContaining("吸附 直线", of: canvas)
        app.buttons["撤销"].tap()
        waitForValue("笔迹 0", of: canvas)
        app.buttons["撤销"].tap()
        waitForValue("笔迹 1", of: canvas)
        XCTAssertEqual(drawingGeometryValue(of: canvas), originalGeometry)
    }

    private func scribblePoints(in rect: CGRect) -> [CGPoint] {
        let passes = max(8, Int(ceil(rect.height / 6)))
        return (0...passes).map { index in
            CGPoint(x: index.isMultiple(of: 2) ? rect.minX : rect.maxX,
                    y: rect.minY + rect.height * CGFloat(index) / CGFloat(passes))
        }
    }

    func testPracticeQuestionAndSupplementUseUnboundedCanvasAndKeepOutsideInk() throws {
        let app = launchIsolatedApp(prefix: "practice-sidebar-unbounded")
        let canvas = app.descendants(matching: .any)["page-canvas-0"]
        let pager = app.scrollViews["document-page-pager"]
        let reset = app.buttons["zoom-reset"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["document-import-button"].exists)
        XCTAssertEqual(canvas.frame.width, pager.frame.width, accuracy: 1)
        XCTAssertEqual(canvas.frame.height, pager.frame.height, accuracy: 1)
        let originalViewport = try canvasViewportRect(of: canvas)
        let background = XCTAttachment(screenshot: app.screenshot())
        background.name = "Practice question remains visible on the unbounded canvas"
        background.lifetime = .keepAlways
        add(background)

        try pinchCanvas(canvas, scale: 0.05, in: app)
        waitUntil(timeout: 3) { reset.label.contains("10%") }
        XCTAssertEqual(try canvasViewportRect(of: canvas).width, originalViewport.width * 10, accuracy: 3)
        drawStroke(on: canvas, from: CGVector(dx: 0.20, dy: 0.25), to: CGVector(dx: 0.36, dy: 0.30))
        waitForValue("笔迹 1", of: canvas)
        let outsideInk = try drawingBounds(of: canvas)
        XCTAssertLessThan(outsideInk.minX, 0)
        XCTAssertLessThan(outsideInk.minY, 0)
        let inkGeometry = drawingGeometryValue(of: canvas)

        openPageSidebar(in: app)
        addPage(named: "方格纸", in: app)
        waitUntil(timeout: 4) { pager.value as? String == "2 / 3" }
        XCTAssertTrue(app.buttons["practice-question-menu"].label.contains("第 1 题"))
        let supplement = app.descendants(matching: .any)["page-canvas-1"]
        XCTAssertTrue(supplement.waitForExistence(timeout: 3))
        XCTAssertEqual(supplement.frame.width, pager.frame.width, accuracy: 1)
        _ = try canvasViewportRect(of: supplement)
        drawStroke(on: supplement)
        waitForValue("笔迹 1", of: supplement)
        app.buttons["page-thumbnail-0"].tap()
        waitUntil(timeout: 4) { pager.value as? String == "1 / 3" }
        app.buttons["关闭页面缩略图"].firstMatch.tap()
        waitForValue("笔迹 1", of: canvas)
        XCTAssertEqual(drawingGeometryValue(of: canvas), inkGeometry)
        XCTAssertTrue(reset.label.contains("10%"))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Practice at 10 percent with writing outside the question background"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.buttons["practice-exit"].tap()
        app.terminate()
        app.launchArguments.append("--reuse-text-interaction-ui-test-workspace")
        app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        waitForValue("笔迹 1", of: canvas)
        XCTAssertEqual(drawingGeometryValue(of: canvas), inkGeometry)
        XCTAssertTrue(reset.label.contains("10%"))
        XCTAssertEqual(pager.value as? String, "1 / 3")
    }

    func testDoubleTapAndHoldOnSelectedContentNeverShowsPencilKitMenu() throws {
        for prefix in ["selected-content-menu", "practice-sidebar-selected-content-menu"] {
            let app = launchIsolatedApp(prefix: prefix)
            let canvas = app.descendants(matching: .any)["page-canvas-0"]
            XCTAssertTrue(canvas.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["document-import-button"].exists)
            insertShape(named: "矩形", in: app, settingsScroll: app.scrollViews["tool-settings-scroll"])
            let shape = app.descendants(matching: .any).matching(identifier: "page-element-shape").firstMatch
            let selection = app.descendants(matching: .any)["lasso-selection-box"]
            checkSelectedContentMenu()

            app.buttons["tool-pen"].tap()
            let frame = canvas.frame
            let line = (0...8).map { CGPoint(x: frame.minX + frame.width * (0.28 + CGFloat($0) * 0.045),
                                           y: frame.minY + frame.height * 0.26) }
            try synthesizeTouchPath(line, on: canvas, in: app, holdBeforeLift: 1.2)
            waitForValueContaining("吸附 直线", of: canvas)
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.26)).tap()
            waitUntil(timeout: 3) { app.buttons["tool-lasso"].value as? String == "selected" && selection.exists }
            checkSelectedContentMenu()
            app.buttons["tool-pen"].tap()
            drawStroke(on: canvas, from: CGVector(dx: 0.28, dy: 0.72), to: CGVector(dx: 0.60, dy: 0.77))
            waitForValue("笔迹 2", of: canvas)

            // Reopening installs a new PencilKit hierarchy. Real iPad fingers must select the
            // existing object without reactivating native selection/menu gestures.
            app.buttons[prefix.hasPrefix("practice") ? "practice-exit" : "home-button"].tap()
            app.terminate()
            app.launchArguments += ["--reuse-text-interaction-ui-test-workspace", "--pencil-only-ui-test"]
            app.launch()
            XCTAssertTrue(canvas.waitForExistence(timeout: 5))
            shape.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(selection.waitForExistence(timeout: 3))
            checkSelectedContentMenu()
            app.terminate()

            func checkSelectedContentMenu() {
                XCTAssertTrue(selection.waitForExistence(timeout: 3))
                selection.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
                assertNoNativeMenu()
                selection.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.0)
                assertNoNativeMenu()
                XCTAssertTrue(app.buttons["删除"].exists, "The app's own selection controls must stay usable")
            }

            func assertNoNativeMenu() {
                XCTAssertEqual(app.menus.count, 0)
                for title in ["Select All", "Insert Space", "Paste", "全选", "插入空白", "粘贴"] {
                    XCTAssertFalse(app.buttons[title].exists, "Unexpected native canvas action: \(title)")
                    XCTAssertFalse(app.menuItems[title].exists)
                }
            }
        }
    }

    func testFingerTapSelectsInsertedAndHeldShapesWithoutAddingInk() throws {
        let app = launchIsolatedApp(prefix: "shape-finger-select")
        let canvas = app.descendants(matching: .any)["page-canvas-0"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let settings = app.scrollViews["tool-settings-scroll"]
        insertShape(named: "直线", in: app, settingsScroll: settings)
        let shape = app.descendants(matching: .any).matching(identifier: "page-element-shape").firstMatch
        let selection = app.descendants(matching: .any)["lasso-selection-box"]
        app.buttons["tool-pen"].tap()
        // A finger target stays comfortable even near a thin line's edge.
        shape.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: 10)).tap()
        waitUntil(timeout: 3) { app.buttons["tool-lasso"].value as? String == "selected" && selection.exists }
        waitForValue("笔迹 0", of: canvas)

        app.buttons["tool-pen"].tap()
        let frame = canvas.frame
        let start = CGPoint(x: frame.minX + frame.width * 0.32, y: frame.minY + frame.height * 0.28)
        let end = CGPoint(x: frame.minX + frame.width * 0.64, y: start.y)
        let points = (0...8).map { index in
            CGPoint(x: start.x + (end.x - start.x) * CGFloat(index) / 8, y: start.y)
        }
        try synthesizeTouchPath(points, on: canvas, in: app, holdBeforeLift: 1.25)
        waitForValue("笔迹 1", of: canvas)
        waitForValueContaining("吸附 直线", of: canvas)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.28))
            .withOffset(CGVector(dx: 0, dy: 10)).tap()
        waitUntil(timeout: 3) { app.buttons["tool-lasso"].value as? String == "selected" && selection.exists }
        waitForValue("笔迹 1", of: canvas)
        let original = selection.frame
        let center = selection.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: 30, dy: 60)))
        XCTAssertGreaterThan(selection.frame.midY, original.midY + 40)
        // Selection still follows the transformed native stroke after deselecting.
        app.buttons["tool-pen"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.28))
            .withOffset(CGVector(dx: 30, dy: 60)).tap()
        waitUntil(timeout: 3) { app.buttons["tool-lasso"].value as? String == "selected" && selection.exists }
        waitForValue("笔迹 1", of: canvas)

        app.buttons["tool-eraser"].tap()
        app.buttons["tool-eraser"].tap()
        app.buttons["eraser-mode-stroke"].tap()
        let point = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.28))
            .withOffset(CGVector(dx: 30, dy: 60))
        point.withOffset(CGVector(dx: 0, dy: -30)).press(forDuration: 0.08,
            thenDragTo: point.withOffset(CGVector(dx: 0, dy: 30)))
        waitForValue("笔迹 0", of: canvas)
        XCTAssertTrue(shape.exists)
        app.buttons["撤销"].tap()
        waitForValue("笔迹 1", of: canvas)

        app.buttons["home-button"].tap()
        app.terminate()
        app.launchArguments += ["--reuse-text-interaction-ui-test-workspace", "--pencil-only-ui-test"]
        app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        app.buttons["tool-pen"].tap()
        shape.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitUntil(timeout: 3) { app.buttons["tool-lasso"].value as? String == "selected" && selection.exists }
        waitForValue("笔迹 1", of: canvas)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Finger selection with a comfortable thin-line frame"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testEraserDeletesShapeAndInkInOneUndoTransactionAndPersists() throws {
        let app = launchIsolatedApp(prefix: "shape-eraser-persistence")
        let canvas = app.descendants(matching: .any)["page-canvas-0"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        insertShape(named: "矩形", in: app, settingsScroll: app.scrollViews["tool-settings-scroll"])
        let shapes = app.descendants(matching: .any).matching(identifier: "page-element-shape")
        let shapeFrame = shapes.firstMatch.frame
        app.buttons["tool-pen"].tap()
        let origin = canvas.coordinate(withNormalizedOffset: .zero)
        let point = origin.withOffset(CGVector(dx: shapeFrame.midX - canvas.frame.minX,
                                              dy: shapeFrame.minY - canvas.frame.minY))
        point.withOffset(CGVector(dx: 0, dy: -40)).press(forDuration: 0.08,
            thenDragTo: point.withOffset(CGVector(dx: 0, dy: 40)))
        waitForValue("笔迹 1", of: canvas)
        app.buttons["tool-eraser"].tap()
        app.buttons["tool-eraser"].tap()
        app.buttons["eraser-mode-stroke"].tap()
        point.withOffset(CGVector(dx: -40, dy: 0)).press(forDuration: 0.08,
            thenDragTo: point.withOffset(CGVector(dx: 40, dy: 0)))
        waitUntil(timeout: 3) { shapes.count == 0 }
        waitForValue("笔迹 0", of: canvas)
        app.buttons["撤销"].tap()
        waitUntil(timeout: 3) { shapes.count == 1 }
        waitForValue("笔迹 1", of: canvas)
        app.buttons["重做"].tap()
        waitUntil(timeout: 3) { shapes.count == 0 }
        waitForValue("笔迹 0", of: canvas)

        app.buttons["home-button"].tap()
        app.terminate()
        app.launchArguments.append("--reuse-text-interaction-ui-test-workspace")
        app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        XCTAssertEqual(shapes.count, 0)
        waitForValue("笔迹 0", of: canvas)
    }

    func testShapeSelectionAndPrecisionEraserAtTenPercentRespectTheOutline() throws {
        let app = launchIsolatedApp(prefix: "shape-small-zoom")
        let canvas = app.descendants(matching: .any)["page-canvas-0"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        try pinchCanvas(canvas, scale: 0.05, in: app)
        waitUntil(timeout: 3) { app.buttons["zoom-reset"].label.contains("10%") }
        insertShape(named: "矩形", in: app, settingsScroll: app.scrollViews["tool-settings-scroll"])
        let shape = app.descendants(matching: .any).matching(identifier: "page-element-shape").firstMatch
        let frame = shape.frame
        app.buttons["tool-pen"].tap()
        shape.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: 10, dy: 0)).tap()
        waitUntil(timeout: 3) { app.buttons["tool-lasso"].value as? String == "selected" }
        app.buttons["tool-eraser"].tap()
        app.buttons["tool-eraser"].tap()
        app.buttons["eraser-mode-precision"].tap()
        let center = canvas.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - canvas.frame.minX, dy: frame.midY - canvas.frame.minY))
        center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: 1, dy: 0)))
        XCTAssertTrue(shape.exists, "An empty shape interior must not be erased as a filled rectangle")
        let edge = center.withOffset(CGVector(dx: frame.width / 2, dy: 0))
        edge.withOffset(CGVector(dx: -5, dy: 0)).press(forDuration: 0.08,
            thenDragTo: edge.withOffset(CGVector(dx: 12, dy: 0)))
        XCTAssertTrue(shape.waitForNonExistence(timeout: 3))
        app.buttons["撤销"].tap()
        XCTAssertTrue(shape.waitForExistence(timeout: 3))
        waitForValue("笔迹 0", of: canvas)
    }

    func testNativeCanvasDoubleTapAndHoldDoNotShowEditingMenusOrBlockWriting() throws {
        let app = launchIsolatedApp(prefix: "canvas-editing-menus")
        let canvas = app.descendants(matching: .any)["page-canvas-0"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        for tool in ["tool-pen", "tool-lasso"] {
            if app.buttons[tool].value as? String != "selected" { app.buttons[tool].tap() }
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.30)).doubleTap()
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.60)).press(forDuration: 0.9)
            XCTAssertEqual(app.menus.count, 0)
            for label in ["Select All", "Insert Space", "Paste", "全选", "插入空白", "粘贴"] {
                XCTAssertFalse(app.buttons[label].exists, "Native canvas menu appeared: \(label)")
            }
            if app.buttons["tool-pen"].value as? String != "selected" { app.buttons["tool-pen"].tap() }
            let value = canvas.value as? String ?? ""
            let count = try XCTUnwrap(Int(value.components(separatedBy: "；")[0].replacingOccurrences(of: "笔迹 ", with: "")))
            drawStroke(on: canvas, from: CGVector(dx: 0.25, dy: 0.4), to: CGVector(dx: 0.5, dy: 0.45))
            waitForValue("笔迹 \(count + 1)；", of: canvas)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Canvas remains writable after double tap and hold"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.buttons["home-button"].tap()
        app.terminate()
        app.launchArguments += ["--reuse-text-interaction-ui-test-workspace", "--pencil-only-ui-test"]
        app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        // On hardware fingers navigate instead of drawing. Test the native selection/menu path
        // under that same policy, with already persisted ink on the page.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.70)).doubleTap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.60)).press(forDuration: 0.9)
        XCTAssertEqual(app.menus.count, 0)
        for label in ["Select All", "Insert Space", "Paste", "全选", "插入空白", "粘贴"] {
            XCTAssertFalse(app.buttons[label].exists)
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    func testHighlighterIsTheFourthDockOptionAndPenWidthsSwitchBackToInk() throws {
        let app = launchIsolatedApp(prefix: "library-dock-highlighter")
        let document = app.staticTexts["UITest One"].firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 8))
        document.tap()
        let pen = app.buttons["tool-pen"]
        let marker = app.buttons["tool-marker"]
        let thick = app.buttons["ink-width-preset-2"]
        let palette = app.descendants(matching: .any)["dockable-tool-palette"]
        let topBar = app.descendants(matching: .any)["annotation-tool-bar"]
        XCTAssertTrue(marker.waitForExistence(timeout: 5))
        XCTAssertTrue(palette.frame.contains(marker.frame))
        XCTAssertGreaterThan(marker.frame.minY, thick.frame.maxY)
        XCTAssertFalse(topBar.frame.intersects(marker.frame))

        marker.tap()
        XCTAssertEqual(marker.value as? String, "selected")
        XCTAssertEqual(pen.value as? String, "selected")
        XCTAssertEqual(pen.label, "笔，当前荧光笔")
        for index in 0...2 {
            XCTAssertEqual(app.buttons["ink-width-preset-\(index)"].value as? String, "not-selected")
        }
        let canvas = app.descendants(matching: .any)["page-canvas-0"]
        drawStroke(on: canvas)
        waitForValue("笔迹 1", of: canvas)

        // Opening the selected parent tool's settings must preserve the active highlighter.
        pen.tap()
        let penSettings = app.descendants(matching: .any)["pen-variant-settings"]
        XCTAssertTrue(penSettings.waitForExistence(timeout: 3))
        XCTAssertEqual(marker.value as? String, "selected")
        app.buttons["pen-variant-fountainPen"].tap()
        XCTAssertTrue(penSettings.waitForNonExistence(timeout: 3))
        XCTAssertEqual(marker.value as? String, "not-selected")
        marker.tap()
        XCTAssertEqual(pen.value as? String, "selected")

        marker.tap()
        let slider = app.sliders["marker-width-slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 3))
        slider.adjust(toNormalizedSliderPosition: 0.75)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.70)).tap()
        XCTAssertTrue(slider.waitForNonExistence(timeout: 3))
        thick.tap()
        XCTAssertEqual(thick.value as? String, "selected")
        XCTAssertEqual(marker.value as? String, "not-selected")
        XCTAssertEqual(pen.value as? String, "selected")
        XCTAssertEqual(pen.label, "笔，当前钢笔")
        drawStroke(on: canvas, from: CGVector(dx: 0.32, dy: 0.58), to: CGVector(dx: 0.58, dy: 0.66))
        waitForValue("笔迹 2", of: canvas)

        app.buttons["tool-eraser"].tap()
        XCTAssertEqual(pen.value as? String, "not-selected")
        pen.tap()
        marker.tap()
        XCTAssertEqual(pen.value as? String, "selected")
        XCTAssertEqual(marker.value as? String, "selected")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Highlighter keeps the pen category selected"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testLibraryReturnsToFolderFilterSearchAndScrolledPosition() throws {
        let app = launchIsolatedApp(prefix: "library-return-context")
        XCTAssertTrue(app.staticTexts["返回目录"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["隐藏侧栏"].exists)
        let librarySearch = app.descendants(matching: .any)["library-search-field"]
        XCTAssertTrue(librarySearch.waitForExistence(timeout: 3))
        let folderArtwork = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "返回目录文件夹外观")).firstMatch
        // SF Symbols' accessibility frame includes the glyph's small built-in side bearing.
        XCTAssertEqual(folderArtwork.frame.minX, librarySearch.frame.minX, accuracy: 5)
        XCTAssertEqual(app.buttons["library-filter-menu"].frame.minX, librarySearch.frame.minX, accuracy: 1)
        let nameColumnX = app.staticTexts["返回目录"].firstMatch.frame.minX
        XCTAssertEqual(app.staticTexts["UITest One"].firstMatch.frame.minX, nameColumnX, accuracy: 1)
        app.staticTexts["返回目录"].firstMatch.tap()
        let folderScreenshot = XCTAttachment(screenshot: app.screenshot())
        folderScreenshot.name = "Compact folder path and list rows"
        folderScreenshot.lifetime = .keepAlways
        add(folderScreenshot)
        selectLibraryKind("canvas", in: app)
        let search = app.textFields["搜索文稿和文件夹"]
        search.tap()
        search.typeText("返回画板")
        app.buttons["library-filter-menu"].tap()
        app.buttons["library-kind-canvas"].tap()

        let items = app.scrollViews["library-items"]
        XCTAssertTrue(items.waitForExistence(timeout: 4))
        items.swipeUp()
        items.swipeUp()
        // UIKit can retain a zero-height keyboard accessibility node after dismissal.
        waitUntil(timeout: 3, application: app) {
            let keyboard = app.keyboards.firstMatch
            return !keyboard.exists || keyboard.frame.height < 1 || keyboard.frame.minY >= app.frame.maxY
        }
        let visible = items.staticTexts.allElementsBoundByIndex.first {
            $0.label.hasPrefix("返回画板") && $0.isHittable
                && $0.frame.minY > items.frame.minY + 30
                && $0.frame.maxY < items.frame.maxY - 30
        }
        let row = try XCTUnwrap(visible)
        XCTAssertEqual(row.frame.minX, nameColumnX, accuracy: 1)
        let title = row.label
        let originalY = row.frame.minY
        row.tap()
        XCTAssertTrue(app.buttons["home-button"].waitForExistence(timeout: 5))
        app.buttons["home-button"].tap()
        XCTAssertTrue(items.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "返回画板")
        XCTAssertTrue(app.buttons["library-filter-menu"].label.contains("画板"))
        let returned = app.staticTexts[title].firstMatch
        waitUntil(timeout: 4) { returned.isHittable }
        XCTAssertEqual(returned.frame.minY, originalY, accuracy: 90)
        XCTAssertEqual(returned.frame.minX, nameColumnX, accuracy: 1)
        app.buttons["清除搜索"].tap()
        XCTAssertTrue(app.buttons["返回目录"].firstMatch.waitForExistence(timeout: 3))
    }

    func testIntegratedIPadSidebarDocumentsAndFullScreenEditor() throws {
#if targetEnvironment(macCatalyst)
        throw XCTSkip("This regression covers the integrated iPad navigation")
#else
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication(bundleIdentifier: "com.tiyi.chat")
        app.launchArguments = ["--pencil-only-ui-test"]
        app.launch()
        let chat = app.buttons["sidebar-chat"]
        let documents = app.buttons["sidebar-documents"]
        let features = app.buttons["sidebar-features"]
        XCTAssertTrue(documents.waitForExistence(timeout: 10), "The iPad sidebar must be visible at launch")
        XCTAssertTrue(documents.isHittable)
        XCTAssertFalse(app.buttons["打开会话列表"].exists)
        let sidebar = app.descendants(matching: .any)["tiyi-main-sidebar"]

        func assertNavigationRows(selected selectedButton: XCUIElement) {
            XCTAssertFalse(sidebar.staticTexts["Tiyi"].exists)
            XCTAssertFalse(sidebar.staticTexts["对话"].exists)
            for (button, title) in [(chat, "聊天"), (documents, "文稿"), (features, "功能")] {
                XCTAssertTrue(button.isHittable)
                XCTAssertEqual(button.label, title)
                XCTAssertEqual(button.frame.minX, chat.frame.minX, accuracy: 1)
                XCTAssertEqual(button.frame.width, chat.frame.width, accuracy: 1)
                XCTAssertEqual(button.frame.height, 52, accuracy: 1)
                XCTAssertEqual(button.staticTexts[title].frame.minX, chat.staticTexts["聊天"].frame.minX, accuracy: 1)
                XCTAssertEqual(button.staticTexts[title].frame.midY, button.frame.midY, accuracy: 1)
                XCTAssertEqual(button.value as? String, button == selectedButton ? "selected" : "not-selected")
            }
            XCTAssertEqual(documents.frame.minY - chat.frame.maxY, features.frame.minY - documents.frame.maxY, accuracy: 1)
        }

        func assertHeaderAligned(identifier: String) {
            let headerContent = app.descendants(matching: .any)[identifier]
            XCTAssertTrue(headerContent.waitForExistence(timeout: 4))
            let sidebarSearch = app.textFields["sidebar-search"]
            XCTAssertEqual(sidebarSearch.frame.midY, headerContent.frame.midY, accuracy: 1)
            XCTAssertEqual(app.buttons["新聊天"].frame.midY, headerContent.frame.midY, accuracy: 1)
            if identifier == "library-search-field" {
                XCTAssertFalse(app.staticTexts["document-library-title"].exists)
                XCTAssertFalse(app.buttons["返回首页"].exists)
                XCTAssertEqual(app.buttons["library-filter-menu"].frame.minX, headerContent.frame.minX, accuracy: 1)
            }
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Aligned workspace header - \(identifier)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }

        assertNavigationRows(selected: chat)
        assertHeaderAligned(identifier: "chat-page-title")
        documents.tap()
        let library = app.descendants(matching: .any)["document-library"]
        XCTAssertTrue(library.waitForExistence(timeout: 8))
        assertHeaderAligned(identifier: "library-search-field")
        assertNavigationRows(selected: documents)
        XCTAssertLessThanOrEqual(documents.frame.maxX, library.frame.minX + 1)
        waitUntil(timeout: 4, application: app) { sidebar.frame.maxY > app.frame.maxY - 60 }
        XCTAssertFalse(app.buttons["显示侧栏"].exists)
        XCTAssertFalse(app.buttons["隐藏侧栏"].exists)
        features.tap()
        assertNavigationRows(selected: features)
        assertHeaderAligned(identifier: "feature-page-title")
        XCTAssertTrue(documents.isHittable)
        XCTAssertFalse(app.staticTexts["文件"].exists)
        app.buttons.containing(.staticText, identifier: "错题本").firstMatch.tap()
        assertHeaderAligned(identifier: "wrongbook-page-title")
        app.buttons["返回功能"].tap()
        assertHeaderAligned(identifier: "feature-page-title")
        chat.tap()
        XCTAssertTrue(library.waitForNonExistence(timeout: 3))
        assertNavigationRows(selected: chat)
        documents.tap()
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        rotateApplicationToLandscape(app)
        waitUntil(timeout: 4) { documents.isHittable && documents.frame.maxX <= library.frame.minX + 1 }
        assertNavigationRows(selected: documents)
        assertHeaderAligned(identifier: "library-search-field")

        let folderName = "导航验收 \(UUID().uuidString.prefix(6))"
        createFolder(named: folderName, in: app)
        app.staticTexts[folderName].firstMatch.tap()
        let newCanvas = app.buttons["新建画板"].firstMatch
        XCTAssertTrue(newCanvas.waitForExistence(timeout: 4))
        newCanvas.tap()
        let name = app.textFields["画板名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        replaceText(in: name, with: "导航验收画板")
        app.buttons["创建"].tap()
        let document = app.staticTexts["导航验收画板"].firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 5))

        let browsingImage = XCTAttachment(screenshot: app.screenshot())
        browsingImage.name = "Tiyi persistent sidebar and document library"
        browsingImage.lifetime = .keepAlways
        add(browsingImage)
        document.tap()
        let home = app.buttons["home-button"]
        XCTAssertTrue(home.waitForExistence(timeout: 8))
        XCTAssertFalse(documents.exists, "The host sidebar must leave the full-screen editor")
        let pager = app.scrollViews["document-page-pager"]
        waitUntil(timeout: 4) { abs(pager.frame.width - app.frame.width) < 3 }
        XCTAssertTrue(app.buttons["tool-marker"].exists)
        home.tap()
        XCTAssertTrue(documents.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[folderName].firstMatch.exists)
        XCTAssertTrue(document.isHittable)
        XCTAssertLessThanOrEqual(documents.frame.maxX, library.frame.minX + 1)
        XCUIDevice.shared.press(.home)
        XCUIDevice.shared.orientation = .portrait
        app.activate()
        waitUntil(timeout: 5, application: app) {
            app.frame.height > app.frame.width
                && sidebar.frame.maxY > app.frame.maxY - 60
        }
        assertNavigationRows(selected: documents)
        assertHeaderAligned(identifier: "library-search-field")

        let search = app.textFields["搜索文稿和文件夹"]
        search.tap()
        search.typeText("导航验收画板")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(sidebar.frame.maxY, app.frame.maxY - 60)
        XCTAssertTrue(document.isHittable)
        document.tap()
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        XCTAssertFalse(documents.exists)
        home.tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "导航验收画板")
        app.buttons["清除搜索"].tap()
        XCTAssertTrue(app.buttons[folderName].firstMatch.exists)
        XCTAssertGreaterThan(sidebar.frame.maxY, app.frame.maxY - 60)
#endif
    }

    func testIntegratedIPhoneLibraryDrawerAndReaderNavigation() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This regression covers the integrated iPhone drawer")
        }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.tiyi.chat")
        app.launch()
        let documents = app.buttons["sidebar-documents"]
        let chat = app.buttons["sidebar-chat"]
        let features = app.buttons["sidebar-features"]
        let library = app.descendants(matching: .any)["document-library"]
        let search = app.descendants(matching: .any)["library-search-field"]

        func edgeSwipe() {
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: 8, dy: app.frame.height * 0.55))
                .press(forDuration: 0.05,
                       thenDragTo: origin.withOffset(CGVector(dx: app.frame.width * 0.80, dy: app.frame.height * 0.55)),
                       withVelocity: .slow, thenHoldForDuration: 0)
        }
        func openDrawer() {
            edgeSwipe()
            waitUntil(timeout: 4, application: app) { documents.exists && documents.isHittable }
        }
        func assertLibrary() {
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            waitUntil(timeout: 4, application: app) { abs(search.frame.minX - 16) < 1 }
            XCTAssertFalse(app.buttons["返回首页"].exists)
            XCTAssertFalse(library.staticTexts["文稿"].exists)
            XCTAssertFalse(app.buttons["新建"].exists)
            XCTAssertFalse(app.buttons["选择项目"].exists)
            XCTAssertEqual(app.buttons["library-filter-menu"].frame.minX, search.frame.minX, accuracy: 1)
            XCTAssertEqual(app.buttons["iCloud 同步状态"].frame.midY, search.frame.midY, accuracy: 1)
            XCTAssertLessThanOrEqual(app.buttons["iCloud 同步状态"].frame.maxX, app.frame.maxX - 16)
        }

        openDrawer()
        documents.tap()
        assertLibrary()
        let folder = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "导航验收 ")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 4))
        folder.tap()
        let breadcrumbs = app.scrollViews["library-breadcrumbs"]
        XCTAssertTrue(breadcrumbs.waitForExistence(timeout: 4))
        let folderScreenshot = XCTAttachment(screenshot: app.screenshot())
        folderScreenshot.name = "iPhone inline folder navigation"
        folderScreenshot.lifetime = .keepAlways
        add(folderScreenshot)
        breadcrumbs.buttons["文稿"].tap()
        assertLibrary()
        let items = app.scrollViews["library-items"]
        items.swipeUp()
        items.swipeDown()
        // A horizontal drag away from the opening edge must also leave the drawer closed.
        items.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.50))
            .press(forDuration: 0.05,
                   thenDragTo: items.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.50)),
                   withVelocity: .slow, thenHoldForDuration: 0)
        assertLibrary()

        openDrawer()
        let drawerScreenshot = XCTAttachment(screenshot: app.screenshot())
        drawerScreenshot.name = "iPhone document library edge drawer"
        drawerScreenshot.lifetime = .keepAlways
        add(drawerScreenshot)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.55)).tap()
        assertLibrary()
        openDrawer()
        chat.tap()
        XCTAssertTrue(app.staticTexts["chat-page-title"].waitForExistence(timeout: 4))
        XCTAssertTrue(library.waitForNonExistence(timeout: 4))
        openDrawer()
        features.tap()
        XCTAssertTrue(app.staticTexts["feature-page-title"].waitForExistence(timeout: 4))
        openDrawer()
        documents.tap()
        assertLibrary()

        // Seed the integrated simulator with the iPad's library fixture before this test.
        let document = app.staticTexts["未命名画板"].firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        let searchInput = app.textFields["搜索文稿和文件夹"]
        searchInput.tap()
        searchInput.typeText("未命名画板")
        document.tap()
        let home = app.buttons["home-button"]
        XCTAssertTrue(home.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["只读"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["tool-pen"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["tiyi-main-sidebar"].exists)
        edgeSwipe()
        XCTAssertFalse(documents.exists, "The host drawer must leave the reader's gesture hierarchy")
        home.tap()
        assertLibrary()
        XCTAssertEqual(searchInput.value as? String, "未命名画板")
        app.buttons["清除搜索"].tap()
        openDrawer()
        documents.tap()
        assertLibrary()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "iPhone compact document library header"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testTabsAndTextEditorUseOneStableInteractionState() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--text-interaction-ui-test",
            "text-state-\(UUID().uuidString)",
            "--drawing-persistence-idle-delay",
            "0.6"
        ]
        app.launch()

        let firstTab = app.buttons["document-tab-UITest One"]
        let secondTab = app.buttons["document-tab-UITest Two"]
        XCTAssertTrue(firstTab.waitForExistence(timeout: 8))
        XCTAssertTrue(secondTab.waitForExistence(timeout: 4))

        secondTab.tap()
        XCTAssertEqual(secondTab.value as? String, "active")
        firstTab.tap()
        XCTAssertEqual(firstTab.value as? String, "active")

        let insertTextButton = app.buttons["tool-text"]
        XCTAssertTrue(insertTextButton.waitForExistence(timeout: 5))
        insertTextButton.tap()
        XCTAssertEqual(insertTextButton.value as? String, "selected")
        XCTAssertEqual(app.buttons["tool-lasso"].value as? String, "not-selected")

        let editor = app.descendants(matching: .any)
            .matching(identifier: "inline-text-editor")
            .firstMatch
        let lassoSelectionBox = app.descendants(matching: .any)
            .matching(identifier: "lasso-selection-box")
            .firstMatch
        XCTAssertFalse(editor.exists)
        XCTAssertFalse(lassoSelectionBox.exists)

        let pageCanvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        XCTAssertTrue(pageCanvas.waitForExistence(timeout: 3))
        tapCanvas(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let originalEditorFrame = editor.frame
        XCTAssertLessThan(
            originalEditorFrame.width,
            pageCanvas.frame.width * 0.30,
            "A new text box should start compact instead of spanning most of the page"
        )
        XCTAssertLessThan(
            originalEditorFrame.height,
            pageCanvas.frame.height * 0.12,
            "A new text box should start at roughly one line of text"
        )
        let moveHandle = app.descendants(matching: .any)
            .matching(identifier: "text-move-handle")
            .firstMatch
        XCTAssertTrue(moveHandle.waitForExistence(timeout: 3))
        let dragStart = moveHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let dragEnd = dragStart.withOffset(CGVector(dx: 70, dy: 36))
        dragStart.press(forDuration: 0.12, thenDragTo: dragEnd)

        let movedEditorFrame = editor.frame
        XCTAssertGreaterThan(
            hypot(
                movedEditorFrame.midX - originalEditorFrame.midX,
                movedEditorFrame.midY - originalEditorFrame.midY
            ),
            20
        )
        XCTAssertFalse(lassoSelectionBox.exists)

        let resizeHandle = app.descendants(matching: .any)
            .matching(identifier: "text-resize-handle")
            .firstMatch
        XCTAssertTrue(resizeHandle.waitForExistence(timeout: 3))
        let frameBeforeResize = editor.frame
        let resizeStart = resizeHandle.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        resizeStart.press(
            forDuration: 0.12,
            thenDragTo: resizeStart.withOffset(CGVector(dx: 54, dy: 28))
        )
        let resizedEditorFrame = editor.frame
        XCTAssertGreaterThan(resizedEditorFrame.width - frameBeforeResize.width, 20)
        XCTAssertGreaterThan(resizedEditorFrame.height - frameBeforeResize.height, 10)
        XCTAssertFalse(lassoSelectionBox.exists)

        let doneButton = app.buttons["text-edit-done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 3))
        doneButton.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
        XCTAssertFalse(lassoSelectionBox.exists)

        let savedText = app.staticTexts["键入文本"].firstMatch
        XCTAssertTrue(savedText.waitForExistence(timeout: 3))
        savedText.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertFalse(lassoSelectionBox.exists)

        let reopenedDoneButton = app.buttons["text-edit-done"]
        XCTAssertTrue(reopenedDoneButton.waitForExistence(timeout: 3))
        reopenedDoneButton.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
        XCTAssertFalse(lassoSelectionBox.exists)

        secondTab.tap()
        XCTAssertEqual(secondTab.value as? String, "active")
    }

    func testEveryVisibleToolHasOneStableSelection() throws {
        let app = launchIsolatedApp(prefix: "toolbar-lasso")
        let toolIDs = [
            "pen",
            "fountainPen",
            "pencil",
            "marker",
            "eraser",
            "lasso",
            "text"
        ]

        for selectedID in toolIDs {
            let selectedButton = app.buttons["tool-\(selectedID)"]
            XCTAssertTrue(selectedButton.waitForExistence(timeout: 5), "Missing \(selectedID) tool")
            selectedButton.tap()
            XCTAssertEqual(selectedButton.value as? String, "selected")

            for otherID in toolIDs where otherID != selectedID {
                XCTAssertEqual(
                    app.buttons["tool-\(otherID)"].value as? String,
                    "not-selected",
                    "Selecting \(selectedID) also selected \(otherID)"
                )
            }
        }

    }

    func testGoodnotesWorkspaceUsesTwoChromeRowsAndDetachedPalette() throws {
        let app = launchIsolatedApp(prefix: "pdf-goodnotes-layout")
        defer { XCUIDevice.shared.orientation = .portrait }
        rotateApplicationToLandscape(app)
        XCTAssertGreaterThan(
            app.frame.width,
            app.frame.height,
            "Goodnotes 参考布局必须在真实横屏画布中验收"
        )
        XCTAssertLessThan(abs(app.frame.minX), 2)
        XCTAssertLessThan(abs(app.frame.minY), 2)

        let tabBar = app.descendants(matching: .any)
            .matching(identifier: "document-tab-bar")
            .firstMatch
        let toolBar = app.descendants(matching: .any)
            .matching(identifier: "annotation-tool-bar")
            .firstMatch
        let palette = app.descendants(matching: .any)
            .matching(identifier: "dockable-tool-palette")
            .firstMatch

        XCTAssertTrue(tabBar.waitForExistence(timeout: 8))
        XCTAssertTrue(toolBar.waitForExistence(timeout: 5))
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
        XCTAssertLessThan(
            tabBar.frame.minY - app.frame.minY,
            64,
            "文稿标签行应紧接系统状态栏，不能悬在画布中部"
        )
        XCTAssertLessThan(abs(tabBar.frame.maxY - toolBar.frame.minY), 3)
        XCTAssertGreaterThanOrEqual(palette.frame.minY, toolBar.frame.maxY)

        let home = app.buttons["home-button"]
        let firstTab = app.buttons["document-tab-UITest One"]
        XCTAssertLessThan(abs(home.frame.midY - firstTab.frame.midY), 3)

        let thumbnails = app.buttons["打开页面缩略图"]
        let pen = app.buttons["tool-pen"]
        let image = app.buttons["插入图片"]
        let importDocument = app.buttons["document-import-button"]
        let output = app.buttons["导出和分享"]
        let more = app.buttons["更多文稿操作"]
        XCTAssertTrue(thumbnails.isHittable)
        XCTAssertTrue(pen.isHittable)
        XCTAssertTrue(image.isHittable)
        XCTAssertFalse(importDocument.exists)
        XCTAssertTrue(output.isHittable)
        XCTAssertTrue(more.isHittable)
        XCTAssertLessThan(abs(thumbnails.frame.midY - pen.frame.midY), 3)
        XCTAssertLessThan(abs(pen.frame.midY - image.frame.midY), 3)
        XCTAssertLessThan(abs(thumbnails.frame.midY - output.frame.midY), 3)
        XCTAssertLessThan(abs(thumbnails.frame.midY - more.frame.midY), 3)
        for button in [thumbnails, pen, image, output, more] {
            XCTAssertEqual(button.frame.midY, toolBar.frame.midY, accuracy: 1)
        }
        for trailingAction in [output, more] {
            XCTAssertGreaterThanOrEqual(
                trailingAction.frame.minX,
                toolBar.frame.minX,
                "右侧文稿操作不能滚到工具栏可视区左侧之外"
            )
            XCTAssertLessThanOrEqual(
                trailingAction.frame.maxX,
                toolBar.frame.maxX,
                "右侧文稿操作必须始终留在工具栏可视区内"
            )
        }
        let history = app.descendants(matching: .any)
            .matching(identifier: "canvas-history-controls")
            .firstMatch
        let undo = app.buttons["canvas-undo-button"]
        let redo = app.buttons["canvas-redo-button"]
        let drawingTools = app.scrollViews["tool-settings-scroll"]
        let shape = app.buttons["插入图形"]
        XCTAssertTrue(history.waitForExistence(timeout: 3))
        XCTAssertTrue(undo.exists)
        XCTAssertTrue(redo.exists)
        XCTAssertFalse(app.descendants(matching: .any)["canvas-history-overlay"].exists)
        XCTAssertTrue(toolBar.frame.contains(history.frame))
        XCTAssertTrue(drawingTools.frame.contains(history.frame))
        XCTAssertGreaterThan(undo.frame.minX, shape.frame.maxX)
        XCTAssertGreaterThan(redo.frame.minX, undo.frame.maxX)
        XCTAssertLessThan(redo.frame.maxX, output.frame.minX)
        for button in [undo, redo] {
            XCTAssertEqual(button.frame.midY, more.frame.midY, accuracy: 1)
            XCTAssertEqual(button.frame.size, more.frame.size)
        }
        XCTAssertLessThan(toolBar.frame.maxX - more.frame.maxX, 20)

        let canvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(canvas.frame.midY, toolBar.frame.maxY)
        XCTAssertLessThanOrEqual(canvas.frame.maxY, app.frame.maxY - 8)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Goodnotes-style document workspace"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCUIDevice.shared.orientation = .portrait
        waitUntil(timeout: 4) {
            app.frame.height > app.frame.width
                && drawingTools.frame.contains(history.frame)
                && toolBar.frame.maxX - more.frame.maxX < 20
        }
        XCTAssertTrue(drawingTools.frame.contains(history.frame))
        XCTAssertGreaterThan(undo.frame.minX, shape.frame.maxX)
        XCTAssertLessThan(toolBar.frame.maxX - more.frame.maxX, 20)
        XCTAssertEqual(undo.frame.midY, more.frame.midY, accuracy: 1)
        XCTAssertEqual(pen.frame.midY, toolBar.frame.midY, accuracy: 1)
    }

    func testDockableToolPaletteSnapsAndReorientsOnAllFourEdges() throws {
        let app = launchIsolatedApp(prefix: "goodnotes-palette-docking")
        defer { XCUIDevice.shared.orientation = .portrait }
        rotateApplicationToLandscape(app)
        XCTAssertGreaterThan(
            app.frame.width,
            app.frame.height,
            "四边吸附必须在与参考图一致的横屏空间中验收"
        )

        let palette = app.descendants(matching: .any)
            .matching(identifier: "dockable-tool-palette")
            .firstMatch
        let region = app.descendants(matching: .any)
            .matching(identifier: "document-page-pager")
            .firstMatch
        XCTAssertTrue(palette.waitForExistence(timeout: 8))
        XCTAssertTrue(region.waitForExistence(timeout: 5))

        @discardableResult
        func dragPalette(to value: String, offset: CGVector) -> CGRect {
            let handle = app.descendants(matching: .any)
                .matching(identifier: "tool-palette-drag-handle")
                .firstMatch
            XCTAssertTrue(handle.waitForExistence(timeout: 3))
            XCTAssertTrue(handle.isHittable)
            handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(
                    forDuration: 0.12,
                    thenDragTo: region.coordinate(withNormalizedOffset: offset),
                    withVelocity: .slow,
                    thenHoldForDuration: 0.12
                )
            waitUntil(timeout: 4) {
                palette.value as? String == value
            }
            if value == "top" || value == "bottom" {
                XCTAssertGreaterThan(palette.frame.width, palette.frame.height)
            } else {
                XCTAssertGreaterThan(palette.frame.height, palette.frame.width)
            }
            return palette.frame
        }

        let topFrame = dragPalette(to: "top", offset: CGVector(dx: 0.50, dy: 0.01))
        XCTAssertLessThan(abs(topFrame.minY - region.frame.minY), 32)

        let rightFrame = dragPalette(to: "right", offset: CGVector(dx: 0.99, dy: 0.50))
        XCTAssertLessThan(abs(rightFrame.maxX - region.frame.maxX), 32)

        let bottomFrame = dragPalette(to: "bottom", offset: CGVector(dx: 0.50, dy: 0.99))
        XCTAssertLessThan(abs(bottomFrame.maxY - region.frame.maxY), 36)

        let upperLeftFrame = dragPalette(
            to: "left",
            offset: CGVector(dx: 0.01, dy: 0.28)
        )
        XCTAssertLessThan(abs(upperLeftFrame.minX - region.frame.minX), 32)

        // Docking to the same edge must preserve the user's position along that edge. This is the
        // movable left-side placement shown in the Goodnotes reference, not one fixed snap point.
        let lowerLeftFrame = dragPalette(
            to: "left",
            offset: CGVector(dx: 0.01, dy: 0.78)
        )
        XCTAssertGreaterThan(
            lowerLeftFrame.midY,
            upperLeftFrame.midY + 120,
            "左侧工具条应能沿边缘上下移动并记住释放位置"
        )

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Goodnotes palette docked along left edge"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testTextAndLassoNeverShareOneInteractionState() throws {
        let app = launchIsolatedApp(prefix: "text-lasso-state")
        let textButton = app.buttons["tool-text"]
        let lassoButton = app.buttons["tool-lasso"]
        let penButton = app.buttons["tool-pen"]
        let editor = app.textViews["inline-text-editor"]
        let selectionBox = app.descendants(matching: .any)
            .matching(identifier: "lasso-selection-box")
            .firstMatch

        textButton.tap()
        tapCanvas(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(textButton.value as? String, "selected")
        XCTAssertFalse(selectionBox.exists)

        lassoButton.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
        XCTAssertEqual(lassoButton.value as? String, "selected")
        XCTAssertFalse(selectionBox.exists)

        let savedText = app.staticTexts["键入文本"].firstMatch
        XCTAssertTrue(savedText.waitForExistence(timeout: 3))
        savedText.tap()
        XCTAssertTrue(selectionBox.waitForExistence(timeout: 3))
        XCTAssertFalse(editor.exists)
        XCTAssertEqual(lassoButton.value as? String, "selected")

        // Repeated taps are frequently recognized as a double tap. The active
        // lasso tool must keep the same selection UI instead of unexpectedly
        // switching the object into text editing.
        savedText.doubleTap()
        XCTAssertTrue(selectionBox.waitForExistence(timeout: 3))
        XCTAssertFalse(editor.exists)
        XCTAssertEqual(lassoButton.value as? String, "selected")

        let editButton = app.buttons["编辑"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 3))
        editButton.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual(textButton.value as? String, "selected")
        XCTAssertEqual(lassoButton.value as? String, "not-selected")
        XCTAssertFalse(selectionBox.exists)

        penButton.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
        XCTAssertEqual(penButton.value as? String, "selected")
        XCTAssertFalse(selectionBox.exists)
    }

    func testRepeatedTextInsertionsKeepOneEditorAndNoLassoBox() throws {
        let app = launchIsolatedApp(prefix: "repeated-text-state")
        let textButton = app.buttons["tool-text"]
        let editor = app.textViews["inline-text-editor"]
        let selectionBox = app.descendants(matching: .any)
            .matching(identifier: "lasso-selection-box")
            .firstMatch

        textButton.tap()
        XCTAssertFalse(editor.exists)
        textButton.tap()
        XCTAssertFalse(editor.exists)
        tapCanvas(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        textButton.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual(app.textViews.matching(identifier: "inline-text-editor").count, 1)
        XCTAssertEqual(textButton.value as? String, "selected")
        XCTAssertEqual(app.buttons["tool-lasso"].value as? String, "not-selected")
        XCTAssertFalse(selectionBox.exists)

        app.buttons["text-edit-done"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
        XCTAssertFalse(selectionBox.exists)
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label == %@", "键入文本")).count,
            1,
            "Repeated taps on an already-selected text tool must not stack hidden text objects"
        )
    }

    func testRepeatedTextLassoTransitionsNeverLeakTheOtherSelectionUI() throws {
        let app = launchIsolatedApp(prefix: "text-lasso-stress")
        let textButton = app.buttons["tool-text"]
        let lassoButton = app.buttons["tool-lasso"]
        let penButton = app.buttons["tool-pen"]
        let editor = app.textViews["inline-text-editor"]
        let selectionBox = app.descendants(matching: .any)
            .matching(identifier: "lasso-selection-box")
            .firstMatch

        textButton.tap()
        tapCanvas(in: app)
        for cycle in 0..<3 {
            XCTAssertTrue(editor.waitForExistence(timeout: 4))
            XCTAssertEqual(app.textViews.matching(identifier: "inline-text-editor").count, 1)
            XCTAssertFalse(selectionBox.exists)
            XCTAssertEqual(textButton.value as? String, "selected")

            editor.tap()
            editor.typeText(" cycle-\(cycle)")
            lassoButton.tap()

            XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
            XCTAssertEqual(lassoButton.value as? String, "selected")
            XCTAssertEqual(textButton.value as? String, "not-selected")
            XCTAssertFalse(
                selectionBox.exists,
                "Text commit leaked a one-frame lasso box on cycle \(cycle)"
            )

            let savedText = app.descendants(matching: .any)
                .matching(identifier: "page-element-text")
                .firstMatch
            XCTAssertTrue(savedText.waitForExistence(timeout: 3))
            savedText.tap()
            XCTAssertTrue(selectionBox.waitForExistence(timeout: 3))
            XCTAssertFalse(editor.exists)

            let editButton = app.buttons["编辑"]
            XCTAssertTrue(editButton.waitForExistence(timeout: 3))
            editButton.tap()
            XCTAssertTrue(editor.waitForExistence(timeout: 3))
            XCTAssertFalse(selectionBox.exists)
            XCTAssertEqual(textButton.value as? String, "selected")
            XCTAssertEqual(lassoButton.value as? String, "not-selected")
        }

        penButton.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
        XCTAssertFalse(selectionBox.exists)
        XCTAssertEqual(penButton.value as? String, "selected")
    }

    func testRapidTextAndLassoTapsNeverRevealADelayedSelectionBox() throws {
        let app = launchIsolatedApp(prefix: "rapid-text-lasso")
        let textButton = app.buttons["tool-text"]
        let lassoButton = app.buttons["tool-lasso"]
        let editor = app.textViews["inline-text-editor"]
        let selectionBox = app.descendants(matching: .any)
            .matching(identifier: "lasso-selection-box")
            .firstMatch

        XCTAssertTrue(textButton.waitForExistence(timeout: 5))

        // Deliberately do not wait for SwiftUI to settle between taps. This is the
        // real interaction that used to let a hidden text selection arrive late.
        for _ in 0..<4 {
            textButton.tap()
            lassoButton.tap()
            textButton.tap()
        }

        XCTAssertFalse(editor.exists)
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label == %@", "键入文本")).count,
            0,
            "Selecting tools must not create hidden text objects"
        )
        XCTAssertEqual(textButton.value as? String, "selected")
        XCTAssertEqual(lassoButton.value as? String, "not-selected")
        XCTAssertFalse(selectionBox.exists)

        tapCanvas(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(app.textViews.matching(identifier: "inline-text-editor").count, 1)
        lassoButton.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
        XCTAssertEqual(lassoButton.value as? String, "selected")
        XCTAssertFalse(selectionBox.exists)

        // Let all queued view updates drain; a delayed selection must not appear.
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        XCTAssertFalse(selectionBox.exists)
    }

    func testAlternatingBlankAndExistingTextTapsNeverReviveOldLassoState() throws {
        let app = launchIsolatedApp(prefix: "alternating-text-lasso")
        let textButton = app.buttons["tool-text"]
        let lassoButton = app.buttons["tool-lasso"]
        let penButton = app.buttons["tool-pen"]
        let editor = app.textViews["inline-text-editor"]
        let selectionBox = app.descendants(matching: .any)
            .matching(identifier: "lasso-selection-box")
            .firstMatch

        XCTAssertTrue(textButton.waitForExistence(timeout: 5))
        textButton.tap()
        tapCanvas(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 4))
        XCTAssertFalse(selectionBox.exists)
        app.buttons["text-edit-done"].tap()

        let savedText = app.staticTexts["键入文本"].firstMatch
        XCTAssertTrue(savedText.waitForExistence(timeout: 3))

        for cycle in 0..<5 {
            lassoButton.tap()
            savedText.tap()
            XCTAssertTrue(
                selectionBox.waitForExistence(timeout: 3),
                "Lasso did not select the text on cycle \(cycle)"
            )
            XCTAssertFalse(editor.exists)

            textButton.tap()
            XCTAssertTrue(selectionBox.waitForNonExistence(timeout: 3))
            savedText.tap()
            XCTAssertTrue(
                editor.waitForExistence(timeout: 3),
                "Text tool did not edit the text on cycle \(cycle)"
            )
            XCTAssertFalse(selectionBox.exists)

            penButton.tap()
            XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
            XCTAssertFalse(selectionBox.exists)

            // Re-enter text mode through a blank-page tap. This exercises the
            // insertion path as well as the existing-object editing path.
            textButton.tap()
            tapCanvas(in: app, at: CGVector(
                dx: 0.64 + CGFloat(cycle) * 0.025,
                dy: 0.22 + CGFloat(cycle) * 0.035
            ))
            XCTAssertTrue(editor.waitForExistence(timeout: 3))
            XCTAssertEqual(app.textViews.matching(identifier: "inline-text-editor").count, 1)
            XCTAssertFalse(selectionBox.exists)
            app.buttons["text-edit-done"].tap()
            XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
            XCTAssertFalse(selectionBox.exists)
        }
    }

    func testSimulatorLassoReceivesDrag() throws {
        let app = launchIsolatedApp(prefix: "lasso-drag")

        let lassoButton = app.buttons["tool-lasso"]
        XCTAssertTrue(lassoButton.waitForExistence(timeout: 5))
        lassoButton.tap()
        XCTAssertEqual(lassoButton.value as? String, "selected")

        let canvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.18))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.38, dy: 0.34))
        start.press(forDuration: 0.12, thenDragTo: end)

        let feedback = app.descendants(matching: .any)
            .matching(identifier: "lasso-feedback")
            .firstMatch
        XCTAssertTrue(
            feedback.waitForExistence(timeout: 2),
            "Simulator drag never reached the lasso recognizer"
        )
        XCTAssertEqual(feedback.label, "未选中内容")
    }

    func testPDFQuestionMarkerClosedLassoSelection() throws {
        let app = launchIsolatedApp(prefix: "pdf-question-lasso")
        let canvas = app.descendants(matching: .any)["page-canvas-0"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        app.buttons["tool-question"].tap()
        let area = app.descendants(matching: .any)["question-capture-area"]
        XCTAssertTrue(area.waitForExistence(timeout: 3))
        area.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).press(forDuration: 0.05,
            thenDragTo: area.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4)))
        app.buttons["question-confirm"].tap()
        XCTAssertTrue(app.buttons["practice-exit"].waitForExistence(timeout: 15))
        app.buttons["practice-exit"].tap()
        let marker = app.descendants(matching: .any)["question-marker"]
        XCTAssertTrue(marker.waitForExistence(timeout: 10))
        app.buttons["tool-lasso"].tap()
        try synthesizeClosedTouchPath(around: marker.frame.insetBy(dx: -22, dy: -22), on: canvas, in: app)
        let selection = app.descendants(matching: .any)["lasso-selection-box"]
        XCTAssertTrue(selection.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["question-selection-open"].exists)
        XCTAssertTrue(app.buttons["删除"].isEnabled)
        app.buttons["删除"].tap()
        XCTAssertTrue(marker.waitForNonExistence(timeout: 3))
    }

    func testSimulatorClosedLassoSelectsAnExistingObject() throws {
        let app = launchIsolatedApp(prefix: "closed-lasso")
        let settingsScroll = app.scrollViews["tool-settings-scroll"]
        XCTAssertTrue(settingsScroll.waitForExistence(timeout: 5))

        let insertShape = app.buttons["插入图形"]
        XCTAssertTrue(insertShape.waitForExistence(timeout: 5))
        reveal(insertShape, in: settingsScroll, bySwiping: .left)
        insertShape.tap()
        XCTAssertTrue(app.buttons["矩形"].waitForExistence(timeout: 3))
        app.buttons["矩形"].tap()

        let shape = app.descendants(matching: .any)
            .matching(identifier: "page-element-shape")
            .firstMatch
        let selectionBox = app.descendants(matching: .any)
            .matching(identifier: "lasso-selection-box")
            .firstMatch
        let canvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        XCTAssertTrue(shape.waitForExistence(timeout: 3))
        XCTAssertTrue(selectionBox.waitForExistence(timeout: 3))
        XCTAssertTrue(canvas.waitForExistence(timeout: 3))

        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.16)).tap()
        XCTAssertTrue(selectionBox.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.buttons["tool-lasso"].value as? String, "selected")

        try synthesizeClosedTouchPath(
            around: shape.frame.insetBy(dx: -22, dy: -22),
            on: canvas,
            in: app
        )

        let feedback = app.descendants(matching: .any)
            .matching(identifier: "lasso-feedback")
            .firstMatch
        let deleteButton = app.buttons["删除"]
        let deadline = Date().addingTimeInterval(4)
        while !deleteButton.exists, !feedback.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }
        XCTAssertTrue(
            deleteButton.exists,
            "A closed Simulator lasso did not select the enclosed shape; "
                + "feedback=\(feedback.exists ? feedback.label : "none"), "
                + "shape=\(shape.frame), canvas=\(canvas.frame)"
        )
        XCTAssertFalse(feedback.exists)

        // Like Freeform, releasing the lasso immediately presents one tight,
        // deterministic object frame instead of leaving a second dotted selection mode.
        XCTAssertTrue(selectionBox.waitForExistence(timeout: 3))

        // Enclosing just one corner must work too; the shape's center is outside this loop.
        let shapeFrame = shape.frame
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.16)).tap()
        XCTAssertTrue(selectionBox.waitForNonExistence(timeout: 3))
        try synthesizeClosedTouchPath(
            around: CGRect(x: shapeFrame.minX - 14, y: shapeFrame.minY - 14, width: 30, height: 30),
            on: canvas, in: app
        )
        XCTAssertTrue(selectionBox.waitForExistence(timeout: 3))
        XCTAssertEqual(selectionBox.frame.width, shapeFrame.width, accuracy: 2)

        let actionBar = app.descendants(matching: .any)
            .matching(identifier: "selection-action-bar")
            .firstMatch
        XCTAssertTrue(actionBar.waitForExistence(timeout: 2))
        XCTAssertFalse(
            actionBar.frame.intersects(selectionBox.frame),
            "Selection actions must not cover the selected object"
        )
        XCTAssertLessThan(
            actionBar.frame.width,
            canvas.frame.width * 0.55,
            "Selection actions should stay compact like Freeform"
        )
    }

    func testStrokeSelectionMoveResizeRotateUndoRedoAndPersistence() throws {
        let app = launchIsolatedApp(prefix: "stroke-object-transform")
        let canvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))

        drawStroke(
            on: canvas,
            from: CGVector(dx: 0.34, dy: 0.39),
            to: CGVector(dx: 0.56, dy: 0.45)
        )
        waitForValue("笔迹 1", of: canvas)

        app.buttons["tool-lasso"].tap()
        let strokeFrame = CGRect(
            x: canvas.frame.minX + canvas.frame.width * 0.29,
            y: canvas.frame.minY + canvas.frame.height * 0.34,
            width: canvas.frame.width * 0.32,
            height: canvas.frame.height * 0.17
        )
        try synthesizeClosedTouchPath(
            around: strokeFrame,
            on: canvas,
            in: app
        )

        let selectionBox = app.descendants(matching: .any)
            .matching(identifier: "lasso-selection-box")
            .firstMatch
        XCTAssertTrue(selectionBox.waitForExistence(timeout: 4))
        let originalSelectionFrame = selectionBox.frame
        let moveStart = selectionBox.coordinate(
            withNormalizedOffset: CGVector(dx: 0.50, dy: 0.50)
        )
        moveStart.press(
            forDuration: 0.10,
            thenDragTo: moveStart.withOffset(CGVector(dx: 72, dy: 38))
        )
        XCTAssertGreaterThan(
            hypot(
                selectionBox.frame.midX - originalSelectionFrame.midX,
                selectionBox.frame.midY - originalSelectionFrame.midY
            ),
            25
        )

        let frameBeforeResize = selectionBox.frame
        let resizeHandle = app.descendants(matching: .any)
            .matching(identifier: "lasso-resize-bottomRight")
            .firstMatch
        XCTAssertTrue(resizeHandle.waitForExistence(timeout: 3))
        let resizeStart = resizeHandle.coordinate(
            withNormalizedOffset: CGVector(dx: 0.50, dy: 0.50)
        )
        resizeStart.press(
            forDuration: 0.10,
            thenDragTo: resizeStart.withOffset(CGVector(dx: 52, dy: 34))
        )
        XCTAssertGreaterThan(selectionBox.frame.width - frameBeforeResize.width, 20)

        guard let geometryBeforeRotation = drawingGeometryValue(of: canvas) else {
            XCTFail("Canvas did not expose drawing geometry")
            return
        }
        let rotationHandle = app.descendants(matching: .any)
            .matching(identifier: "lasso-rotation-handle")
            .firstMatch
        XCTAssertTrue(rotationHandle.waitForExistence(timeout: 3))
        let rotationStart = rotationHandle.coordinate(
            withNormalizedOffset: CGVector(dx: 0.50, dy: 0.50)
        )
        rotationStart.press(
            forDuration: 0.10,
            thenDragTo: rotationStart.withOffset(CGVector(dx: 62, dy: -30))
        )
        waitUntil(timeout: 3) {
            self.drawingGeometryValue(of: canvas) != geometryBeforeRotation
        }
        guard let geometryAfterRotation = drawingGeometryValue(of: canvas) else {
            XCTFail("Rotation did not publish drawing geometry")
            return
        }

        let undo = app.buttons["撤销"]
        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        waitUntil(timeout: 3) {
            self.drawingGeometryValue(of: canvas) == geometryBeforeRotation
        }
        let redo = app.buttons["重做"]
        XCTAssertTrue(redo.isEnabled)
        redo.tap()
        waitUntil(timeout: 3) {
            self.drawingGeometryValue(of: canvas) == geometryAfterRotation
        }

        app.buttons["tool-pen"].tap()
        XCTAssertTrue(selectionBox.waitForNonExistence(timeout: 3))
        let persistedGeometry = drawingGeometryValue(of: canvas)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        app.launchArguments.append("--reuse-text-interaction-ui-test-workspace")
        app.terminate()
        app.launch()

        let relaunchedCanvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        XCTAssertTrue(relaunchedCanvas.waitForExistence(timeout: 8))
        waitForValue("笔迹 1", of: relaunchedCanvas, timeout: 5)
        waitUntil(timeout: 4) {
            self.drawingGeometryValue(of: relaunchedCanvas) == persistedGeometry
        }
    }

    func testSingleFingerTurnsWholePagesWithoutZoomingOrRevealingAdjacentPages() throws {
#if targetEnvironment(macCatalyst)
        throw XCTSkip("This regression covers direct finger navigation on iPad")
#else
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchIsolatedApp(
            prefix: "whole-page-navigation",
            additionalLaunchArguments: ["--pencil-only-ui-test"]
        )
        openPageSidebar(in: app)
        addPage(named: "横线纸", in: app)
        waitUntil(timeout: 4) { (app.scrollViews["document-page-pager"].value as? String ?? "") == "2 / 2" }
        addPage(named: "方格纸", in: app)
        waitUntil(timeout: 4) { (app.scrollViews["document-page-pager"].value as? String ?? "") == "3 / 3" }
        app.buttons["page-thumbnail-0"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons.matching(identifier: "关闭页面缩略图").firstMatch.tap()

        let pager = app.scrollViews["document-page-pager"]
        let counter = app.scrollViews["document-page-pager"]
        let reset = app.buttons["zoom-reset"]
        XCTAssertTrue(pager.waitForExistence(timeout: 5))

        func assertFullPage(_ index: Int) {
            let canvas = app.descendants(matching: .any)["page-canvas-\(index)"]
            waitUntil(timeout: 4) {
                (counter.value as? String ?? "") == "\(index + 1) / 3"
                    && canvas.exists
                    && !canvas.frame.isEmpty
                    && abs(pager.frame.width - canvas.frame.width) < 1
                    && abs(pager.frame.height - canvas.frame.height) < 1
            }
            let viewport = pager.frame.insetBy(dx: 1, dy: 1)
            XCTAssertEqual(pager.frame, canvas.frame, "An unbounded canvas fills exactly one paging viewport")
            XCTAssertTrue(reset.label.contains("100%"), "One finger must never change the zoom")
            waitForValue("笔迹 0", of: canvas)
            for neighbor in 0..<3 where neighbor != index {
                let otherCanvas = app.descendants(matching: .any)["page-canvas-\(neighbor)"]
                if otherCanvas.exists {
                    XCTAssertFalse(
                        otherCanvas.frame.intersects(viewport),
                        "Page \(neighbor + 1) must not peek into the current viewport"
                    )
                }
            }
        }

        func turnPage(forward: Bool) {
            pager.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: forward ? 0.78 : 0.22))
                .press(
                    forDuration: 0.05,
                    thenDragTo: pager.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.58, dy: forward ? 0.22 : 0.78)
                    ),
                    withVelocity: .slow,
                    thenHoldForDuration: 0
                )
        }

        assertFullPage(0)
        turnPage(forward: true)
        assertFullPage(1)
        rotateApplicationToLandscape(app)
        assertFullPage(1)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "One complete page in the landscape workspace"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        turnPage(forward: true)
        assertFullPage(2)
        turnPage(forward: true)
        assertFullPage(2)
        app.buttons["tool-lasso"].tap()
        turnPage(forward: false)
        assertFullPage(1)
        app.buttons["tool-text"].tap()
        turnPage(forward: false)
        assertFullPage(0)
#endif
    }

    func testTwoFingerZoomStaysOnTheCurrentPageAndSingleFingerCanStillTurnPages() throws {
#if targetEnvironment(macCatalyst)
        throw XCTSkip("XCUIElement pinch synthesis is unavailable on Mac Catalyst")
#else
        let app = launchIsolatedApp(
            prefix: "zoomed-page-navigation",
            additionalLaunchArguments: ["--pencil-only-ui-test"]
        )
        openPageSidebar(in: app)
        addPage(named: "横线纸", in: app)
        waitUntil(timeout: 4) { (app.scrollViews["document-page-pager"].value as? String ?? "") == "2 / 2" }
        app.buttons["page-thumbnail-0"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons.matching(identifier: "关闭页面缩略图").firstMatch.tap()
        let pager = app.scrollViews["document-page-pager"]
        let counter = app.scrollViews["document-page-pager"]
        let canvas = app.descendants(matching: .any)["page-canvas-0"]
        let reset = app.buttons["zoom-reset"]
        waitUntil(timeout: 4) { (counter.value as? String ?? "") == "1 / 2" && canvas.exists }
        let fittedWidth = canvas.frame.width
        let initialVisibleWidth = try canvasViewportRect(of: canvas).width

        canvas.pinch(withScale: 1.55, velocity: 1)
        waitUntil(timeout: 4) { !reset.label.contains("100%") }
        XCTAssertEqual(canvas.frame.width, fittedWidth, accuracy: 1)
        XCTAssertLessThan(try canvasViewportRect(of: canvas).width, initialVisibleWidth / 1.15)
        XCTAssertEqual((counter.value as? String ?? ""), "1 / 2", "A two-finger pinch must not turn the page")
        let zoomLabel = reset.label
        let zoomedViewport = try canvasViewportRect(of: canvas)
        let viewport = pager.frame
        try synthesizeTouchPaths([0.43, 0.57].map { heightFraction in
            SynthesizedTouchPath(samples: [
                (CGPoint(x: viewport.midX + 80, y: viewport.minY + viewport.height * heightFraction), 0),
                (CGPoint(x: viewport.midX + 50, y: viewport.minY + viewport.height * heightFraction), 0.12),
                (CGPoint(x: viewport.midX - 80, y: viewport.minY + viewport.height * heightFraction), 0.40)
            ], liftOffset: 0.46)
        }, on: pager, in: app)
        XCTAssertGreaterThan(try canvasViewportRect(of: canvas).minX, zoomedViewport.minX + 40)
        XCTAssertEqual((counter.value as? String ?? ""), "1 / 2", "Two fingers must pan only the current paper")
        XCTAssertEqual(reset.label, zoomLabel, "A parallel two-finger drag must preserve scale")

        pager.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.78))
            .press(
                forDuration: 0.05,
                thenDragTo: pager.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.22)),
                withVelocity: .slow,
                thenHoldForDuration: 0
            )
        waitUntil(timeout: 4) { (counter.value as? String ?? "") == "2 / 2" }
        XCTAssertTrue(reset.label.contains("100%"), "Each canvas remembers its own camera")
        reset.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let secondCanvas = app.descendants(matching: .any)["page-canvas-1"]
        waitUntil(timeout: 4) {
            reset.label.contains("100%")
                && pager.frame.contains(secondCanvas.frame)
        }
        XCTAssertTrue(pager.frame.contains(secondCanvas.frame))
        waitForValue("笔迹 0", of: secondCanvas)

        // Canvas pages can now shrink below fit-page. A staggered pinch must still hold the
        // current page, even after the first finger lifts and the remaining finger drags down.
        let fittedFrame = secondCanvas.frame
        let secondVisibleWidth = try canvasViewportRect(of: secondCanvas).width
        let startY = fittedFrame.midY - fittedFrame.height * 0.15
        let pinchY = startY + fittedFrame.height * 0.13
        try synthesizeTouchPaths([
            SynthesizedTouchPath(samples: [
                (CGPoint(x: fittedFrame.midX - fittedFrame.width * 0.30, y: startY), 0),
                (CGPoint(x: fittedFrame.midX - fittedFrame.width * 0.30, y: startY + 28), 0.10),
                (CGPoint(x: fittedFrame.midX - fittedFrame.width * 0.20, y: startY + 28), 0.24),
                (CGPoint(x: fittedFrame.midX - fittedFrame.width * 0.06, y: pinchY), 0.46)
            ], liftOffset: 0.52),
            SynthesizedTouchPath(samples: [
                (CGPoint(x: fittedFrame.midX + fittedFrame.width * 0.30, y: startY + 28), 0.16),
                (CGPoint(x: fittedFrame.midX + fittedFrame.width * 0.20, y: startY + 28), 0.24),
                (CGPoint(x: fittedFrame.midX + fittedFrame.width * 0.06, y: pinchY), 0.46),
                (CGPoint(x: fittedFrame.midX + fittedFrame.width * 0.06, y: pinchY), 0.58),
                (CGPoint(x: fittedFrame.midX + fittedFrame.width * 0.06, y: startY + fittedFrame.height * 0.48), 0.86)
            ], liftOffset: 0.90)
        ], on: pager, in: app)
        waitUntil(timeout: 4) {
            (counter.value as? String ?? "") == "2 / 2" && !reset.label.contains("100%")
                && abs(secondCanvas.frame.width - fittedFrame.width) <= 2
        }
        XCTAssertGreaterThan(try canvasViewportRect(of: secondCanvas).width, secondVisibleWidth * 2)
        XCTAssertEqual(secondCanvas.frame.midX, pager.frame.midX, accuracy: 2)
        XCTAssertEqual(secondCanvas.frame.midY, pager.frame.midY, accuracy: 2)

        pager.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.22))
            .press(
                forDuration: 0.05,
                thenDragTo: pager.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.78)),
                withVelocity: .slow,
                thenHoldForDuration: 0
            )
        waitUntil(timeout: 4) { (counter.value as? String ?? "") == "1 / 2" }
        XCTAssertEqual(reset.label, zoomLabel, "Returning to a canvas restores that canvas's camera")
        XCTAssertEqual(canvas.frame.width, fittedWidth, accuracy: 2)
        if secondCanvas.exists {
            XCTAssertFalse(secondCanvas.frame.intersects(pager.frame.insetBy(dx: 1, dy: 1)))
        }
#endif
    }

    func testPDFScrollStopsBetweenPagesAndCrossesBoundaryWhileZoomed() throws {
#if targetEnvironment(macCatalyst)
        throw XCTSkip("This regression covers direct finger navigation on iPad")
#else
        XCUIDevice.shared.orientation = .portrait
        let app = launchIsolatedApp(prefix: "pdf-continuous-scroll",
                                    additionalLaunchArguments: ["--pencil-only-ui-test"])
        let reader = app.scrollViews["document-page-pager"]
        let first = app.descendants(matching: .any)["page-canvas-0"]
        let second = app.descendants(matching: .any)["page-canvas-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let originalTop = first.frame.minY

        func dragUp(_ distance: CGFloat) {
            let start = reader.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.85))
            start.press(forDuration: 0.05,
                        thenDragTo: start.withOffset(CGVector(dx: 0, dy: -distance)),
                        withVelocity: .slow, thenHoldForDuration: 0.35)
        }

        // Release at the boundary: both sheets must remain visible without snapping to a page.
        dragUp(min(reader.frame.height * 0.6, first.frame.maxY + 8 - reader.frame.midY))
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertLessThan(first.frame.minY, originalTop - 80)
        XCTAssertGreaterThan(first.frame.maxY, reader.frame.minY + 60)
        XCTAssertLessThan(second.frame.minY, reader.frame.maxY - 60)
        XCTAssertEqual(second.frame.minY - first.frame.maxY, 16, accuracy: 2)
        let stoppedTop = first.frame.minY
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(first.frame.minY, stoppedTop, accuracy: 2, "PDF must stay where the finger released")
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "PDF continuous scrolling across two pages"
        image.lifetime = .keepAlways
        add(image)

        // Zoom uses the same document scroll surface; it must not trap drags inside one page.
        try pinchCanvas(reader, scale: 1.4, in: app)
        waitUntil(timeout: 4) { !app.buttons["zoom-reset"].label.contains("100%") }
        let widthAfterZoom = first.frame.width
        XCTAssertGreaterThan(widthAfterZoom, reader.frame.width)
        for _ in 0..<5 where !second.exists || second.frame.minY > reader.frame.midY {
            dragUp(reader.frame.height * 0.4)
        }
        XCTAssertLessThan(second.frame.minY, reader.frame.midY)
        XCTAssertEqual(second.frame.width, widthAfterZoom, accuracy: 2)
        waitUntil(timeout: 4) { reader.value as? String == "2 / 2" }
#endif
    }

    func testPDFVisibleSecondPageReceivesInkAndUndo() throws {
#if targetEnvironment(macCatalyst)
        throw XCTSkip("This regression covers iPad drawing input")
#else
        XCUIDevice.shared.orientation = .portrait
        let app = launchIsolatedApp(prefix: "pdf-continuous-ink")
        let reader = app.scrollViews["document-page-pager"]
        let first = app.descendants(matching: .any)["page-canvas-0"]
        let second = app.descendants(matching: .any)["page-canvas-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        try pinchCanvas(reader, scale: 0.4, in: app)
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(first.frame.minY, reader.frame.minY)
        XCTAssertLessThan(second.frame.maxY, reader.frame.maxY)
        let frame = second.frame
        try synthesizeTouchPath([
            CGPoint(x: frame.minX + frame.width * 0.25, y: frame.midY),
            CGPoint(x: frame.minX + frame.width * 0.65, y: frame.midY)
        ], on: second, in: app, holdBeforeLift: 0.04)
        waitForValue("笔迹 1", of: second)
        waitForValue("笔迹 0", of: first)
        app.buttons["撤销"].tap()
        waitForValue("笔迹 0", of: second)
        app.buttons["重做"].tap()
        waitForValue("笔迹 1", of: second)
#endif
    }

    func testPDFCanZoomToTenPercentAndZoomBackFromTheMargins() throws {
#if targetEnvironment(macCatalyst)
        throw XCTSkip("This regression covers direct finger navigation on iPad")
#else
        XCUIDevice.shared.orientation = .portrait
        let app = launchIsolatedApp(prefix: "pdf-pinch-in-page-lock",
                                    additionalLaunchArguments: ["--pencil-only-ui-test"])
        let pager = app.scrollViews["document-page-pager"]
        let canvas = app.descendants(matching: .any)["page-canvas-0"]
        let reset = app.buttons["zoom-reset"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let fittedFrame = canvas.frame
        try pinchCanvas(pager, scale: 0.05, in: app)
        waitUntil(timeout: 4) { reset.label.contains("10%") }
        XCTAssertEqual(canvas.frame.width, fittedFrame.width * 0.1, accuracy: 2)
        XCTAssertEqual(pager.value as? String, "1 / 2")
        try pinchCanvas(pager, scale: 0.4, in: app)
        waitUntil(timeout: 3) { reset.label.contains("10%") }
        // Both contacts begin in the surrounding workspace, outside the tiny paper.
        try pinchCanvas(pager, scale: 2, in: app)
        waitUntil(timeout: 4) { !reset.label.contains("10%") }
        XCTAssertGreaterThan(canvas.frame.width, fittedFrame.width * 0.15)
        XCTAssertEqual(pager.value as? String, "1 / 2")
        reset.tap()
        waitUntil(timeout: 4) { reset.label.contains("100%") }
        XCTAssertEqual(canvas.frame.width, fittedFrame.width, accuracy: 2)
#endif
    }

    func testPinchInKeepsPageLockedUntilBothFingersLift() throws {
#if targetEnvironment(macCatalyst)
        throw XCTSkip("This regression covers direct finger navigation on iPad")
#else
        let app = launchIsolatedApp(
            prefix: "pdf-pinch-in-staggered-release",
            additionalLaunchArguments: ["--pencil-only-ui-test"]
        )
        let pager = app.scrollViews["document-page-pager"]
        let counter = app.scrollViews["document-page-pager"]
        let reset = app.buttons["zoom-reset"]
        waitUntil(timeout: 5) { (counter.value as? String ?? "") == "1 / 2" && pager.exists }

        // Exercise both directions and both sides of the fit-page boundary. The trailing finger
        // travels far enough to turn a page if the pager takes over when the pinch ends early.
        for pageIndex in 0...1 {
            let canvas = app.descendants(matching: .any)["page-canvas-\(pageIndex)"]
            let fittedFrame = canvas.frame
            for startsZoomed in [false, true] {
                reset.tap()
                if startsZoomed {
                    canvas.pinch(withScale: 1.55, velocity: 1)
                    waitUntil(timeout: 4) { !reset.label.contains("100%") }
                }
                let frame = fittedFrame
                let direction: CGFloat = pageIndex == 0 ? -1 : 1
                let startY = frame.midY - direction * frame.height * 0.15
                let initialDragY = startY + direction * 28
                let pinchY = startY + direction * frame.height * 0.13
                let endY = startY + direction * frame.height * 0.48
                try synthesizeTouchPaths([
                    SynthesizedTouchPath(samples: [
                        (CGPoint(x: frame.midX - frame.width * 0.30, y: startY), 0),
                        (CGPoint(x: frame.midX - frame.width * 0.30, y: initialDragY), 0.10),
                        (CGPoint(x: frame.midX - frame.width * 0.20, y: initialDragY), 0.24),
                        (CGPoint(x: frame.midX - frame.width * 0.06, y: pinchY), 0.46)
                    ], liftOffset: 0.52),
                    SynthesizedTouchPath(samples: [
                        (CGPoint(x: frame.midX + frame.width * 0.30, y: initialDragY), 0.16),
                        (CGPoint(x: frame.midX + frame.width * 0.20, y: initialDragY), 0.24),
                        (CGPoint(x: frame.midX + frame.width * 0.06, y: pinchY), 0.46),
                        (CGPoint(x: frame.midX + frame.width * 0.06, y: pinchY), 0.58),
                        (CGPoint(x: frame.midX + frame.width * 0.06, y: endY), 0.86)
                    ], liftOffset: 0.90)
                ], on: pager, in: app)
                waitUntil(timeout: 4) {
                    (counter.value as? String ?? "") == "\(pageIndex + 1) / 2"
                        && !reset.label.contains("100%")
                        && canvas.frame.width < fittedFrame.width
                }
            }

            reset.tap()
            // A fresh single-finger gesture must work immediately after all pinch contacts lift.
            pager.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: pageIndex == 0 ? 0.78 : 0.22))
                .press(
                    forDuration: 0.05,
                    thenDragTo: pager.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.58, dy: pageIndex == 0 ? 0.22 : 0.78)
                    ),
                    withVelocity: .slow,
                    thenHoldForDuration: 0
                )
            waitUntil(timeout: 4) { (counter.value as? String ?? "") == "\(2 - pageIndex) / 2" }
            XCTAssertTrue(reset.label.contains("100%"))
        }
#endif
    }

    func testUnboundedCanvasZoomPanAndOutsideInkSurviveRelaunch() throws {
#if targetEnvironment(macCatalyst)
        throw XCTSkip("XCUIElement pinch synthesis is unavailable on Mac Catalyst")
#else
        let app = launchIsolatedApp(prefix: "unbounded-canvas")
        let canvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        let reset = app.buttons["zoom-reset"]
        let pager = app.scrollViews["document-page-pager"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        XCTAssertTrue(reset.waitForExistence(timeout: 3))
        XCTAssertTrue(reset.label.contains("100%"))

        let initialFrame = canvas.frame
        let initialViewport = try canvasViewportRect(of: canvas)
        XCTAssertEqual(initialFrame.width, pager.frame.width, accuracy: 1)
        XCTAssertEqual(initialFrame.height, pager.frame.height, accuracy: 1)
        drawStroke(on: canvas)
        waitForValue("笔迹 1", of: canvas)
        let initialInk = drawingGeometryValue(of: canvas)
        try pinchCanvas(canvas, scale: 0.05, in: app)
        waitUntil(timeout: 3) {
            reset.label.contains("10%")
        }
        XCTAssertEqual(canvas.frame, initialFrame, "Zoom changes the camera, never the drawable surface")
        let halfViewport = try canvasViewportRect(of: canvas)
        XCTAssertEqual(halfViewport.width, initialViewport.width * 10, accuracy: 2)
        XCTAssertEqual(halfViewport.height, initialViewport.height * 10, accuracy: 2)
        XCTAssertEqual(drawingGeometryValue(of: canvas), initialInk)

        try pinchCanvas(canvas, scale: 0.55, in: app)
        waitUntil(timeout: 3) {
            reset.label.contains("10%")
        }
        let beforePan = try canvasViewportRect(of: canvas)
        let frame = canvas.frame
        try synthesizeTouchPaths([0.42, 0.58].map { xFraction in
            SynthesizedTouchPath(samples: [
                (CGPoint(x: frame.minX + frame.width * xFraction, y: frame.minY + frame.height * 0.35), 0),
                (CGPoint(x: frame.minX + frame.width * (xFraction + 0.10), y: frame.minY + frame.height * 0.45), 0.20),
                (CGPoint(x: frame.minX + frame.width * (xFraction + 0.25), y: frame.minY + frame.height * 0.60), 0.50)
            ], liftOffset: 0.55)
        }, on: pager, in: app)
        let movedViewport = try canvasViewportRect(of: canvas)
        XCTAssertLessThan(movedViewport.minX, beforePan.minX - 100)
        XCTAssertLessThan(movedViewport.minY, beforePan.minY - 100)
        XCTAssertEqual(movedViewport.width, halfViewport.width, accuracy: 2)
        XCTAssertEqual(drawingGeometryValue(of: canvas), initialInk)
        XCTAssertEqual((app.scrollViews["document-page-pager"].value as? String ?? ""), "1 / 1")

        app.buttons["ink-width-preset-2"].tap()
        drawStroke(on: canvas, from: CGVector(dx: 0.22, dy: 0.22), to: CGVector(dx: 0.38, dy: 0.26))
        waitForValue("笔迹 2", of: canvas)
        let outsideInkBounds = try drawingBounds(of: canvas)
        XCTAssertLessThan(outsideInkBounds.minX, 0, "Writing left of the former paper must remain at negative coordinates")
        XCTAssertLessThan(outsideInkBounds.minY, 0, "Writing above the former paper must remain at negative coordinates")
        XCTAssertEqual(outsideInkBounds.minX, movedViewport.minX + movedViewport.width * 0.22, accuracy: 18)
        XCTAssertGreaterThan(try XCTUnwrap(inkDarkness(
            in: canvas.screenshot().pngRepresentation,
            around: CGPoint(x: 0.30, y: 0.24),
            radius: 12
        )), 300, "Ink must render under the actual input position outside the old page")
        let inkGeometry = drawingGeometryValue(of: canvas)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Unbounded canvas at 10 percent with ink outside the old paper"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.buttons["home-button"].tap()
        app.terminate()
        app.launchArguments.append("--reuse-text-interaction-ui-test-workspace")
        app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        waitForValue("笔迹 2", of: canvas)
        XCTAssertTrue(reset.label.contains("10%"))
        XCTAssertEqual(try canvasViewportRect(of: canvas), movedViewport)
        XCTAssertEqual(drawingGeometryValue(of: canvas), inkGeometry)
        reset.tap()
        waitUntil(timeout: 3) {
            reset.label.contains("100%")
                && abs(canvas.frame.width - initialFrame.width) <= 2
        }
        XCTAssertEqual(drawingGeometryValue(of: canvas), inkGeometry, "Zooming must preserve the ink's page coordinates")
        XCTAssertEqual(try canvasViewportRect(of: canvas).width, initialViewport.width, accuracy: 2)

        canvas.pinch(withScale: 1.55, velocity: 1.0)
        waitUntil(timeout: 3) {
            !reset.label.contains("100%")
        }
        XCTAssertEqual(canvas.frame, initialFrame)
        XCTAssertLessThan(try canvasViewportRect(of: canvas).width, initialViewport.width * 0.85)

        reset.tap()
        waitUntil(timeout: 3) {
            reset.label.contains("100%")
                && abs(canvas.frame.width - initialFrame.width) <= 2
        }
        XCTAssertEqual(canvas.frame.width, initialFrame.width, accuracy: 2)
#endif
    }

    func testUnboundedTextAndLassoUseTheCameraOutsideTheOriginalPaper() throws {
#if targetEnvironment(macCatalyst)
        throw XCTSkip("This regression uses iPad touch input")
#else
        let app = launchIsolatedApp(prefix: "unbounded-text-lasso")
        let canvas = app.descendants(matching: .any)["page-canvas-0"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        try pinchCanvas(canvas, scale: 0.42, in: app)
        let viewport = try canvasViewportRect(of: canvas)
        XCTAssertLessThan(viewport.minY + viewport.height * 0.25, 0)
        app.buttons["tool-text"].tap()
        tapCanvas(in: app, at: CGVector(dx: 0.28, dy: 0.25))
        let editor = app.textViews["inline-text-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 4))
        replaceText(in: editor, with: "Outside")
        app.buttons["text-edit-done"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 4))
        let text = app.staticTexts["Outside"]
        XCTAssertTrue(text.waitForExistence(timeout: 3))
        XCTAssertLessThan(text.frame.midY, canvas.frame.minY + canvas.frame.height * 0.35)

        app.buttons["tool-lasso"].tap()
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let selection = app.descendants(matching: .any)["lasso-selection-box"]
        XCTAssertTrue(selection.waitForExistence(timeout: 3))
        let originalFrame = text.frame
        let start = selection.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 60, dy: 45)))
        XCTAssertEqual(text.frame.midX - originalFrame.midX, 60, accuracy: 5)
        XCTAssertEqual(text.frame.midY - originalFrame.midY, 45, accuracy: 5)
        let movedFrame = text.frame
        let beforeZoom = try canvasViewportRect(of: canvas)
        try pinchCanvas(canvas, scale: 1.55, in: app)
        let afterZoom = try canvasViewportRect(of: canvas)
        let ratio = beforeZoom.width / afterZoom.width
        XCTAssertGreaterThan(ratio, 1.4, "Camera gestures also work over the lasso overlay")
        XCTAssertEqual(text.frame.width / movedFrame.width, ratio, accuracy: 0.12)

        let savedFrame = text.frame
        app.buttons["home-button"].tap()
        app.terminate()
        app.launchArguments.append("--reuse-text-interaction-ui-test-workspace")
        app.launch()
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertEqual(text.frame.midX, savedFrame.midX, accuracy: 3)
        XCTAssertEqual(text.frame.midY, savedFrame.midY, accuracy: 3)
#endif
    }

    func testSingleFingerWritingDoesNotPanZoomedPaper() throws {
#if targetEnvironment(macCatalyst)
        throw XCTSkip("XCUIElement pinch synthesis is unavailable on Mac Catalyst")
#else
        let app = launchIsolatedApp(prefix: "single-finger-paper-pan")
        let canvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        let reset = app.buttons["zoom-reset"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        XCTAssertTrue(reset.waitForExistence(timeout: 3))

        canvas.pinch(withScale: 1.55, velocity: 1.0)
        waitUntil(timeout: 3) {
            !reset.label.contains("100%")
        }
        let frameBeforeWriting = canvas.frame

        drawStroke(on: canvas)
        waitForValue("笔迹 1", of: canvas)
        XCTAssertEqual(canvas.frame.minX, frameBeforeWriting.minX, accuracy: 2)
        XCTAssertEqual(canvas.frame.minY, frameBeforeWriting.minY, accuracy: 2)
#endif
    }

    func testPenUndoRedoAndClearChangeTheActualCanvas() throws {
        let app = launchIsolatedApp(prefix: "pen-history-clear")
        let canvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        XCTAssertTrue((canvas.value as? String)?.hasPrefix("笔迹 0") == true)

        drawStroke(on: canvas)
        waitForValue("笔迹 1", of: canvas)

        let undo = app.buttons["撤销"]
        XCTAssertTrue(undo.isEnabled, "Canvas state: \(String(describing: canvas.value))")
        undo.tap()
        waitForValue("笔迹 0", of: canvas)

        let redo = app.buttons["重做"]
        XCTAssertTrue(redo.isEnabled)
        redo.tap()
        waitForValue("笔迹 1", of: canvas)

        func requestClear() {
            let more = app.buttons["更多文稿操作"]
            XCTAssertTrue(more.waitForExistence(timeout: 3))
            more.tap()
            let clear = app.buttons["清空当前页批注"]
            XCTAssertTrue(clear.waitForExistence(timeout: 3))
            clear.tap()
        }

        requestClear()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["取消"].tap()
        XCTAssertTrue((canvas.value as? String)?.hasPrefix("笔迹 1") == true)

        requestClear()
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["清空"].tap()
        waitForValue("笔迹 0", of: canvas)

        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        waitForValue("笔迹 1", of: canvas)
    }

    func testInkColorWidthPresetsAndEraserControlsTrackTheSelectedTool() throws {
        let app = launchIsolatedApp(prefix: "tool-settings")

        let penButton = app.buttons["tool-pen"]
        XCTAssertTrue(penButton.waitForExistence(timeout: 5))
        XCTAssertEqual(penButton.value as? String, "selected")
        penButton.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "pen-variant-settings")
                .firstMatch
                .waitForExistence(timeout: 3)
        )
        let fountainPen = app.buttons["pen-variant-fountainPen"]
        XCTAssertTrue(fountainPen.waitForExistence(timeout: 3))
        fountainPen.tap()
        waitUntil(timeout: 3) {
            app.buttons["tool-pen"].label.contains("钢笔")
        }

        let ocean = app.buttons["ink-color-ocean"]
        let graphite = app.buttons["ink-color-graphite"]
        let settingsScroll = app.scrollViews["tool-settings-scroll"]
        XCTAssertTrue(settingsScroll.waitForExistence(timeout: 5))
        XCTAssertTrue(ocean.waitForExistence(timeout: 5))
        reveal(ocean, in: settingsScroll, bySwiping: .left)
        ocean.tap()
        XCTAssertEqual(ocean.value as? String, "selected")
        XCTAssertEqual(graphite.value as? String, "not-selected")

        let thickWidth = app.buttons["ink-width-preset-2"]
        XCTAssertTrue(thickWidth.waitForExistence(timeout: 3))
        thickWidth.tap()
        XCTAssertEqual(thickWidth.value as? String, "selected")

        app.buttons["tool-eraser"].tap()
        XCTAssertFalse(app.buttons["ink-width-preset-2"].exists)
        app.buttons["tool-eraser"].tap()
        let strokeEraser = app.buttons["eraser-mode-stroke"]
        XCTAssertTrue(strokeEraser.waitForExistence(timeout: 3))
        strokeEraser.tap()
        waitUntil(timeout: 3) {
            app.buttons["tool-eraser"].label.contains("整笔")
        }

        app.buttons["tool-pen"].tap()
        app.buttons["tool-marker"].tap()
        XCTAssertTrue(app.buttons["ink-width-preset-2"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["eraser-mode-stroke"].exists)
        XCTAssertTrue(app.buttons["ink-color-ocean"].exists)
    }

    func testStrokeEraserDeletesActualInkAndUndoRestoresIt() throws {
        let app = launchIsolatedApp(prefix: "stroke-eraser")
        let canvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))

        drawStroke(on: canvas)
        waitForValue("笔迹 1", of: canvas)

        let eraserButton = app.buttons["tool-eraser"]
        XCTAssertTrue(eraserButton.waitForExistence(timeout: 3))
        eraserButton.tap()
        XCTAssertEqual(eraserButton.value as? String, "selected")
        eraserButton.tap()

        let strokeEraser = app.buttons["eraser-mode-stroke"]
        XCTAssertTrue(strokeEraser.waitForExistence(timeout: 3))
        strokeEraser.tap()

        let eraseStart = canvas.coordinate(
            withNormalizedOffset: CGVector(dx: 0.45, dy: 0.25)
        )
        let eraseEnd = canvas.coordinate(
            withNormalizedOffset: CGVector(dx: 0.45, dy: 0.56)
        )
        eraseStart.press(forDuration: 0.08, thenDragTo: eraseEnd)
        waitForValue("笔迹 0", of: canvas)

        let undo = app.buttons["撤销"]
        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        waitForValue("笔迹 1", of: canvas)
    }

    func testStrokeEraserDeletionSurvivesAutosavePageSwitchAndRelaunch() throws {
        let app = launchIsolatedApp(prefix: "stroke-eraser-persistence")
        let canvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))

        drawStroke(on: canvas)
        waitForValue("笔迹 1", of: canvas)

        // Exercise the persisted-stroke path as well as a freshly drawn in-memory stroke. The
        // original resurrection bug depended on matching a decoded PencilKit stroke back to its
        // collaboration identity.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        app.launchArguments.append("--reuse-text-interaction-ui-test-workspace")
        app.terminate()
        app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 8))
        waitForValue("笔迹 1", of: canvas, timeout: 5)

        app.buttons["tool-eraser"].tap()
        app.buttons["tool-eraser"].tap()
        let strokeEraser = app.buttons["eraser-mode-stroke"]
        XCTAssertTrue(strokeEraser.waitForExistence(timeout: 3))
        strokeEraser.tap()

        let eraseStart = canvas.coordinate(
            withNormalizedOffset: CGVector(dx: 0.45, dy: 0.25)
        )
        let eraseEnd = canvas.coordinate(
            withNormalizedOffset: CGVector(dx: 0.45, dy: 0.56)
        )
        eraseStart.press(forDuration: 0.08, thenDragTo: eraseEnd)
        waitForValue("笔迹 0", of: canvas)

        // The regression happened only after the materialized-asset save reloaded the
        // collaboration log. Waiting beyond the idle window proves this is not merely a visual erase.
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        XCTAssertTrue(
            (canvas.value as? String)?.hasPrefix("笔迹 0") == true,
            "整笔擦除在自动保存刷新后恢复了旧笔迹"
        )

        openPageSidebar(in: app)
        addPage(named: "空白页", in: app)
        let firstPage = app.buttons["page-thumbnail-0"]
        XCTAssertTrue(firstPage.waitForExistence(timeout: 4))
        // iOS 26 can report a visible SwiftUI grid button as non-hittable after a Menu inserts a
        // page. A coordinate tap exercises the same UI path without relying on that stale AX bit.
        firstPage.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        waitForValue("笔迹 0", of: canvas, timeout: 5)

        app.terminate()
        app.launch()

        let relaunchedCanvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        XCTAssertTrue(relaunchedCanvas.waitForExistence(timeout: 8))
        waitForValue("笔迹 0", of: relaunchedCanvas, timeout: 5)
    }

    func testContinuousStrokeSurvivesPauseAutosaveAndRelaunch() throws {
        let app = launchIsolatedApp(prefix: "continuous-stroke-persistence")
        let canvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))

        let normalizedPoints = [
            CGPoint(x: 0.18, y: 0.24),
            CGPoint(x: 0.28, y: 0.34),
            CGPoint(x: 0.39, y: 0.25),
            CGPoint(x: 0.49, y: 0.38),
            CGPoint(x: 0.60, y: 0.27),
            CGPoint(x: 0.72, y: 0.41)
        ]
        let points = normalizedPoints.map { point in
            CGPoint(
                x: canvas.frame.minX + canvas.frame.width * point.x,
                y: canvas.frame.minY + canvas.frame.height * point.y
            )
        }
        try synthesizeTouchPath(
            points,
            on: canvas,
            in: app,
            holdBeforeLift: 0.12,
            pauseAfterPointIndex: 3,
            pauseDuration: 1.05
        )
        waitForValue("笔迹 1", of: canvas, timeout: 5)
        guard let committedGeometry = drawingGeometryValue(of: canvas) else {
            return XCTFail("连续笔迹没有发布最终几何范围")
        }

        // The old implementation emitted every transient PencilKit sample. Crossing the complete
        // idle-save window could therefore reload a partial snapshot into the live touch.
        RunLoop.current.run(until: Date().addingTimeInterval(3.0))
        XCTAssertTrue(
            (canvas.value as? String)?.hasPrefix("笔迹 1") == true,
            "连续书写在自动保存刷新后消失：\(String(describing: canvas.value))"
        )
        XCTAssertTrue(
            (canvas.value as? String)?.contains("同步重载 0") == true,
            "本地自动保存不应重新安装正在显示的 PencilKit 绘图：\(String(describing: canvas.value))"
        )
        XCTAssertEqual(drawingGeometryValue(of: canvas), committedGeometry)

        app.launchArguments.append("--reuse-text-interaction-ui-test-workspace")
        app.terminate()
        app.launch()
        let relaunchedCanvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        XCTAssertTrue(relaunchedCanvas.waitForExistence(timeout: 8))
        waitForValue("笔迹 1", of: relaunchedCanvas, timeout: 5)
        XCTAssertEqual(drawingGeometryValue(of: relaunchedCanvas), committedGeometry)
    }

    func testPreviousStrokeAutosaveCannotReplaceNextActiveStroke() throws {
        let app = launchIsolatedApp(prefix: "overlapping-stroke-autosave")
        let canvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))

        let firstStroke = [
            CGPoint(
                x: canvas.frame.minX + canvas.frame.width * 0.18,
                y: canvas.frame.minY + canvas.frame.height * 0.20
            ),
            CGPoint(
                x: canvas.frame.minX + canvas.frame.width * 0.32,
                y: canvas.frame.minY + canvas.frame.height * 0.30
            )
        ]
        try synthesizeTouchPath(
            firstStroke,
            on: canvas,
            in: app,
            holdBeforeLift: 0.08
        )
        waitForValue("笔迹 1", of: canvas, timeout: 5)

        let secondStroke = [
            CGPoint(
                x: canvas.frame.minX + canvas.frame.width * 0.42,
                y: canvas.frame.minY + canvas.frame.height * 0.22
            ),
            CGPoint(
                x: canvas.frame.minX + canvas.frame.width * 0.52,
                y: canvas.frame.minY + canvas.frame.height * 0.34
            ),
            CGPoint(
                x: canvas.frame.minX + canvas.frame.width * 0.62,
                y: canvas.frame.minY + canvas.frame.height * 0.25
            ),
            CGPoint(
                x: canvas.frame.minX + canvas.frame.width * 0.74,
                y: canvas.frame.minY + canvas.frame.height * 0.38
            )
        ]
        try synthesizeTouchPath(
            secondStroke,
            on: canvas,
            in: app,
            holdBeforeLift: 0.10,
            pauseAfterPointIndex: 2,
            pauseDuration: 1.05
        )
        waitForValue("笔迹 2", of: canvas, timeout: 5)
        guard let committedGeometry = drawingGeometryValue(of: canvas) else {
            return XCTFail("跨自动保存的第二笔没有发布最终几何范围")
        }

        RunLoop.current.run(until: Date().addingTimeInterval(3.0))
        XCTAssertTrue(
            (canvas.value as? String)?.hasPrefix("笔迹 2") == true,
            "上一笔自动保存覆盖了仍在书写的下一笔：\(String(describing: canvas.value))"
        )
        XCTAssertTrue(
            (canvas.value as? String)?.contains("同步重载 0") == true,
            "相邻笔画完成后不应由本地资产回声重装画布：\(String(describing: canvas.value))"
        )
        XCTAssertEqual(drawingGeometryValue(of: canvas), committedGeometry)

        app.launchArguments.append("--reuse-text-interaction-ui-test-workspace")
        app.terminate()
        app.launch()
        let relaunchedCanvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        XCTAssertTrue(relaunchedCanvas.waitForExistence(timeout: 8))
        waitForValue("笔迹 2", of: relaunchedCanvas, timeout: 5)
        XCTAssertEqual(drawingGeometryValue(of: relaunchedCanvas), committedGeometry)
    }

    func testShortHoldAndLiftKeepOriginalInkWithoutDeferredRecognition() throws {
        let app = launchIsolatedApp(prefix: "shape-hold-production-path")
        let canvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))

        let lineStart = canvas.coordinate(
            withNormalizedOffset: CGVector(dx: 0.24, dy: 0.30)
        )
        let lineEnd = canvas.coordinate(
            withNormalizedOffset: CGVector(dx: 0.66, dy: 0.34)
        )
        lineStart.press(
            forDuration: 0.08,
            thenDragTo: lineEnd,
            withVelocity: .slow,
            thenHoldForDuration: 0.10
        )
        waitForValue("笔迹 1", of: canvas, timeout: 5)
        let originalGeometry = drawingGeometryValue(of: canvas)

        // Lifting cancels the hold; waiting afterwards must never turn handwriting into a shape.
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        XCTAssertTrue((canvas.value as? String)?.contains("吸附 无") == true)
        XCTAssertTrue((canvas.value as? String)?.contains("停笔预览 0") == true)
        XCTAssertEqual(drawingGeometryValue(of: canvas), originalGeometry)
        drawStroke(on: canvas)
        waitForValue("笔迹 2", of: canvas)
    }

    func testHeldInkFiveShapesPreviewUndoEraserAndPersistence() throws {
        let app = launchIsolatedApp(prefix: "shape-hold-snap")
        let canvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        // Tool preferences persist outside this isolated document fixture. Pick the default pen
        // explicitly so a preceding pencil/highlighter test cannot change this regression's ink.
        app.buttons["tool-pen"].tap()
        app.buttons["pen-variant-fountainPen"].tap()
        app.buttons["ink-width-preset-0"].tap()
        app.buttons["ink-color-graphite"].tap()

        let frame = canvas.frame
        let line = (0...12).map { index in
            CGPoint(x: frame.minX + frame.width * (0.24 + CGFloat(index) / 12 * 0.48),
                    y: frame.minY + frame.height * 0.18 + sin(CGFloat(index) / 12 * .pi * 3) * 3)
        }
        try synthesizeTouchPath(line, on: canvas, in: app, holdBeforeLift: 1.15)
        waitForValueContaining("吸附 直线", of: canvas, timeout: 5)
        waitForValue("笔迹 1", of: canvas, timeout: 5)
        XCTAssertTrue((canvas.value as? String)?.contains("停笔预览 1") == true,
                      "The regular shape must finish rendering while the contact is still down")
        let snappedLineGeometry = drawingGeometryValue(of: canvas)
        RunLoop.current.run(until: Date().addingTimeInterval(3.0))
        XCTAssertTrue(
            (canvas.value as? String)?.hasPrefix("笔迹 1") == true,
            "吸附直线在 PencilKit 结束回调或自动保存后消失"
        )
        XCTAssertTrue(
            (canvas.value as? String)?.contains("同步重载 0") == true,
            "吸附直线保存后不应由本地资产回声重装画布"
        )
        XCTAssertEqual(drawingGeometryValue(of: canvas), snappedLineGeometry)

        let radius = min(frame.width, frame.height) * 0.11
        for (index, name, centerX, radiusX) in [
            (2, "圆形", CGFloat(0.32), radius),
            (3, "椭圆", CGFloat(0.68), radius * 1.45)
        ] {
            let points = (0...32).map { index in
                let theta = CGFloat(index) / 32 * 2 * .pi
                let jitter = 1 + 0.025 * sin(5 * theta)
                return CGPoint(x: frame.minX + frame.width * centerX + cos(theta) * radiusX * jitter,
                               y: frame.minY + frame.height * 0.41 + sin(theta) * radius * jitter)
            }
            try synthesizeTouchPath(points, on: canvas, in: app, holdBeforeLift: 1.15)
            waitForValueContaining("吸附 \(name)", of: canvas, timeout: 5)
            waitForValue("笔迹 \(index)", of: canvas, timeout: 5)
            XCTAssertTrue((canvas.value as? String)?.contains("停笔预览 \(index)") == true)
        }

        let squareFrame = CGRect(x: frame.minX + frame.width * 0.32 - radius,
                                 y: frame.minY + frame.height * 0.68 - radius,
                                 width: radius * 2, height: radius * 2)
        try synthesizeClosedTouchPath(around: squareFrame, on: canvas, in: app, holdBeforeLift: 1.15)
        waitForValueContaining("吸附 正方形", of: canvas, timeout: 5)
        waitForValue("笔迹 4", of: canvas, timeout: 5)
        let triangleFrame = CGRect(
            x: frame.minX + frame.width * 0.68 - radius,
            y: squareFrame.minY,
            width: radius * 2.2,
            height: radius * 2
        )
        let triangleVertices = [
            CGPoint(x: triangleFrame.midX, y: triangleFrame.minY),
            CGPoint(x: triangleFrame.maxX, y: triangleFrame.maxY),
            CGPoint(x: triangleFrame.minX, y: triangleFrame.maxY)
        ]
        let trianglePoints = interpolatedClosedPath(
            triangleVertices,
            samplesPerEdge: 5
        )
        try synthesizeTouchPath(
            trianglePoints,
            on: canvas,
            in: app,
            holdBeforeLift: 1.15
        )
        waitForValueContaining("吸附 三角形", of: canvas, timeout: 5)
        waitForValue("笔迹 5", of: canvas, timeout: 5)
        XCTAssertTrue((canvas.value as? String)?.contains("停笔预览 5") == true)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Five held ink shapes"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let finalGeometry = drawingGeometryValue(of: canvas)
        let renderedInk = canvas.screenshot().pngRepresentation
        for point in [CGPoint(x: 0.48, y: 0.18),
                      CGPoint(x: 0.32 + radius / frame.width, y: 0.41),
                      CGPoint(x: 0.68 + radius * 1.45 / frame.width, y: 0.41),
                      CGPoint(x: 0.32, y: 0.68 - radius / frame.height),
                      CGPoint(x: 0.68, y: 0.68 + radius / frame.height)] {
            XCTAssertGreaterThan(try XCTUnwrap(inkDarkness(in: renderedInk, around: point, radius: 12)), 500,
                                 "Each regular shape must have visible ink at its input location")
        }

        let undo = app.buttons["撤销"]
        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        waitForValue("笔迹 4", of: canvas)
        let redo = app.buttons["重做"]
        XCTAssertTrue(redo.isEnabled)
        redo.tap()
        waitForValue("笔迹 5", of: canvas)
        XCTAssertEqual(drawingGeometryValue(of: canvas), finalGeometry)

        // A new ordinary stroke must neither inherit the preview nor overwrite the shape.
        drawStroke(on: canvas, from: CGVector(dx: 0.25, dy: 0.85), to: CGVector(dx: 0.6, dy: 0.86))
        waitForValue("笔迹 6", of: canvas)
        undo.tap()
        waitForValue("笔迹 5", of: canvas)
        XCTAssertEqual(drawingGeometryValue(of: canvas), finalGeometry)

        app.buttons["tool-eraser"].tap()
        app.buttons["tool-eraser"].tap()
        app.buttons["eraser-mode-stroke"].tap()
        drawStroke(on: canvas, from: CGVector(dx: 0.45, dy: 0.13), to: CGVector(dx: 0.45, dy: 0.23))
        waitForValue("笔迹 4", of: canvas)
        undo.tap()
        waitForValue("笔迹 5", of: canvas)
        XCTAssertEqual(drawingGeometryValue(of: canvas), finalGeometry)

        RunLoop.current.run(until: Date().addingTimeInterval(2))
        app.launchArguments.append("--reuse-text-interaction-ui-test-workspace")
        app.terminate()
        app.launch()
        let relaunchedCanvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        XCTAssertTrue(relaunchedCanvas.waitForExistence(timeout: 8))
        waitForValue("笔迹 5", of: relaunchedCanvas, timeout: 5)
        XCTAssertEqual(drawingGeometryValue(of: relaunchedCanvas), finalGeometry)
    }

    func testMovingAfterHeldPreviewRestoresTheSameFreehandStroke() throws {
        let app = launchIsolatedApp(prefix: "shape-hold-resume")
        let canvas = app.descendants(matching: .any)["page-canvas-0"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let frame = canvas.frame
        let points = [CGPoint(x: frame.minX + frame.width * 0.25, y: frame.minY + frame.height * 0.3),
                      CGPoint(x: frame.minX + frame.width * 0.65, y: frame.minY + frame.height * 0.3),
                      CGPoint(x: frame.minX + frame.width * 0.45, y: frame.minY + frame.height * 0.5),
                      CGPoint(x: frame.minX + frame.width * 0.7, y: frame.minY + frame.height * 0.55)]
        try synthesizeTouchPath(points, on: canvas, in: app, holdBeforeLift: 0.1,
                                pauseAfterPointIndex: 1, pauseDuration: 1.15)
        waitForValue("笔迹 1", of: canvas)
        XCTAssertTrue((canvas.value as? String)?.contains("吸附 无") == true)
        XCTAssertTrue((canvas.value as? String)?.contains("停笔预览 1") == true)
        XCTAssertTrue((canvas.value as? String)?.contains("恢复手绘 1") == true)
        let viewport = try canvasViewportRect(of: canvas)
        XCTAssertGreaterThan(try drawingBounds(of: canvas).height, viewport.height * 0.23)
        app.buttons["撤销"].tap()
        waitForValue("笔迹 0", of: canvas)
        app.buttons["重做"].tap()
        waitForValue("笔迹 1", of: canvas)
    }

    func testHeldShapeAtReducedZoomUsesWorldCoordinatesAndKeepsTheNextContact() throws {
        let app = launchIsolatedApp(prefix: "shape-hold-zoom")
        let canvas = app.descendants(matching: .any)["page-canvas-0"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        try pinchCanvas(canvas, scale: 0.42, in: app)
        waitUntil(timeout: 3) { !app.buttons["zoom-reset"].label.contains("100%") }
        let viewport = try canvasViewportRect(of: canvas)
        let frame = canvas.frame
        let firstStart = CGPoint(x: frame.minX + frame.width * 0.22, y: frame.minY + frame.height * 0.22)
        let firstEnd = CGPoint(x: frame.minX + frame.width * 0.5, y: firstStart.y)
        try synthesizeTouchPaths([
            SynthesizedTouchPath(samples: [(firstStart, 0), (firstEnd, 0.3)], liftOffset: 1.5),
            SynthesizedTouchPath(samples: [(CGPoint(x: firstEnd.x, y: firstEnd.y + 80), 1.54),
                                           (CGPoint(x: firstEnd.x + 80, y: firstEnd.y + 100), 1.84)], liftOffset: 1.94)
        ], on: canvas, in: app)
        waitForValue("笔迹 2", of: canvas)
        XCTAssertTrue((canvas.value as? String)?.contains("停笔预览 1") == true)
        app.buttons["撤销"].tap()
        waitForValue("笔迹 1", of: canvas)
        let bounds = try drawingBounds(of: canvas)
        XCTAssertEqual(bounds.minX, viewport.minX + viewport.width * 0.22, accuracy: 12)
        XCTAssertEqual(bounds.midY, viewport.minY + viewport.height * 0.22, accuracy: 12)
        XCTAssertLessThan(bounds.minY, 0)
        XCTAssertGreaterThan(try XCTUnwrap(inkDarkness(in: canvas.screenshot().pngRepresentation,
                                                     around: CGPoint(x: 0.35, y: 0.22), radius: 10)), 300)
        app.buttons["撤销"].tap()
        waitForValue("笔迹 0", of: canvas)
    }

    func testHeldInkOnPDFKeepsHighlighterPencilAndZoomNavigation() throws {
        let app = launchIsolatedApp(prefix: "pdf-held-ink")
        let canvas = app.descendants(matching: .any)["page-canvas-0"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let frame = canvas.frame
        app.buttons["ink-color-ocean"].tap()
        let line = [CGPoint(x: frame.minX + frame.width * 0.28, y: frame.minY + frame.height * 0.35),
                    CGPoint(x: frame.minX + frame.width * 0.5, y: frame.minY + frame.height * 0.35 + 2),
                    CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + frame.height * 0.35)]
        try synthesizeTouchPath(line, on: canvas, in: app, holdBeforeLift: 1.2)
        waitForValue("笔迹 1", of: canvas)
        XCTAssertTrue((canvas.value as? String)?.contains("吸附 直线") == true)
        app.buttons["tool-marker"].tap()
        let markerLine = line.map { CGPoint(x: $0.x, y: $0.y + frame.height * 0.18) }
        try synthesizeTouchPath(markerLine, on: canvas, in: app, holdBeforeLift: 1.2)
        waitForValue("笔迹 2", of: canvas)
        XCTAssertEqual(app.buttons["tool-marker"].value as? String, "selected")
        XCTAssertEqual(app.buttons["tool-pen"].value as? String, "selected")
        XCTAssertTrue((canvas.value as? String)?.contains("吸附 直线") == true)
        app.buttons["tool-pen"].tap()
        app.buttons["pen-variant-pencil"].tap()
        let circle = (0...24).map { index in
            let theta = CGFloat(index) / 24 * 2 * .pi
            return CGPoint(x: frame.midX + cos(theta) * 55, y: frame.minY + frame.height * 0.73 + sin(theta) * 55)
        }
        try synthesizeTouchPath(circle, on: canvas, in: app, holdBeforeLift: 1.2)
        waitForValue("笔迹 3", of: canvas)
        XCTAssertTrue((canvas.value as? String)?.contains("吸附 圆形") == true)
        XCTAssertTrue((canvas.value as? String)?.contains("停笔预览 3") == true)
        let pixels = canvas.screenshot().pngRepresentation
        for point in [CGPoint(x: 0.5, y: 0.35), CGPoint(x: 0.5, y: 0.53),
                      CGPoint(x: 0.5 + 55 / frame.width, y: 0.73)] {
            XCTAssertGreaterThan(try XCTUnwrap(inkDarkness(in: pixels, around: point, radius: 12)), 500)
        }
        let geometry = drawingGeometryValue(of: canvas)
        try pinchCanvas(canvas, scale: 1.4, in: app)
        waitUntil(timeout: 4) { !app.buttons["zoom-reset"].label.contains("100%") }
        XCTAssertEqual((app.scrollViews["document-page-pager"].value as? String ?? ""), "1 / 2")
        XCTAssertEqual(drawingGeometryValue(of: canvas), geometry)
        app.buttons["zoom-reset"].tap()
        waitUntil(timeout: 4) { app.buttons["zoom-reset"].label.contains("100%") }
        app.buttons["撤销"].tap()
        waitForValue("笔迹 2", of: canvas)
        app.buttons["重做"].tap()
        waitForValue("笔迹 3", of: canvas)
        XCTAssertEqual(drawingGeometryValue(of: canvas), geometry)
    }

    func testShapeInsertionMoveDuplicateAndDeleteUseTheLassoSelection() throws {
        let app = launchIsolatedApp(prefix: "shape-lasso")
        let settingsScroll = app.scrollViews["tool-settings-scroll"]
        XCTAssertTrue(settingsScroll.waitForExistence(timeout: 5))

        let insertShape = app.buttons["插入图形"]
        XCTAssertTrue(insertShape.waitForExistence(timeout: 5))
        reveal(insertShape, in: settingsScroll, bySwiping: .left)
        insertShape.tap()

        let rectangle = app.buttons["矩形"]
        XCTAssertTrue(rectangle.waitForExistence(timeout: 3))
        rectangle.tap()

        let shapeElements = app.descendants(matching: .any)
            .matching(identifier: "page-element-shape")
        XCTAssertEqual(shapeElements.count, 1)
        XCTAssertEqual(app.buttons["tool-lasso"].value as? String, "selected")

        let selectionBox = app.descendants(matching: .any)
            .matching(identifier: "lasso-selection-box")
            .firstMatch
        XCTAssertTrue(selectionBox.waitForExistence(timeout: 3))
        let originalFrame = selectionBox.frame
        let start = selectionBox.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 58, dy: 34)))
        let movedFrame = selectionBox.frame
        XCTAssertGreaterThan(
            hypot(movedFrame.midX - originalFrame.midX, movedFrame.midY - originalFrame.midY),
            20
        )

        let duplicate = app.buttons["复制"]
        XCTAssertTrue(duplicate.waitForExistence(timeout: 3))
        duplicate.tap()
        XCTAssertEqual(shapeElements.count, 2)

        let delete = app.buttons["删除"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        XCTAssertEqual(shapeElements.count, 1)
        XCTAssertTrue(selectionBox.waitForNonExistence(timeout: 3))
    }

    func testLockedObjectCannotMoveOrDeleteUntilItIsUnlocked() throws {
        let app = launchIsolatedApp(prefix: "object-lock")
        let settingsScroll = app.scrollViews["tool-settings-scroll"]
        XCTAssertTrue(settingsScroll.waitForExistence(timeout: 5))
        insertShape(named: "矩形", in: app, settingsScroll: settingsScroll)

        let selectionBox = app.descendants(matching: .any)
            .matching(identifier: "lasso-selection-box")
            .firstMatch
        XCTAssertTrue(selectionBox.waitForExistence(timeout: 3))
        let originalFrame = selectionBox.frame

        app.buttons["对象操作"].tap()
        XCTAssertTrue(app.buttons["锁定"].waitForExistence(timeout: 3))
        app.buttons["锁定"].tap()
        XCTAssertFalse(app.buttons["删除"].isEnabled)
        XCTAssertFalse(app.buttons["复制"].isEnabled)

        let lockedStart = selectionBox.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        lockedStart.press(
            forDuration: 0.12,
            thenDragTo: lockedStart.withOffset(CGVector(dx: 70, dy: 38))
        )
        XCTAssertEqual(selectionBox.frame.minX, originalFrame.minX, accuracy: 1)
        XCTAssertEqual(selectionBox.frame.minY, originalFrame.minY, accuracy: 1)

        app.buttons["tool-eraser"].tap()
        let canvas = app.descendants(matching: .any)["page-canvas-0"]
        let lockedEdge = canvas.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: originalFrame.midX - canvas.frame.minX, dy: originalFrame.minY - canvas.frame.minY)
        )
        lockedEdge.withOffset(CGVector(dx: 0, dy: -24)).press(forDuration: 0.08,
            thenDragTo: lockedEdge.withOffset(CGVector(dx: 0, dy: 24)))
        let lockedShape = app.descendants(matching: .any).matching(identifier: "page-element-shape").firstMatch
        XCTAssertTrue(lockedShape.exists, "Locked shapes must survive erasing")
        app.buttons["tool-pen"].tap()
        lockedShape.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(selectionBox.waitForExistence(timeout: 3))

        app.buttons["对象操作"].tap()
        XCTAssertTrue(app.buttons["解锁"].waitForExistence(timeout: 3))
        app.buttons["解锁"].tap()
        XCTAssertTrue(app.buttons["删除"].isEnabled)
        XCTAssertTrue(app.buttons["复制"].isEnabled)

        let unlockedStart = selectionBox.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        unlockedStart.press(
            forDuration: 0.12,
            thenDragTo: unlockedStart.withOffset(CGVector(dx: 70, dy: 38))
        )
        XCTAssertGreaterThan(
            hypot(
                selectionBox.frame.midX - originalFrame.midX,
                selectionBox.frame.midY - originalFrame.midY
            ),
            20
        )
    }

    func testObjectLayerCommandsChangeTheActualRenderOrder() throws {
        let app = launchIsolatedApp(prefix: "object-layer")
        let settingsScroll = app.scrollViews["tool-settings-scroll"]
        XCTAssertTrue(settingsScroll.waitForExistence(timeout: 5))
        insertShape(named: "矩形", in: app, settingsScroll: settingsScroll)
        insertShape(named: "圆形", in: app, settingsScroll: settingsScroll)

        let shapes = app.descendants(matching: .any)
            .matching(identifier: "page-element-shape")
        XCTAssertEqual(shapes.count, 2)
        waitUntil(timeout: 3) {
            self.shapeTitles(in: shapes) == ["矩形", "圆形"]
        }

        app.buttons["对象操作"].tap()
        XCTAssertTrue(app.buttons["移到最后"].waitForExistence(timeout: 3))
        app.buttons["移到最后"].tap()
        waitUntil(timeout: 3) {
            self.shapeTitles(in: shapes) == ["圆形", "矩形"]
        }

        app.buttons["对象操作"].tap()
        XCTAssertTrue(app.buttons["移到最前"].waitForExistence(timeout: 3))
        app.buttons["移到最前"].tap()
        waitUntil(timeout: 3) {
            self.shapeTitles(in: shapes) == ["矩形", "圆形"]
        }
    }

    func testPageLongPressDoesNotBlockSubsequentHandwriting() throws {
        let app = launchIsolatedApp(prefix: "page-long-press")
        let canvas = app.descendants(matching: .any)["page-canvas-0"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let reset = app.buttons["zoom-reset"]
        XCTAssertTrue(reset.waitForExistence(timeout: 3))
        XCTAssertTrue(app.frame.insetBy(dx: 12, dy: 12).contains(reset.frame))
        XCTAssertFalse(app.staticTexts["document-page-counter"].exists)

        for tool in ["tool-lasso", "tool-pen"] {
            if app.buttons[tool].value as? String != "selected" { app.buttons[tool].tap() }
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.60))
                .press(forDuration: 0.8)
            XCTAssertFalse(app.buttons["粘贴最近拷贝的内容"].exists)
            XCTAssertFalse(app.buttons["粘贴"].exists)
            if app.buttons["tool-pen"].value as? String != "selected" { app.buttons["tool-pen"].tap() }
            let value = canvas.value as? String ?? ""
            let count = try XCTUnwrap(Int(value.components(separatedBy: "；")[0]
                .replacingOccurrences(of: "笔迹 ", with: "")))
            drawStroke(on: canvas)
            waitForValue("笔迹 \(count + 1)；", of: canvas)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Writing after long press and visible zoom control"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testClosedLassoGroupsAndUngroupsTwoRealObjects() throws {
        let app = launchIsolatedApp(prefix: "object-group")
        let settingsScroll = app.scrollViews["tool-settings-scroll"]
        XCTAssertTrue(settingsScroll.waitForExistence(timeout: 5))
        insertShape(named: "矩形", in: app, settingsScroll: settingsScroll)

        let shapes = app.descendants(matching: .any)
            .matching(identifier: "page-element-shape")
        let selectionBox = app.descendants(matching: .any)
            .matching(identifier: "lasso-selection-box")
            .firstMatch
        let canvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        XCTAssertEqual(shapes.count, 1)
        XCTAssertTrue(selectionBox.waitForExistence(timeout: 3))

        let firstMove = selectionBox.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        firstMove.press(
            forDuration: 0.12,
            thenDragTo: firstMove.withOffset(CGVector(dx: -150, dy: 0))
        )
        let firstFrame = shapes.element(boundBy: 0).frame

        insertShape(named: "圆形", in: app, settingsScroll: settingsScroll)
        XCTAssertEqual(shapes.count, 2)
        let secondMove = selectionBox.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        secondMove.press(
            forDuration: 0.12,
            thenDragTo: secondMove.withOffset(CGVector(dx: 150, dy: 0))
        )
        let secondFrame = shapes.element(boundBy: 1).frame
        XCTAssertFalse(firstFrame.intersects(secondFrame))

        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.14)).tap()
        XCTAssertTrue(selectionBox.waitForNonExistence(timeout: 3))
        try synthesizeClosedTouchPath(
            around: firstFrame.union(secondFrame).insetBy(dx: -24, dy: -24),
            on: canvas,
            in: app
        )
        XCTAssertTrue(app.buttons["删除"].waitForExistence(timeout: 4))

        app.buttons["对象操作"].tap()
        let group = app.buttons["组合"]
        XCTAssertTrue(group.waitForExistence(timeout: 3))
        XCTAssertTrue(group.isEnabled)
        group.tap()

        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.14)).tap()
        XCTAssertTrue(selectionBox.waitForNonExistence(timeout: 3))
        shapes.element(boundBy: 0).tap()
        XCTAssertTrue(selectionBox.waitForExistence(timeout: 3))
        let groupedFrame = selectionBox.frame
        XCTAssertLessThanOrEqual(groupedFrame.minX, firstFrame.minX + 2)
        XCTAssertGreaterThanOrEqual(groupedFrame.maxX, secondFrame.maxX - 2)

        app.buttons["对象操作"].tap()
        let ungroup = app.buttons["取消组合"]
        XCTAssertTrue(ungroup.waitForExistence(timeout: 3))
        XCTAssertTrue(ungroup.isEnabled)
        ungroup.tap()

        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.14)).tap()
        XCTAssertTrue(selectionBox.waitForNonExistence(timeout: 3))
        shapes.element(boundBy: 0).tap()
        XCTAssertTrue(selectionBox.waitForExistence(timeout: 3))
        XCTAssertLessThan(selectionBox.frame.width, groupedFrame.width * 0.70)
    }

    func testShapeResizeRotateAndStyleChangeARealObject() throws {
        let app = launchIsolatedApp(prefix: "shape-transform-style")
        let settingsScroll = app.scrollViews["tool-settings-scroll"]
        XCTAssertTrue(settingsScroll.waitForExistence(timeout: 5))

        let insertShape = app.buttons["插入图形"]
        XCTAssertTrue(insertShape.waitForExistence(timeout: 5))
        reveal(insertShape, in: settingsScroll, bySwiping: .left)
        insertShape.tap()
        XCTAssertTrue(app.buttons["矩形"].waitForExistence(timeout: 3))
        app.buttons["矩形"].tap()

        let selectionBox = app.descendants(matching: .any)
            .matching(identifier: "lasso-selection-box")
            .firstMatch
        XCTAssertTrue(selectionBox.waitForExistence(timeout: 3))
        let originalBoxFrame = selectionBox.frame

        let resizeHandle = app.descendants(matching: .any)
            .matching(identifier: "lasso-resize-bottomRight")
            .firstMatch
        XCTAssertTrue(resizeHandle.waitForExistence(timeout: 3))
        let resizeStart = resizeHandle.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        resizeStart.press(
            forDuration: 0.1,
            thenDragTo: resizeStart.withOffset(CGVector(dx: 55, dy: 38))
        )
        XCTAssertGreaterThan(selectionBox.frame.width - originalBoxFrame.width, 25)
        XCTAssertGreaterThan(selectionBox.frame.height - originalBoxFrame.height, 15)

        let rotationHandle = app.descendants(matching: .any)
            .matching(identifier: "lasso-rotation-handle")
            .firstMatch
        XCTAssertTrue(rotationHandle.waitForExistence(timeout: 3))
        let rotationOrigin = rotationHandle.frame
        let rotationStart = rotationHandle.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        rotationStart.press(
            forDuration: 0.1,
            thenDragTo: rotationStart.withOffset(CGVector(dx: 65, dy: -28))
        )
        XCTAssertGreaterThan(
            hypot(
                rotationHandle.frame.midX - rotationOrigin.midX,
                rotationHandle.frame.midY - rotationOrigin.midY
            ),
            10
        )

        let style = app.buttons["样式"]
        XCTAssertTrue(style.waitForExistence(timeout: 3))
        style.tap()
        XCTAssertTrue(app.navigationBars["图形样式"].waitForExistence(timeout: 3))

        let dashed = app.switches["shape-dashed"]
        let fill = app.switches["shape-fill-enabled"]
        XCTAssertTrue(dashed.waitForExistence(timeout: 3))
        XCTAssertTrue(fill.exists)
        dashed.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()
        waitUntil(timeout: 2) { dashed.value as? String == "1" }
        fill.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()
        waitUntil(timeout: 2) { fill.value as? String == "1" }

        let lineWidth = app.sliders["shape-line-width"]
        XCTAssertTrue(lineWidth.exists)
        lineWidth.adjust(toNormalizedSliderPosition: 0.72)
        app.navigationBars["图形样式"].buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["图形样式"].waitForNonExistence(timeout: 3))

        let shape = app.descendants(matching: .any)
            .matching(identifier: "page-element-shape")
            .firstMatch
        XCTAssertTrue(shape.waitForExistence(timeout: 3))
        XCTAssertTrue((shape.value as? String)?.contains("虚线") == true)
        XCTAssertTrue((shape.value as? String)?.contains("有填充") == true)
    }

    func testEveryShapeTypeCreatesTheRequestedRealObject() throws {
        let app = launchIsolatedApp(prefix: "all-shape-types")
        let settingsScroll = app.scrollViews["tool-settings-scroll"]
        XCTAssertTrue(settingsScroll.waitForExistence(timeout: 5))

        let expectedShapes = ["直线", "箭头", "矩形", "圆形", "三角形", "菱形"]
        let shapes = app.descendants(matching: .any)
            .matching(identifier: "page-element-shape")

        for (index, title) in expectedShapes.enumerated() {
            insertShape(named: title, in: app, settingsScroll: settingsScroll)
            XCTAssertEqual(shapes.count, index + 1)
            let insertedShape = shapes.matching(
                NSPredicate(format: "value BEGINSWITH %@", title)
            ).firstMatch
            XCTAssertTrue(
                insertedShape.waitForExistence(timeout: 3),
                "插入 \(title) 后没有生成对应的真实页面对象"
            )
        }

        XCTAssertEqual(shapeTitles(in: shapes), expectedShapes)
    }

    func testImageMoveResizeCropAndOpacityChangeARealObject() throws {
        let app = launchIsolatedApp(prefix: "image-object")
        let image = app.descendants(matching: .any)
            .matching(identifier: "page-element-image")
            .firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 5))

        app.buttons["tool-lasso"].tap()
        image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let selectionBox = app.descendants(matching: .any)
            .matching(identifier: "lasso-selection-box")
            .firstMatch
        XCTAssertTrue(selectionBox.waitForExistence(timeout: 3))

        let originalImageFrame = image.frame
        let moveStart = selectionBox.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        moveStart.press(
            forDuration: 0.1,
            thenDragTo: moveStart.withOffset(CGVector(dx: 46, dy: 28))
        )
        XCTAssertGreaterThan(
            hypot(
                image.frame.midX - originalImageFrame.midX,
                image.frame.midY - originalImageFrame.midY
            ),
            20
        )

        let resizeHandle = app.descendants(matching: .any)
            .matching(identifier: "lasso-resize-bottomRight")
            .firstMatch
        XCTAssertTrue(resizeHandle.waitForExistence(timeout: 3))
        let frameBeforeResize = image.frame
        let resizeStart = resizeHandle.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        resizeStart.press(
            forDuration: 0.1,
            thenDragTo: resizeStart.withOffset(CGVector(dx: 52, dy: 30))
        )
        XCTAssertGreaterThan(image.frame.width - frameBeforeResize.width, 25)

        let crop = app.buttons["裁剪"]
        XCTAssertTrue(crop.waitForExistence(timeout: 3))
        crop.tap()
        XCTAssertTrue(app.navigationBars["裁剪图片"].waitForExistence(timeout: 3))

        let leftCrop = app.sliders["image-crop-左侧"]
        let opacity = app.sliders["image-opacity"]
        XCTAssertTrue(leftCrop.waitForExistence(timeout: 3))
        XCTAssertTrue(opacity.exists)
        leftCrop.adjust(toNormalizedSliderPosition: 0.34)
        opacity.adjust(toNormalizedSliderPosition: 0.50)
        app.navigationBars["裁剪图片"].buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["裁剪图片"].waitForNonExistence(timeout: 3))

        XCTAssertTrue(image.waitForExistence(timeout: 3))
        waitForValueContaining("透明度 55%", of: image, timeout: 4)
        XCTAssertGreaterThan(image.frame.height, frameBeforeResize.height * 1.15)
        XCTAssertTrue(selectionBox.exists)
    }

    func testImageRotationPersistsAfterApplicationRelaunch() throws {
        let app = launchIsolatedApp(prefix: "image-object-rotation")
        let image = app.descendants(matching: .any)
            .matching(identifier: "page-element-image")
            .firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        let originalValue = image.value as? String
        waitForValueContaining("旋转 0°", of: image)

        app.buttons["tool-lasso"].tap()
        let selectionBox = app.descendants(matching: .any)
            .matching(identifier: "lasso-selection-box")
            .firstMatch
        XCTAssertTrue(selectionBox.waitForExistence(timeout: 3))

        let rotationHandle = app.descendants(matching: .any)
            .matching(identifier: "lasso-rotation-handle")
            .firstMatch
        XCTAssertTrue(rotationHandle.waitForExistence(timeout: 3))
        let rotationStart = rotationHandle.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        rotationStart.press(
            forDuration: 0.10,
            thenDragTo: rotationStart.withOffset(CGVector(dx: 64, dy: -34))
        )
        waitUntil(timeout: 3) {
            (image.value as? String) != originalValue
                && (image.value as? String)?.contains("旋转 0°") == false
        }
        guard let rotatedValue = image.value as? String else {
            XCTFail("Image did not publish its rotation")
            return
        }
        let rotatedFrame = image.frame

        app.buttons["tool-pen"].tap()
        XCTAssertTrue(selectionBox.waitForNonExistence(timeout: 3))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        app.launchArguments.append("--reuse-text-interaction-ui-test-workspace")
        app.terminate()
        app.launch()

        let relaunchedImage = app.descendants(matching: .any)
            .matching(identifier: "page-element-image")
            .firstMatch
        XCTAssertTrue(relaunchedImage.waitForExistence(timeout: 8))
        waitUntil(timeout: 4) {
            relaunchedImage.value as? String == rotatedValue
        }
        XCTAssertEqual(relaunchedImage.frame.midX, rotatedFrame.midX, accuracy: 3)
        XCTAssertEqual(relaunchedImage.frame.midY, rotatedFrame.midY, accuracy: 3)
        XCTAssertEqual(relaunchedImage.frame.width, rotatedFrame.width, accuracy: 3)
        XCTAssertEqual(relaunchedImage.frame.height, rotatedFrame.height, accuracy: 3)
    }

    func testEveryInkToolCreatesRealStrokesAndParticipatesInHistory() throws {
        let app = launchIsolatedApp(prefix: "all-ink-tools")
        let canvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))

        let tools = ["pen", "fountainPen", "pencil", "marker"]
        for (index, toolID) in tools.enumerated() {
            let tool = app.buttons["tool-\(toolID)"]
            XCTAssertTrue(tool.waitForExistence(timeout: 3))
            tool.tap()
            XCTAssertEqual(tool.value as? String, "selected")

            let y = 0.26 + Double(index) * 0.12
            drawStroke(
                on: canvas,
                from: CGVector(dx: 0.26, dy: y),
                to: CGVector(dx: 0.56, dy: y + 0.04)
            )
            waitForValue("笔迹 \(index + 1)", of: canvas)
        }

        let undo = app.buttons["撤销"]
        for expectedCount in stride(from: 3, through: 0, by: -1) {
            XCTAssertTrue(undo.isEnabled)
            undo.tap()
            waitForValue("笔迹 \(expectedCount)", of: canvas)
        }

        let redo = app.buttons["重做"]
        for expectedCount in 1...4 {
            XCTAssertTrue(redo.isEnabled)
            redo.tap()
            waitForValue("笔迹 \(expectedCount)", of: canvas)
        }
    }

    func testPrecisionEraserChangesOnlyPartOfAStrokeAndUndoRestoresIt() throws {
        let app = launchIsolatedApp(prefix: "precision-eraser")
        let canvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))

        drawStroke(
            on: canvas,
            from: CGVector(dx: 0.24, dy: 0.42),
            to: CGVector(dx: 0.76, dy: 0.42)
        )
        waitForValue("笔迹 1", of: canvas)
        let drawingBeforeErase = canvas.screenshot().pngRepresentation
        let erasedPoint = CGPoint(x: 0.50, y: 0.42)
        guard let inkBeforeErase = inkDarkness(
            in: drawingBeforeErase,
            around: erasedPoint
        ), inkBeforeErase > 0 else {
            return XCTFail("无法读取精细橡皮测试的原始笔迹像素")
        }

        app.buttons["tool-eraser"].tap()
        app.buttons["tool-eraser"].tap()
        let precisionEraser = app.buttons["eraser-mode-precision"]
        XCTAssertTrue(precisionEraser.waitForExistence(timeout: 3))
        // Tapping the current mode is intentional: it closes the popover as well as reaffirming
        // precision mode before the pixel-level erase check.
        precisionEraser.tap()

        let eraseStart = canvas.coordinate(
            withNormalizedOffset: CGVector(dx: 0.50, dy: 0.34)
        )
        let eraseEnd = canvas.coordinate(
            withNormalizedOffset: CGVector(dx: 0.50, dy: 0.50)
        )
        eraseStart.press(forDuration: 0.08, thenDragTo: eraseEnd)
        waitUntil(timeout: 3) {
            guard let erasedInk = inkDarkness(
                in: canvas.screenshot().pngRepresentation,
                around: erasedPoint
            ) else { return false }
            return erasedInk < inkBeforeErase / 3
        }
        XCTAssertFalse(
            (canvas.value as? String)?.hasPrefix("笔迹 0") == true,
            "精细橡皮不应删除整条笔迹"
        )

        let undo = app.buttons["撤销"]
        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        waitForValue("笔迹 1", of: canvas)
        waitUntil(timeout: 3) {
            guard let restoredInk = inkDarkness(
                in: canvas.screenshot().pngRepresentation,
                around: erasedPoint
            ) else { return false }
            return restoredInk >= inkBeforeErase * 4 / 5
        }
    }

    func testTextContentFontSizeAndColorRemainEditable() throws {
        let app = launchIsolatedApp(prefix: "text-formatting")
        app.buttons["tool-text"].tap()
        tapCanvas(in: app)

        let editor = app.textViews["inline-text-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText(" revised")

        let fontSizeButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "字号 ")
        ).firstMatch
        XCTAssertTrue(fontSizeButton.waitForExistence(timeout: 3))
        fontSizeButton.tap()
        XCTAssertTrue(app.buttons["32"].waitForExistence(timeout: 3))
        app.buttons["32"].tap()
        XCTAssertTrue(app.buttons["字号 32"].waitForExistence(timeout: 3))

        app.buttons["文本颜色"].tap()
        let blue = app.buttons["蓝色"]
        XCTAssertTrue(blue.waitForExistence(timeout: 3))
        blue.tap()
        XCTAssertEqual(blue.value as? String, "selected")
        editor.tap()

        app.buttons["text-edit-done"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
        let savedText = app.staticTexts["键入文本 revised"]
        XCTAssertTrue(savedText.waitForExistence(timeout: 3))

        let textElement = app.descendants(matching: .any)
            .matching(identifier: "page-element-text")
            .firstMatch
        XCTAssertTrue(textElement.waitForExistence(timeout: 3))
        XCTAssertTrue((textElement.value as? String)?.contains("字号 32") == true)
        XCTAssertTrue((textElement.value as? String)?.contains("颜色 #2F62E8FF") == true)

        savedText.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["字号 32"].exists)
        app.buttons["文本颜色"].tap()
        XCTAssertTrue(blue.waitForExistence(timeout: 3))
        XCTAssertEqual(blue.value as? String, "selected")
    }

    func testTextFontEmphasisUnderlineAndAlignmentPersistAfterEditing() throws {
        let app = launchIsolatedApp(prefix: "text-full-formatting")
        app.buttons["tool-text"].tap()
        tapCanvas(in: app)

        let editor = app.textViews["inline-text-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))

        app.buttons["文本格式"].tap()
        XCTAssertTrue(app.buttons["字体"].waitForExistence(timeout: 3))
        app.buttons["字体"].tap()
        XCTAssertTrue(app.buttons["衬线"].waitForExistence(timeout: 3))
        app.buttons["衬线"].tap()

        for option in ["粗体", "斜体", "下划线"] {
            app.buttons["文本格式"].tap()
            XCTAssertTrue(app.buttons[option].waitForExistence(timeout: 3))
            app.buttons[option].tap()
        }

        app.buttons["文本格式"].tap()
        XCTAssertTrue(app.buttons["对齐"].waitForExistence(timeout: 3))
        app.buttons["对齐"].tap()
        XCTAssertTrue(app.buttons["居中"].waitForExistence(timeout: 3))
        app.buttons["居中"].tap()

        app.buttons["text-edit-done"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 3))

        let textElement = app.descendants(matching: .any)
            .matching(identifier: "page-element-text")
            .firstMatch
        XCTAssertTrue(textElement.waitForExistence(timeout: 3))
        for expectedValue in [
            "字体 Serif",
            "粗体",
            "斜体",
            "下划线",
            "对齐 center"
        ] {
            XCTAssertTrue(
                (textElement.value as? String)?.contains(expectedValue) == true,
                "文字格式没有保存：\(expectedValue)"
            )
        }

        app.staticTexts["键入文本"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        app.buttons["text-edit-done"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
        for expectedValue in ["字体 Serif", "粗体", "斜体", "下划线", "对齐 center"] {
            XCTAssertTrue((textElement.value as? String)?.contains(expectedValue) == true)
        }
    }

    func testTextRotationPersistsAfterApplicationRelaunch() throws {
        let app = launchIsolatedApp(prefix: "text-object-rotation")
        app.buttons["tool-text"].tap()
        tapCanvas(in: app, at: CGVector(dx: 0.34, dy: 0.36))

        let editor = app.textViews["inline-text-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText(" rotated")
        app.buttons["text-edit-done"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 3))

        let textElement = app.descendants(matching: .any)
            .matching(identifier: "page-element-text")
            .firstMatch
        XCTAssertTrue(textElement.waitForExistence(timeout: 3))
        let originalValue = textElement.value as? String
        waitForValueContaining("旋转 0°", of: textElement)

        app.buttons["tool-lasso"].tap()
        textElement.tap()
        let selectionBox = app.descendants(matching: .any)
            .matching(identifier: "lasso-selection-box")
            .firstMatch
        XCTAssertTrue(selectionBox.waitForExistence(timeout: 3))

        let rotationHandle = app.descendants(matching: .any)
            .matching(identifier: "lasso-rotation-handle")
            .firstMatch
        XCTAssertTrue(rotationHandle.waitForExistence(timeout: 3))
        let rotationStart = rotationHandle.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        rotationStart.press(
            forDuration: 0.10,
            thenDragTo: rotationStart.withOffset(CGVector(dx: 62, dy: -32))
        )
        waitUntil(timeout: 3) {
            (textElement.value as? String) != originalValue
                && (textElement.value as? String)?.contains("旋转 0°") == false
        }
        guard let rotatedValue = textElement.value as? String else {
            XCTFail("Text did not publish its rotation")
            return
        }
        let rotatedFrame = textElement.frame

        app.buttons["tool-pen"].tap()
        XCTAssertTrue(selectionBox.waitForNonExistence(timeout: 3))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        app.launchArguments.append("--reuse-text-interaction-ui-test-workspace")
        app.terminate()
        app.launch()

        let relaunchedText = app.descendants(matching: .any)
            .matching(identifier: "page-element-text")
            .firstMatch
        XCTAssertTrue(relaunchedText.waitForExistence(timeout: 8))
        waitUntil(timeout: 4) {
            relaunchedText.value as? String == rotatedValue
        }
        XCTAssertEqual(relaunchedText.frame.midX, rotatedFrame.midX, accuracy: 3)
        XCTAssertEqual(relaunchedText.frame.midY, rotatedFrame.midY, accuracy: 3)
        XCTAssertEqual(relaunchedText.frame.width, rotatedFrame.width, accuracy: 3)
        XCTAssertEqual(relaunchedText.frame.height, rotatedFrame.height, accuracy: 3)
    }

    func testTextAndShapePersistAfterApplicationRelaunch() throws {
        let app = launchIsolatedApp(prefix: "object-relaunch")
        app.buttons["tool-text"].tap()
        tapCanvas(in: app, at: CGVector(dx: 0.30, dy: 0.30))
        let editor = app.textViews["inline-text-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        replaceText(in: editor, with: "键入文本 persistent")
        app.buttons["text-edit-done"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let savedText = app.staticTexts["键入文本 persistent"]
        XCTAssertTrue(savedText.waitForExistence(timeout: 4))
        let originalTextFrame = savedText.frame

        let settingsScroll = app.scrollViews["tool-settings-scroll"]
        XCTAssertTrue(settingsScroll.waitForExistence(timeout: 3))
        insertShape(named: "矩形", in: app, settingsScroll: settingsScroll)
        let shape = app.descendants(matching: .any)
            .matching(identifier: "page-element-shape")
            .firstMatch
        XCTAssertTrue(shape.waitForExistence(timeout: 3))
        let selectionBox = app.descendants(matching: .any)
            .matching(identifier: "lasso-selection-box")
            .firstMatch
        let start = selectionBox.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(
            forDuration: 0.12,
            thenDragTo: start.withOffset(CGVector(dx: 68, dy: 36))
        )
        let originalShapeFrame = shape.frame

        app.launchArguments.append("--reuse-text-interaction-ui-test-workspace")
        app.terminate()
        app.launch()

        let relaunchedText = app.staticTexts["键入文本 persistent"]
        let relaunchedShape = app.descendants(matching: .any)
            .matching(identifier: "page-element-shape")
            .firstMatch
        XCTAssertTrue(relaunchedText.waitForExistence(timeout: 8))
        XCTAssertTrue(relaunchedShape.waitForExistence(timeout: 4))
        XCTAssertEqual(
            app.descendants(matching: .any)
                .matching(identifier: "page-element-shape").count,
            1
        )
        XCTAssertEqual(relaunchedText.frame.midX, originalTextFrame.midX, accuracy: 3)
        XCTAssertEqual(relaunchedText.frame.midY, originalTextFrame.midY, accuracy: 3)
        XCTAssertEqual(relaunchedShape.frame.midX, originalShapeFrame.midX, accuracy: 3)
        XCTAssertEqual(relaunchedShape.frame.midY, originalShapeFrame.midY, accuracy: 3)
    }

    func testPDFSearchFindsNativeTextNavigatesToPageAndShowsHighlight() throws {
        let app = launchIsolatedApp(prefix: "pdf-search")
        let settingsScroll = app.scrollViews["tool-settings-scroll"]
        XCTAssertTrue(settingsScroll.waitForExistence(timeout: 5))
        app.buttons["tool-lasso"].tap()
        let searchButton = app.buttons["搜索 PDF"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 3))
        reveal(searchButton, in: settingsScroll, bySwiping: .left)
        searchButton.tap()

        XCTAssertTrue(app.navigationBars["UITest Search.pdf"].waitForExistence(timeout: 4))
        let searchField = app.searchFields["搜索 PDF 文本"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        searchField.tap()
        searchField.typeText("NeedleTarget")

        let result = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "第 2 页，")
        ).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "第 1 页，"))
                .firstMatch.exists
        )
        result.tap()

        let highlight = app.descendants(matching: .any)
            .matching(identifier: "pdf-search-highlight-1")
            .firstMatch
        XCTAssertTrue(highlight.waitForExistence(timeout: 5))
        waitUntil(timeout: 5) { (app.scrollViews["document-page-pager"].value as? String) == "2 / 2" }
        XCTAssertTrue(app.descendants(matching: .any)["page-canvas-1"].exists)
    }

    func testDocumentOutputMenusPresentSharePrintAndConflictInterfaces() throws {
        let app = launchIsolatedApp(prefix: "document-output-ui")
        app.buttons["tool-lasso"].tap()
        let output = app.buttons["导出和分享"]
        let more = app.buttons["更多文稿操作"]
        XCTAssertTrue(output.waitForExistence(timeout: 3))
        XCTAssertTrue(more.waitForExistence(timeout: 3))

        for action in ["分享扁平 PDF"] {
            output.tap()
            XCTAssertTrue(app.buttons[action].waitForExistence(timeout: 3))
            for removed in ["导出页面图片", "导出可编辑文稿", "多人协作"] {
                XCTAssertFalse(app.buttons[removed].exists)
            }
            app.buttons[action].tap()
            let activityList = app.otherElements["ActivityListView"]
            XCTAssertTrue(
                activityList.waitForExistence(timeout: 8),
                "\(action) did not present the system share interface"
            )
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.72)).tap()
            XCTAssertTrue(activityList.waitForNonExistence(timeout: 4))
        }

        more.tap()
        tapHittableButton("打印", in: app)
        let localizedPrintTitle = app.navigationBars["打印机选项"].firstMatch
        let englishPrintTitle = app.navigationBars["Options"].firstMatch
        XCTAssertTrue(
            localizedPrintTitle.waitForExistence(timeout: 4)
                || englishPrintTitle.waitForExistence(timeout: 4),
            "Printing did not present the system print-options interface"
        )
        if app.buttons["Close"].exists {
            tapHittableButton("Close", in: app)
        } else {
            tapHittableButton("取消", in: app)
        }
        let printTitle = englishPrintTitle.exists ? englishPrintTitle : localizedPrintTitle
        XCTAssertTrue(printTitle.waitForNonExistence(timeout: 4))

        more.tap()
        tapHittableButton("冲突版本", in: app)
        XCTAssertTrue(app.navigationBars["冲突版本"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["没有待处理冲突"].waitForExistence(timeout: 3))
        tapHittableButton("关闭", in: app)
        XCTAssertTrue(app.navigationBars["冲突版本"].waitForNonExistence(timeout: 3))
    }

    func testIPhoneLibraryWorkspaceTabsSearchAndExportStayReadOnly() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("iPhone-only product boundary")
        }

        let app = launchIsolatedApp(prefix: "pdf-iphone-read-only")
        let readOnly = app.staticTexts["只读"]
        XCTAssertTrue(readOnly.waitForExistence(timeout: 8))
        for tool in ["pen", "fountainPen", "pencil", "marker", "eraser", "lasso", "text"] {
            XCTAssertFalse(app.buttons["tool-\(tool)"].exists)
        }

        let home = app.buttons["home-button"]
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        home.tap()
        XCTAssertTrue(app.descendants(matching: .any)["document-library"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["新建"].exists)
        XCTAssertFalse(app.buttons["选择项目"].exists)

        let pdf = app.staticTexts["UITest Search.pdf"].firstMatch
        XCTAssertTrue(pdf.waitForExistence(timeout: 4))
        pdf.press(forDuration: 0.9)
        for forbiddenAction in ["重命名", "移动", "移到回收站", "永久删除"] {
            XCTAssertFalse(app.buttons[forbiddenAction].exists)
        }
        if app.buttons["打开"].exists {
            app.buttons["打开"].tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.12)).tap()
            pdf.tap()
        }

        XCTAssertTrue(readOnly.waitForExistence(timeout: 5))
        let tabs = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "document-tab-")
        )
        XCTAssertGreaterThanOrEqual(tabs.count, 3)
        let tabScroll = app.scrollViews["document-tab-scroll"]
        XCTAssertTrue(tabScroll.waitForExistence(timeout: 3))

        let firstTab = app.buttons["document-tab-UITest One"]
        XCTAssertTrue(firstTab.waitForExistence(timeout: 3))
        revealDocumentTab(firstTab, in: tabScroll)
        firstTab.tap()
        XCTAssertEqual(firstTab.value as? String, "active")

        let pdfTab = app.buttons["document-tab-UITest Search.pdf"]
        XCTAssertTrue(pdfTab.waitForExistence(timeout: 3))
        revealDocumentTab(pdfTab, in: tabScroll)
        pdfTab.tap()
        XCTAssertEqual(pdfTab.value as? String, "active")

        app.buttons["搜索 PDF"].tap()
        XCTAssertTrue(app.navigationBars["UITest Search.pdf"].waitForExistence(timeout: 4))
        let searchField = app.searchFields["搜索 PDF 文本"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        searchField.tap()
        searchField.typeText("NeedleTarget")
        let result = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "第 2 页，")
        ).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()

        let highlight = app.descendants(matching: .any)
            .matching(identifier: "pdf-search-highlight-1")
            .firstMatch
        XCTAssertTrue(highlight.waitForExistence(timeout: 5))
        waitUntil(timeout: 5) { (app.scrollViews["document-page-pager"].value as? String) == "2 / 2" }

        let canvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-1")
            .firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 3))
        let drawingValue = canvas.value as? String
        drawStroke(on: canvas)
        XCTAssertEqual(canvas.value as? String, drawingValue)
        XCTAssertFalse(app.buttons["tool-lasso"].exists)
        XCTAssertFalse(app.buttons["tool-text"].exists)

        app.buttons["导出和分享"].tap()
        tapHittableButton("分享扁平 PDF", in: app)
        let activityList = app.otherElements["ActivityListView"]
        XCTAssertTrue(activityList.waitForExistence(timeout: 8))
        if app.buttons["Close"].exists {
            app.buttons["Close"].tap()
        } else {
            // On iPhone the activity controller is a bottom sheet. Swiping its
            // inner activity list only scrolls the list; tap the dimmed area
            // above the sheet first, then drag the sheet itself as a fallback.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.10)).tap()
            if !activityList.waitForNonExistence(timeout: 2) {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.18))
                    .press(
                        forDuration: 0.05,
                        thenDragTo: app.coordinate(
                            withNormalizedOffset: CGVector(dx: 0.50, dy: 0.92)
                        ),
                        withVelocity: .fast,
                        thenHoldForDuration: 0
                    )
            }
        }
        XCTAssertTrue(activityList.waitForNonExistence(timeout: 4))
    }

    func testTabletTabStripScrollsBothWaysWithoutReordering() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("iPad tab strip interaction")
        }
        let app = launchIsolatedApp(prefix: "tabs-overflow")
        let strip = app.scrollViews["document-tab-scroll"]
        let first = app.buttons["document-tab-UITest One"]
        let last = app.buttons["document-tab-UITest Tab 8"]
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        XCTAssertTrue(first.isHittable)
        let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "document-tab-"))
        let originalOrder = tabs.allElementsBoundByIndex.map(\.identifier)
        XCTAssertEqual(originalOrder.count, 8)

        func isVisible(_ tab: XCUIElement) -> Bool {
            strip.frame.contains(CGPoint(x: tab.frame.midX, y: tab.frame.midY))
        }
        func swipeStrip(left: Bool) {
            let origin = strip.coordinate(withNormalizedOffset: .zero)
            let y = first.frame.midY - strip.frame.minY
            origin.withOffset(CGVector(dx: strip.frame.width * (left ? 0.82 : 0.18), dy: y))
                .press(forDuration: 0.04,
                       thenDragTo: origin.withOffset(CGVector(dx: strip.frame.width * (left ? 0.18 : 0.82), dy: y)),
                       withVelocity: .slow, thenHoldForDuration: 0)
        }
        for _ in 0..<4 where !isVisible(last) { swipeStrip(left: true) }
        XCTAssertTrue(last.isHittable, "A finger swipe must reveal overflow tabs on iPad")
        XCTAssertEqual(first.value as? String, "active", "Scrolling must not switch or reorder documents")
        XCTAssertEqual(tabs.allElementsBoundByIndex.map(\.identifier), originalOrder)
        last.tap()
        XCTAssertEqual(last.value as? String, "active")
        for _ in 0..<4 where !isVisible(first) { swipeStrip(left: false) }
        XCTAssertTrue(first.isHittable, "The strip must also scroll back to the first document")
        XCTAssertEqual(tabs.allElementsBoundByIndex.map(\.identifier), originalOrder)
        first.tap()
        XCTAssertEqual(first.value as? String, "active")
    }

    func testTabsReorderCloseAndHomeRemainUsable() throws {
        let app = launchIsolatedApp(prefix: "tabs-home")
        let firstTab = app.buttons["document-tab-UITest One"]
        let secondTab = app.buttons["document-tab-UITest Two"]
        XCTAssertTrue(firstTab.waitForExistence(timeout: 5))
        XCTAssertTrue(secondTab.waitForExistence(timeout: 3))
        XCTAssertLessThan(firstTab.frame.minX, secondTab.frame.minX)

        let dragStart = secondTab.coordinate(
            withNormalizedOffset: CGVector(dx: 0.45, dy: 0.50)
        )
        dragStart.press(
            forDuration: 0.35,
            thenDragTo: dragStart.withOffset(CGVector(dx: -250, dy: 70))
        )
        waitUntil(timeout: 3) {
            secondTab.frame.minX < firstTab.frame.minX
        }
        XCTAssertEqual(firstTab.frame.minY, secondTab.frame.minY, accuracy: 1)
        XCTAssertEqual(firstTab.value as? String, "active")

        let reverseDragStart = secondTab.coordinate(
            withNormalizedOffset: CGVector(dx: 0.45, dy: 0.50)
        )
        reverseDragStart.press(
            forDuration: 0.35,
            thenDragTo: reverseDragStart.withOffset(CGVector(dx: 250, dy: 0))
        )
        waitUntil(timeout: 3) {
            firstTab.frame.minX < secondTab.frame.minX
        }
        XCTAssertEqual(firstTab.value as? String, "active")

        firstTab.tap()
        XCTAssertEqual(firstTab.value as? String, "active")
        secondTab.tap()
        XCTAssertEqual(secondTab.value as? String, "active")

        let closeSecond = app.buttons["关闭 UITest Two"]
        XCTAssertTrue(closeSecond.waitForExistence(timeout: 3))
        closeSecond.tap()
        XCTAssertTrue(secondTab.waitForNonExistence(timeout: 3))
        XCTAssertTrue(firstTab.exists)

        let closeLast = app.buttons["关闭 UITest One"]
        XCTAssertTrue(closeLast.waitForExistence(timeout: 3))
        closeLast.tap()
        XCTAssertTrue(app.descendants(matching: .any)["document-library"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["document-tab-bar"].exists)
        // Closing a tab keeps the document in the library and it can be opened again.
        let document = app.staticTexts["UITest One"].firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 3))
        document.tap()
        XCTAssertTrue(firstTab.waitForExistence(timeout: 5))
        XCTAssertFalse(secondTab.exists)
        XCTAssertTrue(closeLast.exists)

        let home = app.buttons["home-button"]
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        home.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["document-library"].waitForExistence(timeout: 3)
        )
    }

    func testLibraryCreatesNestedFoldersCanvasAndReturnsFromDocument() throws {
        let app = launchIsolatedApp(prefix: "library-create-nested")
        XCTAssertTrue(app.descendants(matching: .any)["document-library"].waitForExistence(timeout: 8))

        createFolder(named: "项目 A", in: app)
        let project = app.staticTexts["项目 A"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 4))
        project.tap()
        XCTAssertTrue(app.buttons["项目 A"].firstMatch.waitForExistence(timeout: 3))

        createFolder(named: "子文件夹", in: app)
        let child = app.staticTexts["子文件夹"].firstMatch
        XCTAssertTrue(child.waitForExistence(timeout: 4))
        child.tap()
        XCTAssertTrue(app.buttons["子文件夹"].firstMatch.waitForExistence(timeout: 3))

        let newCanvas = app.buttons["新建画板"].firstMatch
        XCTAssertTrue(newCanvas.waitForExistence(timeout: 3))
        newCanvas.tap()
        let canvasName = app.textFields["画板名称"]
        XCTAssertTrue(canvasName.waitForExistence(timeout: 3))
        replaceText(in: canvasName, with: "验收画板")
        app.buttons["方格"].tap()
        let lightBlue = app.buttons["浅蓝"]
        for _ in 0..<3 where !lightBlue.exists {
            app.swipeUp()
        }
        XCTAssertTrue(lightBlue.waitForExistence(timeout: 3))
        lightBlue.tap()
        app.buttons["创建"].tap()

        let canvas = app.staticTexts["验收画板"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        canvas.tap()
        XCTAssertTrue(app.buttons["home-button"].waitForExistence(timeout: 5))
        app.buttons["home-button"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["document-library"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["项目 A"].firstMatch.exists)
    }

    func testLibraryRenameFavoriteMoveSearchTrashAndRestoreUseRealRows() throws {
        let app = launchIsolatedApp(prefix: "library-metadata-lifecycle")
        XCTAssertTrue(app.staticTexts["UITest One"].firstMatch.waitForExistence(timeout: 8))

        openContextMenu(for: app.staticTexts["UITest One"].firstMatch, in: app)
        tapHittableButton("重命名", in: app)
        let renameField = app.textFields["名称"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 3))
        replaceText(in: renameField, with: "重命名画板")
        tapHittableButton("保存", in: app)
        let renamed = app.staticTexts["重命名画板"].firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 4))

        openContextMenu(for: renamed, in: app)
        tapHittableButton("收藏", in: app)
        selectLibraryScope("favorites", in: app)
        XCTAssertTrue(app.staticTexts["重命名画板"].firstMatch.waitForExistence(timeout: 4))
        selectLibraryScope("documents", in: app)

        createFolder(named: "归档", in: app)
        XCTAssertTrue(app.staticTexts["归档"].firstMatch.waitForExistence(timeout: 4))
        openContextMenu(for: app.staticTexts["重命名画板"].firstMatch, in: app)
        tapHittableButton("移动到", in: app)
        XCTAssertTrue(app.navigationBars["移动到"].waitForExistence(timeout: 3))
        tapHittableButton("归档", in: app)
        XCTAssertTrue(app.navigationBars["移动到"].waitForNonExistence(timeout: 4))

        app.staticTexts["归档"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["重命名画板"].firstMatch.waitForExistence(timeout: 4))

        let gridButton = app.buttons["网格视图"]
        XCTAssertTrue(gridButton.waitForExistence(timeout: 3))
        gridButton.tap()
        XCTAssertTrue(app.buttons["列表视图"].waitForExistence(timeout: 3))
        app.buttons["列表视图"].tap()
        XCTAssertTrue(app.buttons["网格视图"].waitForExistence(timeout: 3))

        let search = app.textFields["搜索文稿和文件夹"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("重命名")
        XCTAssertTrue(app.staticTexts["重命名画板"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["UITest Two"].exists)
        app.buttons["清除搜索"].tap()

        openContextMenu(for: app.staticTexts["重命名画板"].firstMatch, in: app)
        tapHittableButton("移到回收站", in: app)
        tapHittableButton("移到回收站", in: app)
        XCTAssertTrue(app.staticTexts["重命名画板"].firstMatch.waitForNonExistence(timeout: 4))

        selectLibraryScope("trash", in: app)
        let trashed = app.staticTexts["重命名画板"].firstMatch
        XCTAssertTrue(trashed.waitForExistence(timeout: 4))
        openContextMenu(for: trashed, in: app)
        tapHittableButton("恢复", in: app)
        XCTAssertTrue(trashed.waitForNonExistence(timeout: 4))

        selectLibraryScope("documents", in: app)
        app.staticTexts["归档"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["重命名画板"].firstMatch.waitForExistence(timeout: 4))
    }

    func testLibraryFolderAppearanceTypeFiltersAndAllSortOrdersChangeRealRows() throws {
        let app = launchIsolatedApp(prefix: "library-filter-sort")
        XCTAssertTrue(app.staticTexts["UITest One"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["UITest PDF.pdf"].firstMatch.waitForExistence(timeout: 4))

        createFolder(named: "课程资料", in: app)
        openContextMenu(for: app.staticTexts["课程资料"].firstMatch, in: app)
        tapHittableButton("名称、颜色与图标", in: app)
        XCTAssertTrue(app.navigationBars["编辑文件夹"].waitForExistence(timeout: 3))
        let folderName = app.textFields["文件夹名称"]
        XCTAssertTrue(folderName.waitForExistence(timeout: 3))
        replaceText(in: folderName, with: "专题资料")
        app.buttons["紫色"].tap()
        app.buttons["学习"].tap()
        tapHittableButton("保存", in: app)

        let appearance = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "专题资料文件夹外观"))
            .firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 4))
        XCTAssertEqual(appearance.value as? String, "颜色 紫色；图标 学习")

        selectLibraryKind("pdf", in: app)
        XCTAssertTrue(app.staticTexts["UITest PDF.pdf"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["UITest One"].exists)
        XCTAssertFalse(app.staticTexts["UITest Two"].exists)

        selectLibraryKind("canvas", in: app)
        XCTAssertTrue(app.staticTexts["UITest One"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["UITest Two"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["UITest PDF.pdf"].exists)

        selectLibraryKind("all", in: app)

        tapHittableButton("排序：最近修改", in: app)
        tapHittableButton("名称 A–Z", in: app)
        XCTAssertTrue(app.buttons["排序：名称 A–Z"].waitForExistence(timeout: 3))
        XCTAssertLessThan(
            app.staticTexts["UITest One"].firstMatch.frame.minY,
            app.staticTexts["UITest Two"].firstMatch.frame.minY
        )

        tapHittableButton("排序：名称 A–Z", in: app)
        tapHittableButton("名称 Z–A", in: app)
        XCTAssertTrue(app.buttons["排序：名称 Z–A"].waitForExistence(timeout: 3))
        XCTAssertLessThan(
            app.staticTexts["UITest Two"].firstMatch.frame.minY,
            app.staticTexts["UITest One"].firstMatch.frame.minY
        )

        tapHittableButton("排序：名称 Z–A", in: app)
        tapHittableButton("最近创建", in: app)
        XCTAssertTrue(app.buttons["排序：最近创建"].waitForExistence(timeout: 3))
        XCTAssertLessThan(
            app.staticTexts["UITest PDF.pdf"].firstMatch.frame.minY,
            app.staticTexts["UITest Two"].firstMatch.frame.minY
        )

        tapHittableButton("排序：最近创建", in: app)
        tapHittableButton("最近修改", in: app)
        XCTAssertTrue(app.buttons["排序：最近修改"].waitForExistence(timeout: 3))
    }

    func testLibraryBatchCopyStorePreservesContentAndHandlesFailures() {
        let app = XCUIApplication()
        app.launchArguments = ["--library-smoke", "copy-only-" + UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.staticTexts["批量复制验证通过"].waitForExistence(timeout: 60), app.debugDescription)
    }

    func testLibraryBatchCopyPickerSelectionAndIndependentCopies() throws {
        let app = launchIsolatedApp(prefix: "library-batch-copy")
        XCTAssertTrue(app.staticTexts["UITest One"].firstMatch.waitForExistence(timeout: 8))
        createFolder(named: "批量副本", in: app)
        selectLibraryKind("canvas", in: app)
        tapHittableButton("选择项目", in: app)
        app.buttons["library-select-all-documents"].tap()
        XCTAssertTrue(app.staticTexts["已选 2 项"].waitForExistence(timeout: 3))
        // Select-all deliberately excludes folders, which are not supported by file copy.
        XCTAssertTrue(app.buttons["library-copy-selected"].isEnabled)
        app.buttons["library-select-all-documents"].tap()
        XCTAssertFalse(app.buttons["library-copy-selected"].isEnabled)
        app.staticTexts["UITest One"].firstMatch.tap()
        app.staticTexts["UITest Two"].firstMatch.tap()
        app.buttons["library-copy-selected"].tap()
        XCTAssertTrue(app.buttons["复制到此文件夹"].waitForExistence(timeout: 3))
        app.buttons["批量副本"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["没有子文件夹，可直接复制到此处"].exists)
        let picker = XCTAttachment(screenshot: app.screenshot())
        picker.name = "批量复制：目标文件夹"
        picker.lifetime = .keepAlways
        add(picker)
        app.buttons["新建文件夹"].tap()
        let field = app.alerts.textFields["文件夹名称"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("子目录")
        app.alerts.buttons["创建"].tap()
        XCTAssertTrue(app.buttons["子目录"].waitForExistence(timeout: 3))
        app.buttons["复制到此文件夹"].tap()
        XCTAssertTrue(app.staticTexts["已复制 2 个文件"].waitForExistence(timeout: 15))
        app.buttons["查看文件夹"].tap()
        XCTAssertTrue(app.staticTexts["UITest One"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["UITest Two"].exists)
        XCTAssertTrue(app.buttons["子目录"].exists)
        tapHittableButton("选择项目", in: app)
        app.buttons["library-select-all-documents"].tap()
        app.buttons["library-copy-selected"].tap()
        app.buttons["复制到此文件夹"].tap()
        XCTAssertTrue(app.staticTexts["已复制 2 个文件"].waitForExistence(timeout: 15))
        app.buttons["查看文件夹"].tap()
        XCTAssertTrue(app.staticTexts["UITest One_副本"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["UITest Two_副本"].exists)
        let copies = XCTAttachment(screenshot: app.screenshot())
        copies.name = "批量复制：原名和同名副本"
        copies.lifetime = .keepAlways
        add(copies)
        app.buttons["文稿"].tap()
        XCTAssertTrue(app.staticTexts["UITest One"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["UITest Two"].exists)
        XCTAssertFalse(app.staticTexts["UITest One_副本"].exists)
    }

    func testLibraryBatchMoveTrashRestoreAndPermanentDeleteAffectEverySelectedItem() throws {
        let app = launchIsolatedApp(prefix: "library-batch-lifecycle")
        XCTAssertTrue(app.staticTexts["UITest One"].firstMatch.waitForExistence(timeout: 8))
        createFolder(named: "批量归档", in: app)

        tapHittableButton("选择项目", in: app)
        app.staticTexts["UITest One"].firstMatch.tap()
        app.staticTexts["UITest Two"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已选 2 项"].waitForExistence(timeout: 3))
        tapHittableButton("移动", in: app)
        XCTAssertTrue(app.navigationBars["移动到"].waitForExistence(timeout: 3))
        tapHittableButton("批量归档", in: app)
        XCTAssertTrue(app.navigationBars["移动到"].waitForNonExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["UITest One"].exists)
        XCTAssertFalse(app.staticTexts["UITest Two"].exists)

        app.staticTexts["批量归档"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["UITest One"].firstMatch.waitForExistence(timeout: 4))
        tapHittableButton("选择项目", in: app)
        app.staticTexts["UITest One"].firstMatch.tap()
        app.staticTexts["UITest Two"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已选 2 项"].waitForExistence(timeout: 3))
        tapHittableButton("删除", in: app)
        tapHittableButton("移到回收站", in: app)
        XCTAssertTrue(app.staticTexts["UITest One"].firstMatch.waitForNonExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["UITest Two"].exists)

        selectLibraryScope("trash", in: app)
        XCTAssertTrue(app.staticTexts["UITest One"].firstMatch.waitForExistence(timeout: 4))
        app.staticTexts["UITest One"].firstMatch.tap()
        app.staticTexts["UITest Two"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已选 2 项"].waitForExistence(timeout: 3))
        tapHittableButton("恢复", in: app)
        XCTAssertTrue(app.staticTexts["UITest One"].firstMatch.waitForNonExistence(timeout: 4))

        selectLibraryScope("documents", in: app)
        app.staticTexts["批量归档"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["UITest One"].firstMatch.waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["UITest Two"].firstMatch.exists)

        tapHittableButton("选择项目", in: app)
        app.staticTexts["UITest One"].firstMatch.tap()
        app.staticTexts["UITest Two"].firstMatch.tap()
        tapHittableButton("删除", in: app)
        tapHittableButton("移到回收站", in: app)
        selectLibraryScope("trash", in: app)
        XCTAssertTrue(app.staticTexts["UITest One"].firstMatch.waitForExistence(timeout: 4))
        app.staticTexts["UITest One"].firstMatch.tap()
        app.staticTexts["UITest Two"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已选 2 项"].waitForExistence(timeout: 3))
        tapHittableButton("永久删除", in: app)
        tapHittableButton("永久删除", in: app)
        XCTAssertTrue(app.staticTexts["UITest One"].firstMatch.waitForNonExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["UITest Two"].exists)
    }

    func testLibraryFolderSubtreeTrashRestoreCycleGuardAndEmptyTrash() throws {
        let app = launchIsolatedApp(prefix: "library-folder-subtree")
        XCTAssertTrue(app.descendants(matching: .any)["document-library"].waitForExistence(timeout: 8))
        createFolder(named: "父文件夹", in: app)
        app.staticTexts["父文件夹"].firstMatch.tap()
        createFolder(named: "子文件夹", in: app)
        app.staticTexts["子文件夹"].firstMatch.tap()

        let newCanvas = app.buttons["新建画板"].firstMatch
        XCTAssertTrue(newCanvas.waitForExistence(timeout: 3))
        newCanvas.tap()
        let canvasName = app.textFields["画板名称"]
        XCTAssertTrue(canvasName.waitForExistence(timeout: 3))
        replaceText(in: canvasName, with: "树内画板")
        tapHittableButton("创建", in: app)
        XCTAssertTrue(app.staticTexts["树内画板"].firstMatch.waitForExistence(timeout: 4))

        selectLibraryScope("documents", in: app)
        openContextMenu(for: app.staticTexts["父文件夹"].firstMatch, in: app)
        tapHittableButton("移动到", in: app)
        XCTAssertTrue(app.navigationBars["移动到"].waitForExistence(timeout: 3))
        XCTAssertFalse(
            app.buttons.matching(NSPredicate(format: "label == %@", "父文件夹"))
                .allElementsBoundByIndex.contains(where: { $0.isHittable })
        )
        XCTAssertFalse(
            app.buttons.matching(NSPredicate(format: "label == %@", "父文件夹 / 子文件夹"))
                .allElementsBoundByIndex.contains(where: { $0.isHittable })
        )
        tapHittableButton("取消", in: app)

        openContextMenu(for: app.staticTexts["父文件夹"].firstMatch, in: app)
        tapHittableButton("移到回收站", in: app)
        tapHittableButton("移到回收站", in: app)
        selectLibraryScope("trash", in: app)
        XCTAssertTrue(app.staticTexts["父文件夹"].firstMatch.waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["子文件夹"].exists)
        XCTAssertFalse(app.staticTexts["树内画板"].exists)

        openContextMenu(for: app.staticTexts["父文件夹"].firstMatch, in: app)
        tapHittableButton("恢复", in: app)
        selectLibraryScope("documents", in: app)
        app.staticTexts["父文件夹"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["子文件夹"].firstMatch.waitForExistence(timeout: 4))
        app.staticTexts["子文件夹"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["树内画板"].firstMatch.waitForExistence(timeout: 4))

        selectLibraryScope("documents", in: app)
        openContextMenu(for: app.staticTexts["父文件夹"].firstMatch, in: app)
        tapHittableButton("移到回收站", in: app)
        tapHittableButton("移到回收站", in: app)
        selectLibraryScope("trash", in: app)
        XCTAssertTrue(app.staticTexts["父文件夹"].firstMatch.waitForExistence(timeout: 4))
        tapHittableButton("清空", in: app)
        tapHittableButton("清空", in: app)
        XCTAssertTrue(app.staticTexts["回收站是空的"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["父文件夹"].exists)
    }

    func testLibraryRejectsDuplicateNamesAndSinglePermanentDeleteRemovesExactItems() throws {
        let app = launchIsolatedApp(prefix: "library-single-boundary")
        XCTAssertTrue(app.staticTexts["UITest One"].firstMatch.waitForExistence(timeout: 8))
        createFolder(named: "冲突名称", in: app)

        let newButton = app.buttons["新建"]
        newButton.tap()
        tapHittableButton("新建文件夹", in: app)
        let folderName = app.textFields["文件夹名称"]
        XCTAssertTrue(folderName.waitForExistence(timeout: 3))
        replaceText(in: folderName, with: "冲突名称")
        tapHittableButton("保存", in: app)
        XCTAssertTrue(app.alerts["无法保存文件夹"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts["“冲突名称”已存在于这个文件夹中。"]
                .waitForExistence(timeout: 3)
        )
        tapHittableButton("好", in: app)
        tapHittableButton("取消", in: app)
        XCTAssertEqual(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "冲突名称文件夹外观"))
                .count,
            1
        )

        openContextMenu(for: app.staticTexts["UITest One"].firstMatch, in: app)
        tapHittableButton("重命名", in: app)
        let documentName = app.textFields["名称"]
        XCTAssertTrue(documentName.waitForExistence(timeout: 3))
        replaceText(in: documentName, with: "UITest Two")
        tapHittableButton("保存", in: app)
        XCTAssertTrue(app.alerts["操作失败"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts["“UITest Two”已存在于这个文件夹中。"]
                .waitForExistence(timeout: 3)
        )
        tapHittableButton("好", in: app)
        XCTAssertTrue(app.staticTexts["UITest One"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["UITest Two"].firstMatch.exists)

        openContextMenu(for: app.staticTexts["UITest PDF.pdf"].firstMatch, in: app)
        tapHittableButton("移到回收站", in: app)
        tapHittableButton("移到回收站", in: app)
        openContextMenu(for: app.staticTexts["冲突名称"].firstMatch, in: app)
        tapHittableButton("移到回收站", in: app)
        tapHittableButton("移到回收站", in: app)

        selectLibraryScope("trash", in: app)
        let trashedPDF = app.staticTexts["UITest PDF.pdf"].firstMatch
        XCTAssertTrue(trashedPDF.waitForExistence(timeout: 4))
        openContextMenu(for: trashedPDF, in: app)
        tapHittableButton("永久删除", in: app)
        tapHittableButton("永久删除", in: app)
        XCTAssertTrue(trashedPDF.waitForNonExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["冲突名称"].firstMatch.exists)

        let trashedFolder = app.staticTexts["冲突名称"].firstMatch
        openContextMenu(for: trashedFolder, in: app)
        tapHittableButton("永久删除", in: app)
        tapHittableButton("永久删除", in: app)
        XCTAssertTrue(trashedFolder.waitForNonExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["回收站是空的"].waitForExistence(timeout: 4))
    }

    func testLibraryScannerFailureAndCloudSyncControlsGiveVisibleResults() throws {
        let app = launchIsolatedApp(prefix: "library-cloud-sync-ui")
        XCTAssertTrue(app.staticTexts["UITest One"].firstMatch.waitForExistence(timeout: 8))

        tapHittableButton("新建", in: app)
        tapHittableButton("扫描文稿", in: app)
        let scannerCancel = app.buttons["Cancel"]
        XCTAssertTrue(scannerCancel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Show filter settings"].exists)
        scannerCancel.tap()
        XCTAssertTrue(scannerCancel.waitForNonExistence(timeout: 4))

        let cloudSyncStatus = app.buttons["iCloud 同步状态"]
        if !cloudSyncStatus.isHittable {
            let overflow = ["More", "更多"].lazy
                .map { app.buttons[$0].firstMatch }
                .first(where: { $0.exists && $0.isHittable })
            XCTAssertNotNil(
                overflow,
                "The library toolbar hid its secondary actions without a usable overflow button"
            )
            overflow?.tap()
        }
        tapHittableButton("iCloud 同步状态", in: app)
        XCTAssertTrue(app.navigationBars["iCloud 同步状态"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["资料库等待首次同步"].waitForExistence(timeout: 3))

        let syncNow = app.buttons["现在同步"]
        XCTAssertTrue(syncNow.isEnabled)
        syncNow.tap()
        XCTAssertTrue(
            app.staticTexts["资料库已同步至 iCloud"].waitForExistence(timeout: 5)
        )
        let lastSync = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "上次同步：")
        ).firstMatch
        XCTAssertTrue(lastSync.waitForExistence(timeout: 5))
        tapHittableButton("完成", in: app)
        XCTAssertTrue(app.navigationBars["iCloud 同步状态"].waitForNonExistence(timeout: 3))
    }

    func testPageInsertRotateBookmarkDuplicateDeleteAndRestore() throws {
        let app = launchIsolatedApp(prefix: "page-lifecycle")
        let settingsScroll = app.scrollViews["tool-settings-scroll"]
        XCTAssertTrue(settingsScroll.waitForExistence(timeout: 5))

        let thumbnails = app.buttons["打开页面缩略图"]
        XCTAssertTrue(thumbnails.waitForExistence(timeout: 3))
        reveal(thumbnails, in: settingsScroll, bySwiping: .left)
        thumbnails.tap()
        XCTAssertTrue(app.staticTexts["页面"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["page-thumbnail-0"].exists)

        app.buttons["page-add-menu"].tap()
        XCTAssertTrue(app.buttons["空白页"].waitForExistence(timeout: 3))
        app.buttons["空白页"].tap()
        let secondPage = app.buttons["page-thumbnail-1"]
        XCTAssertTrue(secondPage.waitForExistence(timeout: 4))

        app.buttons["选择"].tap()
        secondPage.tap()
        XCTAssertTrue((secondPage.value as? String)?.contains("selected") == true)

        app.buttons["page-action-旋转"].tap()
        waitForValueContaining("rotation-90", of: secondPage)

        app.buttons["page-action-书签"].tap()
        waitForValueContaining("bookmarked", of: secondPage)
        app.buttons["page-filter-bookmarked"].tap()
        XCTAssertTrue(secondPage.exists)
        XCTAssertFalse(app.buttons["page-thumbnail-0"].exists)

        app.buttons["page-filter-all"].tap()
        app.buttons["选择"].tap()
        secondPage.tap()
        app.buttons["page-action-复制"].tap()
        let thirdPage = app.buttons["page-thumbnail-2"]
        XCTAssertTrue(thirdPage.waitForExistence(timeout: 4))

        app.buttons["page-action-删除"].tap()
        let confirmDelete = app.buttons.matching(
            identifier: "page-confirm-delete"
        ).firstMatch
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 3))
        confirmDelete.tap()
        XCTAssertTrue(thirdPage.waitForNonExistence(timeout: 4))

        app.buttons["page-filter-deleted"].tap()
        XCTAssertTrue(thirdPage.waitForExistence(timeout: 3))
        thirdPage.tap()
        let restore = app.buttons["page-action-恢复"]
        XCTAssertTrue(restore.waitForExistence(timeout: 3))
        restore.tap()
        XCTAssertTrue(thirdPage.waitForExistence(timeout: 4))
        XCTAssertEqual(
            app.buttons["page-filter-all"].value as? String,
            "selected"
        )
    }

    func testPracticeUsesDocumentSidebarGridSelectionAndPersistentPageActions() throws {
        let app = launchIsolatedApp(prefix: "practice-sidebar")
        openPageSidebar(in: app)
        let first = app.buttons["page-thumbnail-0"], second = app.buttons["page-thumbnail-1"]
        XCTAssertTrue(second.waitForExistence(timeout: 4))
        XCTAssertEqual(first.frame.midY, second.frame.midY, accuracy: 2)
        XCTAssertGreaterThan(second.frame.minX, first.frame.maxX)
        XCTAssertFalse(app.buttons["page-thumbnail-2"].exists, "the practice fixture starts with exactly two question pages")
        let palette = app.descendants(matching: .any)["dockable-tool-palette"].firstMatch
        XCTAssertGreaterThanOrEqual(palette.frame.minX, 293, "the palette must stay outside the page sidebar, including on iPhone")
        let toolbar = app.descendants(matching: .any)["annotation-tool-bar"].firstMatch
        XCTAssertGreaterThanOrEqual(app.buttons["page-add-menu"].frame.minY, toolbar.frame.maxY)
        app.buttons["选择"].tap(); second.tap()
        XCTAssertTrue((second.value as? String)?.contains("selected") == true, app.debugDescription)
        for title in ["复制", "旋转", "书签", "删除"] {
            XCTAssertTrue(app.buttons["page-action-\(title)"].isHittable)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "practice-shared-sidebar-selection"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["page-action-复制"].tap()
        let third = app.buttons["page-thumbnail-2"]
        XCTAssertTrue(third.waitForExistence(timeout: 4))
        app.buttons["page-action-旋转"].tap(); waitForValueContaining("rotation-90", of: third)
        app.buttons["page-action-书签"].tap(); waitForValueContaining("bookmarked", of: third)
        app.buttons["page-action-删除"].tap()
        let confirm = app.buttons["page-confirm-delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3)); confirm.tap()
        XCTAssertTrue(third.waitForNonExistence(timeout: 4))
        app.buttons["page-filter-deleted"].tap()
        XCTAssertTrue(third.waitForExistence(timeout: 4))
        app.terminate()
        app.launchArguments.append("--reuse-text-interaction-ui-test-workspace")
        app.launch(); openPageSidebar(in: app)
        app.buttons["page-filter-deleted"].tap()
        XCTAssertTrue(third.waitForExistence(timeout: 4)); third.tap()
        app.buttons["page-action-恢复"].tap()
        XCTAssertTrue(app.buttons["page-filter-all"].waitForExistence(timeout: 4))
        waitForValueContaining("rotation-90", of: third)
        waitForValueContaining("bookmarked", of: third)
        third.tap()
        XCTAssertTrue(app.buttons["practice-question-menu"].label.contains("第 2 题"))
        addPage(named: "方格纸", in: app)
        let fourth = app.buttons["page-thumbnail-3"]
        XCTAssertTrue(fourth.waitForExistence(timeout: 4))
        waitForValueContaining("template-grid", of: fourth)
        XCTAssertTrue(app.buttons["practice-question-menu"].label.contains("第 2 题"))
    }

    func testEveryPageTemplateCreatesTheRequestedRealPage() throws {
        let app = launchIsolatedApp(prefix: "page-templates")
        openPageSidebar(in: app)

        let templates = [
            (button: "空白页", value: "template-blank"),
            (button: "横线纸", value: "template-ruled"),
            (button: "方格纸", value: "template-grid"),
            (button: "点阵纸", value: "template-dotted")
        ]
        for (offset, template) in templates.enumerated() {
            addPage(named: template.button, in: app)
            let thumbnail = app.buttons["page-thumbnail-\(offset + 1)"]
            XCTAssertTrue(thumbnail.waitForExistence(timeout: 4))
            waitForValueContaining(template.value, of: thumbnail)
        }
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "page-thumbnail-")
            ).count,
            5
        )
    }

    func testPageReorderKeepsInkAttachedToTheMovedPage() throws {
        let app = launchIsolatedApp(prefix: "page-reorder-assets")
        let originalCanvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        XCTAssertTrue(originalCanvas.waitForExistence(timeout: 5))
        drawStroke(on: originalCanvas)
        waitForValue("笔迹 1", of: originalCanvas)

        openPageSidebar(in: app)
        addPage(named: "横线纸", in: app)
        let source = app.buttons["page-thumbnail-0"]
        let destination = app.buttons["page-thumbnail-1"]
        XCTAssertTrue(source.waitForExistence(timeout: 4))
        XCTAssertTrue(destination.waitForExistence(timeout: 4))
        waitForValueContaining("template-blank", of: source)
        waitForValueContaining("template-ruled", of: destination)

        source.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).press(
            forDuration: 1.0,
            thenDragTo: destination.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            ),
            withVelocity: .slow,
            thenHoldForDuration: 1.0
        )
        waitForValueContaining("template-ruled", of: source, timeout: 5)
        waitForValueContaining("template-blank", of: destination, timeout: 5)

        let movedCanvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-1")
            .firstMatch
        XCTAssertTrue(movedCanvas.waitForExistence(timeout: 5))
        waitForValue("笔迹 1", of: movedCanvas, timeout: 5)

        destination.tap()
        waitForValue("笔迹 1", of: movedCanvas, timeout: 5)
        let firstCanvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        XCTAssertTrue(firstCanvas.waitForExistence(timeout: 3))
        XCTAssertTrue((firstCanvas.value as? String)?.hasPrefix("笔迹 0") == true)
    }

    func testPageMultiSelectRotatesBookmarksDeletesAndRestoresEveryPage() throws {
        let app = launchIsolatedApp(prefix: "page-multi-actions")
        openPageSidebar(in: app)
        addPage(named: "空白页", in: app)
        addPage(named: "横线纸", in: app)

        app.buttons["选择"].tap()
        let second = app.buttons["page-thumbnail-1"]
        let third = app.buttons["page-thumbnail-2"]
        second.tap()
        third.tap()
        XCTAssertTrue((second.value as? String)?.contains("selected") == true)
        XCTAssertTrue((third.value as? String)?.contains("selected") == true)

        app.buttons["page-action-旋转"].tap()
        waitForValueContaining("rotation-90", of: second)
        waitForValueContaining("rotation-90", of: third)
        app.buttons["page-action-书签"].tap()
        waitForValueContaining("bookmarked", of: second)
        waitForValueContaining("bookmarked", of: third)

        app.buttons["page-filter-bookmarked"].tap()
        XCTAssertTrue(second.exists)
        XCTAssertTrue(third.exists)
        XCTAssertFalse(app.buttons["page-thumbnail-0"].exists)

        app.buttons["page-filter-all"].tap()
        app.buttons["选择"].tap()
        second.tap()
        third.tap()
        app.buttons["page-action-删除"].tap()
        let confirmDelete = app.buttons.matching(identifier: "page-confirm-delete").firstMatch
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 3))
        confirmDelete.tap()
        XCTAssertTrue(second.waitForNonExistence(timeout: 4))
        XCTAssertTrue(third.waitForNonExistence(timeout: 4))

        app.buttons["page-filter-deleted"].tap()
        XCTAssertTrue(second.waitForExistence(timeout: 3))
        XCTAssertTrue(third.waitForExistence(timeout: 3))
        second.tap()
        third.tap()
        app.buttons["page-action-恢复"].tap()
        XCTAssertTrue(app.buttons["page-filter-all"].waitForExistence(timeout: 4))
        XCTAssertEqual(app.buttons["page-filter-all"].value as? String, "selected")
        XCTAssertTrue(second.waitForExistence(timeout: 4))
        XCTAssertTrue(third.waitForExistence(timeout: 4))
    }

    private func launchIsolatedApp(
        prefix: String,
        additionalLaunchArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--text-interaction-ui-test",
            "\(prefix)-\(UUID().uuidString)",
            "--drawing-persistence-idle-delay",
            "0.6"
        ] + additionalLaunchArguments
        app.launch()
        return app
    }

    private func openPageSidebar(in app: XCUIApplication) {
        let settingsScroll = app.scrollViews["tool-settings-scroll"]
        XCTAssertTrue(settingsScroll.waitForExistence(timeout: 5))
        let thumbnails = app.buttons["打开页面缩略图"]
        XCTAssertTrue(thumbnails.waitForExistence(timeout: 3))
        reveal(thumbnails, in: settingsScroll, bySwiping: .left)
        thumbnails.tap()
        XCTAssertTrue(app.staticTexts["页面"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["page-thumbnail-0"].waitForExistence(timeout: 3))
    }

    private func addPage(named template: String, in app: XCUIApplication) {
        app.buttons["page-add-menu"].tap()
        let button = app.buttons[template]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        button.tap()
    }

    private func insertShape(
        named shapeName: String,
        in app: XCUIApplication,
        settingsScroll: XCUIElement
    ) {
        let selectionBox = app.descendants(matching: .any)
            .matching(identifier: "lasso-selection-box")
            .firstMatch
        if selectionBox.exists {
            let canvas = app.descendants(matching: .any)
                .matching(identifier: "page-canvas-0")
                .firstMatch
            XCTAssertTrue(canvas.waitForExistence(timeout: 3))
            canvas.coordinate(
                withNormalizedOffset: CGVector(dx: 0.06, dy: 0.08)
            ).tap()
            XCTAssertTrue(selectionBox.waitForNonExistence(timeout: 3))
        }

        let insertShape = app.buttons["插入图形"]
        XCTAssertTrue(insertShape.waitForExistence(timeout: 5))
        reveal(insertShape, in: settingsScroll, bySwiping: .left)
        insertShape.tap()
        let shape = app.buttons[shapeName]
        XCTAssertTrue(shape.waitForExistence(timeout: 3))
        shape.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "lasso-selection-box")
                .firstMatch
                .waitForExistence(timeout: 3)
        )
    }

    private func shapeTitles(in query: XCUIElementQuery) -> [String] {
        query.allElementsBoundByIndex.compactMap { element in
            guard let value = element.value as? String else { return nil }
            return ["矩形", "圆形", "三角形", "菱形", "直线", "箭头"]
                .first(where: value.contains)
        }
    }

    private func drawStroke(on canvas: XCUIElement) {
        drawStroke(
            on: canvas,
            from: CGVector(dx: 0.32, dy: 0.34),
            to: CGVector(dx: 0.58, dy: 0.46)
        )
    }

    private func drawStroke(
        on canvas: XCUIElement,
        from startOffset: CGVector,
        to endOffset: CGVector
    ) {
        let start = canvas.coordinate(withNormalizedOffset: startOffset)
        let end = canvas.coordinate(withNormalizedOffset: endOffset)
        start.press(forDuration: 0.08, thenDragTo: end)
    }

    private func createFolder(named name: String, in app: XCUIApplication) {
        let newButton = app.buttons["新建"]
        XCTAssertTrue(newButton.waitForExistence(timeout: 3))
        newButton.tap()
        XCTAssertTrue(app.buttons["新建文件夹"].waitForExistence(timeout: 3))
        app.buttons["新建文件夹"].tap()
        let field = app.textFields["文件夹名称"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        replaceText(in: field, with: name)
        app.buttons["保存"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 4))
    }

    private func openContextMenu(for element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 3))
        element.press(forDuration: 1.1)
        XCTAssertTrue(app.buttons["移到回收站"].waitForExistence(timeout: 3)
            || app.buttons["恢复"].waitForExistence(timeout: 3))
    }

    private func selectLibraryScope(_ scope: String, in app: XCUIApplication) {
        app.buttons["library-filter-menu"].tap()
        let item = app.buttons["library-scope-\(scope)"]
        let title = ["documents": "全部文稿", "favorites": "收藏夹", "trash": "回收站"][scope]!
        // Native menus on newer iOS versions expose their title instead of SwiftUI IDs.
        (item.exists ? item : app.buttons[title]).tap()
    }

    private func selectLibraryKind(_ kind: String, in app: XCUIApplication) {
        app.buttons["library-filter-menu"].tap()
        let item = app.buttons["library-kind-\(kind)"]
        let title = ["all": "全部", "pdf": "PDF", "canvas": "画板"][kind]!
        (item.exists ? item : app.buttons[title]).tap()
    }

    private func tapHittableButton(
        _ label: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 3
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        var candidate: XCUIElement?
        repeat {
            candidate = app.buttons.matching(
                NSPredicate(
                    format: "label == %@ OR label BEGINSWITH %@",
                    label,
                    "\(label),"
                )
            ).allElementsBoundByIndex.first(where: { $0.isHittable })
            if candidate == nil {
                RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            }
        } while candidate == nil && Date() < deadline
        XCTAssertNotNil(candidate, "No hittable button named \(label)")
        candidate?.tap()
    }

    private func replaceText(in element: XCUIElement, with text: String) {
        element.tap()
        if let currentValue = element.value as? String,
           !currentValue.isEmpty, currentValue != element.placeholderValue {
            element.typeText(
                String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count)
            )
        }
        if let remainingValue = element.value as? String,
           !remainingValue.isEmpty, remainingValue != element.placeholderValue {
            element.typeKey("a", modifierFlags: .command)
            element.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        element.typeText(text)
        waitUntil(timeout: 2) {
            element.value as? String == text
        }
    }

    private enum SwipeDirection {
        case left
        case right
    }

    private func reveal(
        _ element: XCUIElement,
        in scrollView: XCUIElement,
        bySwiping direction: SwipeDirection
    ) {
        for _ in 0..<10 where !element.isHittable {
            let viewport = scrollView.frame
            let elementFrame = element.frame
            let shouldMoveContentLeft: Bool
            if elementFrame.maxX > viewport.maxX {
                shouldMoveContentLeft = true
            } else if elementFrame.minX < viewport.minX {
                shouldMoveContentLeft = false
            } else {
                shouldMoveContentLeft = direction == .left
            }

            let distanceOutsideViewport = shouldMoveContentLeft
                ? elementFrame.minX - viewport.maxX
                : viewport.minX - elementFrame.maxX
            if distanceOutsideViewport > viewport.width {
                if shouldMoveContentLeft {
                    scrollView.swipeLeft()
                } else {
                    scrollView.swipeRight()
                }
                continue
            }

            let startOffset = shouldMoveContentLeft
                ? CGVector(dx: 0.80, dy: 0.50)
                : CGVector(dx: 0.20, dy: 0.50)
            let endOffset = shouldMoveContentLeft
                ? CGVector(dx: 0.42, dy: 0.50)
                : CGVector(dx: 0.58, dy: 0.50)
            scrollView.coordinate(withNormalizedOffset: startOffset).press(
                forDuration: 0.12,
                thenDragTo: scrollView.coordinate(withNormalizedOffset: endOffset),
                withVelocity: .slow,
                thenHoldForDuration: 0.10
            )
        }
        XCTAssertTrue(
            element.isHittable,
            "Could not reveal \(element); viewport=\(scrollView.frame), frame=\(element.frame)"
        )
    }

    private func revealDocumentTab(
        _ element: XCUIElement,
        in scrollView: XCUIElement
    ) {
        for _ in 0..<8 {
            let viewport = scrollView.frame.insetBy(dx: 6, dy: 0)
            let elementFrame = element.frame
            let isInsideViewport = elementFrame.minX >= viewport.minX
                && elementFrame.maxX <= viewport.maxX
            if isInsideViewport { break }

            let moveContentRight = elementFrame.minX < viewport.minX
            let start = scrollView.coordinate(
                withNormalizedOffset: CGVector(
                    dx: moveContentRight ? 0.20 : 0.80,
                    dy: 0.78
                )
            )
            let end = scrollView.coordinate(
                withNormalizedOffset: CGVector(
                    dx: moveContentRight ? 0.82 : 0.18,
                    dy: 0.78
                )
            )
            start.press(
                forDuration: 0.04,
                thenDragTo: end,
                withVelocity: .fast,
                thenHoldForDuration: 0
            )
        }

        let viewport = scrollView.frame.insetBy(dx: 6, dy: 0)
        let elementFrame = element.frame
        let isInsideViewport = elementFrame.minX >= viewport.minX
            && elementFrame.maxX <= viewport.maxX
        XCTAssertTrue(
            isInsideViewport,
            "Could not reveal tab \(element); viewport=\(viewport), frame=\(elementFrame)"
        )
        if isInsideViewport {
            XCTAssertTrue(element.isHittable)
        }
    }

    private func waitForValue(
        _ expectedValue: String,
        of element: XCUIElement,
        timeout: TimeInterval = 3
    ) {
        let predicate = NSPredicate(format: "value BEGINSWITH %@", expectedValue)
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    private func tapCanvas(
        in app: XCUIApplication,
        at normalizedOffset: CGVector = CGVector(dx: 0.5, dy: 0.45)
    ) {
        let canvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        canvas.coordinate(withNormalizedOffset: normalizedOffset).tap()
    }

    private func waitForValueContaining(
        _ expectedValue: String,
        of element: XCUIElement,
        timeout: TimeInterval = 3
    ) {
        let predicate = NSPredicate(format: "value CONTAINS %@", expectedValue)
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    private func drawingGeometryValue(of element: XCUIElement) -> String? {
        guard let value = element.value as? String,
              let range = value.range(of: "范围 ") else { return nil }
        return value[range.lowerBound...].split(separator: "；").first.map(String.init)
    }

    private func canvasViewportRect(of element: XCUIElement) throws -> CGRect {
        try accessibilityRect(of: element, prefix: "视口 ", separator: " ")
    }

    private func drawingBounds(of element: XCUIElement) throws -> CGRect {
        try accessibilityRect(of: element, prefix: "范围 ", separator: ",")
    }

    private func accessibilityRect(of element: XCUIElement, prefix: String, separator: Character) throws -> CGRect {
        let value = try XCTUnwrap(element.value as? String)
        let range = try XCTUnwrap(value.range(of: prefix))
        let field = try XCTUnwrap(value[range.upperBound...].split(separator: "；").first)
        let numbers = field.split(separator: separator).compactMap { Double($0) }
        XCTAssertEqual(numbers.count, 4, value)
        guard numbers.count == 4 else { throw NSError(domain: "CanvasGeometry", code: 1) }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    private func inkDarkness(
        in pngData: Data,
        around normalizedPoint: CGPoint,
        radius: Int = 8
    ) -> Int? {
        guard let image = UIImage(data: pngData)?.cgImage else { return nil }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        let centerX = min(max(Int(normalizedPoint.x * CGFloat(width)), 0), width - 1)
        let centerY = min(max(Int(normalizedPoint.y * CGFloat(height)), 0), height - 1)
        var darkness = 0
        for y in max(0, centerY - radius)...min(height - 1, centerY + radius) {
            for x in max(0, centerX - radius)...min(width - 1, centerX + radius) {
                let offset = (y * width + x) * 4
                let luminance = (
                    299 * Int(pixels[offset])
                        + 587 * Int(pixels[offset + 1])
                        + 114 * Int(pixels[offset + 2])
                ) / 1_000
                darkness += max(0, 245 - luminance)
            }
        }
        return darkness
    }

    private func waitUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.12,
        application: XCUIApplication? = nil,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        let succeeded = condition()
        if !succeeded {
            let app = application ?? XCUIApplication()
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Interaction hierarchy at line \(line)"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            if app.state == .runningForeground {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Unmet interaction condition at line \(line)"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
        }
        XCTAssertTrue(succeeded, file: file, line: line)
    }

    /// iOS Simulator 26 can acknowledge a device-orientation request before the application
    /// window receives the corresponding scene resize. Cycle through both landscape directions
    /// and verify the actual application frame so layout tests never pass in portrait or fail on
    /// that transient simulator race.
    private func rotateApplicationToLandscape(_ application: XCUIApplication) {
        for orientation in [
            UIDeviceOrientation.landscapeLeft,
            .landscapeRight,
            .landscapeLeft
        ] {
            XCUIDevice.shared.orientation = orientation
            let deadline = Date().addingTimeInterval(3)
            while application.frame.width <= application.frame.height,
                  Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            }
            if application.frame.width > application.frame.height {
                return
            }
            XCUIDevice.shared.orientation = .portrait
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("Simulator 未能把应用窗口切换为横屏")
    }

    private func synthesizeClosedTouchPath(
        around rect: CGRect,
        on targetElement: XCUIElement,
        in application: XCUIApplication,
        holdBeforeLift: TimeInterval = 0.10
    ) throws {
        let insetRect = rect.standardized
        let points = [
            CGPoint(x: insetRect.minX, y: insetRect.minY),
            CGPoint(x: insetRect.midX, y: insetRect.minY),
            CGPoint(x: insetRect.maxX, y: insetRect.minY),
            CGPoint(x: insetRect.maxX, y: insetRect.midY),
            CGPoint(x: insetRect.maxX, y: insetRect.maxY),
            CGPoint(x: insetRect.midX, y: insetRect.maxY),
            CGPoint(x: insetRect.minX, y: insetRect.maxY),
            CGPoint(x: insetRect.minX, y: insetRect.midY),
            CGPoint(x: insetRect.minX, y: insetRect.minY)
        ]

        try synthesizeTouchPath(
            points,
            on: targetElement,
            in: application,
            holdBeforeLift: holdBeforeLift
        )
    }

    private func synthesizeTouchPath(
        _ points: [CGPoint],
        on targetElement: XCUIElement,
        in application: XCUIApplication,
        holdBeforeLift: TimeInterval,
        pauseAfterPointIndex: Int? = nil,
        pauseDuration: TimeInterval = 0
    ) throws {
        guard points.count >= 2 else {
            XCTFail("A synthesized touch path needs at least two points")
            return
        }

        var samples: [(point: CGPoint, offset: TimeInterval)] = [(points[0], 0)]
        var lastMoveOffset = 0.10
        for (index, point) in points.dropFirst().enumerated() {
            let pointIndex = index + 1
            samples.append((point, lastMoveOffset))
            if pauseAfterPointIndex == pointIndex {
                lastMoveOffset += max(pauseDuration, 0)
                samples.append((point, lastMoveOffset))
            }
            if pointIndex < points.count - 1 {
                lastMoveOffset += 0.06
            }
        }
        try synthesizeTouchPaths([
            SynthesizedTouchPath(samples: samples, liftOffset: lastMoveOffset + holdBeforeLift)
        ], on: targetElement, in: application)
    }

    private func pinchCanvas(_ canvas: XCUIElement, scale: CGFloat, in app: XCUIApplication) throws {
        // A full-viewport canvas has floating controls near its corners. Pinch through the
        // middle so both initial contacts belong to the workspace, including when shrinking.
        let frame = canvas.frame
        try synthesizeTouchPaths([-1.0, 1.0].map { side in
            SynthesizedTouchPath(samples: [
                (CGPoint(x: frame.midX + side * frame.width * 0.24, y: frame.midY), 0),
                (CGPoint(x: frame.midX + side * frame.width * 0.24 * (1 + scale) / 2, y: frame.midY), 0.28),
                (CGPoint(x: frame.midX + side * frame.width * 0.24 * scale, y: frame.midY), 0.56)
            ], liftOffset: 0.62)
        }, on: canvas, in: app)
    }

    private struct SynthesizedTouchPath {
        let samples: [(point: CGPoint, offset: TimeInterval)]
        let liftOffset: TimeInterval
    }

    private func synthesizeTouchPaths(
        _ touchPaths: [SynthesizedTouchPath],
        on targetElement: XCUIElement,
        in application: XCUIApplication
    ) throws {
        guard let firstPoint = touchPaths.first?.samples.first?.point,
              touchPaths.allSatisfy({ !$0.samples.isEmpty }) else {
            XCTFail("Synthesized touch paths must contain samples")
            return
        }
        guard let pathClass = NSClassFromString("XCPointerEventPath"),
              let eventClass = NSClassFromString("XCSynthesizedEventRecord"),
              let rawAllocatedEvent = class_createInstance(eventClass, 0) else {
            throw XCTSkip("XCTest pointer event synthesis is unavailable")
        }
        let allocatedEvent = rawAllocatedEvent as AnyObject

        typealias InitTouch = @convention(c) (
            AnyObject, Selector, CGPoint, TimeInterval
        ) -> AnyObject
        typealias TouchOffset = @convention(c) (
            AnyObject, Selector, TimeInterval
        ) -> Void
        typealias MoveTouch = @convention(c) (
            AnyObject, Selector, CGPoint, TimeInterval
        ) -> Void
        typealias InitEvent = @convention(c) (
            AnyObject, Selector, NSString, UInt64, Int64
        ) -> AnyObject
        typealias AddPath = @convention(c) (
            AnyObject, Selector, AnyObject
        ) -> Void
        typealias EventBuilder = @convention(block) (
            AnyObject,
            UnsafeMutablePointer<AnyObject?>?
        ) -> AnyObject?
        typealias DispatchEvent = @convention(c) (
            AnyObject,
            Selector,
            AnyObject,
            UnsafeMutablePointer<AnyObject?>?
        ) -> Bool
        typealias GetOrientation = @convention(c) (
            AnyObject,
            Selector
        ) -> Int64
        typealias GetDisplayID = @convention(c) (
            AnyObject,
            Selector
        ) -> UInt64
        typealias SetOriginalOffset = @convention(c) (
            AnyObject,
            Selector,
            CGVector
        ) -> Void

        let initPathSelector = NSSelectorFromString("initForTouchAtPoint:offset:")
        let moveSelector = NSSelectorFromString("moveToPoint:atOffset:")
        let liftSelector = NSSelectorFromString("liftUpAtOffset:")
        let initEventSelector = NSSelectorFromString(
            "initWithName:displayID:interfaceOrientation:"
        )
        let addPathSelector = NSSelectorFromString("addPointerEventPath:")
        let dispatchSelector = NSSelectorFromString(
            "_dispatchEventWithEventBuilder:error:"
        )
        let orientationSelector = NSSelectorFromString("interfaceOrientation")
        let displayIDSelector = NSSelectorFromString("displayID")
        let setOriginalOffsetSelector = NSSelectorFromString("setOriginalOffset:")

        let interfaceOrientation: Int64
        if targetElement.responds(to: orientationSelector) {
            interfaceOrientation = unsafeBitCast(
                targetElement.method(for: orientationSelector),
                to: GetOrientation.self
            )(targetElement, orientationSelector)
        } else {
            interfaceOrientation = 1
        }
        let resolvedDisplayID: UInt64
        if targetElement.responds(to: displayIDSelector) {
            resolvedDisplayID = unsafeBitCast(
                targetElement.method(for: displayIDSelector),
                to: GetDisplayID.self
            )(targetElement, displayIDSelector)
        } else {
            resolvedDisplayID = 0
        }
        // XCUIElement query objects report zero here even though the resolved
        // iOS Simulator screen is display 1. XCTest's own coordinate events
        // use display 1, and display 0 is silently discarded by the daemon.
        let displayID = resolvedDisplayID == 0 ? 1 : resolvedDisplayID
        let event = unsafeBitCast(
            allocatedEvent.method(for: initEventSelector),
            to: InitEvent.self
        )(
            allocatedEvent,
            initEventSelector,
            "Document touch interaction",
            displayID,
            interfaceOrientation
        )
        if event.responds(to: setOriginalOffsetSelector) {
            let targetFrame = targetElement.frame
            let originalOffset = CGVector(
                dx: firstPoint.x - targetFrame.minX,
                dy: firstPoint.y - targetFrame.minY
            )
            unsafeBitCast(
                event.method(for: setOriginalOffsetSelector),
                to: SetOriginalOffset.self
            )(event, setOriginalOffsetSelector, originalOffset)
        }
        for touchPath in touchPaths {
            guard let rawAllocatedPath = class_createInstance(pathClass, 0),
                  let firstSample = touchPath.samples.first else {
                throw XCTSkip("XCTest pointer path allocation is unavailable")
            }
            let allocatedPath = rawAllocatedPath as AnyObject
            let path = unsafeBitCast(
                allocatedPath.method(for: initPathSelector),
                to: InitTouch.self
            )(allocatedPath, initPathSelector, firstSample.point, firstSample.offset)
            for sample in touchPath.samples.dropFirst() {
                unsafeBitCast(path.method(for: moveSelector), to: MoveTouch.self)(
                    path, moveSelector, sample.point, sample.offset
                )
            }
            unsafeBitCast(path.method(for: liftSelector), to: TouchOffset.self)(
                path, liftSelector, touchPath.liftOffset
            )
            unsafeBitCast(event.method(for: addPathSelector), to: AddPath.self)(
                event, addPathSelector, path
            )
        }

        guard application.responds(to: dispatchSelector) else {
            throw XCTSkip("XCTest element event dispatch is unavailable")
        }
        let builder: EventBuilder = { _, _ in event }
        let builderObject = unsafeBitCast(builder, to: AnyObject.self)
        var synthesisError: AnyObject?
        let succeeded = unsafeBitCast(
            application.method(for: dispatchSelector),
            to: DispatchEvent.self
        )(application, dispatchSelector, builderObject, &synthesisError)
        XCTAssertTrue(
            succeeded,
            "Could not synthesize touch interaction: \(String(describing: synthesisError))"
        )
    }

    private func interpolatedClosedPath(
        _ vertices: [CGPoint],
        samplesPerEdge: Int
    ) -> [CGPoint] {
        guard vertices.count >= 2 else { return vertices }
        var points: [CGPoint] = []
        for index in vertices.indices {
            let start = vertices[index]
            let end = vertices[(index + 1) % vertices.count]
            for sample in 0..<samplesPerEdge {
                let progress = CGFloat(sample) / CGFloat(samplesPerEdge)
                points.append(
                    CGPoint(
                        x: start.x + (end.x - start.x) * progress,
                        y: start.y + (end.y - start.y) * progress
                    )
                )
            }
        }
        points.append(vertices[0])
        return points
    }
}
