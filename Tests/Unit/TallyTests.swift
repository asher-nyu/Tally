import Foundation
import Testing
@testable import Tally

nonisolated struct TallyTests {
    private let us = Locale(identifier: "en_US")

    @Test func codecRoundTripPreservesExactValues() throws {
        let ledger = Ledger(expenses: [
            Expense(merchant: "Café 示例", amountMinor: 12_345, billingDay: 31, category: .food, notes: "Fictional example.\nSecond line."),
            Expense(merchant: "Variable example"),
            Expense(merchant: "Fictional income", amountMinor: 123_456, billingDay: 1, category: .income, kind: .income)
        ])
        let encoded = try LedgerCodec.encode(ledger)
        #expect(try LedgerCodec.decode(encoded) == ledger)
        #expect(try LedgerCodec.encode(ledger) == encoded)
    }

    @Test func codecAcceptsExplicitNullAndMissingOptionalValues() throws {
        let ledger = Ledger(expenses: [Expense(merchant: "Example")])
        let encoded = try LedgerCodec.encode(ledger)
        var root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var rows = try #require(root["expenses"] as? [[String: Any]])
        rows[0]["amountMinor"] = NSNull()
        rows[0]["billingDay"] = NSNull()
        rows[0].removeValue(forKey: "kind")
        root["expenses"] = rows
        #expect(try LedgerCodec.decode(JSONSerialization.data(withJSONObject: root)) == ledger)
        #expect(try LedgerCodec.decode(encoded).expenses[0].amountMinor == nil)
        #expect(try LedgerCodec.decode(JSONSerialization.data(withJSONObject: root)).expenses[0].kind == .expense)
    }

    @Test(arguments: ["", "not JSON", "{}", "[]", "{\"formatVersion\":1}", "{\"formatVersion\":\"1\"}"])
    func codecRejectsMalformedData(_ json: String) {
        #expect(throws: LedgerError.corruptFile) { try LedgerCodec.decode(Data(json.utf8)) }
    }

    @Test func codecRecognizesFutureVersionBeforeReadingPayload() {
        #expect(throws: LedgerError.unsupportedVersion(99)) {
            try LedgerCodec.decode(Data(#"{"formatVersion":99,"futureSchema":true}"#.utf8))
        }
    }

    @Test func codecRejectsOversizedFileBeforeParsing() {
        let data = Data(repeating: 0x20, count: LedgerCodec.maximumFileBytes + 1)
        #expect(throws: LedgerError.fileTooLarge) { try LedgerCodec.decode(data) }
    }

    @Test(arguments: ["ZZZ", "usd", "", "US"])
    func codecRejectsUnsupportedCurrency(_ code: String) {
        #expect(throws: LedgerError.unsupportedCurrency(code)) { try LedgerCodec.encode(Ledger(currencyCode: code)) }
    }

    @Test func codecRejectsDuplicateExpenseIdentifiers() {
        let row = Expense(merchant: "Example")
        #expect(throws: LedgerError.duplicateExpenseID) { try LedgerCodec.encode(Ledger(expenses: [row, row])) }
    }

    @Test(arguments: ["", " \n\t ", String(repeating: "a", count: LedgerCodec.maximumMerchantLength + 1)])
    func codecRejectsInvalidMerchant(_ merchant: String) {
        #expect(throws: LedgerError.invalidMerchant) { try LedgerCodec.encode(Ledger(expenses: [Expense(merchant: merchant)])) }
    }

    @Test func codecEnforcesAmountBoundsWithoutRounding() throws {
        for value in [-1, LedgerCodec.maximumAmountMinor + 1, Int64.max] {
            #expect(throws: LedgerError.amountOutOfRange) {
                try LedgerCodec.encode(Ledger(expenses: [Expense(merchant: "Example", amountMinor: value)]))
            }
        }
        let ledger = Ledger(expenses: [Expense(merchant: "Zero", amountMinor: 0), Expense(merchant: "Limit", amountMinor: LedgerCodec.maximumAmountMinor)])
        #expect(try LedgerCodec.decode(LedgerCodec.encode(ledger)) == ledger)
    }

    @Test(arguments: [0, -1, 32, Int.max])
    func codecRejectsInvalidBillingDay(_ day: Int) {
        #expect(throws: LedgerError.invalidBillingDay) {
            try LedgerCodec.encode(Ledger(expenses: [Expense(merchant: "Example", billingDay: day)]))
        }
    }

    @Test func codecEnforcesNotesAndRowCountLimits() {
        let notes = String(repeating: "x", count: LedgerCodec.maximumNotesLength + 1)
        #expect(throws: LedgerError.notesTooLong) { try LedgerCodec.encode(Ledger(expenses: [Expense(merchant: "Example", notes: notes)])) }
        let rows = (0...LedgerCodec.maximumExpenseCount).map { Expense(merchant: "Example \($0)") }
        #expect(throws: LedgerError.tooManyExpenses) { try LedgerCodec.encode(Ledger(expenses: rows)) }
    }

    @Test func moneyParsesExactMinorUnitsAndBlankAmounts() throws {
        #expect(try Money.parse("1,234.56", currencyCode: "USD", locale: us) == 123_456)
        #expect(try Money.parse("0.29", currencyCode: "USD", locale: us) == 29)
        #expect(try Money.parse(".5", currencyCode: "USD", locale: us) == 50)
        #expect(try Money.parse(" 0 ", currencyCode: "USD", locale: us) == 0)
        #expect(try Money.parse(" \n ", currencyCode: "USD", locale: us) == nil)
    }

    @Test func moneyRespectsLocaleDecimalAndGroupingSeparators() throws {
        #expect(try Money.parse("1.234,56", currencyCode: "EUR", locale: Locale(identifier: "de_DE")) == 123_456)
        #expect(try Money.parse("1 234,56", currencyCode: "EUR", locale: Locale(identifier: "fr_FR")) == 123_456)
        #expect(try Money.parse("12,34,567.89", currencyCode: "INR", locale: Locale(identifier: "en_IN")) == 123_456_789)
        #expect(try Money.parse("١٢٣٫٤٥", currencyCode: "USD", locale: Locale(identifier: "ar_EG")) == 12_345)
    }

    @Test(arguments: ["-1.00", "1e2", "NaN", "$1.00", "12,34.00", "1,234,", "1.2.3", ".", "1 2", "9999999999999999999999999999999999"])
    func moneyRejectsAmbiguousOrInvalidInput(_ value: String) {
        #expect(throws: (any Error).self) { try Money.parse(value, currencyCode: "USD", locale: us) }
    }

    @Test func moneyUsesCurrencyMinorUnitPrecision() throws {
        #expect(try Money.parse("123", currencyCode: "JPY", locale: us) == 123)
        #expect(try Money.parse("1.234", currencyCode: "KWD", locale: us) == 1_234)
        #expect(throws: MoneyError.tooManyFractionDigits(0)) { try Money.parse("1.5", currencyCode: "JPY", locale: us) }
        #expect(throws: MoneyError.tooManyFractionDigits(2)) { try Money.parse("1.001", currencyCode: "USD", locale: us) }
        #expect(throws: MoneyError.unsupportedCurrency) { try Money.parse("1", currencyCode: "XXX", locale: us) }
    }

    @Test func moneyFormattingKeepsEveryMinorUnit() throws {
        for code in Currency.supportedCodes {
            for locale in [us, Locale(identifier: "de_DE")] {
                for value in [Int64(0), 1, 29, 123_456, LedgerCodec.maximumAmountMinor] {
                    let text = Money.inputString(value, currencyCode: code, locale: locale)
                    #expect(try Money.parse(text, currencyCode: code, locale: locale) == value)
                }
            }
        }
        #expect(Money.format(123_456, currencyCode: "USD", locale: us) == "$1,234.56")
        #expect(Money.format(nil, currencyCode: "USD", locale: us) == "Variable")
        #expect(Money.inputString(nil, currencyCode: "USD", locale: us).isEmpty)
    }

    @Test func totalsExcludeVariableAmountsAndRemainExactAtBounds() throws {
        let ledger = Ledger(expenses: [
            Expense(merchant: "One", amountMinor: 10_099),
            Expense(merchant: "Two", amountMinor: 101),
            Expense(merchant: "Varies"),
            Expense(merchant: "Fictional income", amountMinor: 20_000, kind: .income),
            Expense(merchant: "Variable income", kind: .income)
        ])
        #expect(ledger.knownMonthlyTotalMinor == 10_200)
        #expect(ledger.knownMonthlyIncomeMinor == 20_000)
        #expect(ledger.knownMonthlyBalanceMinor == 9_800)
        #expect(ledger.variableExpenseCount == 1)
        #expect(ledger.variableIncomeCount == 1)
        let maximum = Ledger(expenses: (0..<LedgerCodec.maximumExpenseCount).map { Expense(merchant: "Example \($0)", amountMinor: LedgerCodec.maximumAmountMinor) })
        try LedgerCodec.validate(maximum)
        #expect(maximum.knownMonthlyTotalMinor == LedgerCodec.maximumAmountMinor * Int64(LedgerCodec.maximumExpenseCount))
        #expect(maximum.knownMonthlyBalanceMinor == -maximum.knownMonthlyTotalMinor)
    }

    @Test func dueDateIncludesTodayAndAdvancesAfterItPasses() {
        let row = Expense(merchant: "Example", billingDay: 15)
        #expect(row.nextDue(onOrAfter: date(2026, 9, 15, hour: 22), calendar: calendar()) == date(2026, 9, 15))
        #expect(row.nextDue(onOrAfter: date(2026, 9, 16), calendar: calendar()) == date(2026, 10, 15))
    }

    @Test func dueDateClamps31ToFebruaryAndReturnsTo31InMarch() {
        let row = Expense(merchant: "Example", billingDay: 31)
        #expect(row.nextDue(onOrAfter: date(2024, 2, 1), calendar: calendar()) == date(2024, 2, 29))
        #expect(row.nextDue(onOrAfter: date(2025, 2, 1), calendar: calendar()) == date(2025, 2, 28))
        #expect(row.nextDue(onOrAfter: date(2025, 3, 1), calendar: calendar()) == date(2025, 3, 31))
        #expect(row.nextDue(onOrAfter: date(2026, 4, 30, hour: 20), calendar: calendar()) == date(2026, 4, 30))
    }

    @Test func dueDateUsesCalendarAcrossDaylightSavingAndYearBoundary() {
        #expect(Expense(merchant: "Spring", billingDay: 10).nextDue(onOrAfter: date(2024, 3, 1), calendar: calendar()) == date(2024, 3, 10))
        #expect(Expense(merchant: "Fall", billingDay: 3).nextDue(onOrAfter: date(2024, 11, 3, hour: 18), calendar: calendar()) == date(2024, 11, 3))
        #expect(Expense(merchant: "New year", billingDay: 1).nextDue(onOrAfter: date(2026, 12, 31), calendar: calendar()) == date(2027, 1, 1))
    }

    @Test func variableOrInvalidBillingDayHasNoInventedDueDate() {
        for day in [nil, 0, 32] as [Int?] {
            #expect(Expense(merchant: "Example", billingDay: day).nextDue(onOrAfter: date(2026, 1, 1), calendar: calendar()) == nil)
        }
    }

    @Test func mergeCombinesIndependentChanges() throws {
        let base = Ledger(expenses: [Expense(merchant: "One", amountMinor: 100), Expense(merchant: "Two", amountMinor: 200)])
        var local = base
        var remote = base
        local.expenses[0].amountMinor = 101
        remote.expenses[1].notes = "Updated elsewhere"
        remote.expenses.append(Expense(merchant: "Added elsewhere"))
        let merged = try LedgerMerger.merge(base: base, local: local, remote: remote)
        #expect(merged.expenses == [local.expenses[0], remote.expenses[1], remote.expenses[2]])
    }

    @Test func mergeRetainsCompetingEditsInMarkedDeterministicCopy() throws {
        let base = Ledger(expenses: [Expense(merchant: String(repeating: "x", count: LedgerCodec.maximumMerchantLength), amountMinor: 100)])
        var local = base
        var remote = base
        local.expenses[0].amountMinor = 200
        remote.expenses[0].amountMinor = 300
        let merged = try LedgerMerger.merge(base: base, local: local, remote: remote)
        #expect(merged.expenses.count == 2)
        #expect(merged.expenses[0] == local.expenses[0])
        #expect(merged.expenses[1].merchant.hasSuffix(" (conflicting copy)"))
        #expect(merged.expenses[1].merchant.count == LedgerCodec.maximumMerchantLength)
        #expect(merged.expenses[1].amountMinor == 300)
        #expect(merged.expenses[1].id != base.expenses[0].id)
        #expect(try LedgerMerger.merge(base: base, local: local, remote: remote) == merged)
        #expect(try LedgerMerger.merge(base: base, local: merged, remote: remote) == merged)
    }

    @Test func mergePreservesConcurrentEditsAgainstDeletion() throws {
        let base = Ledger(expenses: [Expense(merchant: "Example", amountMinor: 100)])
        var deleted = base
        deleted.expenses = []
        var edited = base
        edited.expenses[0].amountMinor = 200
        #expect(try LedgerMerger.merge(base: base, local: deleted, remote: edited).expenses == edited.expenses)
        #expect(try LedgerMerger.merge(base: base, local: edited, remote: deleted).expenses == edited.expenses)
        #expect(try LedgerMerger.merge(base: base, local: deleted, remote: base).expenses.isEmpty)
        #expect(try LedgerMerger.merge(base: base, local: deleted, remote: deleted).expenses.isEmpty)
    }

    @Test func mergeRejectsIncompatibleIdentitiesAndConcurrentCurrencyChanges() {
        let base = Ledger(expenses: [Expense(merchant: "Example", amountMinor: 100)])
        var local = base
        local.currencyCode = "EUR"
        var remote = base
        remote.expenses[0].amountMinor = 200
        #expect(throws: LedgerMergeError.differentCurrencies) { try LedgerMerger.merge(base: base, local: local, remote: remote) }
        #expect(throws: LedgerMergeError.differentLedger) { try LedgerMerger.merge(base: base, local: local, remote: Ledger()) }
    }

    @Test func versionOneFilesUpgradeToMonthlySchedulesWithoutChangingAmounts() throws {
        let original = Ledger(expenses: [Expense(merchant: "Fictional monthly entry", amountMinor: 12_345, billingDay: 31)])
        var json = try #require(JSONSerialization.jsonObject(with: LedgerCodec.encode(original)) as? [String: Any])
        json["formatVersion"] = 1
        var rows = try #require(json["expenses"] as? [[String: Any]])
        rows[0].removeValue(forKey: "recurrence")
        rows[0].removeValue(forKey: "anchorDate")
        rows[0].removeValue(forKey: "kind")
        json["expenses"] = rows

        let upgraded = try LedgerCodec.decode(JSONSerialization.data(withJSONObject: json))

        #expect(upgraded == original)
        #expect(upgraded.formatVersion == LedgerCodec.currentFormatVersion)
        #expect(upgraded.expenses[0].recurrence == .monthly)
        #expect(upgraded.expenses[0].anchorDate == nil)
        #expect(upgraded.totals(inYearContaining: date(2026, 1, 1), calendar: calendar()).expenseMinor == 12_345 * 12)
    }

    @Test func everyRecurrenceRoundTripsWithCalendarOnlyAnchors() throws {
        let ledger = Ledger(expenses: [
            Expense(merchant: "Fictional monthly entry", amountMinor: 1, billingDay: 31),
            Expense(merchant: "Fictional payday", amountMinor: 2, kind: .income, recurrence: .everyTwoWeeks, anchorDate: ScheduleDate(year: 2026, month: 1, day: 2)),
            Expense(merchant: "Fictional annual bonus", amountMinor: 3, kind: .income, recurrence: .annual, anchorDate: ScheduleDate(year: 2024, month: 2, day: 29)),
            Expense(merchant: "Fictional purchase", amountMinor: 4, recurrence: .oneTime, anchorDate: ScheduleDate(year: 2027, month: 4, day: 15))
        ])
        #expect(try LedgerCodec.decode(LedgerCodec.encode(ledger)) == ledger)
    }

    @Test func nonmonthlySchedulesRequireValidAnchorDates() {
        for recurrence in [Recurrence.everyTwoWeeks, .annual, .oneTime] {
            #expect(throws: LedgerError.invalidSchedule) {
                try LedgerCodec.encode(Ledger(expenses: [Expense(merchant: "Fictional entry", recurrence: recurrence)]))
            }
        }
        for anchor in [ScheduleDate(year: 2025, month: 2, day: 29), ScheduleDate(year: 2026, month: 4, day: 31), ScheduleDate(year: 0, month: 1, day: 1), ScheduleDate(year: 10_000, month: 1, day: 1)] {
            #expect(throws: LedgerError.invalidSchedule) {
                try LedgerCodec.encode(Ledger(expenses: [Expense(merchant: "Fictional entry", recurrence: .annual, anchorDate: anchor)]))
            }
        }
    }

    @Test func biweeklyPaydaysProduceTwoOrThreeActualPaymentsPerMonth() {
        let entry = Expense(merchant: "Fictional payday", amountMinor: 100_001, kind: .income, recurrence: .everyTwoWeeks, anchorDate: ScheduleDate(year: 2026, month: 1, day: 2))
        #expect(entry.occurrences(inMonthContaining: date(2026, 1, 20), calendar: calendar()) == [date(2026, 1, 2), date(2026, 1, 16), date(2026, 1, 30)])
        #expect(entry.occurrences(inMonthContaining: date(2026, 2, 1), calendar: calendar()) == [date(2026, 2, 13), date(2026, 2, 27)])
        let ledger = Ledger(expenses: [entry])
        #expect(ledger.totals(inMonthContaining: date(2026, 1, 1), calendar: calendar()).incomeMinor == 300_003)
        #expect(ledger.totals(inMonthContaining: date(2026, 2, 1), calendar: calendar()).incomeMinor == 200_002)
        #expect(entry.occurrenceCount(inYearContaining: date(2026, 7, 1), calendar: calendar()) == 26)
        #expect(entry.occurrenceCount(inYearContaining: date(2025, 7, 1), calendar: calendar()) == 0)
    }

    @Test func biweeklyYearCanContainTwentySevenPayments() {
        let entry = Expense(merchant: "Fictional payday", amountMinor: 1_001, kind: .income, recurrence: .everyTwoWeeks, anchorDate: ScheduleDate(year: 2027, month: 1, day: 1))
        let dates = entry.occurrences(inYearContaining: date(2027, 6, 1), calendar: calendar())
        #expect(dates.count == 27)
        #expect(dates.first == date(2027, 1, 1))
        #expect(dates.last == date(2027, 12, 31))
        #expect(Ledger(expenses: [entry]).totals(inYearContaining: date(2027, 6, 1), calendar: calendar()).incomeMinor == 27_027)
    }

    @Test func biweeklyDatesUseCalendarDaysAcrossDaylightSaving() {
        let entry = Expense(merchant: "Fictional payday", recurrence: .everyTwoWeeks, anchorDate: ScheduleDate(year: 2024, month: 3, day: 3))
        #expect(entry.nextDue(onOrAfter: date(2024, 3, 4), calendar: calendar()) == date(2024, 3, 17))
        #expect(entry.nextDue(onOrAfter: date(2024, 3, 17, hour: 22), calendar: calendar()) == date(2024, 3, 17))
        #expect(entry.nextDue(onOrAfter: date(2024, 3, 18), calendar: calendar()) == date(2024, 3, 31))
        let fall = Expense(merchant: "Fictional payday", recurrence: .everyTwoWeeks, anchorDate: ScheduleDate(year: 2024, month: 10, day: 27))
        #expect(fall.nextDue(onOrAfter: date(2024, 10, 28), calendar: calendar()) == date(2024, 11, 10))
    }

    @Test func annualPaymentsCountOnlyInTheirMonthAndStartYear() {
        let entry = Expense(merchant: "Fictional annual subscription", amountMinor: 12_001, recurrence: .annual, anchorDate: ScheduleDate(year: 2026, month: 10, day: 15))
        let ledger = Ledger(expenses: [entry])
        #expect(ledger.totals(inMonthContaining: date(2026, 9, 1), calendar: calendar()).expenseMinor == 0)
        #expect(ledger.totals(inMonthContaining: date(2026, 10, 1), calendar: calendar()).expenseMinor == 12_001)
        #expect(ledger.totals(inYearContaining: date(2026, 1, 1), calendar: calendar()).expenseMinor == 12_001)
        #expect(ledger.totals(inYearContaining: date(2025, 1, 1), calendar: calendar()).expenseMinor == 0)
        #expect(entry.nextDue(onOrAfter: date(2026, 10, 16), calendar: calendar()) == date(2027, 10, 15))
    }

    @Test func annualLeapDayClampsAndReturnsToLeapDay() {
        let entry = Expense(merchant: "Fictional annual bonus", recurrence: .annual, anchorDate: ScheduleDate(year: 2024, month: 2, day: 29))
        #expect(entry.nextDue(onOrAfter: date(2023, 1, 1), calendar: calendar()) == date(2024, 2, 29))
        #expect(entry.occurrences(inYearContaining: date(2025, 1, 1), calendar: calendar()) == [date(2025, 2, 28)])
        #expect(entry.nextDue(onOrAfter: date(2025, 2, 28, hour: 20), calendar: calendar()) == date(2025, 2, 28))
        #expect(entry.occurrences(inYearContaining: date(2028, 1, 1), calendar: calendar()) == [date(2028, 2, 29)])
    }

    @Test func oneTimePaymentsBelongOnlyToTheirExactPeriod() {
        let entry = Expense(merchant: "Fictional one-time bonus", amountMinor: 50_123, kind: .income, recurrence: .oneTime, anchorDate: ScheduleDate(year: 2026, month: 12, day: 31))
        #expect(entry.nextDue(onOrAfter: date(2026, 12, 31, hour: 23), calendar: calendar()) == date(2026, 12, 31))
        #expect(entry.nextDue(onOrAfter: date(2027, 1, 1), calendar: calendar()) == nil)
        #expect(entry.occurrenceCount(inMonthContaining: date(2026, 12, 1), calendar: calendar()) == 1)
        #expect(entry.occurrenceCount(inMonthContaining: date(2027, 1, 1), calendar: calendar()) == 0)
        #expect(entry.occurrenceCount(inYearContaining: date(2027, 1, 1), calendar: calendar()) == 0)
        #expect(Ledger(expenses: [entry]).totals(inYearContaining: date(2026, 1, 1), calendar: calendar()).incomeMinor == 50_123)
    }

    @Test func monthlyVariableDatesHaveAmountsWithoutInventedOccurrences() {
        let entry = Expense(merchant: "Fictional undated bill", amountMinor: 101)
        #expect(entry.occurrences(inMonthContaining: date(2026, 1, 1), calendar: calendar()).isEmpty)
        #expect(entry.occurrenceCount(inMonthContaining: date(2026, 1, 1), calendar: calendar()) == 1)
        #expect(entry.occurrenceCount(inYearContaining: date(2026, 1, 1), calendar: calendar()) == 12)
        #expect(Ledger(expenses: [entry]).totals(inYearContaining: date(2026, 1, 1), calendar: calendar()).expenseMinor == 1_212)
    }

    @Test func mixedSchedulesHaveExactPeriodTotalsAndVariableOccurrenceCounts() {
        let ledger = Ledger(expenses: [
            Expense(merchant: "Fictional monthly bill", amountMinor: 10_001),
            Expense(merchant: "Fictional annual subscription", amountMinor: 12_001, recurrence: .annual, anchorDate: ScheduleDate(year: 2026, month: 1, day: 15)),
            Expense(merchant: "Fictional payday", amountMinor: 100_001, kind: .income, recurrence: .everyTwoWeeks, anchorDate: ScheduleDate(year: 2026, month: 1, day: 2)),
            Expense(merchant: "Fictional annual bonus", amountMinor: 50_001, kind: .income, recurrence: .annual, anchorDate: ScheduleDate(year: 2026, month: 12, day: 1)),
            Expense(merchant: "Variable fortnightly income", kind: .income, recurrence: .everyTwoWeeks, anchorDate: ScheduleDate(year: 2026, month: 1, day: 2)),
            Expense(merchant: "Variable monthly bill")
        ])
        let january = ledger.totals(inMonthContaining: date(2026, 1, 1), calendar: calendar())
        #expect(january.incomeMinor == 300_003)
        #expect(january.expenseMinor == 22_002)
        #expect(january.balanceMinor == 278_001)
        #expect(january.variableIncomeCount == 3)
        #expect(january.variableExpenseCount == 1)
        let year = ledger.totals(inYearContaining: date(2026, 1, 1), calendar: calendar())
        #expect(year.incomeMinor == 2_650_027)
        #expect(year.expenseMinor == 132_013)
        #expect(year.balanceMinor == 2_518_014)
        #expect(year.variableIncomeCount == 26)
        #expect(year.variableExpenseCount == 12)
    }

    @Test func calendarOnlyAnchorsKeepTheirLocalDayAcrossTimeZones() throws {
        let anchor = ScheduleDate(year: 2026, month: 1, day: 2)
        for zone in ["America/New_York", "Pacific/Honolulu", "Asia/Tokyo"] {
            var local = Calendar(identifier: .gregorian)
            local.timeZone = try #require(TimeZone(identifier: zone))
            let localDate = try #require(anchor.date(calendar: local))
            #expect(ScheduleDate(date: localDate, calendar: local) == anchor)
            let entry = Expense(merchant: "Fictional entry", recurrence: .oneTime, anchorDate: anchor)
            #expect(entry.nextDue(onOrAfter: localDate, calendar: local) == localDate)
        }
    }

    @Test func yearlyTotalsStayExactAtMaximumSupportedBounds() throws {
        let rows = (0..<LedgerCodec.maximumExpenseCount).map {
            Expense(merchant: "Fictional payday \($0)", amountMinor: LedgerCodec.maximumAmountMinor, kind: .income, recurrence: .everyTwoWeeks, anchorDate: ScheduleDate(year: 2027, month: 1, day: 1))
        }
        let ledger = Ledger(expenses: rows)
        try LedgerCodec.validate(ledger)
        let totals = ledger.totals(inYearContaining: date(2027, 1, 1), calendar: calendar())
        #expect(totals.incomeMinor == LedgerCodec.maximumAmountMinor * Int64(LedgerCodec.maximumExpenseCount) * 27)
        #expect(totals.balanceMinor == totals.incomeMinor)
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
}
