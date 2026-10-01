import SwiftUI

struct ExpenseRowView: View {
    let expense: Expense
    let currencyCode: String
    let isCompact: Bool
    let period: CashFlowPeriod
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        categoryIcon
                        nameAndCategory
                    }
                    amount
                        .padding(.leading, 44)
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    categoryIcon
                    nameAndCategory
                    Spacer(minLength: 12)
                    if !isCompact {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(schedule.date, systemImage: "calendar")
                                .font(.subheadline)
                            if schedule.showsOccurrenceCount, let count = schedule.occurrenceCount {
                                Text(count)
                                    .font(.caption)
                            }
                        }
                        .foregroundStyle(Color("SecondaryText"))
                        .frame(width: 128, alignment: .leading)
                    }
                    amount
                        .frame(minWidth: isCompact ? 72 : 120, alignment: .trailing)
                        .layoutPriority(1)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibilityDescription)
    }

    private var categoryIcon: some View {
        Image(systemName: expense.kind == .income ? "arrow.down.left" : expense.category.symbolName)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(expense.kind == .income ? Color.accentColor : Color.secondary)
            .frame(width: 32, height: 32)
            .background((expense.kind == .income ? Color.accentColor : Color.secondary).opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)
    }

    private var nameAndCategory: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(expense.merchant)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .help(expense.merchant)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(isCompact ? "\(entryDescription) · \(schedule.date)" : entryDescription)
                    .fixedSize(horizontal: false, vertical: true)
                if let reminder = expense.reminder {
                    Image(systemName: "bell")
                        .help("Reminder: \(reminderDescription(reminder))")
                        .accessibilityHidden(true)
                }
            }
            .font(.caption)
            .foregroundStyle(Color("SecondaryText"))
        }
    }

    private func reminderDescription(_ reminder: PaymentReminder) -> String {
        let lead = switch reminder.daysBefore {
        case 0: "On the day"
        case 1: "1 day before"
        case 7: "1 week before"
        default: "\(reminder.daysBefore) days before"
        }
        let time = CashFlowPeriod.calendar.date(bySettingHour: reminder.hour, minute: reminder.minute, second: 0, of: period.today)
        return time.map { "\(lead), \($0.formatted(date: .omitted, time: .shortened))" } ?? lead
    }

    private var amount: some View {
        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 4) {
            Text(amountDescription)
                .font(expense.amountMinor == nil ? .subheadline : .body.weight(.semibold))
                .foregroundStyle(expense.amountMinor == nil ? Color("SecondaryText") : (expense.kind == .income ? .accentColor : .primary))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(expense.customRecurrence?.intervalDescription ?? expense.recurrence.title)
                .font(.caption)
                .foregroundStyle(Color("SecondaryText"))
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
        }
    }

    private var billingDescription: String {
        if expense.recurrence == .monthly, let day = expense.billingDay {
            return "Day \(day) each month"
        }
        return expense.recurrenceSummary
    }

    private var schedule: ExpenseScheduleDescription {
        ExpenseScheduleDescription(expense: expense, period: period)
    }

    private var scheduleAccessibilityDescription: String {
        ([billingDescription, schedule.date] + [schedule.occurrenceCount].compactMap { $0 })
            .joined(separator: ", ")
    }

    private var rowAccessibilityDescription: String {
        let details = "\(expense.merchant), \(expense.kind.title), \(expense.category.title), \(Money.format(expense.amountMinor, currencyCode: currencyCode)), \(scheduleAccessibilityDescription)"
        guard let reminder = expense.reminder else { return details }
        return "\(details), Reminder: \(reminderDescription(reminder))"
    }

    private var entryDescription: String {
        expense.kind == .income ? ExpenseCategory.income.title : expense.category.title
    }

    private var amountDescription: String {
        let formatted = Money.format(expense.amountMinor, currencyCode: currencyCode)
        return expense.kind == .income && expense.amountMinor != nil ? "+\(formatted)" : formatted
    }
}
