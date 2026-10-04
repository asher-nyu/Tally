#if os(iOS)
import XCTest

@MainActor
final class MobileFileActionsUITests: XCTestCase {
    func testFilenameIsPlainTextAndFileActionsLiveInMore() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-native-mobile", "--ui-testing-mobile-file-actions"]
        app.launch()
        defer { app.terminate() }

        let navigation = app.navigationBars["Fictional Budget"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 15))
        let title = navigation.staticTexts["Fictional Budget"]
        XCTAssertTrue(title.exists)
        XCTAssertFalse(navigation.buttons["Fictional Budget"].exists)
        title.tap()
        XCTAssertFalse(app.buttons["Share"].exists)
        XCTAssertFalse(app.links.matching(NSPredicate(format: "label BEGINSWITH %@", "Fictional Budget, Tally Document")).firstMatch.exists)
        capture("Plain filename after tapping")

        let more = app.buttons["tallyOptionsButton"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Share"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
        XCTAssertTrue(app.buttons["Privacy & Support"].exists)
        capture("File actions in More")
        app.buttons["Rename"].tap()

        let alert = app.alerts["Rename File"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let field = alert.textFields["renameFileName"]
        XCTAssertEqual(field.value as? String, "Fictional Budget")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(navigation.exists)
        XCTAssertFalse(alert.exists)

        more.tap()
        app.buttons["Rename"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons.matching(identifier: "renameFileConfirm").allElementsBoundByIndex.last?.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertTrue(navigation.exists)

        more.tap()
        app.buttons["Rename"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Fictional Budget".count) + "Fictional Household.tally")
        let confirmButtons = alert.buttons.matching(identifier: "renameFileConfirm").allElementsBoundByIndex
        XCTAssertFalse(confirmButtons.isEmpty)
        XCTAssertEqual(confirmButtons.last?.isEnabled, true, "Rename must be enabled for a valid filename")
        capture("Rename field before confirmation")
        // Return confirms UIKit's preferred action without relying on cached
        // accessibility coordinates during simulator keyboard transitions.
        field.typeText("\n")
        let renamedNavigation = app.navigationBars["Fictional Household"]
        XCTAssertTrue(renamedNavigation.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.alerts["Couldn’t Rename File"].exists)
        XCTAssertFalse(app.alerts["File Deleted"].exists)
        XCTAssertTrue(app.staticTexts["Fictional rent"].exists)
        XCTAssertFalse(renamedNavigation.buttons["Fictional Household"].exists)
        renamedNavigation.staticTexts["Fictional Household"].tap()
        XCTAssertFalse(app.buttons["Share"].exists)
        capture("Renamed file with passive title")

        more.tap()
        app.buttons["Share"].tap()
        let activityList = app.otherElements["ActivityListView"]
        XCTAssertTrue(activityList.waitForExistence(timeout: 5))
        XCTAssertEqual(activityList.otherElements["LP.CaptionBar.TopCaption"].firstMatch.label, "Fictional Household")
        XCTAssertTrue(activityList.cells["Save to Files"].firstMatch.exists)
        capture("Share sheet for renamed file")
    }

    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let accessibility = XCTAttachment(string: XCUIApplication().debugDescription)
        accessibility.name = "\(name) accessibility tree"
        accessibility.lifetime = .keepAlways
        add(accessibility)
    }
}
#endif
