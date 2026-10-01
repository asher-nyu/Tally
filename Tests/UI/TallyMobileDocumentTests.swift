#if os(iOS)
import XCTest

@MainActor
final class TallyMobileDocumentTests: XCTestCase {
    private var app: XCUIApplication!
    private var fixtureRow: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Fictional rent")).firstMatch
    }

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-native-mobile"]
        app.launch()
        XCTAssertTrue(fixtureRow.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["addExpenseButton"].wait(for: \.isEnabled, toEqual: true, timeout: 8))
        XCTAssertTrue(fixtureRow.wait(for: \.isEnabled, toEqual: true, timeout: 8))
        XCTAssertTrue(fixtureRow.wait(for: \.isHittable, toEqual: true, timeout: 8))
    }

    override func tearDown() async throws {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app?.terminate()
        app = nil
    }

    func testDeletionOffersRecoveryAndClosesTheEditor() {
        performFixtureAction("nativeMobileDelete", title: "Delete Fixture")
        let alert = app.alerts["File Deleted"]
        XCTAssertTrue(alert.waitForExistence(timeout: 8))
        XCTAssertTrue(alert.buttons["documentDeletedRecover"].exists)
        XCTAssertTrue(alert.buttons["documentDeletedClose"].exists)
        XCTAssertFalse(alert.buttons["OK"].exists)
        alert.buttons["documentDeletedClose"].firstMatch.tap()
        XCTAssertTrue(fixtureRow.waitForNonExistence(timeout: 8))
        XCTAssertFalse(alert.exists)
    }

    func testExternalRestoreDismissesTheAlertAndKeepsTheEditor() {
        performFixtureAction("nativeMobileRestore", title: "Restore Fixture")
        let alert = app.alerts["File Deleted"]
        XCTAssertTrue(alert.waitForExistence(timeout: 8))
        XCTAssertTrue(alert.waitForNonExistence(timeout: 12))
        XCTAssertTrue(fixtureRow.exists)
        XCTAssertTrue(app.buttons["addExpenseButton"].isEnabled)
    }

    func testRecoverySavesAndOpensAUsableCopy() {
        performFixtureAction("nativeMobileDelete", title: "Delete Fixture")
        let alert = app.alerts["File Deleted"]
        XCTAssertTrue(alert.waitForExistence(timeout: 8))
        alert.buttons["documentDeletedRecover"].firstMatch.tap()
        let save = app.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 8))
        XCTAssertFalse(alert.exists)
        let filename = app.textFields["DOCPicker.filenameTextField"]
        XCTAssertTrue(filename.exists)
        filename.tap()
        let previousName = filename.value as? String ?? ""
        filename.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previousName.count)
            + "Fictional Recovery \(UUID().uuidString.prefix(8))")
        // The system picker can finish keyboard presentation after typeText
        // returns. Wait for its control before tapping the moving Save bar.
        let hideKeyboard = app.buttons["Hide keyboard"]
        if hideKeyboard.waitForExistence(timeout: 3) {
            hideKeyboard.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        }
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 10))
        XCTAssertTrue(fixtureRow.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["addExpenseButton"].wait(for: \.isEnabled, toEqual: true, timeout: 8))
        XCTAssertFalse(alert.exists)
        app.buttons["addExpenseButton"].tap()
        XCTAssertTrue(app.textFields["expenseMerchantField"].waitForExistence(timeout: 5))
        app.buttons["cancelExpenseButton"].tap()
    }

    func testNativeEditorChangePersistsAfterClosingAndReopening() {
        fixtureRow.tap()
        let merchant = app.textFields["expenseMerchantField"]
        XCTAssertTrue(merchant.waitForExistence(timeout: 5))
        merchant.tap()
        let old = merchant.value as? String ?? ""
        merchant.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + "Fictional saved rent")
        app.buttons["saveExpenseButton"].tap()
        let updated = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Fictional saved rent")).firstMatch
        XCTAssertTrue(updated.waitForExistence(timeout: 5))
        app.buttons["BackButton"].firstMatch.tap()
        // Document Browser renders this item in its provider process; the
        // visible button retains the title, while its proxy holds the ID.
        let reopen = app.buttons["Reopen Fixture"]
        XCTAssertTrue(reopen.waitForExistence(timeout: 8))
        reopen.tap()
        XCTAssertTrue(updated.waitForExistence(timeout: 8))
        let search = app.searchFields.firstMatch
        if !search.exists, app.buttons["Search"].exists { app.buttons["Search"].tap() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        let query = "No matching fictional payment"
        search.typeText(query)
        XCTAssertTrue(updated.waitForNonExistence(timeout: 5))
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: query.count))
        XCTAssertTrue(updated.waitForExistence(timeout: 5))
    }

    private func performFixtureAction(_ identifier: String, title: String) {
        if app.buttons[identifier].exists {
            app.buttons[identifier].tap()
        } else {
            app.buttons["OverflowBarButtonItem"].tap()
            app.buttons[title.replacingOccurrences(of: " Fixture", with: "")].tap()
        }
    }
}
#endif
