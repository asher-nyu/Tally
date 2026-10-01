import XCTest
#if os(iOS)
import Vision
#endif

/// These tests exercise the real editor with an empty in-memory document.
/// Native file-browser behavior, persistence, and iCloud sync are separate checks.
@MainActor
final class TallyUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEntryCanBeCreatedEditedAndFoundBySearch() throws {
        let app = launchIsolatedApp()
        addEntry(in: app, merchant: "Internet", amount: "49.99")
        addEntry(in: app, merchant: "Mobile plan", amount: "25.00")
        XCTAssertEqual(entryRows(in: app).count, 2)

        let originalRow = row(in: app, merchant: "Internet")
        XCTAssertTrue(originalRow.waitForExistence(timeout: 5))
        let originalIdentifier = originalRow.identifier
        activate(originalRow)

        replaceText(in: app.textFields["expenseMerchantField"], with: "Home Internet")
        replaceText(in: app.textFields["expenseAmountField"], with: "35.50")
        saveEditor(in: app)

        let editedRow = app.buttons[originalIdentifier]
        expect(editedRow, toMatch: "label CONTAINS %@", "Home Internet")
        expect(editedRow, toMatch: "label CONTAINS %@", "$35.50")
        XCTAssertEqual(entryRows(in: app).count, 2, "Editing must update the existing entry.")

        let search = revealSearch(in: app)
        replaceText(in: search, with: "Home Internet")
        XCTAssertTrue(editedRow.waitForExistence(timeout: 5))
        XCTAssertTrue(row(in: app, merchant: "Mobile plan").waitForNonExistence(timeout: 5))
        XCTAssertEqual(entryRows(in: app).count, 1)

        replaceText(in: search, with: "No merchant matches this")
        XCTAssertTrue(editedRow.waitForNonExistence(timeout: 5))
        XCTAssertEqual(entryRows(in: app).count, 0)

