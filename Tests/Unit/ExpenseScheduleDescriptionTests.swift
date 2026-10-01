import Foundation
import Testing
@testable import Tally

@MainActor
struct ExpenseScheduleDescriptionTests {
    @Test func annualIncomeOutsideSelectedMonthIsNotExpectedWithoutDuplicateZeroCount() {
        let bonus = Expense(merchant: "Fictional bonus", kind: .income, recurrence: .annual,
                            anchorDate: ScheduleDate(year: 2026, month: 12, day: 10))
        let description = ExpenseScheduleDescription(expense: bonus, period: period(.month, 2026, 9))

        #expect(description.date == "Not expected this month")
        #expect(description.occurrenceCount == nil)
        #expect(!description.showsOccurrenceCount)
    }

    @Test func oneTimeIncomeOutsideSelectedYearIsNotExpectedWithoutDuplicateZeroCount() {
        let project = Expense(merchant: "Fictional project", kind: .income, recurrence: .oneTime,
                              anchorDate: ScheduleDate(year: 2025, month: 8, day: 2))
        let description = ExpenseScheduleDescription(expense: project, period: period(.year, 2026, 9))

        #expect(description.date == "Not expected this year")
        #expect(description.occurrenceCount == nil)
        #expect(!description.showsOccurrenceCount)
    }

    @Test func incomeCountsDescribeTheActualScheduleWithoutClaimingReceipt() {
        let salary = Expense(merchant: "Fictional salary", kind: .income, recurrence: .everyTwoWeeks,
                             anchorDate: ScheduleDate(year: 2026, month: 1, day: 2))
        let january = ExpenseScheduleDescription(expense: salary, period: period(.month, 2026, 1))
        let february = ExpenseScheduleDescription(expense: salary, period: period(.month, 2026, 2))
        let year = ExpenseScheduleDescription(expense: salary, period: period(.year, 2026, 1))

        #expect(january.occurrenceCount == "3 times this month")
        #expect(february.occurrenceCount == "Twice this month")
        #expect(year.occurrenceCount == "26 times this year")
        #expect(january.showsOccurrenceCount && february.showsOccurrenceCount && year.showsOccurrenceCount)
    }

    @Test func annualIncomeUsesOnceForAccessibilityWithoutAnExtraVisualSubtitle() {
        let bonus = Expense(merchant: "Fictional bonus", kind: .income, recurrence: .annual,
                            anchorDate: ScheduleDate(year: 2026, month: 12, day: 10))
        let december = ExpenseScheduleDescription(expense: bonus, period: period(.month, 2026, 12))
        let year = ExpenseScheduleDescription(expense: bonus, period: period(.year, 2026, 9))

        #expect(december.occurrenceCount == "Once this month")
        #expect(year.occurrenceCount == "Once this year")
        #expect(!december.showsOccurrenceCount && !year.showsOccurrenceCount)
    }

    @Test func expensesRetainDueAndPaymentLanguageWithoutZeroSubtitles() {
        let insurance = Expense(merchant: "Fictional insurance", recurrence: .annual,
                                anchorDate: ScheduleDate(year: 2026, month: 10, day: 3))
        let september = ExpenseScheduleDescription(expense: insurance, period: period(.month, 2026, 9))
        let october = ExpenseScheduleDescription(expense: insurance, period: period(.month, 2026, 10))
        let rent = Expense(merchant: "Fictional rent", billingDay: 1)
        let year = ExpenseScheduleDescription(expense: rent, period: period(.year, 2026, 9))

        #expect(september.date == "Not due this month")
        #expect(september.occurrenceCount == nil)
        #expect(!september.showsOccurrenceCount)
        #expect(october.occurrenceCount == "1 payment this month")
        #expect(year.occurrenceCount == "12 payments this year")
        #expect(year.showsOccurrenceCount)
    }

    @Test(arguments: [EntryKind.income, .expense])
    func varyingMonthlyDateDoesNotMeanUnscheduled(_ kind: EntryKind) {
        let variable = Expense(merchant: "Fictional variable date", kind: kind)
        let description = ExpenseScheduleDescription(expense: variable, period: period(.month, 2026, 9))

        #expect(description.date == "Date varies")
        #expect(description.occurrenceCount == (kind == .income ? "Once this month" : "1 payment this month"))
        #expect(!description.showsOccurrenceCount)
    }

    @Test func overviewLabelsDistinguishIncomeFromPaymentsAndPastFromUpcoming() {
        let past = period(.month, 2026, 8)
        let current = period(.month, 2026, 9)
        let future = period(.month, 2026, 10)

        #expect(ExpenseScheduleDescription.overviewDateLabel(for: .income, period: past) == "First income")
        #expect(ExpenseScheduleDescription.overviewDateLabel(for: .expense, period: past) == "First payment")
        for selected in [current, future] {
            #expect(ExpenseScheduleDescription.overviewDateLabel(for: .income, period: selected) == "Next income")
            #expect(ExpenseScheduleDescription.overviewDateLabel(for: .expense, period: selected) == "Next payment")
        }
    }

    private func period(_ kind: CashFlowPeriod.Kind, _ year: Int, _ month: Int) -> CashFlowPeriod {
        let calendar = CashFlowPeriod.calendar
        let selected = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
        let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27))!
        return CashFlowPeriod(kind: kind, date: selected, today: today)
    }
}
