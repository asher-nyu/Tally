import Foundation
import Testing
@testable import Tally

nonisolated struct CustomRecurrenceTests {
    @Test func quarterlyPaymentsUseActualMonthsAndExactAmounts() {
        let entry = entry(.init(frequency: .monthly, interval: 3, monthDays: [15]), amount: 1_001)
        #expect(entry.occurrences(inYearContaining: date(2026, 1, 1), calendar: calendar()) == [
            date(2026, 1, 15), date(2026, 4, 15), date(2026, 7, 15), date(2026, 10, 15)
        ])
        let ledger = Ledger(expenses: [entry])
        #expect(ledger.totals(inMonthContaining: date(2026, 2, 1), calendar: calendar()).expenseMinor == 0)
        #expect(ledger.totals(inMonthContaining: date(2026, 4, 1), calendar: calendar()).expenseMinor == 1_001)
        #expect(ledger.totals(inYearContaining: date(2026, 1, 1), calendar: calendar()).expenseMinor == 4_004)
    }

    @Test func twiceMonthlyIncomeStartsOnFirstEligibleDate() {
        let entry = entry(.init(frequency: .monthly, monthDays: [1, 15]), anchor: .init(year: 2026, month: 1, day: 10), amount: 100_001, kind: .income)
        #expect(entry.occurrences(inMonthContaining: date(2026, 1, 1), calendar: calendar()) == [date(2026, 1, 15)])
        #expect(entry.occurrences(inMonthContaining: date(2026, 2, 1), calendar: calendar()) == [date(2026, 2, 1), date(2026, 2, 15)])
        #expect(entry.occurrenceCount(inYearContaining: date(2026, 1, 1), calendar: calendar()) == 23)
        #expect(Ledger(expenses: [entry]).totals(inYearContaining: date(2027, 1, 1), calendar: calendar()).incomeMinor == 2_400_024)
    }

    @Test func clampedMonthDaysDeduplicateOnlyOverlappingDates() {
        let entry = entry(.init(frequency: .monthly, monthDays: [31, 28, 30, 29]), anchor: .init(year: 2024, month: 1, day: 1))
        #expect(entry.occurrences(inMonthContaining: date(2024, 2, 1), calendar: calendar()) == [date(2024, 2, 28), date(2024, 2, 29)])
        #expect(entry.occurrences(inMonthContaining: date(2025, 2, 1), calendar: calendar()) == [date(2025, 2, 28)])
        #expect(entry.occurrences(inMonthContaining: date(2025, 3, 1), calendar: calendar()) == [
            date(2025, 3, 28), date(2025, 3, 29), date(2025, 3, 30), date(2025, 3, 31)
        ])
        #expect(Ledger(expenses: [entry]).totals(inMonthContaining: date(2025, 2, 1), calendar: calendar()).variableExpenseCount == 1)
    }

    @Test func monthlyRuleDoesNotInventAnOccurrenceOnTheAnchor() {
        let entry = entry(.init(frequency: .monthly, monthDays: [5]), anchor: .init(year: 2026, month: 1, day: 31))
        #expect(entry.nextDue(onOrAfter: date(2025, 1, 1), calendar: calendar()) == date(2026, 2, 5))
        #expect(entry.occurrenceCount(inYearContaining: date(2026, 1, 1), calendar: calendar()) == 11)
    }

    @Test func multiWeekdayRulesUseSundayAnchoredWeeksRegardlessOfLocale() {
        let entry = entry(.init(frequency: .weekly, interval: 2, weekdays: [5, 1, 2]), anchor: .init(year: 2026, month: 1, day: 7))
        let expected = [date(2026, 1, 8), date(2026, 1, 18), date(2026, 1, 19), date(2026, 1, 22)]
        var mondayFirst = calendar()
        mondayFirst.firstWeekday = 2
        mondayFirst.minimumDaysInFirstWeek = 4
        mondayFirst.locale = Locale(identifier: "en_GB")
        #expect(entry.occurrences(inMonthContaining: date(2026, 1, 1), calendar: mondayFirst) == expected)
        #expect(entry.occurrenceCount(inMonthContaining: date(2026, 1, 1), calendar: mondayFirst) == 4)
        #expect(entry.nextDue(onOrAfter: date(2026, 1, 23), calendar: mondayFirst) == date(2026, 2, 1))
    }

    @Test func weeklyIntervalsContinueAcrossYearBoundaries() {
        let entry = entry(.init(frequency: .weekly, interval: 2, weekdays: [1, 6]), anchor: .init(year: 2025, month: 12, day: 31))
        #expect(entry.occurrences(inMonthContaining: date(2026, 1, 1), calendar: calendar()) == [
            date(2026, 1, 2), date(2026, 1, 11), date(2026, 1, 16), date(2026, 1, 25), date(2026, 1, 30)
        ])
        #expect(entry.occurrenceCount(inMonthContaining: date(2026, 1, 1), calendar: calendar()) == 5)
    }

    @Test func lastFridayRuleFindsActualMonthEnds() {
        let entry = entry(.init(frequency: .monthly, ordinal: -1, ordinalWeekday: 6))
        #expect(entry.nextDue(onOrAfter: date(2026, 1, 1), calendar: calendar()) == date(2026, 1, 30))
        #expect(entry.nextDue(onOrAfter: date(2026, 1, 31), calendar: calendar()) == date(2026, 2, 27))
        #expect(entry.nextDue(onOrAfter: date(2026, 2, 28), calendar: calendar()) == date(2026, 3, 27))
        #expect(entry.occurrenceCount(inYearContaining: date(2026, 1, 1), calendar: calendar()) == 12)
    }

    @Test func fifthWeekdaySkipsMonthsWithoutAValidDate() {
        let entry = entry(.init(frequency: .monthly, ordinal: 5, ordinalWeekday: 2))
        #expect(entry.occurrences(inMonthContaining: date(2026, 2, 1), calendar: calendar()).isEmpty)
        #expect(entry.nextDue(onOrAfter: date(2026, 1, 1), calendar: calendar()) == date(2026, 3, 30))
        #expect(entry.nextDue(onOrAfter: date(2026, 3, 31), calendar: calendar()) == date(2026, 6, 29))
    }

    @Test func yearlySelectedMonthsUseAnchorDayAndInterval() {
        let entry = entry(.init(frequency: .yearly, interval: 2, months: [11, 2, 8, 5]), anchor: .init(year: 2026, month: 5, day: 31))
        #expect(entry.occurrences(inYearContaining: date(2026, 1, 1), calendar: calendar()) == [date(2026, 5, 31), date(2026, 8, 31), date(2026, 11, 30)])
        #expect(entry.occurrenceCount(inYearContaining: date(2027, 1, 1), calendar: calendar()) == 0)
        #expect(entry.occurrences(inYearContaining: date(2028, 1, 1), calendar: calendar()) == [
            date(2028, 2, 29), date(2028, 5, 31), date(2028, 8, 31), date(2028, 11, 30)
        ])
    }

    @Test func yearlyLeapDayReturnsAfterNonLeapClamping() {
        let entry = entry(.init(frequency: .yearly, months: [2]), anchor: .init(year: 2024, month: 2, day: 29))
        #expect(entry.nextDue(onOrAfter: date(2024, 3, 1), calendar: calendar()) == date(2025, 2, 28))
        #expect(entry.occurrences(inYearContaining: date(2028, 1, 1), calendar: calendar()) == [date(2028, 2, 29)])
    }

    @Test func yearlyOrdinalAppliesToEverySelectedMonth() {
        let entry = entry(.init(frequency: .yearly, interval: 2, months: [1, 7], ordinal: 1, ordinalWeekday: 2))
        #expect(entry.occurrences(inYearContaining: date(2026, 1, 1), calendar: calendar()) == [date(2026, 1, 5), date(2026, 7, 6)])
        #expect(entry.occurrences(inYearContaining: date(2028, 1, 1), calendar: calendar()) == [date(2028, 1, 3), date(2028, 7, 3)])
    }

    @Test func impossibleFifthWeekdayCycleTerminatesWithoutPhantomPayments() {
        // February 2026 has four Mondays. A 400-year interval repeats that
        // same Gregorian pattern forever, so this valid selection has no dates.
        let entry = entry(.init(frequency: .yearly, interval: 400, months: [2], ordinal: 5, ordinalWeekday: 2))
        #expect(entry.nextDue(onOrAfter: date(2026, 1, 1), calendar: calendar()) == nil)
        #expect(entry.occurrenceCount(inYearContaining: date(2026, 1, 1), calendar: calendar()) == 0)
    }

    @Test func dailyIntervalsIncludeTheirEndDateAndKeepTodayDue() {
        let entry = entry(.init(frequency: .daily, interval: 3, endDate: .init(year: 2026, month: 10, day: 3)), anchor: .init(year: 2026, month: 9, day: 27))
        #expect(entry.occurrences(inMonthContaining: date(2026, 9, 1), calendar: calendar()) == [date(2026, 9, 27), date(2026, 9, 30)])
        #expect(entry.nextDue(onOrAfter: date(2026, 10, 3, hour: 23), calendar: calendar()) == date(2026, 10, 3))
        #expect(entry.nextDue(onOrAfter: date(2026, 10, 4), calendar: calendar()) == nil)
        #expect(entry.occurrenceCount(inYearContaining: date(2026, 1, 1), calendar: calendar()) == 3)
    }

    @Test func monthlyEndDateStopsLaterEligibleDates() {
        let entry = entry(.init(frequency: .monthly, monthDays: [1, 15], endDate: .init(year: 2026, month: 3, day: 15)))
        #expect(entry.occurrenceCount(inYearContaining: date(2026, 1, 1), calendar: calendar()) == 6)
        #expect(entry.nextDue(onOrAfter: date(2026, 3, 16), calendar: calendar()) == nil)
        #expect(entry.occurrences(inMonthContaining: date(2026, 4, 1), calendar: calendar()).isEmpty)
    }

    @Test func weeklyEndDateStopsEachWeekdaySeriesInclusively() {
        let entry = entry(.init(frequency: .weekly, weekdays: [2, 6], endDate: .init(year: 2026, month: 1, day: 9)))
        #expect(entry.occurrences(inYearContaining: date(2026, 1, 1), calendar: calendar()) == [date(2026, 1, 2), date(2026, 1, 5), date(2026, 1, 9)])
        #expect(entry.occurrenceCount(inYearContaining: date(2026, 1, 1), calendar: calendar()) == 3)
        #expect(entry.nextDue(onOrAfter: date(2026, 1, 10), calendar: calendar()) == nil)
    }

    @Test func dailyRulesKeepLocalDatesAcrossDaylightSavingAndTimeZones() throws {
        let entry = entry(.init(frequency: .daily, endDate: .init(year: 2024, month: 3, day: 12)), anchor: .init(year: 2024, month: 3, day: 9))
        for zone in ["America/New_York", "Pacific/Honolulu", "Asia/Tokyo"] {
            var local = calendar()
            local.timeZone = try #require(TimeZone(identifier: zone))
            let query = try #require(ScheduleDate(year: 2024, month: 3, day: 1).date(calendar: local))
            let dates = entry.occurrences(inMonthContaining: query, calendar: local)
            #expect(dates.map { ScheduleDate(date: $0, calendar: local) } == (9...12).map { ScheduleDate(year: 2024, month: 3, day: $0) })
            #expect(entry.occurrenceCount(inMonthContaining: query, calendar: local) == 4)
            #expect(dates.allSatisfy { local.component(.hour, from: $0) == 0 })
        }
    }

    @Test func maximumIntervalAndDistantQueriesJumpDirectlyToEligibleDates() {
        let sparse = entry(.init(frequency: .daily, interval: 999))
        #expect(sparse.nextDue(onOrAfter: date(2026, 1, 2), calendar: calendar()) == date(2028, 9, 26))
        let old = entry(.init(frequency: .daily), anchor: .init(year: 1600, month: 1, day: 1))
        #expect(old.nextDue(onOrAfter: date(9999, 12, 31), calendar: calendar()) == date(9999, 12, 31))
    }

    @Test func dailyAndWeeklyLeapYearCountsMatchTheirActualOccurrences() {
        for rule in [CustomRecurrence(frequency: .daily), CustomRecurrence(frequency: .weekly, weekdays: Array(1...7))] {
            let entry = entry(rule, anchor: .init(year: 2024, month: 1, day: 1))
            #expect(entry.occurrences(inYearContaining: date(2024, 1, 1), calendar: calendar()).count == 366)
            #expect(entry.occurrenceCount(inYearContaining: date(2024, 1, 1), calendar: calendar()) == 366)
            #expect(entry.occurrenceCount(inYearContaining: date(2025, 1, 1), calendar: calendar()) == 365)
        }
    }

    @Test func dailyYearTotalsRemainExactAtAllSupportedBounds() throws {
        let rows = (0..<LedgerCodec.maximumExpenseCount).map { index in
            Expense(merchant: "Fictional daily income \(index)", amountMinor: LedgerCodec.maximumAmountMinor, kind: .income,
                    recurrence: .custom, anchorDate: .init(year: 2024, month: 1, day: 1), customRecurrence: .init(frequency: .daily))
        }
        let ledger = Ledger(expenses: rows)
        try LedgerCodec.validate(ledger)
        let totals = ledger.totals(inYearContaining: date(2024, 1, 1), calendar: calendar())
        #expect(totals.incomeMinor == 3_659_999_999_996_340_000)
        #expect(totals.balanceMinor == totals.incomeMinor)
    }

    @Test func everyCustomShapeRoundTripsWithoutLosingSelectionsOrEndDates() throws {
        let rules = [
            CustomRecurrence(frequency: .daily, interval: 3, endDate: .init(year: 2027, month: 2, day: 1)),
            CustomRecurrence(frequency: .weekly, interval: 2, weekdays: [2, 4, 6]),
            CustomRecurrence(frequency: .monthly, monthDays: [1, 15, 31]),
            CustomRecurrence(frequency: .monthly, ordinal: -1, ordinalWeekday: 6),
            CustomRecurrence(frequency: .yearly, interval: 2, months: [2, 7]),
            CustomRecurrence(frequency: .yearly, months: [1, 10], ordinal: 3, ordinalWeekday: 4)
        ]
        let ledger = Ledger(expenses: rules.map { entry($0) })
        let encoded = try LedgerCodec.encode(ledger)
        #expect(try LedgerCodec.decode(encoded) == ledger)
        #expect(try LedgerCodec.encode(LedgerCodec.decode(encoded)) == encoded)
        #expect(ledger.formatVersion == LedgerCodec.currentFormatVersion)
    }

    @Test func versionTwoFilesUpgradeWithoutChangingExistingSchedules() throws {
        let original = Ledger(expenses: [
            Expense(merchant: "Fictional monthly bill", amountMinor: 123, billingDay: 31),
            Expense(merchant: "Fictional fortnightly income", amountMinor: 456, kind: .income, recurrence: .everyTwoWeeks, anchorDate: .init(year: 2026, month: 1, day: 2)),
            Expense(merchant: "Fictional annual bill", amountMinor: 789, recurrence: .annual, anchorDate: .init(year: 2024, month: 2, day: 29)),
            Expense(merchant: "Fictional one-time bonus", recurrence: .oneTime, anchorDate: .init(year: 2026, month: 10, day: 15))
        ])
        var json = try #require(JSONSerialization.jsonObject(with: LedgerCodec.encode(original)) as? [String: Any])
        json["formatVersion"] = 2
        let upgraded = try LedgerCodec.decode(JSONSerialization.data(withJSONObject: json))
        #expect(upgraded == original)
        #expect(upgraded.expenses.allSatisfy { $0.customRecurrence == nil })
        #expect(upgraded.formatVersion == LedgerCodec.currentFormatVersion)
    }

    @Test func codecRejectsInvalidCustomRulesAndHiddenSelections() {
        let invalid = [
            CustomRecurrence(interval: 0), CustomRecurrence(interval: -1), CustomRecurrence(interval: 1_000), CustomRecurrence(interval: Int.max),
            CustomRecurrence(frequency: .weekly), CustomRecurrence(frequency: .weekly, weekdays: [0]),
            CustomRecurrence(frequency: .weekly, weekdays: [8]), CustomRecurrence(frequency: .weekly, weekdays: [2, 2]),
            CustomRecurrence(frequency: .monthly), CustomRecurrence(frequency: .monthly, monthDays: [0]),
            CustomRecurrence(frequency: .monthly, monthDays: [32]), CustomRecurrence(frequency: .monthly, monthDays: [1, 1]),
            CustomRecurrence(frequency: .monthly, ordinal: 0, ordinalWeekday: 2), CustomRecurrence(frequency: .monthly, ordinal: 6, ordinalWeekday: 2),
            CustomRecurrence(frequency: .monthly, ordinal: 1), CustomRecurrence(frequency: .monthly, ordinalWeekday: 2),
            CustomRecurrence(frequency: .monthly, ordinal: 1, ordinalWeekday: 8),
            CustomRecurrence(frequency: .monthly, monthDays: [1], ordinal: 1, ordinalWeekday: 2),
            CustomRecurrence(frequency: .yearly), CustomRecurrence(frequency: .yearly, months: [0]),
            CustomRecurrence(frequency: .yearly, months: [13]), CustomRecurrence(frequency: .yearly, months: [2, 2]),
            CustomRecurrence(frequency: .daily, weekdays: [2]), CustomRecurrence(frequency: .weekly, weekdays: [2], monthDays: [1]),
            CustomRecurrence(frequency: .monthly, monthDays: [1], months: [1]), CustomRecurrence(frequency: .yearly, monthDays: [1], months: [1]),
            CustomRecurrence(endDate: .init(year: 2025, month: 12, day: 31)), CustomRecurrence(endDate: .init(year: 2026, month: 2, day: 30))
        ]
        for rule in invalid {
            let entry = entry(rule)
            #expect(throws: LedgerError.invalidCustomRecurrence) { try LedgerCodec.encode(Ledger(expenses: [entry])) }
            #expect(entry.nextDue(onOrAfter: date(2026, 1, 1), calendar: calendar()) == nil)
            #expect(entry.occurrenceCount(inYearContaining: date(2026, 1, 1), calendar: calendar()) == 0)
        }
    }

    @Test func customRulesRequireTheirAnchorAndCannotAttachToPresets() {
        #expect(throws: LedgerError.invalidSchedule) {
            try LedgerCodec.encode(Ledger(expenses: [Expense(merchant: "Fictional custom", recurrence: .custom, customRecurrence: .init())]))
        }
        #expect(throws: LedgerError.invalidCustomRecurrence) {
            try LedgerCodec.encode(Ledger(expenses: [Expense(merchant: "Fictional custom", recurrence: .custom, anchorDate: .init(year: 2026, month: 1, day: 1))]))
        }
        #expect(throws: LedgerError.invalidCustomRecurrence) {
            try LedgerCodec.encode(Ledger(expenses: [Expense(merchant: "Fictional monthly", customRecurrence: .init())]))
        }
    }

    @Test func codecRejectsScheduleFieldsThatBelongToAnotherFrequency() {
        #expect(throws: LedgerError.invalidSchedule) {
            try LedgerCodec.encode(Ledger(expenses: [Expense(merchant: "Fictional monthly", anchorDate: .init(year: 2026, month: 1, day: 1))]))
        }
        for recurrence in [Recurrence.everyTwoWeeks, .annual, .oneTime, .custom] {
            let rule: CustomRecurrence? = recurrence == .custom ? .init() : nil
            #expect(throws: LedgerError.invalidSchedule) {
                try LedgerCodec.encode(Ledger(expenses: [Expense(merchant: "Fictional dated entry", billingDay: 15, recurrence: recurrence,
                                                               anchorDate: .init(year: 2026, month: 1, day: 1), customRecurrence: rule)]))
            }
        }
    }

    @Test func decodingRejectsUnknownFrequencyAndInvalidCustomPayloads() throws {
        let ledger = Ledger(expenses: [entry(.init())])
        var json = try #require(JSONSerialization.jsonObject(with: LedgerCodec.encode(ledger)) as? [String: Any])
        var rows = try #require(json["expenses"] as? [[String: Any]])
        var rule = try #require(rows[0]["customRecurrence"] as? [String: Any])
        rule["frequency"] = "hourly"
        rows[0]["customRecurrence"] = rule
        json["expenses"] = rows
        #expect(throws: LedgerError.corruptFile) { try LedgerCodec.decode(JSONSerialization.data(withJSONObject: json)) }
        rule["frequency"] = "daily"
        rule["interval"] = 0
        rows[0]["customRecurrence"] = rule
        json["expenses"] = rows
        #expect(throws: LedgerError.invalidCustomRecurrence) { try LedgerCodec.decode(JSONSerialization.data(withJSONObject: json)) }
    }

    @Test func concurrentCustomScheduleEditsPreserveBothRulesDeterministically() throws {
        let base = Ledger(expenses: [entry(.init(frequency: .monthly, monthDays: [1, 15]))])
        var local = base
        var remote = base
        local.expenses[0].customRecurrence?.interval = 3
        remote.expenses[0].customRecurrence?.endDate = .init(year: 2026, month: 12, day: 31)
        let merged = try LedgerMerger.merge(base: base, local: local, remote: remote)
        #expect(merged.expenses.count == 2)
        #expect(merged.expenses[0] == local.expenses[0])
        #expect(merged.expenses[1].customRecurrence == remote.expenses[0].customRecurrence)
        #expect(merged.expenses[1].merchant.hasSuffix(" (conflicting copy)"))
        #expect(merged.expenses[1].id != merged.expenses[0].id)
        #expect(try LedgerMerger.merge(base: base, local: merged, remote: remote) == merged)
        #expect(try LedgerCodec.decode(LedgerCodec.encode(merged)) == merged)
    }

    @Test func compactAndFullSummariesDescribeCustomRules() {
        let rule = CustomRecurrence(frequency: .monthly, interval: 3, monthDays: [1, 15])
        #expect(rule.intervalDescription == "Every 3 months")
        #expect(entry(rule).recurrenceSummary == "Every 3 months · Days 1, 15")
        #expect(Expense(merchant: "Fictional monthly").recurrenceSummary == "Monthly")
    }

    private func entry(_ rule: CustomRecurrence, anchor: ScheduleDate = .init(year: 2026, month: 1, day: 1), amount: Int64? = nil, kind: EntryKind = .expense) -> Expense {
        Expense(merchant: "Fictional custom entry", amountMinor: amount, kind: kind, recurrence: .custom, anchorDate: anchor, customRecurrence: rule)
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
