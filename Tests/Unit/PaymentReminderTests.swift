import Foundation
import Testing
@testable import Tally

nonisolated struct PaymentReminderTests {
    @Test func defaultsAreOptInAndRoundTripWithTheirEntry() throws {
        #expect(Expense(merchant: "Fictional bill", billingDay: 15).reminder == nil)
        #expect(PaymentReminder() == PaymentReminder(daysBefore: 0, hour: 9, minute: 0))
        #expect(PaymentReminder().sound == .ripple)
        #expect(PaymentReminder().sound.title == "Ripple")
        #expect(PaymentReminder().sound.bundledFilename == "Rebound.caf")
        let ledger = Ledger(expenses: [
            Expense(merchant: "Fictional bill", amountMinor: 123, billingDay: 15, websiteLink: "https://example.com", reminder: .init(daysBefore: 7, hour: 23, minute: 59)),
            Expense(merchant: "Fictional income", billingDay: 1, kind: .income)
        ])
        #expect(try LedgerCodec.decode(LedgerCodec.encode(ledger)) == ledger)
        #expect(ledger.formatVersion == 6)
    }

    @Test func soundMenuContainsExactlyFiveTonesAndSilenceInProductOrder() {
        #expect(PaymentReminderSound.allCases.map(\.title) == ["Ripple", "Pebble", "Glow", "Lift", "Signal", "None"])
        #expect(PaymentReminderSound.allCases.filter { $0.bundledFilename == nil } == [.none])
    }

    private struct LegacySoundChoice: Sendable {
        let stored: String
        let rewritten: String
        let title: String
        let filename: String?
    }

    private static let legacySoundChoices = [
        LegacySoundChoice(stored: "triTone", rewritten: "rebound", title: "Ripple", filename: "Rebound.caf"),
        LegacySoundChoice(stored: "bamboo", rewritten: "bamboo", title: "Pebble", filename: "Bamboo.caf"),
        LegacySoundChoice(stored: "bell", rewritten: "bell", title: "Signal", filename: "Bell.caf"),
        LegacySoundChoice(stored: "chime", rewritten: "chime", title: "Lift", filename: "Chime.caf"),
        LegacySoundChoice(stored: "chord", rewritten: "chord", title: "Glow", filename: "Chord.caf"),
        LegacySoundChoice(stored: "glass", rewritten: "rebound", title: "Ripple", filename: "Rebound.caf"),
        LegacySoundChoice(stored: "note", rewritten: "rebound", title: "Ripple", filename: "Rebound.caf"),
        LegacySoundChoice(stored: "pulse", rewritten: "rebound", title: "Ripple", filename: "Rebound.caf"),
        LegacySoundChoice(stored: "rebound", rewritten: "rebound", title: "Ripple", filename: "Rebound.caf"),
        LegacySoundChoice(stored: "systemDefault", rewritten: "rebound", title: "Ripple", filename: "Rebound.caf"),
        LegacySoundChoice(stored: "none", rewritten: "none", title: "None", filename: nil)
    ]

    @Test(arguments: legacySoundChoices)
    private func existingSoundIdentifiersMapToTheCurrentPalette(_ fixture: LegacySoundChoice) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "daysBefore": 1, "hour": 9, "minute": 41, "sound": fixture.stored
        ])
        let reminder = try JSONDecoder().decode(PaymentReminder.self, from: data)
        #expect(reminder.sound.title == fixture.title)
        #expect(reminder.sound.bundledFilename == fixture.filename)
        #expect(reminder.daysBefore == 1 && reminder.hour == 9 && reminder.minute == 41)
        let rewritten = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(reminder)) as? [String: Any])
        #expect(rewritten["sound"] as? String == fixture.rewritten)
    }

    @Test(arguments: [1, 2, 3, 4, 5])
    func olderFormatsNeverEnableReminders(_ version: Int) throws {
        let original = Ledger(expenses: [Expense(merchant: "Fictional bill", amountMinor: 123, billingDay: 15)])
        var json = try #require(JSONSerialization.jsonObject(with: LedgerCodec.encode(original)) as? [String: Any])
        json["formatVersion"] = version
        let upgraded = try LedgerCodec.decode(JSONSerialization.data(withJSONObject: json))
        #expect(upgraded == original)
        #expect(upgraded.expenses[0].reminder == nil)
        #expect(upgraded.formatVersion == 6)
    }

    @Test func versionFiveRemindersWithoutSoundUseRipple() throws {
        let data = Data(#"{"formatVersion":5,"id":"11111111-1111-1111-1111-111111111111","currencyCode":"USD","expenses":[{"id":"22222222-2222-2222-2222-222222222222","merchant":"Fictional bill","amountMinor":1200,"billingDay":15,"category":"other","notes":"","reminder":{"daysBefore":2,"hour":10,"minute":30}}]}"#.utf8)
        let migrated = try LedgerCodec.decode(data)
        let reminder = try #require(migrated.expenses.first?.reminder)
        #expect(migrated.formatVersion == 6)
        #expect(reminder == PaymentReminder(daysBefore: 2, hour: 10, minute: 30, sound: .ripple))
        #expect(try LedgerCodec.decode(LedgerCodec.encode(migrated)) == migrated)
    }

    @Test(arguments: PaymentReminderSound.allCases)
    func everySoundChoiceRoundTripsInItsReminder(_ sound: PaymentReminderSound) throws {
        let original = Ledger(expenses: [
            Expense(merchant: "Fictional bill", billingDay: 15, reminder: .init(sound: sound))
        ])
        let encoded = try LedgerCodec.encode(original)
        let decoded = try LedgerCodec.decode(encoded)
        #expect(decoded == original)
        #expect(decoded.expenses[0].reminder?.sound == sound)
        let json = try JSONSerialization.jsonObject(with: encoded)
        let object = try #require(json as? [String: Any])
        let expenses = try #require(object["expenses"] as? [[String: Any]])
        let reminder = try #require(expenses[0]["reminder"] as? [String: Any])
        #expect(reminder["sound"] as? String == sound.rawValue)
    }

    @Test func unknownReminderSoundIsRejectedInsteadOfReplacingTheChoice() throws {
        let original = Ledger(expenses: [Expense(merchant: "Fictional bill", billingDay: 15, reminder: .init())])
        let encoded = try LedgerCodec.encode(original)
        let json = try JSONSerialization.jsonObject(with: encoded)
        var object = try #require(json as? [String: Any])
        var expenses = try #require(object["expenses"] as? [[String: Any]])
        var reminder = try #require(expenses[0]["reminder"] as? [String: Any])
        reminder["sound"] = "unknownSound"
        expenses[0]["reminder"] = reminder
        object["expenses"] = expenses
        let invalid = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: LedgerError.corruptFile) { try LedgerCodec.decode(invalid) }
    }

    @Test func concurrentSoundChoicesSurviveAsSeparateConflictCopies() throws {
        let base = Ledger(expenses: [Expense(merchant: "Fictional bill", billingDay: 15, reminder: .init())])
        var local = base
        var remote = base
        local.expenses[0].reminder?.sound = .signal
        remote.expenses[0].reminder?.sound = .none
        let merged = try LedgerMerger.merge(base: base, local: local, remote: remote)
        #expect(merged.expenses.count == 2)
        #expect(merged.expenses[0].reminder?.sound == PaymentReminderSound.signal)
        #expect(merged.expenses[1].reminder?.sound == PaymentReminderSound.none)
    }

    @Test func invalidReminderSettingsAndVariableDatesAreRejected() {
        let invalid = [PaymentReminder(daysBefore: -1), .init(daysBefore: 3), .init(daysBefore: 30), .init(daysBefore: Int.max),
                       .init(hour: -1), .init(hour: 24), .init(minute: -1), .init(minute: 60)]
        for reminder in invalid {
            #expect(!reminder.isValid)
            #expect(throws: LedgerError.invalidReminder) {
                try LedgerCodec.encode(Ledger(expenses: [Expense(merchant: "Fictional bill", billingDay: 15, reminder: reminder)]))
            }
        }
        #expect(throws: LedgerError.invalidReminder) {
            try LedgerCodec.encode(Ledger(expenses: [Expense(merchant: "Fictional variable-date bill", reminder: .init())]))
        }
        #expect(ReminderPlanner.plan(for: Ledger(expenses: [Expense(merchant: "Fictional invalid reminder", reminder: .init(daysBefore: Int.max))]), now: date(2026, 1, 1), calendar: calendar()).reminders.isEmpty)
    }

    @Test func simpleMonthlyReminderRepeatsOnItsLeadDay() throws {
        let entry = Expense(merchant: "Fictional bill", billingDay: 15, reminder: .init(daysBefore: 7))
        let plan = plan(entry, now: date(2026, 1, 1))
        let first = try #require(plan.reminders.first)
        #expect(plan.reminders.count == 1)
        #expect(first.repeats)
        #expect(first.dueDate == date(2026, 1, 15))
        #expect(first.fireDate == date(2026, 1, 8, hour: 9))
        #expect(first.dateComponents.day == 8)
        #expect(first.dateComponents.hour == 9)
        #expect(first.dateComponents.month == nil && first.dateComponents.year == nil)
        #expect(first.identifier.hasPrefix("tally.payment."))
        #expect(first.identifier.hasSuffix("repeat.monthly"))
        #expect(plan.truncatedEntryIDs.isEmpty && plan.nextUnscheduledFireDateByEntry.isEmpty)
    }

    @Test func monthEndReminderUsesClampedDueDates() throws {
        let entry = Expense(merchant: "Fictional month-end bill", billingDay: 31, reminder: .init(daysBefore: 1))
        let reminders = plan(entry, now: date(2026, 2, 1)).reminders
        let first = try #require(reminders.first)
        #expect(!first.repeats)
        #expect(first.dueDate == date(2026, 2, 28))
        #expect(first.fireDate == date(2026, 2, 27, hour: 9))
        #expect(reminders[1].dueDate == date(2026, 3, 31))
        #expect(reminders[1].fireDate == date(2026, 3, 30, hour: 9))
    }

    @Test func leadTimesCrossMonthAndYearBoundaries() throws {
        let entry = Expense(merchant: "Fictional first-of-month bill", billingDay: 1, reminder: .init(daysBefore: 7))
        let first = try #require(plan(entry, now: date(2025, 12, 20)).reminders.first)
        #expect(!first.repeats)
        #expect(first.dueDate == date(2026, 1, 1))
        #expect(first.fireDate == date(2025, 12, 25, hour: 9))
    }

    @Test func annualBonusRepeatsOnlyAfterItsFirstYearBegins() throws {
        let started = Expense(merchant: "Fictional bonus", kind: .income, recurrence: .annual, anchorDate: .init(year: 2024, month: 12, day: 15), reminder: .init())
        let first = try #require(plan(started, now: date(2026, 1, 1)).reminders.first)
        #expect(first.repeats)
        #expect(first.dateComponents.month == 12 && first.dateComponents.day == 15)
        #expect(first.fireDate == date(2026, 12, 15, hour: 9))
        var future = started
        future.anchorDate = .init(year: 2027, month: 12, day: 15)
        let futurePlan = plan(future, now: date(2026, 1, 1))
        #expect(futurePlan.reminders.allSatisfy { !$0.repeats })
        #expect(futurePlan.reminders.first?.fireDate == date(2027, 12, 15, hour: 9))
    }

    @Test func annualLeapDayReminderReturnsToFebruary29() {
        let entry = Expense(merchant: "Fictional annual bill", recurrence: .annual, anchorDate: .init(year: 2024, month: 2, day: 29), reminder: .init())
        let reminders = plan(entry, now: date(2025, 1, 1)).reminders
        #expect(reminders.allSatisfy { !$0.repeats })
        #expect(reminders.first?.fireDate == date(2025, 2, 28, hour: 9))
        #expect(reminders.contains { $0.fireDate == date(2028, 2, 29, hour: 9) })
    }

    @Test func oneTimeReminderFinishesWithoutARefreshWarning() {
        let entry = Expense(merchant: "Fictional one-time bill", recurrence: .oneTime, anchorDate: .init(year: 2026, month: 4, day: 1), reminder: .init(daysBefore: 7))
        let upcoming = plan(entry, now: date(2026, 3, 24))
        #expect(upcoming.reminders.count == 1)
        #expect(upcoming.reminders.first?.fireDate == date(2026, 3, 25, hour: 9))
        #expect(upcoming.nextUnscheduledFireDateByEntry.isEmpty)
        #expect(plan(entry, now: date(2026, 3, 25, hour: 9)).reminders.isEmpty)
        #expect(plan(entry, now: date(2026, 4, 2)).reminders.isEmpty)
    }

    @Test func springGapMovesToTheNextValidTimeWithoutChangingThePaymentDate() {
        let entry = Expense(merchant: "Fictional daily bill", recurrence: .custom, anchorDate: .init(year: 2026, month: 3, day: 7),
                            customRecurrence: .init(frequency: .daily, endDate: .init(year: 2026, month: 3, day: 9)), reminder: .init(hour: 2, minute: 30))
        let reminders = plan(entry, now: date(2026, 3, 6, hour: 23)).reminders
        #expect(reminders.map(\.fireDate) == [date(2026, 3, 7, hour: 2, minute: 30), date(2026, 3, 8, hour: 3), date(2026, 3, 9, hour: 2, minute: 30)])
        #expect(reminders[1].dueDate == date(2026, 3, 8))
        #expect(reminders.allSatisfy { !$0.repeats })
    }

    @Test func autumnOverlapUsesTheFirstLocalTimeOnly() throws {
        let entry = Expense(merchant: "Fictional autumn bill", recurrence: .oneTime, anchorDate: .init(year: 2026, month: 11, day: 1), reminder: .init(hour: 1, minute: 30))
        let first = try #require(plan(entry, now: date(2026, 10, 31)).reminders.first)
        #expect(calendar().component(.hour, from: first.fireDate) == 1)
        #expect(calendar().component(.minute, from: first.fireDate) == 30)
        #expect(calendar().timeZone.secondsFromGMT(for: first.fireDate) == -4 * 3_600)
        #expect(plan(entry, now: first.fireDate.addingTimeInterval(60)).reminders.isEmpty)
    }

    @Test func leadingCalendarDaysRemainCorrectAcrossDaylightSaving() throws {
        let entry = Expense(merchant: "Fictional spring bill", recurrence: .oneTime, anchorDate: .init(year: 2026, month: 3, day: 9), reminder: .init(daysBefore: 1))
        let first = try #require(plan(entry, now: date(2026, 3, 7)).reminders.first)
        #expect(first.fireDate == date(2026, 3, 8, hour: 9))
        #expect(first.dueDate == date(2026, 3, 9))
    }

    @Test func finiteCustomRuleHonorsItsInclusiveDueEndDate() {
        let entry = Expense(merchant: "Fictional finite income", kind: .income, recurrence: .custom, anchorDate: .init(year: 2026, month: 1, day: 1),
                            customRecurrence: .init(frequency: .monthly, monthDays: [1, 15], endDate: .init(year: 2026, month: 3, day: 15)), reminder: .init(daysBefore: 2))
        let result = plan(entry, now: date(2026, 1, 1))
        #expect(result.reminders.count == 5)
        #expect(result.reminders.last?.dueDate == date(2026, 3, 15))
        #expect(result.reminders.last?.fireDate == date(2026, 3, 13, hour: 9))
        #expect(result.truncatedEntryIDs.isEmpty && result.nextUnscheduledFireDateByEntry.isEmpty)
    }

    @Test func simpleCustomWeeklyTriggersPreserveEachWeekdayAndLeadOffset() {
        let entry = Expense(merchant: "Fictional weekly income", kind: .income, recurrence: .custom, anchorDate: .init(year: 2026, month: 1, day: 1),
                            customRecurrence: .init(frequency: .weekly, weekdays: [2, 6]), reminder: .init(daysBefore: 2))
        let reminders = plan(entry, now: date(2026, 1, 1)).reminders
        #expect(reminders.count == 2)
        #expect(reminders.allSatisfy { $0.repeats })
        #expect(reminders.map { $0.dateComponents.weekday } == [7, 4])
        #expect(reminders.map(\.fireDate) == [date(2026, 1, 3, hour: 9), date(2026, 1, 7, hour: 9)])
        #expect(Set(reminders.map(\.identifier)).count == 2)
    }

    @Test func simpleCustomDailyTriggerHasNoFixedDate() throws {
        let entry = Expense(merchant: "Fictional daily bill", recurrence: .custom, anchorDate: .init(year: 2025, month: 1, day: 1),
                            customRecurrence: .init(frequency: .daily), reminder: .init())
        let first = try #require(plan(entry, now: date(2026, 1, 1, hour: 10)).reminders.first)
        #expect(first.repeats)
        #expect(first.fireDate == date(2026, 1, 2, hour: 9))
        #expect(first.dateComponents.day == nil && first.dateComponents.weekday == nil && first.dateComponents.year == nil)
    }

    @Test func overnightDailyNotificationsAreBoundedAndReportFirstUnscheduledDate() {
        let entry = Expense(merchant: "Fictional early daily bill", recurrence: .custom, anchorDate: .init(year: 2026, month: 1, day: 1),
                            customRecurrence: .init(frequency: .daily), reminder: .init(hour: 2))
        let result = plan(entry, now: date(2026, 1, 1))
        #expect(result.reminders.count == 64)
        #expect(result.reminders.allSatisfy { !$0.repeats })
        #expect(result.reminders.last?.fireDate == date(2026, 3, 5, hour: 2))
        #expect(result.truncatedEntryIDs == [entry.id])
        #expect(result.nextUnscheduledFireDateByEntry[entry.id] == date(2026, 3, 6, hour: 2))
    }

    @Test func fortnightlyIncomeUsesDatedNotificationsWithAnHonestLimit() {
        let entry = Expense(merchant: "Fictional fortnightly pay", kind: .income, recurrence: .everyTwoWeeks, anchorDate: .init(year: 2026, month: 1, day: 2), reminder: .init())
        let result = plan(entry, now: date(2026, 1, 1))
        #expect(result.reminders.count == 64)
        #expect(result.reminders.allSatisfy { !$0.repeats })
        #expect(result.reminders.prefix(3).map(\.fireDate) == [date(2026, 1, 2, hour: 9), date(2026, 1, 16, hour: 9), date(2026, 1, 30, hour: 9)])
        #expect(result.nextUnscheduledFireDateByEntry[entry.id] == calendar().date(byAdding: .day, value: 64 * 14, to: date(2026, 1, 2, hour: 9)))
    }

    @Test func distantOneTimeReminderIsScheduledAtItsActualDateBeyondTheExpansionHorizon() {
        let entry = Expense(merchant: "Fictional future payment", recurrence: .oneTime, anchorDate: .init(year: 2034, month: 4, day: 1), reminder: .init())
        let result = plan(entry, now: date(2026, 1, 1))
        #expect(result.horizonEnd == date(2031, 1, 1))
        #expect(result.reminders.count == 1)
        #expect(result.reminders.first?.fireDate == date(2034, 4, 1, hour: 9))
        #expect(result.reminders.first?.dateComponents.year == 2034)
        #expect(result.reminders.first?.repeats == false)
        #expect(result.truncatedEntryIDs.isEmpty)
        #expect(result.nextUnscheduledFireDateByEntry.isEmpty)
    }

    @Test func distantRecurringAnchorKeepsItsFirstReminderAndBoundsFurtherExpansion() {
        let entry = Expense(merchant: "Fictional future annual payment", recurrence: .annual,
                            anchorDate: .init(year: 2034, month: 4, day: 1), reminder: .init(daysBefore: 7))
        let result = plan(entry, now: date(2026, 1, 1))
        #expect(result.reminders.count == 1)
        #expect(result.reminders.first?.fireDate == date(2034, 3, 25, hour: 9))
        #expect(result.reminders.first?.dateComponents.year == 2034)
        #expect(result.reminders.first?.repeats == false)
        #expect(result.truncatedEntryIDs == [entry.id])
        #expect(result.nextUnscheduledFireDateByEntry[entry.id] == date(2035, 3, 25, hour: 9))
    }

    @Test func disablingOrDeletingAnEntryRemovesItsPlannedRequests() {
        let entry = Expense(merchant: "Fictional bill", billingDay: 15, reminder: .init())
        var ledger = Ledger(expenses: [entry])
        #expect(ReminderPlanner.plan(for: ledger, now: date(2026, 1, 1), calendar: calendar()).reminders.count == 1)
        ledger.expenses[0].reminder = nil
        #expect(ReminderPlanner.plan(for: ledger, now: date(2026, 1, 1), calendar: calendar()).reminders.isEmpty)
        ledger.expenses = []
        #expect(ReminderPlanner.plan(for: ledger, now: date(2026, 1, 1), calendar: calendar()).reminders.isEmpty)
    }

    @Test func identifiersRemainStableWhenContentChangesAndAreNamespacedByLedger() {
        var ledger = Ledger(expenses: [Expense(merchant: "Fictional bill", amountMinor: 123, billingDay: 15, reminder: .init())])
        let first = ReminderPlanner.plan(for: ledger, now: date(2026, 1, 1), calendar: calendar()).reminders
        ledger.expenses[0].merchant = "Fictional renamed bill"
        ledger.expenses[0].amountMinor = 456
        let renamed = ReminderPlanner.plan(for: ledger, now: date(2026, 1, 2), calendar: calendar()).reminders
        #expect(first.map(\.identifier) == renamed.map(\.identifier))
        ledger.id = UUID()
        #expect(ReminderPlanner.plan(for: ledger, now: date(2026, 1, 2), calendar: calendar()).reminders.map(\.identifier) != first.map(\.identifier))
    }

    @Test func remindersUseTheRequestedLocalTimeWithoutPersistingAZone() throws {
        let entry = Expense(merchant: "Fictional local bill", recurrence: .oneTime, anchorDate: .init(year: 2026, month: 10, day: 15), reminder: .init())
        let ledger = Ledger(expenses: [entry])
        for zone in ["America/New_York", "Asia/Tokyo"] {
            var local = calendar()
            local.timeZone = try #require(TimeZone(identifier: zone))
            let now = try #require(ScheduleDate(year: 2026, month: 10, day: 14).date(calendar: local))
            let first = try #require(ReminderPlanner.plan(for: ledger, now: now, calendar: local).reminders.first)
            #expect(local.component(.hour, from: first.fireDate) == 9)
            #expect(first.dateComponents.year == 2026 && first.dateComponents.month == 10 && first.dateComponents.day == 15)
            #expect(first.dateComponents.hour == 9 && first.dateComponents.timeZone == nil)
            #expect(first.dateComponents.calendar?.identifier == .gregorian)
        }
        let json = try #require(JSONSerialization.jsonObject(with: LedgerCodec.encode(ledger)) as? [String: Any])
        let rows = try #require(json["expenses"] as? [[String: Any]])
        let reminder = try #require(rows[0]["reminder"] as? [String: Any])
        #expect(Set(reminder.keys) == ["daysBefore", "hour", "minute", "sound"])
    }

    @Test func conflictingReminderEditsArePreservedByMerge() throws {
        let base = Ledger(expenses: [Expense(merchant: "Fictional bill", billingDay: 15, reminder: .init())])
        var local = base
        var remote = base
        local.expenses[0].reminder?.daysBefore = 1
        remote.expenses[0].reminder?.hour = 10
        let merged = try LedgerMerger.merge(base: base, local: local, remote: remote)
        #expect(merged.expenses.count == 2)
        #expect(merged.expenses[0].reminder == local.expenses[0].reminder)
        #expect(merged.expenses[1].reminder == remote.expenses[0].reminder)
        #expect(try LedgerCodec.decode(LedgerCodec.encode(merged)) == merged)
    }

    @Test(arguments: [7, 21])
    func morningAndEveningDailyRemindersRepeatAcrossDaylightSaving(_ hour: Int) throws {
        let entry = Expense(merchant: "Fictional daily reminder", recurrence: .custom,
                            anchorDate: .init(year: 2025, month: 1, day: 1),
                            customRecurrence: .init(frequency: .daily), reminder: .init(hour: hour, minute: 30))
        try assertRepeatingPlanMatchesSchedule(entry, from: date(2026, 1, 1), until: date(2027, 1, 1))
    }

    @Test func quarterlyAndSelectedMonthlyDaysRepeatWithoutChangingTheirDates() throws {
        let quarterly = Expense(merchant: "Fictional quarterly tax", recurrence: .custom,
                                anchorDate: .init(year: 2025, month: 1, day: 15),
                                customRecurrence: .init(frequency: .monthly, interval: 3, monthDays: [15]),
                                reminder: .init(daysBefore: 7))
        let quarterlyPlan = plan(quarterly, now: date(2026, 1, 1))
        #expect(quarterlyPlan.reminders.count == 4)
        #expect(quarterlyPlan.nextUnscheduledFireDateByEntry.isEmpty)
        try assertRepeatingPlanMatchesSchedule(quarterly, from: date(2026, 1, 1), until: date(2030, 1, 1))
        let twiceMonthly = Expense(merchant: "Fictional twice-monthly income", kind: .income, recurrence: .custom,
                                   anchorDate: .init(year: 2025, month: 1, day: 1),
                                   customRecurrence: .init(frequency: .monthly, monthDays: [8, 23]),
                                   reminder: .init(daysBefore: 7))
        #expect(plan(twiceMonthly, now: date(2026, 1, 1)).reminders.count == 2)
        try assertRepeatingPlanMatchesSchedule(twiceMonthly, from: date(2026, 1, 1), until: date(2030, 1, 1))
    }

    @Test func annualLeadsAndSelectedYearlyMonthsRepeatAcrossYearBoundaries() throws {
        let annual = Expense(merchant: "Fictional annual bill", recurrence: .annual,
                             anchorDate: .init(year: 2025, month: 1, day: 3), reminder: .init(daysBefore: 7))
        let first = try #require(plan(annual, now: date(2026, 1, 1)).reminders.first)
        #expect(first.dateComponents.month == 12 && first.dateComponents.day == 27)
        try assertRepeatingPlanMatchesSchedule(annual, from: date(2026, 1, 1), until: date(2030, 1, 1))
        let selected = Expense(merchant: "Fictional seasonal bill", recurrence: .custom,
                               anchorDate: .init(year: 2025, month: 1, day: 31),
                               customRecurrence: .init(frequency: .yearly, months: [1, 4, 7, 10]),
                               reminder: .init(daysBefore: 2))
        try assertRepeatingPlanMatchesSchedule(selected, from: date(2026, 1, 1), until: date(2030, 1, 1))
    }

    @Test func ordinalWeekdaysKeepExactDatedAlertsRatherThanNormalizingToAnotherDay() {
        for ordinal in [3, 4, 5, -1] {
            let entry = Expense(merchant: "Fictional ordinal Monday", recurrence: .custom,
                                anchorDate: .init(year: 2025, month: 1, day: 1),
                                customRecurrence: .init(frequency: .monthly, ordinal: ordinal, ordinalWeekday: 2),
                                reminder: .init())
            let result = plan(entry, now: date(2026, 1, 1))
            #expect(!result.reminders.isEmpty)
            #expect(result.reminders.allSatisfy { !$0.repeats })
            #expect(result.reminders.allSatisfy { calendar().component(.weekday, from: $0.dueDate) == 2 })
            #expect(!result.reminders.contains { $0.fireDate == date(2026, 3, 1) })
        }
    }

    @Test func futureAnchorsRepeatOnlyWhenEveryPatternStartsAtARealOccurrence() throws {
        let soon = Expense(merchant: "Fictional future annual", recurrence: .annual,
                           anchorDate: .init(year: 2026, month: 12, day: 15), reminder: .init(daysBefore: 7))
        let first = try #require(plan(soon, now: date(2026, 9, 1)).reminders.first)
        #expect(first.repeats && first.fireDate == date(2026, 12, 8, hour: 9))
        var distant = soon
        distant.anchorDate = .init(year: 2027, month: 12, day: 15)
        #expect(plan(distant, now: date(2026, 9, 1)).reminders.allSatisfy { !$0.repeats })
        let quarterly = Expense(merchant: "Fictional future quarterly", recurrence: .custom,
                                anchorDate: .init(year: 2027, month: 1, day: 15),
                                customRecurrence: .init(frequency: .monthly, interval: 3, monthDays: [15]), reminder: .init())
        #expect(plan(quarterly, now: date(2026, 9, 1)).reminders.allSatisfy { !$0.repeats })
        #expect(plan(quarterly, now: date(2026, 12, 1)).reminders.allSatisfy { $0.repeats })
    }

    @Test func unsupportedCalendarPatternsRetainExactDatedSchedules() {
        let monthlyFive = Expense(merchant: "Fictional every five months", recurrence: .custom,
                                  anchorDate: .init(year: 2025, month: 1, day: 15),
                                  customRecurrence: .init(frequency: .monthly, interval: 5, monthDays: [15]), reminder: .init())
        let marchLead = Expense(merchant: "Fictional March first", recurrence: .annual,
                               anchorDate: .init(year: 2025, month: 3, day: 1), reminder: .init(daysBefore: 1))
        let lastMonday = Expense(merchant: "Fictional last Monday", recurrence: .custom,
                                 anchorDate: .init(year: 2025, month: 1, day: 1),
                                 customRecurrence: .init(frequency: .monthly, ordinal: -1, ordinalWeekday: 2), reminder: .init())
        for entry in [monthlyFive, marchLead, lastMonday] {
            let result = plan(entry, now: date(2026, 1, 1))
            #expect(!result.reminders.isEmpty)
            #expect(result.reminders.allSatisfy { !$0.repeats })
        }
        let leap = plan(marchLead, now: date(2028, 1, 1))
        #expect(leap.reminders.first?.fireDate == date(2028, 2, 29, hour: 9))
    }

    @Test func clampedMonthlySelectionsDoNotCreateDuplicateRepeatingAlerts() throws {
        let entry = Expense(merchant: "Fictional April bill", recurrence: .custom,
                            anchorDate: .init(year: 2025, month: 4, day: 1),
                            customRecurrence: .init(frequency: .monthly, interval: 12, monthDays: [30, 31]), reminder: .init())
        #expect(plan(entry, now: date(2026, 1, 1)).reminders.count == 1)
        try assertRepeatingPlanMatchesSchedule(entry, from: date(2026, 1, 1), until: date(2030, 1, 1))
    }

    private func assertRepeatingPlanMatchesSchedule(_ expense: Expense, from start: Date, until end: Date) throws {
        let calendar = calendar()
        let reminder = try #require(expense.reminder)
        let result = plan(expense, now: start)
        #expect(!result.reminders.isEmpty && result.reminders.allSatisfy { $0.repeats })
        var actual: [Date] = []
        for item in result.reminders {
            var match = item.dateComponents
            match.calendar = calendar
            var cursor = start
            while let next = calendar.nextDate(after: cursor, matching: match, matchingPolicy: .nextTime, repeatedTimePolicy: .first), next < end {
                actual.append(next)
                cursor = next
            }
        }
        var expected: [Date] = []
        var cursor = calendar.startOfDay(for: start)
        while let due = expense.nextDue(onOrAfter: cursor, calendar: calendar), due < end {
            let day = try #require(calendar.date(byAdding: .day, value: -reminder.daysBefore, to: due))
            let fire = try #require(calendar.date(bySettingHour: reminder.hour, minute: reminder.minute, second: 0, of: day,
                                                  matchingPolicy: .nextTime, repeatedTimePolicy: .first))
            if fire > start && fire < end { expected.append(fire) }
            cursor = try #require(calendar.date(byAdding: .day, value: 1, to: due))
        }
        // Include a due date just beyond the comparison window when its lead
        // notification still belongs inside the window.
        if let due = expense.nextDue(onOrAfter: cursor, calendar: calendar),
           let day = calendar.date(byAdding: .day, value: -reminder.daysBefore, to: due),
           let fire = calendar.date(bySettingHour: reminder.hour, minute: reminder.minute, second: 0, of: day,
                                   matchingPolicy: .nextTime, repeatedTimePolicy: .first), fire > start && fire < end {
            expected.append(fire)
        }
        #expect(actual.count == Set(actual).count)
        #expect(actual.sorted() == expected.sorted())
    }

    private func plan(_ expense: Expense, now: Date) -> ReminderPlan {
        ReminderPlanner.plan(for: Ledger(expenses: [expense]), now: now, calendar: calendar())
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}
