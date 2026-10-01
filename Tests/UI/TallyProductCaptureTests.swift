#if os(iOS)
import XCTest

/// Opt-in capture of the established fictional Jordan scenario in the real app.
/// The driver supplies an owned working-copy URL and configures the status bar.
@MainActor
final class TallyProductCaptureTests: XCTestCase {
    func testCaptureJordanRentReminder() throws {
        continueAfterFailure = false
        guard let raw = ProcessInfo.processInfo.environment["TALLY_PRODUCT_CAPTURE_URL"],
              var url = URL(string: raw), url.isFileURL,
              url.deletingLastPathComponent().lastPathComponent.hasPrefix("TallyProductCapture-") else {
            throw XCTSkip("Product capture requires an explicitly supplied fictional working copy.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-launchBehavior", "fileBrowser"]
        app.launch()
        // Installing a fresh app moves its simulator data container. Locate
        // only the explicitly owned working folder; never inspect other files.
        let captureFolder = url.deletingLastPathComponent().lastPathComponent
        let applications = url.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let candidates = try FileManager.default.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil)
            .map { $0.appendingPathComponent("Documents").appendingPathComponent(captureFolder).appendingPathComponent("My Money.tally") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        XCTAssertEqual(candidates.count, 1, "The owned scenario working copy must be unique.")
        url = try XCTUnwrap(candidates.first)
        app.open(url)
        let row = app.buttons["expenseRow-CE05C4E0-C8C6-5713-A5AD-61E73730972C"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        for _ in 0..<5 where !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.buttons["cancelExpenseButton"].waitForExistence(timeout: 5))
        let form = app.collectionViews["Expense details"]
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        let toggle = app.switches["entryReminderToggle"]
        for _ in 0..<5 where !toggle.isHittable { form.swipeUp() }
        XCTAssertTrue(toggle.isHittable)
        let actualToggle = toggle.switches.firstMatch.exists ? toggle.switches.firstMatch : toggle
        if (toggle.value as? String) != "1" { actualToggle.tap() }
        let lead = app.buttons["reminderLeadTimePicker"]
        for _ in 0..<4 where !lead.isHittable { form.swipeUp() }
        lead.tap()
        app.buttons["1 day before"].tap()
        let sound = app.buttons["reminderSoundPicker"]
        for _ in 0..<4 where !sound.isHittable { form.swipeUp() }
        XCTAssertTrue(sound.isHittable)
        sound.tap()
        for title in ["Ripple", "Pebble", "Glow", "Lift", "Signal", "None"] {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 3))
        }
        XCTAssertFalse(app.buttons["System default"].exists)
        XCTAssertFalse(app.buttons["Tri-tone"].exists)
        attach("Verified current sound palette")
        app.buttons["Ripple"].tap()
        XCTAssertEqual(sound.value as? String, "Ripple")
        form.swipeUp()
        Thread.sleep(forTimeInterval: 2)
        attach("Tally-iPhone-03")
        app.buttons["cancelExpenseButton"].tap()
        XCTAssertTrue(app.buttons["cancelExpenseButton"].waitForNonExistence(timeout: 5))
        app.terminate()
    }

    private func attach(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        if name == "Tally-iPhone-03" {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("TallyProductCapture-\(UUID().uuidString).png")
            do {
                try screenshot.pngRepresentation.write(to: url, options: .atomic)
                print("TALLY_PRODUCT_CAPTURE_PATH: \(url.path)")
            } catch { XCTFail("Could not export the native product screenshot: \(error)") }
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
