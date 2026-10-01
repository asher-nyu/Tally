import SwiftUI

struct LedgerOverviewView: View {
    let ledger: Ledger
    let totals: PeriodTotals
    let isCompact: Bool
    let period: CashFlowPeriod
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var totalSize: CGFloat = 32

    private var nextEntry: Expense? {
        ledger.expenses
            .filter { period.nextDate(for: $0) != nil }
            .min {
                (period.nextDate(for: $0) ?? .distantFuture) <
                (period.nextDate(for: $1) ?? .distantFuture)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isCompact {
                balance
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 16) {
                        moneyIn
                        moneyOut
                    }
                } else {
                    HStack(alignment: .top, spacing: 20) {
                        moneyIn.frame(maxWidth: .infinity, alignment: .leading)
                        moneyOut.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 28) {
                    balance.frame(maxWidth: .infinity, alignment: .leading)
                    moneyIn.frame(maxWidth: .infinity, alignment: .leading)
                    moneyOut.frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                if ledger.expenses.contains(where: { $0.merchant.hasSuffix(" (conflicting copy)") }) {
                    Label("Conflicting copies are included in these totals. Review the copies and remove the version you don’t need.", systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("conflictingEntriesNotice")
                }
                Text(totalsExplanation)
                    .font(.caption)
                    .foregroundStyle(Color("SecondaryText"))
                    .accessibilityIdentifier("variableExpenseCount")
                if let nextEntry, let nextDate = period.nextDate(for: nextEntry) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "calendar")
                            .accessibilityHidden(true)
                        Text("\(ExpenseScheduleDescription.overviewDateLabel(for: nextEntry.kind, period: period)): \(CashFlowPeriod.format(nextDate, style: .dateTime.month(.abbreviated).day())) · \(nextEntry.merchant)")
                    }
                    .font(.caption)
                    .foregroundStyle(Color("SecondaryText"))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("nextBillingDate")
                }
            }
        }
    }

    private var balance: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Net cash flow")
                .font(.subheadline)
                .foregroundStyle(Color("SecondaryText"))
            Text(Money.format(totals.balanceMinor, currencyCode: ledger.currencyCode))
                .font(.system(size: totalSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("monthlyBalance")
    }

    private var moneyIn: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Income", systemImage: "arrow.down.left")
                .font(.subheadline)
                .foregroundStyle(Color("SecondaryText"))
            Text(Money.format(totals.incomeMinor, currencyCode: ledger.currencyCode))
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("monthlyIncome")
    }

    private var moneyOut: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Expenses", systemImage: "arrow.up.right")
                .font(.subheadline)
                .foregroundStyle(Color("SecondaryText"))
            Text(Money.format(totals.expenseMinor, currencyCode: ledger.currencyCode))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fixedMonthlyTotal")
    }

    private var totalsExplanation: String {
        let variableCount = totals.variableExpenseCount + totals.variableIncomeCount
        guard variableCount > 0 else { return "\(ledger.currencyCode) · Fixed amounts this \(period.kind.unit)" }
        let amounts = variableCount == 1 ? "variable amount" : "variable amounts"
        return "\(ledger.currencyCode) · Fixed amounts only · \(variableCount) \(amounts) excluded"
    }
}
