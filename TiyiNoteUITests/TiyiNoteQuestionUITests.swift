import XCTest

final class TiyiNoteQuestionUITests: XCTestCase {
    func testCanvasQuestionCancelAnswerReopenAndRelaunch() {
        let app = launch("question-canvas")
        let canvas = app.descendants(matching: .any)["page-canvas-0"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        canvas.pinch(withScale: 1.3, velocity: 1)
        let before = canvas.value as? String
        circle(in: app, canvas: canvas)
        XCTAssertFalse(app.buttons["question-cancel"].exists)
        XCTAssertFalse(app.buttons["重新圈选"].exists)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.8)).tap()
        XCTAssertTrue(app.buttons["question-confirm"].waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["question-marker"].exists)
        XCTAssertEqual(canvas.value as? String, before)
        circle(in: app, canvas: canvas)
        app.buttons["question-confirm"].tap()
        let exit = app.buttons["practice-exit"]
        XCTAssertTrue(exit.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["tool-question"].exists)
        XCTAssertTrue(app.buttons["tool-lasso"].exists)
        app.buttons["tool-pen"].tap()
        // Dismiss pen settings by choosing the actual nib.
        if app.buttons["pen-variant-pen"].waitForExistence(timeout: 2) { app.buttons["pen-variant-pen"].tap() }
        let answerCanvas = app.descendants(matching: .any)["page-canvas-0"]
        answerCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: answerCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.6)))
        XCTAssertTrue(waitValue("笔迹 1", element: answerCanvas))
        let inkBounds = field("范围 ", of: answerCanvas)
        let inkAppearance = field("墨迹 ", of: answerCanvas)?.split(separator: ",").dropFirst().joined(separator: ",")
        exit.tap()
        let marker = app.descendants(matching: .any)["question-marker"]
        XCTAssertTrue(marker.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["tool-question"].exists)
        XCTAssertEqual(field("视口 ", of: canvas), before?.components(separatedBy: "；").first { $0.hasPrefix("视口 ") })
        openMarker(in: app, marker: marker)
        XCTAssertTrue(exit.waitForExistence(timeout: 10))
        XCTAssertTrue(waitValue("笔迹 1", element: answerCanvas))
        XCTAssertEqual(field("范围 ", of: answerCanvas), inkBounds)
        XCTAssertEqual(field("墨迹 ", of: answerCanvas)?.split(separator: ",").dropFirst().joined(separator: ","), inkAppearance)
        app.buttons["作答操作"].tap()
        app.buttons["标记完成"].tap()
        exit.tap()
        XCTAssertTrue(marker.waitForExistence(timeout: 10))
        XCTAssertEqual(marker.label, "继续圈题作答，已完成")
        app.terminate()
        app.launchArguments.append("--reuse-text-interaction-ui-test-workspace")
        app.launch()
        XCTAssertTrue(marker.waitForExistence(timeout: 10))
        XCTAssertEqual(marker.label, "继续圈题作答，已完成")
        openMarker(in: app, marker: marker)
        XCTAssertTrue(exit.waitForExistence(timeout: 10))
        XCTAssertTrue(waitValue("笔迹 1", element: answerCanvas))
        exit.tap()
    }

    func testPDFQuestionAndAccountPracticeHasNoCaptureTool() {
        let app = launch("pdf-question")
        let canvas = app.descendants(matching: .any)["page-canvas-0"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        circle(in: app, canvas: canvas)
        let handle = app.descendants(matching: .any)["调整圈题范围 1"]
        let origin = handle.frame.origin
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: -12, dy: -12)))
        XCTAssertLessThan(handle.frame.minX, origin.x)
        let originalFrame = canvas.frame
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "PDF 圈题浮动操作栏"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["question-confirm"].tap()
        XCTAssertTrue(app.buttons["practice-exit"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["tool-question"].exists)
        app.buttons["practice-exit"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["question-marker"].waitForExistence(timeout: 10))
        XCTAssertEqual(canvas.frame, originalFrame)
        app.terminate()
        let practice = launch("practice-sidebar-question")
        XCTAssertTrue(practice.buttons["practice-exit"].waitForExistence(timeout: 10))
        XCTAssertFalse(practice.buttons["tool-question"].exists)
        XCTAssertTrue(practice.buttons["tool-lasso"].exists)
    }

    func testMarkerLassoEnterDeleteAndDragPersist() {
        let app = launch("question-marker-lasso")
        let canvas = app.descendants(matching: .any)["page-canvas-0"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(app.buttons["tool-question"].frame.minX, app.buttons["tool-eraser"].frame.maxX)
        XCTAssertLessThan(app.buttons["tool-question"].frame.maxX, app.buttons["tool-text"].frame.minX)
        circle(in: app, canvas: canvas)
        app.buttons["question-confirm"].tap()
        XCTAssertTrue(app.buttons["practice-exit"].waitForExistence(timeout: 15))
        app.buttons["practice-exit"].tap()
        let marker = app.descendants(matching: .any)["question-marker"].firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 10))
        app.buttons["tool-pen"].tap()
        if app.buttons["pen-variant-pen"].waitForExistence(timeout: 2) { app.buttons["pen-variant-pen"].tap() }
        let original = marker.frame
        marker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let selection = app.descendants(matching: .any)["lasso-selection-box"]
        XCTAssertTrue(selection.waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["tool-lasso"].value as? String, "selected")
        XCTAssertTrue(waitValue("笔迹 0", element: canvas))
        XCTAssertTrue(app.buttons["删除"].isEnabled)
        XCTAssertTrue(app.buttons["question-selection-open"].exists)
        XCTAssertFalse(app.buttons["practice-exit"].exists)
        selection.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: selection.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 90, dy: 80)))
        XCTAssertEqual(marker.frame.midX, original.midX + 90, accuracy: 4)
        XCTAssertEqual(marker.frame.midY, original.midY + 80, accuracy: 4)
        let moved = marker.frame
        for title in ["复制", "拷贝", "截图", "对象操作"] {
            XCTAssertFalse(app.buttons[title].exists)
        }
        XCTAssertFalse(app.descendants(matching: .any)["lasso-rotation-handle"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'lasso-resize-'")).firstMatch.exists)
        XCTAssertEqual(app.buttons["question-selection-open"].label, "进入作答")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "套索选中作答标记"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["question-selection-open"].tap()
        XCTAssertTrue(app.buttons["practice-exit"].waitForExistence(timeout: 10))
        app.buttons["practice-exit"].tap()
        XCTAssertTrue(marker.waitForExistence(timeout: 10))
        XCTAssertEqual(marker.frame.midX, moved.midX, accuracy: 1)
        app.terminate()
        app.launchArguments.append("--reuse-text-interaction-ui-test-workspace")
        app.launch()
        XCTAssertTrue(marker.waitForExistence(timeout: 10))
        XCTAssertEqual(marker.frame.midX, moved.midX, accuracy: 1)
        XCTAssertEqual(marker.frame.midY, moved.midY, accuracy: 1)
        // Finger selection under the pen uses the same canvas recognizer as ordinary shapes.
        app.buttons["tool-pen"].tap()
        if app.buttons["pen-variant-pen"].waitForExistence(timeout: 2) { app.buttons["pen-variant-pen"].tap() }
        marker.tap()
        XCTAssertTrue(selection.waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["tool-lasso"].value as? String, "selected")
        XCTAssertFalse(app.buttons["practice-exit"].exists)
        app.buttons["question-selection-open"].tap()
        XCTAssertTrue(app.buttons["practice-exit"].waitForExistence(timeout: 10))
        app.buttons["practice-exit"].tap()
        XCTAssertTrue(marker.waitForExistence(timeout: 10))
        app.buttons["tool-lasso"].tap()
        marker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(selection.waitForExistence(timeout: 3))
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.8)).tap()
        XCTAssertTrue(selection.waitForNonExistence(timeout: 3))
        marker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["删除"].tap()
        XCTAssertTrue(marker.waitForNonExistence(timeout: 3))
        app.terminate()
        app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        XCTAssertFalse(marker.exists)
    }

    func testDocumentAttachmentPersistenceAndCloudTransportChecks() {
        let app = XCUIApplication()
        app.launchArguments = ["--document-question-checks"]
        app.launch()
        XCTAssertTrue(app.staticTexts["question-checks-passed"].waitForExistence(timeout: 45), app.debugDescription)
    }

    private func openMarker(in app: XCUIApplication, marker: XCUIElement) {
        marker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        if app.buttons["question-selection-open"].waitForExistence(timeout: 2) {
            app.buttons["question-selection-open"].tap()
        }
    }

    private func launch(_ prefix: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--text-interaction-ui-test", "\(prefix)-\(UUID().uuidString)", "--drawing-persistence-idle-delay", "0.6"]
        app.launch()
        return app
    }
    private func circle(in app: XCUIApplication, canvas: XCUIElement) {
        app.buttons["tool-question"].tap()
        let area = app.descendants(matching: .any)["question-capture-area"]
        XCTAssertTrue(area.waitForExistence(timeout: 3))
        area.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.12)).press(forDuration: 0.05,
            thenDragTo: area.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.35)))
        XCTAssertTrue(app.buttons["question-confirm"].waitForExistence(timeout: 5))
        let selection = app.descendants(matching: .any)["question-selection-box"]
        let action = app.buttons["question-confirm"]
        XCTAssertLessThan(action.frame.maxY, selection.frame.minY)
        XCTAssertEqual(action.frame.midX, selection.frame.midX, accuracy: 3)
    }
    private func field(_ prefix: String, of element: XCUIElement) -> String? {
        (element.value as? String)?.components(separatedBy: "；").first { $0.hasPrefix(prefix) }
    }
    private func waitValue(_ text: String, element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", text), object: element)], timeout: 6) == .completed
    }
}
