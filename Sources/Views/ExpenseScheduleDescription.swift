import Foundation

/// Describes a schedule, without implying that money has already changed hands.
struct ExpenseScheduleDescription {
    let date: String
    let occurrenceCount: String?
    let showsOccurrenceCount: Bool

    init(expense: Expense, period: CashFlowPeriod) {
        let count = period.paymentCount(for: expense)
        showsOccurrenceCount = count > 1
        if count == 0 {
            occurrenceCount = nil
        } else if expense.kind == .income {
            let frequency = switch count {
            case 1: "Once"
            case 2: "Twice"
            default: "\(count) times"
            }
            occurrenceCount = "\(frequency) this \(period.kind.unit)"
        } else {
            occurrenceCount = "\(count) \(count == 1 ? "payment" : "payments") this \(period.kind.unit)"
        }

        if let nextDate = period.rowDate(for: expense) {
            date = CashFlowPeriod.calendar.isDate(nextDate, inSameDayAs: period.today)
                ? "Today"
                : CashFlowPeriod.format(nextDate, style: .dateTime.month(.abbreviated).day())
        } else if expense.recurrence == .monthly, expense.billingDay == nil {
            date = "Date varies"
        } else {
            let absence = expense.kind == .income ? "Not expected" : "Not due"
            date = "\(absence) this \(period.kind.unit)"
        }
    }

    static func overviewDateLabel(for kind: EntryKind, period: CashFlowPeriod) -> String {
        let position = period.interval.end <= period.today ? "First" : "Next"
        return "\(position) \(kind == .income ? "income" : "payment")"
    }
}
