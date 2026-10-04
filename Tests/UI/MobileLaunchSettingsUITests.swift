#if os(iOS)
import XCTest

@MainActor
final class MobileLaunchSettingsUITests: XCTestCase {
    private var activeApp: XCUIApplication?
    private var activeSession: UUID?
    override func setUpWithError() throws { continueAfterFailure = false }

    override func tearDown() async throws {
        if let app = activeApp, let session = activeSession { cleanUp(app, session: session) }
        activeApp = nil
        activeSession = nil
    }

    func testRestoredFileKeepsTheBrowserCoveredThroughOpeningAndPresentation() throws {
        let session = UUID()
        let app = XCUIApplication()
        activeApp = app
        activeSession = session
        app.launchArguments = ["--ui-testing", "--ui-testing-mobile-launch-settings"]
        app.launchEnvironment["TALLY_MOBILE_LAUNCH_TEST_SESSION"] = session.uuidString
        app.launchEnvironment["TALLY_MOBILE_LAUNCH_TEST_ACTION"] = "seedA"
        app.launchEnvironment["TALLY_MOBILE_LAUNCH_TEST_RESTORE_DELAY_MS"] = "8000"
        app.launchEnvironment["TALLY_MOBILE_LAUNCH_TEST_PRESENT_DELAY_MS"] = "8000"
        // Do not wait for browser/editor options: observe the native first
        // screen while resolution and the opened document are still pending.
        app.launch()
        assertCoveredLaunchPhase("resolving", in: app)
        attachScreenshot(app, named: "Launch cover while resolving the fictional last file")
        assertCoveredLaunchPhase("presenting", in: app)
        attachScreenshot(app, named: "Launch cover after opening the fictional last file")
        assertDocument("A", in: app)
        XCTAssertFalse(launchCover(in: app).exists)

        // The launch cover must never reappear when returning to Files or
        // choosing another file during the same session.
        app.buttons["BackButton"].firstMatch.tap()
        assertBrowser(in: app)
        openFixture("B", in: app)
        assertDocument("B", in: app)
    }

    func testUnreadableLastFileFallsBackToUsableBrowserWithoutAnError() throws {
        let session = UUID()
        let app = launch(session, action: "seedCorruptA")
        assertBrowser(in: app)
        XCTAssertFalse(app.alerts.element.exists)
        openFixture("B", in: app)
        assertDocument("B", in: app)
    }

    func testSettingsFromBrowserAndEditorPersistAndLastFileReopens() throws {
        let session = UUID()
        let app = launch(session, action: "reset")

        assertBrowser(in: app)
        openSettings(in: app)
        assertChoice("Open last used file", in: app)
        choose("Show file browser", in: app)
        finishSettings(in: app)

        app.terminate()
        relaunch(app, session: session)
        assertBrowser(in: app)
        openSettings(in: app)
        assertChoice("Show file browser", in: app)
        choose("Open last used file", in: app)
        finishSettings(in: app)

        openFixture("A", in: app)
        assertDocument("A", in: app)
        openSettings(in: app)
        assertChoice("Open last used file", in: app)
        attachScreenshot(app, named: "Settings from an open fictional file")
        finishSettings(in: app)
        assertDocument("A", in: app)

        openOptions(in: app)
        app.buttons["Privacy & Support"].tap()
        XCTAssertTrue(app.buttons["privacyPolicyDone"].waitForExistence(timeout: 5))
        app.buttons["privacyPolicyDone"].tap()
        assertDocument("A", in: app)

        app.terminate()
        relaunch(app, session: session)
        assertDocument("A", in: app)
        openSettings(in: app)
        choose("Show file browser", in: app)
        finishSettings(in: app)
        app.terminate()
        relaunch(app, session: session)
        assertBrowser(in: app)
        attachScreenshot(app, named: "File browser after changing launch preference")
    }

    func testMissingLastFileFallsBackToBrowserWithoutAnError() throws {
        let session = UUID()
        let app = launch(session, action: "seedA")
        assertDocument("A", in: app)
        app.terminate()
        relaunch(app, session: session, action: "deleteA")
        assertBrowser(in: app)
        XCTAssertFalse(app.alerts.element.exists)
        openSettings(in: app)
        assertChoice("Open last used file", in: app)
        finishSettings(in: app)
        openFixture("B", in: app)
        assertDocument("B", in: app)
        app.terminate()
        relaunch(app, session: session)
        assertDocument("B", in: app)
    }

