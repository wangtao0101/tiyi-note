import XCTest
import ObjectiveC
import UIKit

final class TiyiNoteTextInteractionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    func testTabsAndTextEditorUseOneStableInteractionState() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--text-interaction-ui-test",
            "text-state-\(UUID().uuidString)"
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
        RunLoop.current.run(until: Date().addingTimeInterval(2))
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

    func testPinchZoomAndResetChangeTheActualWorkspaceScale() throws {
#if targetEnvironment(macCatalyst)
        throw XCTSkip("XCUIElement pinch synthesis is unavailable on Mac Catalyst")
#else
        let app = launchIsolatedApp(prefix: "pinch-zoom")
        let canvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        let reset = app.buttons["zoom-reset"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        XCTAssertTrue(reset.waitForExistence(timeout: 3))
        XCTAssertTrue(reset.label.contains("100%"))

        let initialFrame = canvas.frame
        canvas.pinch(withScale: 1.55, velocity: 1.0)
        waitUntil(timeout: 3) {
            !reset.label.contains("100%")
        }
        XCTAssertGreaterThan(canvas.frame.width, initialFrame.width * 1.15)

        reset.tap()
        waitUntil(timeout: 3) {
            reset.label.contains("100%")
                && abs(canvas.frame.width - initialFrame.width) <= 2
        }
        XCTAssertEqual(canvas.frame.width, initialFrame.width, accuracy: 2)
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

        let clear = app.buttons["清空当前页批注"]
        clear.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["取消"].tap()
        XCTAssertTrue((canvas.value as? String)?.hasPrefix("笔迹 1") == true)

        clear.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["清空"].tap()
        waitForValue("笔迹 0", of: canvas)

        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        waitForValue("笔迹 1", of: canvas)
    }

    func testInkColorWidthAndEraserControlsTrackTheSelectedTool() throws {
        let app = launchIsolatedApp(prefix: "tool-settings")

        let ocean = app.buttons["ink-color-ocean"]
        let graphite = app.buttons["ink-color-graphite"]
        let settingsScroll = app.scrollViews["tool-settings-scroll"]
        XCTAssertTrue(settingsScroll.waitForExistence(timeout: 5))
        XCTAssertTrue(ocean.waitForExistence(timeout: 5))
        reveal(ocean, in: settingsScroll, bySwiping: .left)
        ocean.tap()
        XCTAssertEqual(ocean.value as? String, "selected")
        XCTAssertEqual(graphite.value as? String, "not-selected")

        let widthSlider = app.descendants(matching: .any)
            .matching(identifier: "ink-width-slider")
            .firstMatch
        XCTAssertTrue(widthSlider.exists)
        reveal(widthSlider, in: settingsScroll, bySwiping: .left)
        let originalWidthValue = widthSlider.value as? String
        widthSlider.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5))
            .press(
                forDuration: 0.1,
                thenDragTo: widthSlider.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.82, dy: 0.5)
                )
            )
        XCTAssertNotEqual(widthSlider.value as? String, originalWidthValue)

        app.buttons["tool-eraser"].tap()
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "ink-width-slider")
            .firstMatch.exists)
        let eraserMode = app.segmentedControls["eraser-mode-picker"]
        XCTAssertTrue(eraserMode.waitForExistence(timeout: 3))
        reveal(eraserMode, in: settingsScroll, bySwiping: .right)
        eraserMode.buttons["整笔"].tap()
        XCTAssertTrue(eraserMode.buttons["整笔"].isSelected)

        app.buttons["tool-marker"].tap()
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "ink-width-slider")
            .firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.segmentedControls["eraser-mode-picker"].exists)
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

        let eraserMode = app.segmentedControls["eraser-mode-picker"]
        XCTAssertTrue(eraserMode.waitForExistence(timeout: 3))
        eraserMode.buttons["整笔"].tap()
        XCTAssertTrue(eraserMode.buttons["整笔"].isSelected)

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
        let eraserMode = app.segmentedControls["eraser-mode-picker"]
        XCTAssertTrue(eraserMode.waitForExistence(timeout: 3))
        eraserMode.buttons["整笔"].tap()

        let eraseStart = canvas.coordinate(
            withNormalizedOffset: CGVector(dx: 0.45, dy: 0.25)
        )
        let eraseEnd = canvas.coordinate(
            withNormalizedOffset: CGVector(dx: 0.45, dy: 0.56)
        )
        eraseStart.press(forDuration: 0.08, thenDragTo: eraseEnd)
        waitForValue("笔迹 0", of: canvas)

        // The regression happened only after the 650 ms materialized-asset save reloaded the
        // collaboration log. Waiting well beyond it proves this is not merely a visual erase.
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        XCTAssertTrue(
            (canvas.value as? String)?.hasPrefix("笔迹 0") == true,
            "整笔擦除在自动保存刷新后恢复了旧笔迹"
        )

        openPageSidebar(in: app)
        addPage(named: "空白页", in: app)
        let firstPage = app.buttons["page-thumbnail-0"]
        XCTAssertTrue(firstPage.waitForExistence(timeout: 4))
        firstPage.tap()
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

    func testHoldingRoughShapesSnapsBeforeLiftAndSupportsUndoPersistence() throws {
        let app = launchIsolatedApp(prefix: "shape-hold-snap")
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
            thenHoldForDuration: 0.92
        )
        waitForValueContaining("吸附 直线", of: canvas, timeout: 5)
        waitForValue("笔迹 1", of: canvas, timeout: 5)

        let rectangleFrame = CGRect(
            x: canvas.frame.minX + canvas.frame.width * 0.30,
            y: canvas.frame.minY + canvas.frame.height * 0.48,
            width: canvas.frame.width * 0.34,
            height: canvas.frame.height * 0.22
        )
        try synthesizeClosedTouchPath(
            around: rectangleFrame,
            on: canvas,
            in: app,
            holdBeforeLift: 0.92
        )
        waitForValueContaining("吸附 矩形", of: canvas, timeout: 5)
        waitForValue("笔迹 2", of: canvas, timeout: 5)

        let ellipseFrame = CGRect(
            x: canvas.frame.minX + canvas.frame.width * 0.12,
            y: canvas.frame.minY + canvas.frame.height * 0.70,
            width: canvas.frame.width * 0.24,
            height: canvas.frame.height * 0.16
        )
        let ellipsePoints = (0...24).map { index in
            let theta = CGFloat(index) / 24 * 2 * .pi
            return CGPoint(
                x: ellipseFrame.midX + cos(theta) * ellipseFrame.width / 2,
                y: ellipseFrame.midY + sin(theta) * ellipseFrame.height / 2
            )
        }
        try synthesizeTouchPath(
            ellipsePoints,
            on: canvas,
            in: app,
            holdBeforeLift: 0.92
        )
        waitForValueContaining("吸附 圆形", of: canvas, timeout: 5)
        waitForValue("笔迹 3", of: canvas, timeout: 5)

        let triangleFrame = CGRect(
            x: canvas.frame.minX + canvas.frame.width * 0.62,
            y: canvas.frame.minY + canvas.frame.height * 0.70,
            width: canvas.frame.width * 0.24,
            height: canvas.frame.height * 0.17
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
            holdBeforeLift: 0.92
        )
        waitForValueContaining("吸附 三角形", of: canvas, timeout: 5)
        waitForValue("笔迹 4", of: canvas, timeout: 5)

        let undo = app.buttons["撤销"]
        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        waitForValue("笔迹 3", of: canvas)
        let redo = app.buttons["重做"]
        XCTAssertTrue(redo.isEnabled)
        redo.tap()
        waitForValue("笔迹 4", of: canvas)

        RunLoop.current.run(until: Date().addingTimeInterval(2))
        app.launchArguments.append("--reuse-text-interaction-ui-test-workspace")
        app.terminate()
        app.launch()
        let relaunchedCanvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        XCTAssertTrue(relaunchedCanvas.waitForExistence(timeout: 8))
        waitForValue("笔迹 4", of: relaunchedCanvas, timeout: 5)
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

    func testCopyAndScreenshotPasteCreateRealImageObjects() throws {
        let app = launchIsolatedApp(prefix: "object-paste")
        let settingsScroll = app.scrollViews["tool-settings-scroll"]
        XCTAssertTrue(settingsScroll.waitForExistence(timeout: 5))
        insertShape(named: "矩形", in: app, settingsScroll: settingsScroll)

        let canvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-0")
            .firstMatch
        let images = app.descendants(matching: .any)
            .matching(identifier: "page-element-image")
        XCTAssertTrue(canvas.waitForExistence(timeout: 3))
        XCTAssertEqual(images.count, 0)

        app.buttons["拷贝"].tap()
        showPasteMenu(on: canvas, at: CGVector(dx: 0.20, dy: 0.72), in: app)
        app.buttons["粘贴最近拷贝的内容"].tap()
        waitUntil(timeout: 4) { images.count == 1 }
        XCTAssertTrue(app.buttons["截图"].waitForExistence(timeout: 3))

        app.buttons["截图"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.18)).tap()
        showPasteMenu(on: canvas, at: CGVector(dx: 0.78, dy: 0.72), in: app)
        app.buttons["粘贴最近拷贝的内容"].tap()
        waitUntil(timeout: 4) { images.count == 2 }

        XCTAssertEqual(app.buttons["tool-lasso"].value as? String, "selected")
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

        app.buttons["tool-eraser"].tap()
        let eraserMode = app.segmentedControls["eraser-mode-picker"]
        XCTAssertTrue(eraserMode.waitForExistence(timeout: 3))
        XCTAssertTrue(eraserMode.buttons["精细"].isSelected)

        let eraseStart = canvas.coordinate(
            withNormalizedOffset: CGVector(dx: 0.50, dy: 0.34)
        )
        let eraseEnd = canvas.coordinate(
            withNormalizedOffset: CGVector(dx: 0.50, dy: 0.50)
        )
        eraseStart.press(forDuration: 0.08, thenDragTo: eraseEnd)
        waitUntil(timeout: 3) {
            canvas.screenshot().pngRepresentation != drawingBeforeErase
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
            canvas.screenshot().pngRepresentation == drawingBeforeErase
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
        editor.tap()
        editor.typeText(" persistent")
        app.buttons["text-edit-done"].tap()

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
        XCTAssertTrue(app.staticTexts["2 / 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["page-canvas-1"].exists)
    }

    func testDocumentOutputMenusPresentSharePrintAndConflictInterfaces() throws {
        let app = launchIsolatedApp(prefix: "document-output-ui")
        let settingsScroll = app.scrollViews["tool-settings-scroll"]
        XCTAssertTrue(settingsScroll.waitForExistence(timeout: 5))
        app.buttons["tool-lasso"].tap()
        let output = app.buttons["导出、分享和打印"]
        XCTAssertTrue(output.waitForExistence(timeout: 3))
        reveal(output, in: settingsScroll, bySwiping: .left)

        for action in ["分享扁平 PDF", "导出页面图片", "导出可编辑文稿"] {
            output.tap()
            XCTAssertTrue(app.buttons[action].waitForExistence(timeout: 3))
            app.buttons[action].tap()
            let activityList = app.otherElements["ActivityListView"]
            XCTAssertTrue(
                activityList.waitForExistence(timeout: 8),
                "\(action) did not present the system share interface"
            )
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.72)).tap()
            XCTAssertTrue(activityList.waitForNonExistence(timeout: 4))
        }

        output.tap()
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

        output.tap()
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
        XCTAssertTrue(app.staticTexts["文稿"].firstMatch.waitForExistence(timeout: 4))
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
        XCTAssertTrue(app.staticTexts["2 / 2"].waitForExistence(timeout: 5))

        let canvas = app.descendants(matching: .any)
            .matching(identifier: "page-canvas-1")
            .firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 3))
        let drawingValue = canvas.value as? String
        drawStroke(on: canvas)
        XCTAssertEqual(canvas.value as? String, drawingValue)
        XCTAssertFalse(app.buttons["tool-lasso"].exists)
        XCTAssertFalse(app.buttons["tool-text"].exists)

        app.buttons["导出、分享和打印"].tap()
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

        firstTab.tap()
        XCTAssertEqual(firstTab.value as? String, "active")
        secondTab.tap()
        XCTAssertEqual(secondTab.value as? String, "active")

        let closeSecond = app.buttons["关闭 UITest Two"]
        XCTAssertTrue(closeSecond.waitForExistence(timeout: 3))
        closeSecond.tap()
        XCTAssertTrue(secondTab.waitForNonExistence(timeout: 3))
        XCTAssertTrue(firstTab.exists)

        let home = app.buttons["home-button"]
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        home.tap()
        XCTAssertTrue(
            app.staticTexts["文稿"].firstMatch.waitForExistence(timeout: 3)
        )
    }

    func testLibraryCreatesNestedFoldersCanvasAndReturnsFromDocument() throws {
        let app = launchIsolatedApp(prefix: "library-create-nested")
        XCTAssertTrue(app.staticTexts["文稿"].firstMatch.waitForExistence(timeout: 8))

        createFolder(named: "项目 A", in: app)
        let project = app.staticTexts["项目 A"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 4))
        project.tap()
        XCTAssertTrue(app.staticTexts["项目 A"].firstMatch.waitForExistence(timeout: 3))

        createFolder(named: "子文件夹", in: app)
        let child = app.staticTexts["子文件夹"].firstMatch
        XCTAssertTrue(child.waitForExistence(timeout: 4))
        child.tap()
        XCTAssertTrue(app.staticTexts["子文件夹"].firstMatch.waitForExistence(timeout: 3))

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
        XCTAssertTrue(app.staticTexts["文稿"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["项目 A"].firstMatch.exists)
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
        tapHittableButton("收藏夹", in: app)
        XCTAssertTrue(app.staticTexts["重命名画板"].firstMatch.waitForExistence(timeout: 4))
        tapHittableButton("文稿", in: app)

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

        tapHittableButton("搜索文稿", in: app)
        let search = app.searchFields["搜索文稿和文件夹"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.typeText("重命名")
        XCTAssertTrue(app.staticTexts["重命名画板"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["UITest Two"].exists)
        tapHittableButton("搜索文稿", in: app)

        openContextMenu(for: app.staticTexts["重命名画板"].firstMatch, in: app)
        tapHittableButton("移到回收站", in: app)
        tapHittableButton("移到回收站", in: app)
        XCTAssertTrue(app.staticTexts["重命名画板"].firstMatch.waitForNonExistence(timeout: 4))

        tapHittableButton("回收站", in: app)
        let trashed = app.staticTexts["重命名画板"].firstMatch
        XCTAssertTrue(trashed.waitForExistence(timeout: 4))
        openContextMenu(for: trashed, in: app)
        tapHittableButton("恢复", in: app)
        XCTAssertTrue(trashed.waitForNonExistence(timeout: 4))

        tapHittableButton("文稿", in: app)
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

        tapHittableButton("全部", in: app)
        tapHittableButton("PDF", in: app)
        XCTAssertTrue(app.staticTexts["UITest PDF.pdf"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["UITest One"].exists)
        XCTAssertFalse(app.staticTexts["UITest Two"].exists)

        tapHittableButton("PDF", in: app)
        tapHittableButton("画板", in: app)
        XCTAssertTrue(app.staticTexts["UITest One"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["UITest Two"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["UITest PDF.pdf"].exists)

        tapHittableButton("画板", in: app)
        tapHittableButton("全部", in: app)

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

        tapHittableButton("回收站", in: app)
        XCTAssertTrue(app.staticTexts["UITest One"].firstMatch.waitForExistence(timeout: 4))
        app.staticTexts["UITest One"].firstMatch.tap()
        app.staticTexts["UITest Two"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已选 2 项"].waitForExistence(timeout: 3))
        tapHittableButton("恢复", in: app)
        XCTAssertTrue(app.staticTexts["UITest One"].firstMatch.waitForNonExistence(timeout: 4))

        tapHittableButton("文稿", in: app)
        app.staticTexts["批量归档"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["UITest One"].firstMatch.waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["UITest Two"].firstMatch.exists)

        tapHittableButton("选择项目", in: app)
        app.staticTexts["UITest One"].firstMatch.tap()
        app.staticTexts["UITest Two"].firstMatch.tap()
        tapHittableButton("删除", in: app)
        tapHittableButton("移到回收站", in: app)
        tapHittableButton("回收站", in: app)
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
        XCTAssertTrue(app.staticTexts["文稿"].firstMatch.waitForExistence(timeout: 8))
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

        tapHittableButton("文稿", in: app)
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
        tapHittableButton("回收站", in: app)
        XCTAssertTrue(app.staticTexts["父文件夹"].firstMatch.waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["子文件夹"].exists)
        XCTAssertFalse(app.staticTexts["树内画板"].exists)

        openContextMenu(for: app.staticTexts["父文件夹"].firstMatch, in: app)
        tapHittableButton("恢复", in: app)
        tapHittableButton("文稿", in: app)
        app.staticTexts["父文件夹"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["子文件夹"].firstMatch.waitForExistence(timeout: 4))
        app.staticTexts["子文件夹"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["树内画板"].firstMatch.waitForExistence(timeout: 4))

        tapHittableButton("文稿", in: app)
        openContextMenu(for: app.staticTexts["父文件夹"].firstMatch, in: app)
        tapHittableButton("移到回收站", in: app)
        tapHittableButton("移到回收站", in: app)
        tapHittableButton("回收站", in: app)
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

        tapHittableButton("回收站", in: app)
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

    private func launchIsolatedApp(prefix: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--text-interaction-ui-test",
            "\(prefix)-\(UUID().uuidString)"
        ]
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

    private func showPasteMenu(
        on canvas: XCUIElement,
        at offset: CGVector,
        in app: XCUIApplication
    ) {
        canvas.coordinate(withNormalizedOffset: offset).press(forDuration: 0.72)
        XCTAssertTrue(
            app.buttons["粘贴最近拷贝的内容"].waitForExistence(timeout: 3),
            "Long press did not present the page paste menu"
        )
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
        if let currentValue = element.value as? String, !currentValue.isEmpty {
            element.typeText(
                String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count)
            )
        }
        if (element.value as? String)?.isEmpty == false {
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
        return String(value[range.lowerBound...])
    }

    private func waitUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.12,
        condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        XCTAssertTrue(condition())
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
        holdBeforeLift: TimeInterval
    ) throws {
        guard points.count >= 2 else {
            XCTFail("A synthesized touch path needs at least two points")
            return
        }

        guard let pathClass = NSClassFromString("XCPointerEventPath"),
              let eventClass = NSClassFromString("XCSynthesizedEventRecord"),
              let rawAllocatedPath = class_createInstance(pathClass, 0),
              let rawAllocatedEvent = class_createInstance(eventClass, 0) else {
            throw XCTSkip("XCTest pointer event synthesis is unavailable")
        }
        let allocatedPath = rawAllocatedPath as AnyObject
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

        let path = unsafeBitCast(
            allocatedPath.method(for: initPathSelector),
            to: InitTouch.self
        )(allocatedPath, initPathSelector, points[0], 0)
        for (index, point) in points.dropFirst().enumerated() {
            unsafeBitCast(path.method(for: moveSelector), to: MoveTouch.self)(
                path,
                moveSelector,
                point,
                0.10 + Double(index) * 0.06
            )
        }
        let finalMoveOffset = 0.10 + Double(max(points.count - 2, 0)) * 0.06
        unsafeBitCast(path.method(for: liftSelector), to: TouchOffset.self)(
            path,
            liftSelector,
            finalMoveOffset + holdBeforeLift
        )

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
            "Closed lasso",
            displayID,
            interfaceOrientation
        )
        if event.responds(to: setOriginalOffsetSelector) {
            let targetFrame = targetElement.frame
            let originalOffset = CGVector(
                dx: points[0].x - targetFrame.minX,
                dy: points[0].y - targetFrame.minY
            )
            unsafeBitCast(
                event.method(for: setOriginalOffsetSelector),
                to: SetOriginalOffset.self
            )(event, setOriginalOffsetSelector, originalOffset)
        }
        unsafeBitCast(event.method(for: addPathSelector), to: AddPath.self)(
            event,
            addPathSelector,
            path
        )

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
            "Could not synthesize closed lasso: \(String(describing: synthesisError))"
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
