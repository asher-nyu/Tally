#if os(macOS)
import XCTest

/// Exercises the real schedule editor using one fictional, in-memory expense.
/// No user documents or product screenshot scenarios are opened by these tests.
@MainActor
final class TallyScheduleDatePickerTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSingleDigitDateUsesItsOwnWidthAndSelectedDateSurvivesSave() throws {
        let app = launchDateFixture()
        openEditor(in: app)

        let seventh = closedDateFrame(day: 7, in: app)
        selectOctoberDay(17, in: app)
        let seventeenth = closedDateFrame(day: 17, in: app)
        XCTAssertGreaterThan(
            seventeenth.width, seventh.width + 3,
            "A single-digit day must not reserve the extra digit's width."
        )
        XCTAssertEqual(seventeenth.height, seventh.height, accuracy: 1)
        XCTAssertEqual(seventeenth.maxX, seventh.maxX, accuracy: 1,
                       "Changing the date must preserve the field's trailing alignment.")

        selectOctoberDay(7, in: app)
        let compactAgain = closedDateFrame(day: 7, in: app)
        XCTAssertEqual(compactAgain.width, seventh.width, accuracy: 1,
                       "The date must shrink back when returning to a single-digit day.")

        selectOctoberDay(17, in: app)
        saveEditor(in: app)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "expenseRow-")).count, 1,
                       "Changing the schedule must update the existing expense.")
        openEditor(in: app)
        _ = closedDateFrame(day: 17, in: app)
        app.buttons["cancelExpenseButton"].click()
    }

    func testCancellingEditorDiscardsCalendarSelection() throws {
        let app = launchDateFixture()
        openEditor(in: app)
        _ = closedDateFrame(day: 7, in: app)

        selectOctoberDay(17, in: app)
        _ = closedDateFrame(day: 17, in: app)
        app.buttons["cancelExpenseButton"].click()
        XCTAssertTrue(app.buttons["cancelExpenseButton"].waitForNonExistence(timeout: 5))

        openEditor(in: app)
        _ = closedDateFrame(day: 7, in: app)
        app.buttons["cancelExpenseButton"].click()
    }

    private func launchDateFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--ui-testing-date-spacing",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["addExpenseButton"].waitForExistence(timeout: 10))
        XCTAssertTrue(fixtureRow(in: app).waitForExistence(timeout: 5))
        return app
    }

    private func fixtureRow(in app: XCUIApplication) -> XCUIElement {
        app.buttons["expenseRow-00000000-0000-4000-8000-000000000017"]
    }

    private func openEditor(in app: XCUIApplication) {
        app.activate()
        let row = fixtureRow(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        XCTAssertTrue(app.buttons["entryAnchorDatePicker"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["expenseMerchantField"].value as? String, "Meal delivery")
    }

    private func closedDateFrame(day: Int, in app: XCUIApplication) -> CGRect {
        let button = app.buttons["entryAnchorDatePicker"]
        let expected = "Oct \(day), 2026"
        let predicate = NSPredicate(format: "value == %@", expected)
        expectation(for: predicate, evaluatedWith: button)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["entryAnchorDatePickerDone"].waitForNonExistence(timeout: 5),
                      "Measure only the closed date field, never its calendar popover.")
        XCTAssertTrue(button.isHittable)
        XCTAssertGreaterThan(button.frame.width, 0)
        return button.frame
    }

    private func selectOctoberDay(_ day: Int, in app: XCUIApplication) {
        let button = app.buttons["entryAnchorDatePicker"]
        let currentValue = button.value as? String ?? ""
        let fields = currentValue.split(separator: " ")
        guard fields.count == 3, fields[0] == "Oct", fields[2] == "2026",
              let selectedDay = Int(fields[1].dropLast()) else {
            XCTFail("Expected an October 2026 date before opening the calendar: \(currentValue)")
            return
        }
        button.click()
        let calendar = app.descendants(matching: .any)
            .matching(identifier: "entryAnchorDatePickerCalendar").firstMatch
        XCTAssertTrue(calendar.waitForExistence(timeout: 5))

        // AppKit's calendar initially focuses the selected date. Its day cells
        // are not separate accessibility elements: arrows move the focused
        // date, and Space selects it. Return would only activate Done.
        let direction: XCUIKeyboardKey = day > selectedDay ? .rightArrow : .leftArrow
        for _ in 0..<abs(day - selectedDay) {
            app.typeKey(direction, modifierFlags: [])
        }
        app.typeKey(" ", modifierFlags: [])
        app.buttons["entryAnchorDatePickerDone"].click()
    }

    private func saveEditor(in app: XCUIApplication) {
        let save = app.buttons["saveExpenseButton"]
        XCTAssertTrue(save.isEnabled)
        save.click()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5))
    }
}
#endif