    func testExplicitFileOpenTakesPriorityOverLastUsedFile() throws {
        let session = UUID()
        let app = launch(session, action: "seedA")
        assertDocument("A", in: app)
        app.terminate()
        relaunch(app, session: session, action: "explicitB")
        assertDocument("B", in: app)
        XCTAssertFalse(app.alerts.element.exists)
        openSettings(in: app)
        assertChoice("Open last used file", in: app)
        finishSettings(in: app)
        assertDocument("B", in: app)
        app.terminate()
        relaunch(app, session: session)
        assertDocument("B", in: app)
    }

    func testSettingsRemainUsableWithAccessibilityText() throws {
        let session = UUID()
        let app = XCUIApplication()
        activeApp = app
        activeSession = session
        // Run in both simulator system appearances; UIKit does not use the
        // macOS AppleInterfaceStyle defaults argument for its color scheme.
        app.launchArguments = ["--ui-testing", "--ui-testing-mobile-launch-settings",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchEnvironment["TALLY_MOBILE_LAUNCH_TEST_SESSION"] = session.uuidString
        app.launchEnvironment["TALLY_MOBILE_LAUNCH_TEST_ACTION"] = "reset"
        app.launch()
        waitForOptions(in: app)
        openSettings(in: app)
        assertChoice("Open last used file", in: app)
        attachScreenshot(app, named: "Settings with accessibility text and default choice")
        choose("Show file browser", in: app)
        let picker = app.buttons["launchBehaviorPicker"]
        XCTAssertTrue(picker.isHittable)
        XCTAssertGreaterThanOrEqual(picker.frame.height, 44)
        attachScreenshot(app, named: "Settings with accessibility text and browser choice")
        finishSettings(in: app)
        assertBrowser(in: app)
    }

    func testPrivacyAndSupportRemainsAvailableFromTheFileBrowser() throws {
        let session = UUID()
        let app = XCUIApplication()
        activeApp = app
        activeSession = session
        app.launchEnvironment["TALLY_MOBILE_LAUNCH_TEST_HIDE_FIXTURE_ACTIONS"] = "1"
        relaunch(app, session: session, action: "reset")
        assertBrowser(in: app)
        attachScreenshot(app, named: "File browser with Tally options")
        openOptions(in: app)
        attachScreenshot(app, named: "Native browser options presentation")
        app.buttons["Privacy & Support"].tap()
        XCTAssertTrue(app.buttons["privacyPolicyDone"].waitForExistence(timeout: 5))
        app.buttons["privacyPolicyDone"].tap()
        XCTAssertTrue(app.buttons["privacyPolicyDone"].waitForNonExistence(timeout: 5))
        assertBrowser(in: app)
    }

    func testIconOptionsOpenSettingsFromBrowserAndEditor() throws {
        let session = UUID()
        let app = launch(session, action: "reset")
        assertBrowser(in: app)
        openSettings(in: app)
        assertChoice("Open last used file", in: app)
        attachScreenshot(app, named: "Settings from the file browser")
        choose("Show file browser", in: app)
        finishSettings(in: app)
        openFixture("A", in: app)
        assertDocument("A", in: app)
        openSettings(in: app)
        assertChoice("Show file browser", in: app)
        attachScreenshot(app, named: "Settings from the open file")
        finishSettings(in: app)
        assertDocument("A", in: app)
    }

    private func launch(_ session: UUID, action: String) -> XCUIApplication {
        let app = XCUIApplication()
        activeApp = app
        activeSession = session
        relaunch(app, session: session, action: action)
        return app
    }

    private func relaunch(_ app: XCUIApplication, session: UUID, action: String = "") {
        app.launchArguments = ["--ui-testing", "--ui-testing-mobile-launch-settings"]
        app.launchEnvironment["TALLY_MOBILE_LAUNCH_TEST_SESSION"] = session.uuidString
        app.launchEnvironment["TALLY_MOBILE_LAUNCH_TEST_ACTION"] = action
        app.launch()
        waitForOptions(in: app)
    }

    private func cleanUp(_ app: XCUIApplication, session: UUID) {
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "TALLY_MOBILE_LAUNCH_TEST_RESTORE_DELAY_MS")
        app.launchEnvironment.removeValue(forKey: "TALLY_MOBILE_LAUNCH_TEST_PRESENT_DELAY_MS")
        app.launchEnvironment["TALLY_MOBILE_LAUNCH_TEST_SESSION"] = session.uuidString
        app.launchEnvironment["TALLY_MOBILE_LAUNCH_TEST_ACTION"] = "cleanup"
        app.launch()
        app.terminate()
    }

