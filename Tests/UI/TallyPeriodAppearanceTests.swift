import XCTest

#if os(iOS)
import Vision

@MainActor
final class TallyPeriodAppearanceTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPeriodResetRemainsLegibleAndAlignedAtStandardTextSize() throws {
        try exerciseResetControls(accessibilityText: false)
    }

    func testPeriodResetRemainsLegibleAndAlignedAtLargestTextSize() throws {
        try exerciseResetControls(accessibilityText: true)
    }

    func testRepeatedPeriodNavigationPreservesControlPositions() {
        let app = launchPopulatedApp(accessibilityText: false)
        let picker = app.descendants(matching: .any)
            .matching(identifier: "periodKindPicker").firstMatch
        let title = app.staticTexts["selectedPeriodTitle"]
        let reset = app.buttons["currentPeriodButton"]
        let previous = app.buttons["previousPeriodButton"]
        let next = app.buttons["nextPeriodButton"]
        let filter = app.descendants(matching: .any)
            .matching(identifier: "expenseFilterPicker").firstMatch
        let sort = app.buttons["expenseSortMenu"]
        let controls = [picker, previous, next, filter, sort]

        for segment in ["Month", "Year"] {
            picker.buttons[segment].tap()
            let originalTitle = title.label
            let baseline = controls.map(\.frame)
            var resetFrame: CGRect?
            XCTAssertFalse(reset.exists)

            for direction in [next, previous, next] {
                direction.tap()
                XCTAssertTrue(reset.waitForExistence(timeout: 3))
                XCTAssertNotEqual(title.label, originalTitle)
                XCTAssertTrue(reset.isHittable)
                XCTAssertGreaterThanOrEqual(reset.frame.height, 44)
                XCTAssertGreaterThanOrEqual(reset.frame.width, 44)
                if let resetFrame {
                    assertFrame(reset.frame, matches: resetFrame)
                } else {
                    resetFrame = reset.frame
                }
                for (control, frame) in zip(controls, baseline) {
                    assertFrame(control.frame, matches: frame)
                    XCTAssertFalse(reset.frame.insetBy(dx: 1, dy: 1)
                        .intersects(control.frame.insetBy(dx: 1, dy: 1)))
                }

                reset.tap()
                XCTAssertTrue(reset.waitForNonExistence(timeout: 3))
                XCTAssertEqual(title.label, originalTitle)
                for (control, frame) in zip(controls, baseline) {
                    assertFrame(control.frame, matches: frame)
                }
            }
        }
    }

    private func launchPopulatedApp(accessibilityText: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--ui-testing-populated",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ] + (accessibilityText ? ["--ui-testing-accessibility-text"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["nextPeriodButton"].waitForExistence(timeout: 10))
        return app
    }

    private func exerciseResetControls(accessibilityText: Bool) throws {
        let app = launchPopulatedApp(accessibilityText: accessibilityText)
        let picker = app.descendants(matching: .any)
            .matching(identifier: "periodKindPicker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let title = app.staticTexts["selectedPeriodTitle"]
        let reset = app.buttons["currentPeriodButton"]
        let previous = app.buttons["previousPeriodButton"]
        let next = app.buttons["nextPeriodButton"]

        for (segment, label) in [("Month", "This month"), ("Year", "This year")] {
            picker.buttons[segment].tap()
            let originalTitle = title.label
            let originalPickerFrame = picker.frame
            let originalNextFrame = next.frame
            XCTAssertFalse(reset.exists)

            next.tap()
            XCTAssertTrue(reset.waitForExistence(timeout: 3))
            XCTAssertEqual(reset.label, label)
            XCTAssertTrue(reset.isHittable)
            XCTAssertGreaterThanOrEqual(reset.frame.width, 44)
            XCTAssertGreaterThanOrEqual(reset.frame.height, 44)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(reset.frame))

            try assertRenderedLabel(label, in: reset)
            for control in [picker, previous, next, title] {
                XCTAssertFalse(reset.frame.insetBy(dx: 1, dy: 1)
                    .intersects(control.frame.insetBy(dx: 1, dy: 1)))
            }
            if accessibilityText {
                XCTAssertGreaterThanOrEqual(reset.frame.minY, picker.frame.maxY,
                                            "Large text needs a separate reset row.")
            } else {
                XCTAssertEqual(reset.frame.midY, picker.frame.midY, accuracy: 1,
                               "Reset and period selection should share a visual centerline.")
            }

            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "\(segment) reset at \(accessibilityText ? "accessibility5" : "standard") text"
            screenshot.lifetime = .keepAlways
            add(screenshot)

            reset.tap()
            XCTAssertTrue(reset.waitForNonExistence(timeout: 3))
            XCTAssertEqual(title.label, originalTitle)
            XCTAssertEqual(picker.frame, originalPickerFrame)
            XCTAssertEqual(next.frame, originalNextFrame)
        }
    }

    private func assertFrame(_ frame: CGRect, matches expected: CGRect,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(frame.minX, expected.minX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(frame.minY, expected.minY, accuracy: 1, file: file, line: line)
        XCTAssertEqual(frame.width, expected.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(frame.height, expected.height, accuracy: 1, file: file, line: line)
    }

    private func assertRenderedLabel(_ label: String, in button: XCUIElement) throws {
        let image = try XCTUnwrap(button.screenshot().image.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let renderedText = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        XCTAssertTrue(renderedText.contains(label),
                      "The rendered reset label must be complete at every text size; found \(renderedText).")
    }
}
#endif