        replaceText(in: search, with: "")
        XCTAssertTrue(editedRow.waitForExistence(timeout: 5))
        XCTAssertTrue(row(in: app, merchant: "Mobile plan").waitForExistence(timeout: 5))
        XCTAssertEqual(entryRows(in: app).count, 2, "Searching must not remove entries.")
    }

    func testInvalidEntryCannotBeSavedAndCancelDiscardsChanges() throws {
        let app = launchIsolatedApp()
        activate(app.buttons["addExpenseButton"])

        let save = app.buttons["saveExpenseButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        expect(save, toMatch: "enabled == false")

        // A valid amount alone must not allow an unnamed entry.
        replaceText(in: app.textFields["expenseAmountField"], with: "12.34")
        expect(save, toMatch: "enabled == false")
        replaceText(in: app.textFields["expenseMerchantField"], with: "Electricity")
        expect(save, toMatch: "enabled == true")

        // The UI must reject extra fractional digits instead of rounding silently.
        replaceText(in: app.textFields["expenseAmountField"], with: "12.345")
        expect(save, toMatch: "enabled == false")
        XCTAssertTrue(app.staticTexts["This currency allows up to 2 decimal places."]
            .waitForExistence(timeout: 5))

        replaceText(in: app.textFields["expenseAmountField"], with: "12.34")
        expect(save, toMatch: "enabled == true")
        activate(app.buttons["cancelExpenseButton"])
        XCTAssertTrue(save.waitForNonExistence(timeout: 5))
        XCTAssertEqual(entryRows(in: app).count, 0, "Cancel must discard the new entry.")
    }

    #if os(macOS)
    func testClosedMenuPickersResizeForTheirSelectedTitles() throws {
        let app = launchIsolatedApp()
        activate(app.buttons["addExpenseButton"])

        func closedFrame(for identifier: String, selectedTitle: String) -> CGRect {
            let picker = app.popUpButtons[identifier]
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            expect(picker, toMatch: "label CONTAINS %@ OR value CONTAINS %@", selectedTitle, selectedTitle)
            XCTAssertTrue(
                app.menuItems[selectedTitle].waitForNonExistence(timeout: 3),
                "Measure \(identifier) only after its native menu has closed."
            )
            XCTAssertTrue(picker.isHittable)
            let frame = picker.frame
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
            return frame
        }

        for (identifier, shortTitle, longTitle) in [
            ("expenseCategoryPicker", "Other", "Subscriptions"),
            ("entryFrequencyPicker", "Monthly", "Every two weeks")
        ] {
            let initial = closedFrame(for: identifier, selectedTitle: shortTitle)
            var firstExpandedWidth: CGFloat?
            for cycle in 1...2 {
                selectMenuOption(longTitle, in: identifier, app: app)
                let expanded = closedFrame(for: identifier, selectedTitle: longTitle)
                XCTAssertGreaterThan(
                    expanded.width, initial.width + 8,
                    "\(identifier) must expand for \(longTitle), cycle \(cycle)."
                )
                XCTAssertEqual(expanded.height, initial.height, accuracy: 1)
                if let firstExpandedWidth {
                    XCTAssertEqual(expanded.width, firstExpandedWidth, accuracy: 2,
                                   "Selecting the long title again must restore the same width.")
                } else {
                    firstExpandedWidth = expanded.width
                }

                selectMenuOption(shortTitle, in: identifier, app: app)
                let compact = closedFrame(for: identifier, selectedTitle: shortTitle)
                XCTAssertEqual(
                    compact.width, initial.width, accuracy: 2,
                    "\(identifier) must shrink back for \(shortTitle), cycle \(cycle)."
                )
                XCTAssertEqual(compact.height, initial.height, accuracy: 1)
            }
        }

        attachScreenshot(of: app, named: "Closed Other and Monthly pickers after repeated long-title selections")
        activate(app.buttons["cancelExpenseButton"])
        XCTAssertTrue(app.buttons["cancelExpenseButton"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(entryRows(in: app).count, 0)
    }

    func testNativeRowContextMenuKeepsActionsAvailable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-populated", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        if !app.buttons["addExpenseButton"].waitForExistence(timeout: 1) {
            activate(app.menuBars.menuBarItems["File"])
            activate(app.menuItems["New Window"])
        }
        XCTAssertTrue(app.buttons["addExpenseButton"].waitForExistence(timeout: 10))
        let savedRow = row(in: app, merchant: "Apartment rent")
        XCTAssertTrue(savedRow.waitForExistence(timeout: 5))
        let originalRowCount = entryRows(in: app).count

        app.activate()
        savedRow.rightClick()
        XCTAssertTrue(app.menuItems["Edit…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Open website"].exists)
        XCTAssertTrue(app.menuItems["Delete…"].exists)
        attachScreenshot(of: app, named: "Native expense context menu with website action")
        activate(app.menuItems["Edit…"])
        expect(app.textFields["expenseMerchantField"], toMatch: "value == %@", "Apartment rent")
        expect(app.textFields["providerWebsiteField"], toMatch: "value == %@", "https://example.com/rent")
        activate(app.buttons["cancelExpenseButton"])
        XCTAssertTrue(app.buttons["cancelExpenseButton"].waitForNonExistence(timeout: 5))

        app.activate()
        savedRow.rightClick()
        activate(app.menuItems["Delete…"])
        XCTAssertTrue(app.buttons["confirmDeleteExpenseButton"].waitForExistence(timeout: 5))
        activate(app.windows.buttons["Cancel"].firstMatch)
        XCTAssertTrue(app.buttons["confirmDeleteExpenseButton"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(savedRow.exists)
        XCTAssertEqual(entryRows(in: app).count, originalRowCount, "Cancelling deletion must preserve the expense.")
    }
    #endif

    func testOptionalWebsitePersistsValidatesAndCanBeRemoved() throws {
        let app = launchIsolatedApp()
        addEntry(in: app, merchant: "Internet", amount: "49.99")
        let savedRow = row(in: app, merchant: "Internet")
        let entryID = String(savedRow.identifier.dropFirst("expenseRow-".count))
        let openWebsite = app.buttons["openWebsite-\(entryID)"]
        XCTAssertFalse(openWebsite.exists, "An entry saved without a website must not have an Open Website action.")

        activate(savedRow)
        let website = app.textFields["providerWebsiteField"]
        replaceText(in: website, with: "example.com/account")
        saveEditor(in: app)
        XCTAssertTrue(openWebsite.waitForExistence(timeout: 5))
        XCTAssertTrue(openWebsite.isHittable)

        activate(savedRow)
        expect(website, toMatch: "value == %@", "https://example.com/account")
        replaceText(in: website, with: "javascript:alert(1)")
        expect(app.buttons["saveExpenseButton"], toMatch: "enabled == false")
        let error = app.descendants(matching: .any)
            .matching(identifier: "providerWebsiteError").firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5), "An unsupported URL scheme must explain why the entry cannot be saved.")

        replaceText(in: website, with: "")
        XCTAssertTrue(error.waitForNonExistence(timeout: 5))
        saveEditor(in: app)
        XCTAssertTrue(openWebsite.waitForNonExistence(timeout: 5), "Clearing a saved website must remove its row action.")
        XCTAssertTrue(savedRow.waitForExistence(timeout: 5))
        XCTAssertEqual(entryRows(in: app).count, 1, "Website changes must update the existing entry.")
    }

    func testReminderRequiresDatePersistsAndCancelsDraftChanges() throws {
        let app = launchIsolatedApp()
        activate(app.buttons["addExpenseButton"])
        replaceText(in: app.textFields["expenseMerchantField"], with: "Phone plan")
        replaceText(in: app.textFields["expenseAmountField"], with: "25.00")

        let toggle = reminderToggle(in: app)
        expect(toggle, toMatch: "value == 0 OR value == %@", "0")
        setReminderEnabled(true, in: app)
        let save = app.buttons["saveExpenseButton"]
        expect(save, toMatch: "enabled == false")
        let dateError = app.staticTexts["reminderDateError"]
        #if os(iOS)
        let reminderForm = editorForm(in: app)
        guard revealFormControl(dateError, in: app, inside: reminderForm, initiallyScrollDown: true) else { return }
        #endif
        XCTAssertTrue(dateError.waitForExistence(timeout: 5), "A reminder must require an explicit monthly payment date.")

        selectMenuOption("Day 15", in: "expenseBillingDayPicker", app: app)
        XCTAssertTrue(dateError.waitForNonExistence(timeout: 5))
        selectMenuOption("1 day before", in: "reminderLeadTimePicker", app: app)
        let time = app.descendants(matching: .any)
            .matching(identifier: "reminderTimePicker").firstMatch
        XCTAssertTrue(time.waitForExistence(timeout: 5))
        assertReminderSound("Ripple", in: app)
        saveEditor(in: app)

        let savedRow = row(in: app, merchant: "Phone plan")
        XCTAssertTrue(savedRow.waitForExistence(timeout: 5))
        activate(savedRow)
        expect(reminderToggle(in: app), toMatch: "value == 1 OR value == %@", "1")
        let leadTime = app.descendants(matching: .any)
            .matching(identifier: "reminderLeadTimePicker").firstMatch
        assertReminderLeadTime("1 day before", in: app)
        selectMenuOption("2 days before", in: "reminderLeadTimePicker", app: app)
        activate(app.buttons["cancelExpenseButton"])
        XCTAssertTrue(save.waitForNonExistence(timeout: 5))

        activate(savedRow)
        assertReminderLeadTime("1 day before", in: app)
        setReminderEnabled(false, in: app)
        XCTAssertTrue(time.waitForNonExistence(timeout: 5))
        saveEditor(in: app)
        activate(savedRow)
        expect(reminderToggle(in: app), toMatch: "value == 0 OR value == %@", "0")
        XCTAssertFalse(leadTime.exists, "Turning reminders off must persist when the entry is reopened.")
        activate(app.buttons["cancelExpenseButton"])
        XCTAssertTrue(save.waitForNonExistence(timeout: 5))
        XCTAssertEqual(entryRows(in: app).count, 1)
    }

    func testSelectingTheCurrentSoundRequestsAnotherPreview() throws {
        let app = launchIsolatedApp(additionalArguments: ["--ui-testing-sound-previews"])
        activate(app.buttons["addExpenseButton"])
        replaceText(in: app.textFields["expenseMerchantField"], with: "Preview regression")
        setReminderEnabled(true, in: app)
        selectMenuOption("Day 15", in: "expenseBillingDayPicker", app: app)
        assertReminderSound("Ripple", in: app)

        let requests = app.staticTexts["reminderPreviewRequestCount"]
        expect(requests, toMatch: "value == %@ OR label == %@", "0", "0")
        selectMenuOption("Ripple", in: "reminderSoundPicker", app: app)
        expect(requests, toMatch: "value == %@ OR label == %@", "1", "1")
        selectMenuOption("Ripple", in: "reminderSoundPicker", app: app)
        expect(requests, toMatch: "value == %@ OR label == %@", "2", "2")
        assertReminderSound("Ripple", in: app)

        selectMenuOption("Signal", in: "reminderSoundPicker", app: app)
        expect(requests, toMatch: "value == %@ OR label == %@", "3", "3")
        selectMenuOption("Signal", in: "reminderSoundPicker", app: app)
        expect(requests, toMatch: "value == %@ OR label == %@", "4", "4")
        assertReminderSound("Signal", in: app)

        selectMenuOption("None", in: "reminderSoundPicker", app: app)
        selectMenuOption("None", in: "reminderSoundPicker", app: app)
        expect(requests, toMatch: "value == %@ OR label == %@", "4", "4")
        assertReminderSound("None", in: app)
        activate(app.buttons["cancelExpenseButton"])
        XCTAssertTrue(app.buttons["saveExpenseButton"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(entryRows(in: app).count, 0, "Auditioning sounds must not create a saved item.")
    }

    func testReminderSoundChoicesPersistAndCancelDiscardsDraftChanges() throws {
        let app = launchIsolatedApp()
        activate(app.buttons["addExpenseButton"])
        replaceText(in: app.textFields["expenseMerchantField"], with: "Sound preference")
        replaceText(in: app.textFields["expenseAmountField"], with: "12.00")
        setReminderEnabled(true, in: app)
        selectMenuOption("Day 15", in: "expenseBillingDayPicker", app: app)
        assertReminderSound("Ripple", in: app)

        selectMenuOption("Signal", in: "reminderSoundPicker", app: app, expectedOptions: [
            "Ripple", "Pebble", "Glow", "Lift", "Signal", "None"
        ])
        assertReminderSound("Signal", in: app)
        selectMenuOption("Lift", in: "reminderSoundPicker", app: app)
        assertReminderSound("Lift", in: app)
        saveEditor(in: app)

        let savedRow = row(in: app, merchant: "Sound preference")
        XCTAssertTrue(savedRow.waitForExistence(timeout: 5))
        activate(savedRow)
        assertReminderSound("Lift", in: app)
        selectMenuOption("None", in: "reminderSoundPicker", app: app)
        assertReminderSound("None", in: app)
        saveEditor(in: app)

        activate(savedRow)
        assertReminderSound("None", in: app)
        selectMenuOption("Ripple", in: "reminderSoundPicker", app: app)
        assertReminderSound("Ripple", in: app)
        activate(app.buttons["cancelExpenseButton"])
        XCTAssertTrue(app.buttons["saveExpenseButton"].waitForNonExistence(timeout: 5))

        activate(savedRow)
        assertReminderSound("None", in: app)
        selectMenuOption("Ripple", in: "reminderSoundPicker", app: app)
        saveEditor(in: app)

        activate(savedRow)
        assertReminderSound("Ripple", in: app)
        attachScreenshot(of: app, named: "Saved Ripple reminder sound after selecting and cancelling alternatives")
        activate(app.buttons["cancelExpenseButton"])
        XCTAssertTrue(app.buttons["saveExpenseButton"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(entryRows(in: app).count, 1, "Changing reminder sound must update the same payment.")
    }

    func testIncomeAndExpensesProduceBalanceAndExcludeVariableAmounts() throws {
        let app = launchIsolatedApp()
        activate(app.buttons["addExpenseButton"])
        selectSegment("Income", in: "entryKindPicker", app: app)
        replaceText(in: app.textFields["expenseMerchantField"], with: "Salary")
        replaceText(in: app.textFields["expenseAmountField"], with: "2500.00")
        saveEditor(in: app)
        expect(row(in: app, merchant: "Salary"), toMatch: "label CONTAINS %@", "Income")

        addEntry(in: app, merchant: "Rent", amount: "875.00")
        expect(row(in: app, merchant: "Rent"), toMatch: "label CONTAINS %@", "Expense")
        assertPeriodTotals(in: app, income: "$2,500.00", outgoing: "$875.00", balance: "$1,625.00")

        activate(app.buttons["addExpenseButton"])
        replaceText(in: app.textFields["expenseMerchantField"], with: "Groceries")
        // Switching to Variable must exclude even a previously entered fixed amount.
        replaceText(in: app.textFields["expenseAmountField"], with: "222.22")
        selectSegment("Variable", in: "expenseAmountKindPicker", app: app)
        XCTAssertTrue(app.textFields["expenseAmountField"].waitForNonExistence(timeout: 5))
        saveEditor(in: app)

        expect(row(in: app, merchant: "Groceries"), toMatch: "label CONTAINS %@", "Variable")
        XCTAssertEqual(entryRows(in: app).count, 3)
        assertPeriodTotals(in: app, income: "$2,500.00", outgoing: "$875.00", balance: "$1,625.00")
        let explanation = app.descendants(matching: .any)
            .matching(identifier: "variableExpenseCount").firstMatch
        expect(explanation, toMatch: "label CONTAINS %@ OR value CONTAINS %@", "1 variable amount excluded", "1 variable amount excluded")
    }

    func testAnnualExpenseIsCountedOnceAndMonthlyIncomeTwelveTimesInYear() throws {
        let app = launchIsolatedApp()
        activate(app.buttons["addExpenseButton"])
        selectSegment("Income", in: "entryKindPicker", app: app)
        replaceText(in: app.textFields["expenseMerchantField"], with: "Monthly salary")
        replaceText(in: app.textFields["expenseAmountField"], with: "2000.00")
        saveEditor(in: app)

        activate(app.buttons["addExpenseButton"])
        replaceText(in: app.textFields["expenseMerchantField"], with: "Annual insurance")
        replaceText(in: app.textFields["expenseAmountField"], with: "1200.00")
        selectMenuOption("Annually", in: "entryFrequencyPicker", app: app)
        // The editor starts the annual schedule today, within the current month and year.
        let datePicker = app.descendants(matching: .any)
            .matching(identifier: "entryAnchorDatePicker").firstMatch
        XCTAssertTrue(datePicker.waitForExistence(timeout: 5))
        saveEditor(in: app)

        XCTAssertEqual(entryRows(in: app).count, 2)
        assertPeriodTotals(in: app, income: "$2,000.00", outgoing: "$1,200.00", balance: "$800.00")

        selectSegment("Year", in: "periodKindPicker", app: app)
        assertPeriodTotals(in: app, income: "$24,000.00", outgoing: "$1,200.00", balance: "$22,800.00")

        selectSegment("Month", in: "periodKindPicker", app: app)
        assertPeriodTotals(in: app, income: "$2,000.00", outgoing: "$1,200.00", balance: "$800.00")
        XCTAssertEqual(entryRows(in: app).count, 2, "Changing the overview period must not duplicate entries.")
    }

    func testBiweeklyIncomeUsesFirstDateAndKeepsScheduleWhenReopened() throws {
        let app = launchIsolatedApp()
        activate(app.buttons["addExpenseButton"])
        selectSegment("Income", in: "entryKindPicker", app: app)
        replaceText(in: app.textFields["expenseMerchantField"], with: "Fortnightly pay")
        replaceText(in: app.textFields["expenseAmountField"], with: "100.00")
        selectMenuOption("Every two weeks", in: "entryFrequencyPicker", app: app)

        let datePicker = app.descendants(matching: .any)
            .matching(identifier: "entryAnchorDatePicker").firstMatch
        XCTAssertTrue(datePicker.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "expenseBillingDayPicker").firstMatch.exists)

        // The first date defaults to today. Count full $100 payments every 14 days
        // through this month's end, rather than an averaged monthly amount.
        let today = Date()
        let calendar = Calendar(identifier: .gregorian)
        let daysInMonth = try XCTUnwrap(calendar.range(of: .day, in: .month, for: today)).count
        let remainingDays = daysInMonth - calendar.component(.day, from: today)
        let paymentCount = remainingDays / 14 + 1
        let expectedIncome = "$\(paymentCount * 100).00"
        saveEditor(in: app)

        let savedRow = row(in: app, merchant: "Fortnightly pay")
        expect(savedRow, toMatch: "label CONTAINS %@", "Every two weeks")
        assertPeriodTotals(in: app, income: expectedIncome, outgoing: "$0.00", balance: expectedIncome)

        activate(savedRow)
        let frequency = app.descendants(matching: .any)
            .matching(identifier: "entryFrequencyPicker").firstMatch
        expect(frequency, toMatch: "label CONTAINS %@ OR value CONTAINS %@", "Every two weeks", "Every two weeks")
        XCTAssertTrue(datePicker.waitForExistence(timeout: 5), "The saved recurrence must retain its first-date editor.")
        saveEditor(in: app)
        XCTAssertEqual(entryRows(in: app).count, 1)
        assertPeriodTotals(in: app, income: expectedIncome, outgoing: "$0.00", balance: expectedIncome)
    }

    func testYearNavigationAndResetKeepControlsAlignedAcrossRepeatedTransitions() throws {
        let app = launchIsolatedApp(additionalArguments: ["--ui-testing-wide-window"])
        #if os(macOS)
        XCTAssertGreaterThanOrEqual(
            app.windows.firstMatch.frame.width, 800,
            "This regression must exercise the wide Mac period-control layout."
        )
        #endif
        addEntry(in: app, merchant: "Monthly internet", amount: "50.00")
        selectSegment("Year", in: "periodKindPicker", app: app)

        let title = app.descendants(matching: .any)
            .matching(identifier: "selectedPeriodTitle").firstMatch
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        let currentYearTitle = String(currentYear)
        let nextYearTitle = String(currentYear + 1)
        expect(title, toMatch: "label == %@", currentYearTitle)

        let reset = app.buttons["currentPeriodButton"]
        XCTAssertFalse(reset.exists, "The current year must not show a reset action.")
        let baseline = capturePeriodControlFrames(in: app)
        assertPeriodControls(in: app, match: baseline, context: "Initial year")
        var resetFrame: CGRect?

        for transition in 1...3 {
            activate(app.buttons["nextPeriodButton"])
            expect(title, toMatch: "label == %@", nextYearTitle)
            expect(reset, toMatch: "enabled == true")
            assertResetButton(reset, in: app, match: &resetFrame)
            assertPeriodControls(in: app, match: baseline, context: "Next year, transition \(transition)")

            activate(reset)
            expect(title, toMatch: "label == %@", currentYearTitle)
            XCTAssertTrue(reset.waitForNonExistence(timeout: 3), "Returning to this year must remove the reset action.")
            assertPeriodControls(in: app, match: baseline, context: "Reset year, transition \(transition)")
        }

        XCTAssertEqual(entryRows(in: app).count, 1)
        assertPeriodTotals(in: app, income: "$0.00", outgoing: "$600.00", balance: "-$600.00")
        attachScreenshot(of: app, named: "Year overview after three next-year and reset transitions")
    }

    func testCurrentMonthResetAppearsOnlyAwayFromTodayWithoutMovingControls() throws {
        let app = launchIsolatedApp(additionalArguments: ["--ui-testing-wide-window"])
        addEntry(in: app, merchant: "Monthly internet", amount: "50.00")
        let title = app.descendants(matching: .any)
            .matching(identifier: "selectedPeriodTitle").firstMatch
        let currentTitle = title.label
        let reset = app.buttons["currentPeriodButton"]
        XCTAssertFalse(reset.exists, "This month must not appear while the current month is selected.")
        let baseline = capturePeriodControlFrames(in: app)
        var resetFrame: CGRect?

        for direction in ["nextPeriodButton", "previousPeriodButton"] {
            activate(app.buttons[direction])
            expect(title, toMatch: "label != %@", currentTitle)
            expect(reset, toMatch: "enabled == true")
            assertResetButton(reset, in: app, match: &resetFrame)
            assertPeriodControls(in: app, match: baseline, context: "Month after \(direction)")
            activate(reset)
            expect(title, toMatch: "label == %@", currentTitle)
            XCTAssertTrue(reset.waitForNonExistence(timeout: 3))
            assertPeriodControls(in: app, match: baseline, context: "Current month restored")
        }
        attachScreenshot(of: app, named: "Current month has no reset action and retains aligned navigation")
    }

    #if os(macOS)
    func testScrollingRemainsAvailableWithIndicatorsDisabled() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-populated", "--ui-testing-scroll-overflow", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let row = app.buttons["expenseRow-00000000-0000-4000-8000-000000000001"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let baseline = capturePeriodControlFrames(in: app)
        activate(app.buttons["nextPeriodButton"])
        assertPeriodControls(in: app, match: baseline, context: "Scrollable list after changing month")
        activate(app.buttons["currentPeriodButton"])
        XCTAssertTrue(app.buttons["currentPeriodButton"].waitForNonExistence(timeout: 3))
        assertPeriodControls(in: app, match: baseline, context: "Scrollable list after returning to this month")
        let list = app.scrollViews.containing(.button, identifier: row.identifier).firstMatch
        XCTAssertTrue(list.exists)
        let originalY = row.frame.minY
        list.scroll(byDeltaX: 0, deltaY: -220)
        XCTAssertNotEqual(row.frame.minY, originalY, "The list must remain scrollable.")
        list.scroll(byDeltaX: 0, deltaY: -90)

        activate(app.buttons["addExpenseButton"])
        let merchant = app.textFields["expenseMerchantField"]
        XCTAssertTrue(merchant.waitForExistence(timeout: 5))
        let form = app.scrollViews.containing(.textField, identifier: "expenseMerchantField").firstMatch
        XCTAssertTrue(form.exists)
        let originalMerchantY = merchant.frame.minY
        form.scroll(byDeltaX: 0, deltaY: -300)
        XCTAssertNotEqual(merchant.frame.minY, originalMerchantY, "The form must remain scrollable.")
        form.scroll(byDeltaX: 0, deltaY: -120)
        activate(app.buttons["cancelExpenseButton"])
    }
    #endif

    func testCustomMonthlyIntervalPersistsAndCancelDiscardsDraftChanges() throws {
        let app = launchIsolatedApp()
        activate(app.buttons["addExpenseButton"])
        replaceText(in: app.textFields["expenseMerchantField"], with: "Quarterly membership")
        replaceText(in: app.textFields["expenseAmountField"], with: "60.00")
        selectMenuOption("Custom…", in: "entryFrequencyPicker", app: app)

        let interval = app.textFields["customIntervalField"]
        XCTAssertTrue(interval.waitForExistence(timeout: 5))
        selectMenuOption("Monthly", in: "customFrequencyPicker", app: app)
        let done = app.buttons["saveCustomRepeatButton"]
        expect(interval, toMatch: "value == %@", "1")
        expect(done, toMatch: "enabled == true")
        replaceText(in: interval, with: "999")
        XCTAssertGreaterThanOrEqual(interval.frame.width, 60, "The interval field must leave room for its supported three-digit values.")
        expect(done, toMatch: "enabled == true")
        attachScreenshot(of: app, named: "Custom repeat interval 999 at the supported upper bound")
        replaceText(in: interval, with: "1000")
        expect(done, toMatch: "enabled == false")
        replaceText(in: interval, with: "3")
        expect(done, toMatch: "enabled == true")
        attachScreenshot(of: app, named: "Custom monthly repeat every three months before Done")
        activate(done)
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["editCustomRepeatButton"].waitForExistence(timeout: 5))
        saveEditor(in: app)

        let savedRow = row(in: app, merchant: "Quarterly membership")
        XCTAssertTrue(savedRow.waitForExistence(timeout: 5))
        let originalIdentifier = savedRow.identifier
        let originalLabel = savedRow.label
        assertPeriodTotals(in: app, income: "$0.00", outgoing: "$60.00", balance: "-$60.00")

        // Reopen the stored entry and its custom rule, then change only the draft.
        activate(savedRow)
        activate(app.buttons["editCustomRepeatButton"])
        expect(interval, toMatch: "value == %@", "3")
        let frequency = app.descendants(matching: .any)
            .matching(identifier: "customFrequencyPicker").firstMatch
        expect(frequency, toMatch: "label CONTAINS %@ OR value CONTAINS %@", "Monthly", "Monthly")
        replaceText(in: interval, with: "4")
        let cancel = app.buttons["cancelCustomRepeatButton"]
        activate(cancel)
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))

        // Cancel must leave the entry's rule at three months, even if the parent
        // entry editor is subsequently saved.
        activate(app.buttons["editCustomRepeatButton"])
        expect(interval, toMatch: "value == %@", "3")
        activate(app.buttons["cancelCustomRepeatButton"])
        XCTAssertTrue(interval.waitForNonExistence(timeout: 5))
        saveEditor(in: app)

        XCTAssertEqual(entryRows(in: app).count, 1)
        expect(app.buttons[originalIdentifier], toMatch: "label == %@", originalLabel)
        assertPeriodTotals(in: app, income: "$0.00", outgoing: "$60.00", balance: "-$60.00")
    }

    #if os(iOS)
    func testCustomIntervalRemainsUsableAtLargestAccessibilityTextSize() throws {
        let app = launchIsolatedApp(additionalArguments: ["--ui-testing-accessibility-text"])
        activate(app.buttons["addExpenseButton"])
        selectMenuOption("Custom…", in: "entryFrequencyPicker", app: app)

        let interval = app.textFields["customIntervalField"]
        replaceText(in: interval, with: "999")
        XCTAssertGreaterThan(interval.frame.width, 100, "The sheet must inherit accessibility text size and scale the interval field.")
        XCTAssertGreaterThan(interval.frame.height, 40, "The interval's text and field height must scale at accessibility text size.")
        XCTAssertTrue(interval.isHittable, "The interval must remain reachable while it is being edited.")
        expect(app.buttons["saveCustomRepeatButton"], toMatch: "enabled == true")
        attachScreenshot(of: app, named: "Custom repeat interval 999 at accessibility text size five")

        activate(app.buttons["cancelCustomRepeatButton"])
        XCTAssertTrue(interval.waitForNonExistence(timeout: 5))
        activate(app.buttons["cancelExpenseButton"])
        XCTAssertTrue(app.buttons["cancelExpenseButton"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(entryRows(in: app).count, 0, "Cancel must leave the empty document unchanged.")
    }
    #endif

    #if os(iOS)
    func testPopulatedListKeepsWebsiteAndAmountColumnsAligned() throws {
        let app = launchPopulatedList(accessibilityText: false)
        let rent = populatedRow(1, in: app)
        let rentWebsite = populatedWebsite(1, in: app)
        guard revealPopulatedRow(rent, website: rentWebsite, in: app) else { return }
        assertWebsiteTarget(rentWebsite, named: "Apartment rent", in: app)
        XCTAssertGreaterThanOrEqual(rentWebsite.frame.minX, rent.frame.maxX,
                                    "The website action must not overlap the edit or amount column.")
        XCTAssertEqual(rentWebsite.frame.minY, rent.frame.minY, accuracy: 2,
                       "The website action should align with the top of its entry.")
        let rentAmount = try renderedAmountFrame("$1,450.00", in: rent)
        let websiteColumnX = rentWebsite.frame.minX
        expect(rent, toMatch: "label CONTAINS %@", "Reminder: 1 day before")
        expect(rent, toMatch: "label CONTAINS %@", "9:00")
        expect(rent, toMatch: "label CONTAINS %@", "1 payment this month")

        let broadband = populatedRow(2, in: app)
        guard revealPopulatedListItem(broadband, in: app) else { return }
        let broadbandAmount = try renderedAmountFrame("$65.00", in: broadband)
        XCTAssertEqual(broadbandAmount.maxX, rentAmount.maxX, accuracy: 3,
                       "Rendered amounts must align across expenses with and without a website.")
        XCTAssertFalse(populatedWebsite(2, in: app).exists)
        attachScreenshot(of: app, named: "Populated list with aligned linked and unlinked entries")

        let annual = populatedRow(3, in: app)
        let annualWebsite = populatedWebsite(3, in: app)
        guard revealPopulatedRow(annual, website: annualWebsite, in: app) else { return }
        assertWebsiteTarget(annualWebsite, named: "Cedar creative software subscription", in: app)
        expect(annual, toMatch: "label CONTAINS %@", "Cedar creative software subscription")
        expect(annual, toMatch: "label CONTAINS %@", "Annually")
        let annualAmount = try renderedAmountFrame("$240.00", in: annual)
        XCTAssertEqual(annualAmount.maxX, rentAmount.maxX, accuracy: 3,
                       "A long name must not shift the rendered amount column.")
        XCTAssertEqual(annualWebsite.frame.minX, websiteColumnX, accuracy: 1)
        attachScreenshot(of: app, named: "Populated list with a long annual entry and mixed schedules")

        activate(annual)
        expect(app.textFields["expenseMerchantField"], toMatch: "value == %@", "Cedar creative software subscription")
        activate(app.buttons["cancelExpenseButton"])
        XCTAssertTrue(app.buttons["cancelExpenseButton"].waitForNonExistence(timeout: 5))
    }

    func testPopulatedListRemainsUsableAtLargestAccessibilityTextSize() throws {
        let app = launchPopulatedList(accessibilityText: true)
        let rent = populatedRow(1, in: app)
        let rentWebsite = populatedWebsite(1, in: app)
        guard revealPopulatedRow(rent, website: rentWebsite, in: app) else { return }
        assertWebsiteTarget(rentWebsite, named: "Apartment rent", in: app)
        XCTAssertGreaterThan(rent.frame.height, 120, "The entry must use its expanded accessibility layout.")
        XCTAssertGreaterThanOrEqual(rentWebsite.frame.minY, rent.frame.maxY,
                                    "The website action must sit below the entry at accessibility text sizes.")
        expect(rent, toMatch: "label CONTAINS %@", "$1,450.00")
        expect(rent, toMatch: "label CONTAINS %@", "Reminder: 1 day before")
        expect(rent, toMatch: "label CONTAINS %@", "9:00")
        expect(rent, toMatch: "label CONTAINS %@", "1 payment this month")
        attachScreenshot(of: app, named: "Linked entry and reminder at accessibility text size five")

        let annual = populatedRow(3, in: app)
        let annualWebsite = populatedWebsite(3, in: app)
        guard revealPopulatedRow(annual, website: annualWebsite, in: app) else { return }
        assertWebsiteTarget(annualWebsite, named: "Cedar creative software subscription", in: app)
        expect(annual, toMatch: "label CONTAINS %@", "Cedar creative software subscription")
        expect(annual, toMatch: "label CONTAINS %@", "Annually")
        XCTAssertGreaterThanOrEqual(annualWebsite.frame.minY, annual.frame.maxY)
        attachScreenshot(of: app, named: "Long annual entry with separate website action at accessibility text size five")

        guard revealPopulatedListItem(annual, in: app) else { return }
        activate(annual)
        expect(app.textFields["expenseMerchantField"], toMatch: "value == %@", "Cedar creative software subscription")
        activate(app.buttons["cancelExpenseButton"])
        XCTAssertTrue(app.buttons["cancelExpenseButton"].waitForNonExistence(timeout: 5))
    }

    private func launchPopulatedList(accessibilityText: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--ui-testing-populated",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ] + (accessibilityText ? ["--ui-testing-accessibility-text"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["addExpenseButton"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "expenseList").firstMatch
            .waitForExistence(timeout: 5))
        return app
    }

    private func populatedRow(_ number: Int, in app: XCUIApplication) -> XCUIElement {
        app.buttons[String(format: "expenseRow-00000000-0000-4000-8000-%012d", number)]
    }

    private func populatedWebsite(_ number: Int, in app: XCUIApplication) -> XCUIElement {
        app.buttons[String(format: "openWebsite-00000000-0000-4000-8000-%012d", number)]
    }

    private func assertWebsiteTarget(_ button: XCUIElement, named merchant: String, in app: XCUIApplication) {
        assertVisibleListItem(button, in: app)
        XCTAssertEqual(button.label, "Open \(merchant) website")
        XCTAssertGreaterThanOrEqual(button.frame.width, 44)
        XCTAssertGreaterThanOrEqual(button.frame.height, 44)
    }

    private func assertVisibleListItem(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.exists)
        let list = app.descendants(matching: .any).matching(identifier: "expenseList").firstMatch
        let viewport = formViewport(list, in: app, horizontalInset: 0)
        XCTAssertTrue(viewport.contains(element.frame),
                      "The complete list item must remain inside the visible list: \(element.identifier), \(element.frame), viewport \(viewport).")
        XCTAssertTrue(element.isHittable)
    }

    private func renderedAmountFrame(_ amount: String, in row: XCUIElement) throws -> CGRect {
        let frame = row.frame
        let screenshot = row.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Rendered amount \(amount) in \(row.identifier)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        var matches: [CGRect] = []
        var recognizedText: [String] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            recognizedText.append(candidate.string)
            guard let range = candidate.string.range(of: amount),
                  let rectangle = try candidate.boundingBox(for: range) else { continue }
            let bounds = rectangle.boundingBox
            matches.append(CGRect(
                x: frame.minX + bounds.minX * frame.width,
                y: frame.minY + (1 - bounds.maxY) * frame.height,
                width: bounds.width * frame.width,
                height: bounds.height * frame.height
            ))
        }
        XCTAssertEqual(matches.count, 1,
                       "Expected exactly one rendered \(amount) in the row screenshot; recognized \(recognizedText).")
        return try XCTUnwrap(matches.first)
    }

    private func revealPopulatedRow(_ row: XCUIElement, website: XCUIElement, in app: XCUIApplication) -> Bool {
        guard revealPopulatedListItem(website, keepingVisible: row, in: app) else { return false }
        let list = app.descendants(matching: .any).matching(identifier: "expenseList").firstMatch
        let viewport = formViewport(list, in: app, horizontalInset: 0)
        if row.frame.union(website.frame).height <= viewport.height {
            assertVisibleListItem(row, in: app)
        } else {
            // A tall accessibility row and its website action may need separate
            // scroll positions. Verify both without claiming they fit together.
            guard revealPopulatedListItem(row, in: app) else { return false }
            attachScreenshot(of: app, named: "Expanded row before its separate website action")
            guard revealPopulatedListItem(website, in: app) else { return false }
        }
        return true
    }

    private func revealPopulatedListItem(
        _ element: XCUIElement, keepingVisible companion: XCUIElement? = nil, in app: XCUIApplication
    ) -> Bool {
        let list = app.descendants(matching: .any).matching(identifier: "expenseList").firstMatch
        for _ in 0..<8 {
            let viewport = formViewport(list, in: app, horizontalInset: 0)
            var frame = element.exists ? element.frame : .null
            if let companion, companion.exists, !frame.isNull {
                let combined = frame.union(companion.frame)
                if combined.height <= viewport.height { frame = combined }
            }
            if !frame.isEmpty, !frame.isNull, viewport.contains(frame) {
                assertVisibleListItem(element, in: app)
                return element.isHittable
            }
            let limit = viewport.height / 3
            let distance: CGFloat
            if frame.isNull || frame.isEmpty {
                distance = -limit
            } else if frame.minY < viewport.minY {
                distance = min(limit, max(44, viewport.minY - frame.minY + 24))
            } else {
                distance = -min(limit, max(44, frame.maxY - viewport.maxY + 24))
            }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let x = viewport.midX - app.frame.minX
            let y = viewport.midY - app.frame.minY
            origin.withOffset(CGVector(dx: x, dy: y - distance / 2))
                .press(forDuration: 0.05,
                       thenDragTo: origin.withOffset(CGVector(dx: x, dy: y + distance / 2)),
                       withVelocity: .slow, thenHoldForDuration: 0.15)
        }
        assertVisibleListItem(element, in: app)
        return element.isHittable
    }
    #endif

    func testEntryListAndEditorAccessibility() throws {
        let app = launchIsolatedApp()
        addEntry(in: app, merchant: "Internet", amount: "49.99")

        if #available(macOS 14.0, iOS 17.0, *) {
            try audit(in: app)
            activate(row(in: app, merchant: "Internet"))
            XCTAssertTrue(app.buttons["saveExpenseButton"].waitForExistence(timeout: 5))
            try audit(in: app)
        } else {
            throw XCTSkip("Accessibility audits require macOS 14 or iOS 17.")
        }
    }

    private func launchIsolatedApp(additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ] + additionalArguments
        app.launch()
        #if os(macOS)
        if !app.buttons["addExpenseButton"].waitForExistence(timeout: 1) {
            // macOS can restore the running app without an open test window.
            activate(app.menuBars.menuBarItems["File"])
            activate(app.menuItems["New Window"])
        }
        #endif
        XCTAssertTrue(app.buttons["addExpenseButton"].waitForExistence(timeout: 10))
        XCTAssertEqual(entryRows(in: app).count, 0, "Each launch must use a fresh isolated document.")
        return app
    }

    private func periodLayoutControls(in app: XCUIApplication) -> [(String, XCUIElement)] {
        #if os(macOS)
        let sort = app.popUpButtons["expenseSortMenu"]
        #else
        let sort = app.buttons["expenseSortMenu"]
        #endif
        return [
            ("periodKindPicker", app.descendants(matching: .any).matching(identifier: "periodKindPicker").firstMatch),
            ("previousPeriodButton", app.buttons["previousPeriodButton"]),
            ("nextPeriodButton", app.buttons["nextPeriodButton"]),
            ("expenseFilterPicker", app.descendants(matching: .any).matching(identifier: "expenseFilterPicker").firstMatch),
            ("expenseSortMenu", sort)
        ]
    }

    private func assertResetButton(_ reset: XCUIElement, in app: XCUIApplication, match expected: inout CGRect?) {
        XCTAssertTrue(reset.isHittable, "The visible reset action must be interactive.")
        let frame = reset.frame
        XCTAssertFalse(frame.isEmpty)
        #if os(iOS)
        XCTAssertGreaterThanOrEqual(frame.width, 44, "The reset action must have a full touch target.")
        XCTAssertGreaterThanOrEqual(frame.height, 44, "The reset action must have a full touch target.")
        #endif
        if let expected {
            XCTAssertEqual(frame.minX, expected.minX, accuracy: 2)
            XCTAssertEqual(frame.minY, expected.minY, accuracy: 2)
            XCTAssertEqual(frame.width, expected.width, accuracy: 2)
            XCTAssertEqual(frame.height, expected.height, accuracy: 2)
        } else {
            expected = frame
        }
        for (identifier, control) in periodLayoutControls(in: app) {
            XCTAssertFalse(frame.insetBy(dx: 1, dy: 1).intersects(control.frame.insetBy(dx: 1, dy: 1)),
                           "The visible reset action must not overlap \(identifier).")
        }
    }

    private func capturePeriodControlFrames(in app: XCUIApplication) -> [String: CGRect] {
        Dictionary(uniqueKeysWithValues: periodLayoutControls(in: app).map { identifier, element in
            XCTAssertTrue(element.waitForExistence(timeout: 5), "Missing \(identifier)")
            return (identifier, element.frame)
        })
    }

    private func assertPeriodControls(
        in app: XCUIApplication,
        match baseline: [String: CGRect],
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let controls = periodLayoutControls(in: app)
        let frames = capturePeriodControlFrames(in: app)
        let tolerance: CGFloat = 2
        for (identifier, element) in controls {
            guard let frame = frames[identifier], let original = baseline[identifier] else {
                XCTFail("\(context): missing frame for \(identifier)", file: file, line: line)
                continue
            }
            XCTAssertFalse(frame.isEmpty, "\(context): \(identifier) has an empty frame", file: file, line: line)
            XCTAssertEqual(frame.minX, original.minX, accuracy: tolerance, "\(context): \(identifier) moved horizontally", file: file, line: line)
            XCTAssertEqual(frame.minY, original.minY, accuracy: tolerance, "\(context): \(identifier) moved vertically", file: file, line: line)
            XCTAssertEqual(frame.width, original.width, accuracy: tolerance, "\(context): \(identifier) changed width", file: file, line: line)
            XCTAssertEqual(frame.height, original.height, accuracy: tolerance, "\(context): \(identifier) changed height", file: file, line: line)

            if identifier == "periodKindPicker" || identifier == "expenseFilterPicker" {
                // The native container is a group; its actionable segments must be hittable.
                let labels = identifier == "periodKindPicker" ? ["Month", "Year"] : ["All", "Scheduled", "Variable"]
                for label in labels {
                    #if os(macOS)
                    let segment = element.radioButtons[label]
                    #else
                    let segment = element.buttons[label]
                    #endif
                    XCTAssertTrue(segment.isHittable, "\(context): \(label) segment is not hittable", file: file, line: line)
                }
            } else if element.isEnabled {
                XCTAssertTrue(element.isHittable, "\(context): \(identifier) is not hittable", file: file, line: line)
            }
        }

        for firstIndex in controls.indices {
            for secondIndex in controls.indices where secondIndex > firstIndex {
                let firstID = controls[firstIndex].0
                let secondID = controls[secondIndex].0
                guard let first = frames[firstID], let second = frames[secondID] else { continue }
                XCTAssertFalse(
                    first.insetBy(dx: 1, dy: 1).intersects(second.insetBy(dx: 1, dy: 1)),
                    "\(context): \(firstID) overlaps \(secondID)", file: file, line: line
                )
            }
        }
    }

    private func addEntry(in app: XCUIApplication, merchant: String, amount: String) {
        activate(app.buttons["addExpenseButton"])
        replaceText(in: app.textFields["expenseMerchantField"], with: merchant)
        replaceText(in: app.textFields["expenseAmountField"], with: amount)
        saveEditor(in: app)
        XCTAssertTrue(row(in: app, merchant: merchant).waitForExistence(timeout: 5))
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func saveEditor(in app: XCUIApplication) {
        let save = app.buttons["saveExpenseButton"]
        expect(save, toMatch: "enabled == true")
        activate(save)
        XCTAssertTrue(save.waitForNonExistence(timeout: 5))
    }

    private func entryRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "expenseRow-"))
    }

    private func row(in app: XCUIApplication, merchant: String) -> XCUIElement {
        entryRows(in: app).matching(NSPredicate(format: "label BEGINSWITH %@", merchant + ",")).firstMatch
    }

    private func selectSegment(_ label: String, in identifier: String, app: XCUIApplication) {
        let picker = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        #if os(macOS)
        activate(picker.radioButtons[label])
        #else
        activate(picker.buttons[label])
        #endif
    }

    private func selectMenuOption(
        _ label: String, in identifier: String, app: XCUIApplication,
        expectedOptions: [String] = []
    ) {
        #if os(macOS)
        app.activate()
        activate(app.popUpButtons[identifier])
        for title in expectedOptions {
            let option = app.menuItems[title]
            XCTAssertTrue(option.waitForExistence(timeout: 5), "The menu must offer \(title).")
            XCTAssertTrue(option.isHittable, "The \(title) option must be available in the open menu.")
        }
        if !expectedOptions.isEmpty {
            attachScreenshot(of: app, named: "Available named reminder sounds")
        }
        let item = app.menuItems[label]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
        #else
        dismissEntryKeyboard(in: app)
        let picker = app.buttons[identifier]
        _ = picker.waitForExistence(timeout: 1)
        let editorPickerIdentifiers: Set<String> = [
            "expenseCategoryPicker", "entryFrequencyPicker",
            "expenseBillingDayPicker", "reminderLeadTimePicker", "reminderSoundPicker"
        ]
        let container = editorPickerIdentifiers.contains(identifier) ? editorForm(in: app) : nil
        guard revealFormControl(
            picker, in: app, inside: container,
            initiallyScrollDown: identifier == "reminderLeadTimePicker" || identifier == "reminderSoundPicker",
            searchUpward: identifier == "expenseBillingDayPicker"
        ) else { return }
        activate(picker)
        for title in expectedOptions {
            let option = app.buttons[title]
            XCTAssertTrue(option.waitForExistence(timeout: 5), "The menu must offer \(title).")
            XCTAssertTrue(option.isHittable, "The \(title) option must be available in the open menu.")
        }
        if !expectedOptions.isEmpty {
            attachScreenshot(of: app, named: "Available named reminder sounds")
        }
        activate(app.buttons[label])
        #endif
    }

    private func setReminderEnabled(_ enabled: Bool, in app: XCUIApplication) {
        let toggle = reminderToggle(in: app)
        let isOn = NSPredicate(format: "value == 1 OR value == %@", "1").evaluate(with: toggle)
        if isOn != enabled {
            #if os(iOS)
            // SwiftUI exposes the labelled row and its native switch separately.
            // Tapping the row's center can miss the trailing switch entirely.
            let nativeSwitch = toggle.switches.firstMatch
            let target = nativeSwitch.exists ? nativeSwitch : toggle
            XCTAssertTrue(target.isHittable, "The reminder switch must be directly tappable.")
            activate(target)
            #else
            activate(toggle)
            #endif
        }
        expect(toggle, toMatch: "value == %d OR value == %@", enabled ? 1 : 0, enabled ? "1" : "0")
    }

    private func assertReminderLeadTime(_ title: String, in app: XCUIApplication) {
        let picker = app.descendants(matching: .any).matching(identifier: "reminderLeadTimePicker").firstMatch
        #if os(iOS)
        guard revealFormControl(picker, in: app, inside: editorForm(in: app), initiallyScrollDown: true) else { return }
        expect(picker.staticTexts[title], toMatch: "exists == true")
        #else
        expect(picker, toMatch: "label CONTAINS %@ OR value CONTAINS %@", title, title)
        #endif
    }

    private func assertReminderSound(_ title: String, in app: XCUIApplication) {
        #if os(iOS)
        dismissEntryKeyboard(in: app)
        let picker = app.buttons["reminderSoundPicker"]
        guard revealFormControl(picker, in: app, inside: editorForm(in: app), initiallyScrollDown: true) else { return }
        // A SwiftUI Menu exposes its selected value on the control itself on
        // iPad; its visual label need not be a separate accessibility child.
        expect(picker, toMatch: "value == %@ OR label == %@", title, title)
        XCTAssertGreaterThanOrEqual(picker.frame.width, 44, "Sound must retain a full touch target.")
        XCTAssertGreaterThanOrEqual(picker.frame.height, 44, "Sound must retain a full touch target.")
        #else
        app.activate()
        let picker = app.popUpButtons["reminderSoundPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        expect(picker, toMatch: "label CONTAINS %@ OR value CONTAINS %@", title, title)
        let window = app.windows.containing(.popUpButton, identifier: "reminderSoundPicker").firstMatch
        XCTAssertTrue(window.exists, "The Sound picker must belong to a visible window.")
        let sheet = window.sheets.containing(.popUpButton, identifier: "reminderSoundPicker").firstMatch
        let windowViewport = sheet.exists ? sheet.frame.intersection(window.frame) : window.frame
        let scrollContainer = app.scrollViews.containing(.popUpButton, identifier: "reminderSoundPicker").firstMatch
        var viewport = scrollContainer.exists ? scrollContainer.frame.intersection(windowViewport) : windowViewport
        for _ in 0..<6 where scrollContainer.exists && !viewport.contains(picker.frame) {
            guard !viewport.isEmpty, viewport.height.isFinite else { break }
            let frame = picker.frame
            let distance = frame.minY < viewport.minY
                ? min(viewport.height / 3, viewport.minY - frame.minY + 12)
                : -min(viewport.height / 3, frame.maxY - viewport.maxY + 12)
            scrollContainer.scroll(byDeltaX: 0, deltaY: distance)
            viewport = scrollContainer.frame.intersection(windowViewport)
        }
        XCTAssertTrue(viewport.contains(picker.frame), "The full native Sound picker must be within its visible form: \(picker.frame), viewport: \(viewport).")
        XCTAssertGreaterThan(picker.frame.width, 0)
        XCTAssertGreaterThan(picker.frame.height, 0)
        #endif
        XCTAssertTrue(picker.isHittable, "The Sound picker must be directly usable after revealing it.")
    }

    private func reminderToggle(in app: XCUIApplication) -> XCUIElement {
        #if os(iOS)
        dismissEntryKeyboard(in: app)
        #endif
        let toggle = app.descendants(matching: .any)
            .matching(identifier: "entryReminderToggle").firstMatch
        #if os(iOS)
        _ = revealFormControl(toggle, in: app, inside: editorForm(in: app), initiallyScrollDown: true)
        #endif
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        return toggle
    }

    #if os(iOS)
    private func editorForm(in app: XCUIApplication) -> XCUIElement {
        app.collectionViews.matching(NSPredicate(format: "label == %@ OR label == %@", "Expense details", "Income details")).firstMatch
    }

    private func dismissEntryKeyboard(in app: XCUIApplication) {
        let dismissKeyboard = app.buttons["dismissEntryKeyboardButton"]
        // iPad can show only the hardware-keyboard accessory. Its Done button
        // still ends text editing even when no Keyboard element is present.
        if dismissKeyboard.exists || app.keyboards.firstMatch.exists {
            XCTAssertTrue(dismissKeyboard.waitForExistence(timeout: 3), "The editor should expose Done while text editing is active.")
            activate(dismissKeyboard)
            XCTAssertTrue(dismissKeyboard.waitForNonExistence(timeout: 3))
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        }
    }

    private func revealFormControl(
        _ control: XCUIElement, in app: XCUIApplication,
        inside suppliedContainer: XCUIElement? = nil, initiallyScrollDown: Bool = false,
        searchUpward: Bool = false
    ) -> Bool {
        let identifier = control.exists ? control.identifier : "requested form control"
        let containers: [XCUIElement]
        if let suppliedContainer {
            containers = [suppliedContainer]
        } else {
            guard control.exists else {
                XCTFail("A virtualized form control needs its known scroll container before it can be revealed.")
                return false
            }
            containers = app.collectionViews.containing(control.elementType, identifier: identifier).allElementsBoundByIndex
                + app.scrollViews.containing(control.elementType, identifier: identifier).allElementsBoundByIndex
        }
        guard let scrollContainer = containers
            .filter({ $0.exists && !$0.frame.intersection(app.frame).isEmpty })
            .min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            XCTFail("The \(identifier) control must belong to a visible, scrollable form.")
            return false
        }
        var scrollDiagnostics: [String] = []
        for attempt in 0..<8 {
            let viewport = formViewport(scrollContainer, in: app)
            let frame = control.exists ? control.frame : .null
            scrollDiagnostics.append("Attempt \(attempt + 1): control \(frame), viewport \(viewport)")
            if control.exists && viewport.contains(frame) { break }
            guard !viewport.isEmpty, viewport.height.isFinite else {
                XCTFail("The \(identifier) form has no usable viewport: \(viewport).")
                return false
            }
            let maximumMovement = viewport.height / 3
            let movement: CGFloat
            if frame.isNull || frame.isEmpty {
                // The billing-date picker is above the reminder validation
                // footer and can require several upward drags to materialize.
                // Other controls retain the bounded bidirectional search.
                movement = searchUpward || (attempt == 0 && !initiallyScrollDown)
                    ? maximumMovement : -maximumMovement
            } else if frame.minY < viewport.minY {
                movement = min(maximumMovement, max(44, viewport.minY - frame.minY + 12))
            } else {
                movement = -min(maximumMovement, max(44, frame.maxY - viewport.maxY + 12))
            }
            // Move only the clipped distance plus a small margin. Holding at
            // the end prevents a full-form swipe's momentum from overshooting.
            let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            let centerX = viewport.midX - app.frame.minX
            let centerY = viewport.midY - app.frame.minY
            let start = origin.withOffset(CGVector(dx: centerX, dy: centerY - movement / 2))
            let end = origin.withOffset(CGVector(dx: centerX, dy: centerY + movement / 2))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.15)
        }
        guard control.waitForExistence(timeout: 2) else {
            XCTFail("The \(identifier) control should appear after bounded scrolling. \(scrollDiagnostics.joined(separator: "; "))")
            return false
        }
        let finalViewport = formViewport(scrollContainer, in: app)
        let finalFrame = control.frame
        let fullyVisible = finalViewport.contains(finalFrame)
        XCTAssertTrue(
            fullyVisible,
            "The complete \(identifier) control must be inside its form viewport; a clipped label can report hittable while its value remains offscreen. Final control: \(finalFrame), viewport: \(finalViewport). \(scrollDiagnostics.joined(separator: "; "))"
        )
        XCTAssertTrue(control.isHittable, "The \(identifier) control must be hittable after bounded scrolling. Control: \(finalFrame), viewport: \(finalViewport).")
        return fullyVisible && control.isHittable
    }

    private func formViewport(_ form: XCUIElement, in app: XCUIApplication, horizontalInset: CGFloat = 1) -> CGRect {
        var viewport = form.frame.intersection(app.frame)
        // SwiftUI's Form accessibility frame can extend underneath the sheet's
        // navigation bar. Exclude that covered strip before checking a row.
        for bar in app.navigationBars.allElementsBoundByIndex where bar.isHittable {
            let frame = bar.frame
            if frame.intersects(viewport), frame.minY <= viewport.minY + frame.height {
                let top = max(viewport.minY, frame.maxY)
                viewport = CGRect(x: viewport.minX, y: top, width: viewport.width, height: max(0, viewport.maxY - top))
            }
        }
        for search in app.searchFields.allElementsBoundByIndex where search.isHittable {
            let searchFrame = search.frame
            guard searchFrame.midY > app.frame.midY, searchFrame.intersects(viewport) else { continue }
            // The native floating search field has a larger glass container.
            // Exclude that observed container, not only the text's inner frame.
            let searchIdentifier = search.identifier.isEmpty ? search.label : search.identifier
            let bubble = app.otherElements.containing(.searchField, identifier: searchIdentifier)
                .allElementsBoundByIndex
                .map(\.frame)
                .filter { $0.contains(searchFrame) && $0.height > searchFrame.height + 1 }
                .min { $0.width * $0.height < $1.width * $1.height } ?? searchFrame
            viewport.size.height = max(0, min(viewport.maxY, bubble.minY) - viewport.minY)
        }
        return viewport.insetBy(dx: horizontalInset, dy: 0)
    }
    #endif

    private func assertPeriodTotals(
        in app: XCUIApplication, income: String, outgoing: String, balance: String
    ) {
        for (identifier, amount) in [
            ("monthlyIncome", income),
            ("fixedMonthlyTotal", outgoing),
            ("monthlyBalance", balance)
        ] {
            let summary = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            XCTAssertTrue(summary.waitForExistence(timeout: 5))
            expect(summary, toMatch: "label CONTAINS %@ OR value CONTAINS %@", amount, amount)
        }
    }

    @available(macOS 14.0, iOS 17.0, *)
    private func audit(in app: XCUIApplication) throws {
        let previousFailureBehavior = continueAfterFailure
        continueAfterFailure = true
        defer { continueAfterFailure = previousFailureBehavior }
        app.activate()
        try app.performAccessibilityAudit { issue in
            let issueDescription = issue.detailedDescription
            let elementDescription = issue.element?.debugDescription ?? "No element supplied by the audit."
            let appDescription = app.debugDescription
            print("Accessibility issue details:\n\(issueDescription)")
            print("Accessibility offending element:\n\(elementDescription)")
            print("Accessibility application hierarchy:\n\(appDescription)")
            for (name, description) in [
                ("Accessibility issue details", issueDescription),
                ("Accessibility offending element", elementDescription),
                ("Accessibility application hierarchy", appDescription)
            ] {
                let attachment = XCTAttachment(string: description)
                attachment.name = name
                attachment.lifetime = .keepAlways
                self.add(attachment)
            }
            // Diagnostics must not suppress or mark the accessibility issue as handled.
            return false
        }
    }

    private func revealSearch(in app: XCUIApplication) -> XCUIElement {
        let search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 2) || !search.isHittable {
            let searchButton = app.buttons["Search"].firstMatch
            if searchButton.waitForExistence(timeout: 2) {
                activate(searchButton)
            }
        }
        XCTAssertTrue(search.waitForExistence(timeout: 5), "The native search field should be available.")
        return search
    }

    private func replaceText(in field: XCUIElement, with value: String) {
        #if os(macOS)
        XCUIApplication().activate()
        #endif
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        activate(field)
        let emptyPredicate = NSPredicate(format: "value == %@ OR value == %@", "", field.placeholderValue ?? "")
        #if os(macOS)
        field.typeKey("a", modifierFlags: .command)
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        #else
        let app = XCUIApplication()
        let numberPadDelete = app.popovers.keys["Delete"].firstMatch
        let usesNativeNumberPad = numberPadDelete.exists && numberPadDelete.isHittable
        let reportedValue = field.value as? String ?? ""
        let existingValue = reportedValue == field.placeholderValue ? "" : reportedValue
        if usesNativeNumberPad {
            // iPad's numeric popover can lose its focus lock when a hardware
            // modifier is sent. Keep editing through its visible native keys.
            for _ in 0..<existingValue.utf16.count {
                if emptyPredicate.evaluate(with: field) { break }
                numberPadDelete.tap()
            }
            if !emptyPredicate.evaluate(with: field) {
                // A tap can place the caret before the value. Select the full
                // value through the edit menu rather than sending Command-A.
                field.press(forDuration: 1)
                let selectAllMenuItem = app.menuItems["Select All"].firstMatch
                let selectAllButton = app.buttons["Select All"].firstMatch
                let selectAll = selectAllMenuItem.waitForExistence(timeout: 1)
                    ? selectAllMenuItem : selectAllButton
                guard selectAll.waitForExistence(timeout: 2), selectAll.isHittable else {
                    XCTFail("The native edit menu must offer Select All to clear \(field.identifier).")
                    return
                }
                selectAll.tap()
                let popoverDelete = app.popovers.keys["Delete"].firstMatch
                let visibleDelete = popoverDelete.exists && popoverDelete.isHittable
                    ? popoverDelete
                    : app.keys.matching(NSPredicate(format: "label ==[c] %@", "Delete"))
                        .allElementsBoundByIndex.first(where: { $0.isHittable })
                guard let delete = visibleDelete else {
                    XCTFail("A visible Delete key is required after selecting \(field.identifier).")
                    return
                }
                delete.tap()
            }
        } else if !existingValue.isEmpty {
            // On other iOS keyboards, move to the end before deleting. A
            // placeholder reported as the value adds only empty deletes.
            field.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: .command)
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existingValue.utf16.count))
        }
        #endif
        let cleared = XCTNSPredicateExpectation(predicate: emptyPredicate, object: field)
        guard XCTWaiter.wait(for: [cleared], timeout: 5) == .completed else {
            XCTFail("The \(field.identifier) field must be empty before replacement text is entered.")
            return
        }
        if !value.isEmpty {
            #if os(iOS)
            if usesNativeNumberPad && value.allSatisfy({ app.popovers.keys[String($0)].firstMatch.exists }) {
                for character in value {
                    let key = app.popovers.keys[String(character)].firstMatch
                    XCTAssertTrue(key.isHittable, "The native number-pad key \(character) must be visible.")
                    key.tap()
                }
            } else {
                field.typeText(value)
            }
            #else
            field.typeText(value)
            #endif
        }
        if value.isEmpty {
            expect(field, toMatch: "value == %@ OR value == %@", "", field.placeholderValue ?? "")
        } else {
            expect(field, toMatch: "value == %@", value)
        }
    }

    private func activate(_ element: XCUIElement) {
        #if os(macOS)
        // Reactivation while a native menu is tracking can dismiss it before
        // its item is selected, so keep an already-open menu uninterrupted.
        if element.elementType != .menuItem { XCUIApplication().activate() }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        element.click()
        #else
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        element.tap()
        #endif
    }

    private func expect(
        _ element: XCUIElement,
        toMatch format: String,
        _ arguments: CVarArg...,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: format, argumentArray: arguments)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
            "Expected \(element.identifier) to satisfy \(predicate)",
            file: file, line: line
        )
    }
}