    private func assertBrowser(in app: XCUIApplication) {
        waitForOptions(in: app)
        XCTAssertFalse(app.buttons["addExpenseButton"].exists)
        XCTAssertFalse(launchCover(in: app).exists)
    }

    private func launchCover(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "tallyLaunchCover").firstMatch
    }

    private func assertCoveredLaunchPhase(_ phase: String, in app: XCUIApplication) {
        let cover = launchCover(in: app)
        let predicate = NSPredicate { _, _ in cover.exists && (cover.value as? String) == phase }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: app)], timeout: 15), .completed)
        XCTAssertTrue(cover.isHittable)
        XCTAssertGreaterThanOrEqual(cover.frame.width, app.frame.width * 0.95)
        XCTAssertGreaterThanOrEqual(cover.frame.height, app.frame.height * 0.95)
        let namedOptions = app.buttons["Tally options"]
        XCTAssertFalse(namedOptions.exists && namedOptions.isHittable)
        let newFile = app.buttons["New Tally File"]
        XCTAssertFalse(newFile.exists && newFile.isHittable)
        let systemOptions = app.buttons.matching(NSPredicate(format: "label == %@", "More")).firstMatch
        XCTAssertFalse(systemOptions.exists && systemOptions.isHittable, "The native browser must remain covered until the restored editor can be shown.")
    }

    private func openFixture(_ suffix: String, in app: XCUIApplication) {
        openOptions(in: app)
        let fixture = app.buttons["Open fixture \(suffix)"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 5))
        fixture.tap()
    }

    private func assertDocument(_ suffix: String, in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["addExpenseButton"].waitForExistence(timeout: 15))
        let expected = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Launch fixture \(suffix)")).firstMatch
        XCTAssertTrue(expected.waitForExistence(timeout: 5), "The requested fictional file must be visible.")
    }

    private func openOptions(in app: XCUIApplication) {
        waitForOptions(in: app)
        guard let more = optionsButton(in: app) else {
            XCTFail("Tally options must be available after the launch screen settles.")
            return
        }
        more.tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Privacy & Support"].exists)
    }

    private func optionsButton(in app: XCUIApplication) -> XCUIElement? {
        guard !launchCover(in: app).exists else { return nil }
        let identified = app.buttons.matching(identifier: "tallyOptionsButton").firstMatch
        if identified.exists && identified.isHittable { return identified }
        let named = app.buttons["Tally options"]
        if named.exists && named.isHittable { return named }
        // UIDocumentBrowser's remote toolbar applies the system symbol label.
        // Tally's added global action is the leading More button; the browser's
        // own view-options button remains on the trailing side. Resolve their
        // positions only for a tap after the visible browser has settled.
        guard !app.buttons["addExpenseButton"].exists else { return nil }
        let systemOptions = app.buttons.matching(NSPredicate(format: "label == %@", "More"))
        guard systemOptions.firstMatch.exists else { return nil }
        return systemOptions
            .allElementsBoundByIndex.filter(\.isHittable).min { $0.frame.minX < $1.frame.minX }
    }

    private func waitForOptions(in app: XCUIApplication) {
        let predicate = NSPredicate { [self] _, _ in
            guard !launchCover(in: app).exists else { return false }
            let identified = app.buttons.matching(identifier: "tallyOptionsButton").firstMatch
            if identified.exists && identified.isHittable { return true }
            let named = app.buttons["Tally options"]
            if named.exists && named.isHittable { return true }
            guard !app.buttons["addExpenseButton"].exists else { return false }
            // Do not enumerate native toolbar proxies during a cold launch:
            // presentation can replace them between indexed snapshot reads.
            let browserOptions = app.buttons.matching(NSPredicate(format: "label == %@", "More")).firstMatch
            return browserOptions.exists && browserOptions.isHittable
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: app)], timeout: 15), .completed)
    }

    private func openSettings(in app: XCUIApplication) {
        openOptions(in: app)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["launchBehaviorPicker"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settingsDoneButton"].exists)
    }

    private func choose(_ title: String, in app: XCUIApplication) {
        app.buttons["launchBehaviorPicker"].tap()
        let option = app.buttons[title]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        assertChoice(title, in: app)
    }

    private func assertChoice(_ title: String, in app: XCUIApplication) {
        let picker = app.buttons["launchBehaviorPicker"]
        let predicate = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", title, title)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: picker)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    private func finishSettings(in app: XCUIApplication) {
        app.buttons["settingsDoneButton"].tap()
        XCTAssertTrue(app.buttons["settingsDoneButton"].waitForNonExistence(timeout: 5))
    }

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
