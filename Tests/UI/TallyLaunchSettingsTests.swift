#if os(macOS)
import XCTest

/// Real Settings, NSDocument, and process relaunches using an owned cache directory
/// and one unique defaults suite per test. No personal file is opened or modified.
@MainActor
final class TallyLaunchSettingsTests: XCTestCase {
    private var app: XCUIApplication!
    private var session: UUID!
    private var root: URL?

    override func setUp() async throws {
        await MainActor.run {
            continueAfterFailure = false
            session = UUID()
            app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "--ui-testing-launch-settings",
                                   "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                   "-ApplePersistenceIgnoreState", "YES",
                                   "-NSQuitAlwaysKeepsWindows", "NO", "-NSRecentDocumentsLimit", "0"]
            app.launchEnvironment["TALLY_LAUNCH_TEST_SESSION"] = session.uuidString
        }
    }

    override func tearDown() async throws {
        let remainingRoot: URL? = await MainActor.run {
            guard let app = self.app else { return nil }
            app.terminate()
            app.launchEnvironment["TALLY_LAUNCH_TEST_ACTION"] = "cleanup"
            app.launch()
            let status = self.field("launchTestStatus")
            let cleaned = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return element.exists && (element.value as? String ?? element.label) == "cleaned"
            }, object: status)
            let result = XCTWaiter.wait(for: [cleaned], timeout: 15)
            if result != .completed {
                let attachment = XCTAttachment(string: app.debugDescription)
                attachment.name = "Launch fixture cleanup hierarchy"
                attachment.lifetime = .keepAlways
                self.add(attachment)
            }
            app.terminate()
            return result == .completed ? self.root : nil
        }
        if let root {
            XCTAssertNotNil(remainingRoot, "The app-owned fixture cleanup must finish.")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
    }

    func testSettingsKeyboardShortcutAndMenuPersistBrowserChoiceAcrossRelaunch() throws {
        try launch()
        assertBrowser()
        dismissBrowser()
        app.typeKey(",", modifierFlags: .command)
        assertPicker("Open last used file")
        attach("Default launch preference in Settings")
        choose("Show file browser")
        expect("launchTestPreference", "fileBrowser")
        app.typeKey("w", modifierFlags: .command)

        app.menuBars.menuBarItems["Tally"].click()
        let settings = app.menuItems["Settings…"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.click()
        assertPicker("Show file browser")
        app.typeKey("w", modifierFlags: .command)
        app.buttons["launchTestOpenA"].click()
        assertOpen("Launch-A.tally")
        expect("launchTestHasBookmark", "true")

        try relaunch()
        assertBrowser()
        expect("launchTestOpenCount", "0")
        expect("launchTestFileCount", "2")
        dismissBrowser()
        app.typeKey(",", modifierFlags: .command)
        assertPicker("Show file browser")
        attach("Browser preference persists after a process relaunch")
    }

    func testClosedLastUsedFileReopensOnNextLaunch() throws {
        try launch()
        dismissBrowser()
        app.buttons["launchTestOpenB"].click()
        assertOpen("Launch-B.tally")
        expect("launchTestHasBookmark", "true")
        app.typeKey("w", modifierFlags: .command)
        expect("launchTestOpenCount", "0")
        try relaunch()
        assertOpen("Launch-B.tally")
        expect("launchTestOpenCount", "1")
        expect("launchTestFileCount", "2")
        attach("Last used file reopens after its window was closed")
    }

    func testMissingLastUsedFileFallsBackToBrowserWithoutCreatingAFile() throws {
        try launch(action: "seedA")
        assertOpen("Launch-A.tally")
        try relaunch(action: "deleteA")
        assertBrowser()
        expect("launchTestOpenCount", "0")
        expect("launchTestFileCount", "1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try fixture("Launch-A.tally").path))
        attach("Missing last file opens the file browser")
    }

    func testRenamedLastUsedFileReopensThroughItsBookmark() throws {
        try launch(action: "seedA")
        assertOpen("Launch-A.tally")
        try relaunch(action: "renameA")
        assertOpen("Renamed-A.tally")
        expect("launchTestOpenCount", "1")
        expect("launchTestFileCount", "2")
    }

    func testPreviousVersionRecentFileIsAdoptedAndRemembered() throws {
        try launch(action: "legacyRecentA")
        assertOpen("Launch-A.tally")
        expect("launchTestHasBookmark", "true")
        // The next process has no legacy-history fixture: only the bookmark
        // saved by the production coordinator can reopen this document.
        try relaunch()
        assertOpen("Launch-A.tally")
        expect("launchTestOpenCount", "1")
        expect("launchTestFileCount", "2")
    }


    private func launch(action: String? = nil) throws {
        app.launchEnvironment["TALLY_LAUNCH_TEST_ACTION"] = action
        app.launch()
        expect("launchTestStatus", "ready")
        let root = URL(fileURLWithPath: text(field("launchTestRootPath")), isDirectory: true)
        XCTAssertEqual(root.lastPathComponent, "TallyLaunchSettingsTests-\(session.uuidString)")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".test-owner"), encoding: .utf8), session.uuidString)
        self.root = root
    }

    private func relaunch(action: String? = nil) throws {
        app.terminate()
        try launch(action: action)
    }

    private func fixture(_ name: String) throws -> URL {
        let root = try XCTUnwrap(root)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".test-owner"), encoding: .utf8), session.uuidString)
        return root.appendingPathComponent(name)
    }

    private var picker: XCUIElement { app.popUpButtons["launchBehaviorPicker"].firstMatch }

    private func assertPicker(_ title: String) {
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        let match = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return element.value as? String == title || element.label == title
        }, object: picker)
        XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 5), .completed)
    }

    private func choose(_ title: String) {
        picker.click()
        let choice = app.menuItems[title].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.click()
        assertPicker(title)
    }

    private func assertBrowser() {
        XCTAssertTrue(app.windows.buttons["Open"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.windows.buttons["Cancel"].firstMatch.exists)
    }

    private func dismissBrowser() {
        assertBrowser()
        app.windows.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(app.windows.buttons["Cancel"].firstMatch.waitForNonExistence(timeout: 5))
    }

    private func assertOpen(_ filename: String) {
        let window = app.windows["launchDocument-\(filename)"]
        XCTAssertTrue(window.waitForExistence(timeout: 12))
        expect("launchTestOpenPaths", root!.appendingPathComponent(filename).path)
    }

    private func field(_ identifier: String) -> XCUIElement { app.staticTexts[identifier].firstMatch }
    private func text(_ element: XCUIElement) -> String { element.value as? String ?? element.label }

    private func expect(_ identifier: String, _ value: String) {
        let element = field(identifier)
        let match = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let element = object as? XCUIElement, element.exists else { return false }
            return (element.value as? String ?? element.label) == value
        }, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 15), .completed,
                       "\(identifier) should equal \(value); found \(element.exists ? text(element) : "absent")")
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
