import Foundation

nonisolated enum EntryKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case expense, income

    var id: String { rawValue }
    var title: String { self == .expense ? "Expense" : "Income" }
}

nonisolated enum Recurrence: String, Codable, CaseIterable, Identifiable, Sendable {
    case monthly, everyTwoWeeks, annual, oneTime, custom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .monthly: "Monthly"
        case .everyTwoWeeks: "Every two weeks"
        case .annual: "Annually"
        case .oneTime: "One time"
        case .custom: "Custom…"
        }
    }
}

/// A Gregorian calendar date with no time or time-zone offset in the file.
nonisolated struct ScheduleDate: Codable, Equatable, Hashable, Sendable {
    var year: Int
    var month: Int
    var day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(date: Date, calendar: Calendar = .current) {
        let components = Self.gregorian(in: calendar).dateComponents([.year, .month, .day], from: date)
        year = components.year ?? 1
        month = components.month ?? 1
        day = components.day ?? 1
    }

    func date(calendar: Calendar = .current) -> Date? {
        guard (1...9_999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        let calendar = Self.gregorian(in: calendar)
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        guard actual.year == year, actual.month == month, actual.day == day else { return nil }
        return calendar.startOfDay(for: date)
    }

    var isValid: Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return date(calendar: calendar) != nil
    }

    /// Recurrence uses Gregorian dates in the requested time zone, independent
    /// of a device's preferred calendar or the zone where the file was created.
    static func gregorian(in calendar: Calendar) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = calendar.timeZone
        result.locale = calendar.locale
        return result
    }
}

nonisolated enum ExpenseCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case housing, utilities, subscriptions, food, transport, health, income, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .housing: "Housing"
        case .utilities: "Utilities"
        case .subscriptions: "Subscriptions"
        case .food: "Food"
        case .transport: "Transport"
        case .health: "Health"
        case .income: "Income"
        case .other: "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .housing: "house"
        case .utilities: "bolt"
        case .subscriptions: "repeat"
        case .food: "fork.knife"
        case .transport: "car"
        case .health: "heart"
        case .income: "arrow.down.left"
        case .other: "square.grid.2x2"
        }
    }
}

nonisolated struct Expense: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var merchant: String
    /// Integer minor units (cents for USD). Nil means the amount varies.
    var amountMinor: Int64?
    /// A recurring day of the month; nil means the billing date varies.
    var billingDay: Int?
    var category: ExpenseCategory
    var notes: String
    var kind: EntryKind
    var recurrence: Recurrence
    var anchorDate: ScheduleDate?
    var customRecurrence: CustomRecurrence?
    var websiteLink: String?
    var reminder: PaymentReminder?

    init(id: UUID = UUID(), merchant: String, amountMinor: Int64? = nil, billingDay: Int? = nil,
         category: ExpenseCategory = .other, notes: String = "", kind: EntryKind = .expense,
         recurrence: Recurrence = .monthly, anchorDate: ScheduleDate? = nil,
         customRecurrence: CustomRecurrence? = nil, websiteLink: String? = nil,
         reminder: PaymentReminder? = nil) {
        self.id = id
        self.merchant = merchant
        self.amountMinor = amountMinor
        self.billingDay = billingDay
        self.category = category
        self.notes = notes
        self.kind = kind
        self.recurrence = recurrence
        self.anchorDate = anchorDate
        self.customRecurrence = customRecurrence
        self.websiteLink = websiteLink
        self.reminder = reminder
    }

    private enum CodingKeys: String, CodingKey {
        case id, merchant, amountMinor, billingDay, category, notes, kind, recurrence, anchorDate, customRecurrence, websiteLink, reminder
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        merchant = try values.decode(String.self, forKey: .merchant)
        amountMinor = try values.decodeIfPresent(Int64.self, forKey: .amountMinor)
        billingDay = try values.decodeIfPresent(Int.self, forKey: .billingDay)
        category = try values.decode(ExpenseCategory.self, forKey: .category)
        notes = try values.decode(String.self, forKey: .notes)
        // Version-one files written before income support contain only expenses.
        kind = try values.decodeIfPresent(EntryKind.self, forKey: .kind) ?? .expense
        recurrence = try values.decodeIfPresent(Recurrence.self, forKey: .recurrence) ?? .monthly
        anchorDate = try values.decodeIfPresent(ScheduleDate.self, forKey: .anchorDate)
        customRecurrence = try values.decodeIfPresent(CustomRecurrence.self, forKey: .customRecurrence)
        websiteLink = try values.decodeIfPresent(String.self, forKey: .websiteLink)
        reminder = try values.decodeIfPresent(PaymentReminder.self, forKey: .reminder)
    }

    var recurrenceSummary: String {
        recurrence == .custom ? customRecurrence?.summary(anchor: anchorDate) ?? "Custom" : recurrence.title
    }

    /// Due dates are whole local calendar days. Today remains due all day.
    /// Months without the requested day use their final day instead.
    func nextDue(onOrAfter date: Date = .now, calendar: Calendar = .current) -> Date? {
        let calendar = ScheduleDate.gregorian(in: calendar)
        let today = calendar.startOfDay(for: date)
        if recurrence != .monthly {
            guard let anchorDate, let firstDate = anchorDate.date(calendar: calendar) else { return nil }
            switch recurrence {
            case .monthly: break
            case .custom:
                return customRecurrence?.nextDue(onOrAfter: today, anchor: anchorDate, calendar: calendar)
            case .oneTime:
                return firstDate >= today ? firstDate : nil
            case .everyTwoWeeks:
                guard today > firstDate else { return firstDate }
                guard let days = calendar.dateComponents([.day], from: firstDate, to: today).day,
                      days >= 0 else { return nil }
                let periods = days / 14 + (days.isMultiple(of: 14) ? 0 : 1)
                return calendar.date(byAdding: .day, value: periods * 14, to: firstDate)
            case .annual:
                let year = max(anchorDate.year, calendar.component(.year, from: today))
                if let due = annualDate(in: year, calendar: calendar), due >= today { return due }
                return annualDate(in: year + 1, calendar: calendar)
            }
        }
        guard let billingDay, (1...31).contains(billingDay),
              let month = calendar.dateInterval(of: .month, for: date) else { return nil }
        func dueDate(in monthStart: Date) -> Date? {
            guard let days = calendar.range(of: .day, in: .month, for: monthStart),
                  let due = calendar.date(byAdding: .day, value: min(billingDay, days.count) - 1, to: monthStart)
            else { return nil }
            return calendar.startOfDay(for: due)
        }
        if let due = dueDate(in: month.start), due >= today { return due }
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: month.start) else { return nil }
        return dueDate(in: nextMonth)
    }

    func occurrences(inMonthContaining date: Date, calendar: Calendar = .current) -> [Date] {
        occurrences(in: .month, containing: date, calendar: calendar)
    }

    func occurrences(inYearContaining date: Date, calendar: Calendar = .current) -> [Date] {
        occurrences(in: .year, containing: date, calendar: calendar)
    }

    func occurrenceCount(inMonthContaining date: Date, calendar: Calendar = .current) -> Int {
        occurrenceCount(in: .month, containing: date, calendar: calendar)
    }

    func occurrenceCount(inYearContaining date: Date, calendar: Calendar = .current) -> Int {
        occurrenceCount(in: .year, containing: date, calendar: calendar)
    }

    private func annualDate(in year: Int, calendar: Calendar) -> Date? {
        guard (1...9_999).contains(year), let anchorDate,
              let monthStart = calendar.date(from: DateComponents(year: year, month: anchorDate.month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: monthStart) else { return nil }
        return calendar.date(byAdding: .day, value: min(anchorDate.day, days.count) - 1, to: monthStart)
    }

    private func occurrences(in component: Calendar.Component, containing date: Date, calendar: Calendar) -> [Date] {
        let calendar = ScheduleDate.gregorian(in: calendar)
        guard let interval = calendar.dateInterval(of: component, for: date) else { return [] }
        var results: [Date] = []
        var next = nextDue(onOrAfter: interval.start, calendar: calendar)
        // A rule produces at most one occurrence on each Gregorian day.
        while let due = next, due < interval.end, results.count < 366 {
            guard due >= interval.start else { break }
            results.append(due)
            guard let followingDay = calendar.date(byAdding: .day, value: 1, to: due) else { break }
            next = nextDue(onOrAfter: followingDay, calendar: calendar)
        }
        return results
    }

    private func occurrenceCount(in component: Calendar.Component, containing date: Date, calendar: Calendar) -> Int {
        let calendar = ScheduleDate.gregorian(in: calendar)
        guard let interval = calendar.dateInterval(of: component, for: date) else { return 0 }
        if recurrence == .custom {
            guard let anchorDate, let customRecurrence else { return 0 }
            return customRecurrence.occurrenceCount(in: interval, anchor: anchorDate, calendar: calendar)
        }
        if recurrence == .monthly {
            if let billingDay, !(1...31).contains(billingDay) { return 0 }
            return component == .year ? 12 : 1
        }
        guard let first = nextDue(onOrAfter: interval.start, calendar: calendar), first < interval.end else { return 0 }
        guard recurrence == .everyTwoWeeks else { return 1 }
        guard let finalDay = calendar.date(byAdding: .day, value: -1, to: interval.end),
              let remainingDays = calendar.dateComponents([.day], from: first, to: finalDay).day,
              remainingDays >= 0 else { return 0 }
        return remainingDays / 14 + 1
    }
}

nonisolated struct PeriodTotals: Equatable, Sendable {
    var incomeMinor: Int64 = 0
    var expenseMinor: Int64 = 0
    var variableIncomeCount: Int = 0
    var variableExpenseCount: Int = 0

    var balanceMinor: Int64 {
        let (balance, overflow) = incomeMinor.subtractingReportingOverflow(expenseMinor)
        return overflow ? Int64.min : balance
    }
}

nonisolated struct Ledger: Codable, Equatable, Sendable {
    var formatVersion: Int
    var id: UUID
    var currencyCode: String
    var expenses: [Expense]

    init(formatVersion: Int = 6, id: UUID = UUID(), currencyCode: String = "USD", expenses: [Expense] = []) {
        self.formatVersion = formatVersion
        self.id = id
        self.currencyCode = currencyCode
        self.expenses = expenses
    }

    /// Compatibility helpers for the current month. New period views should
    /// calculate totals once with an explicit reference month or year.
    var knownMonthlyTotalMinor: Int64 { totals(inMonthContaining: .now).expenseMinor }
    var knownMonthlyIncomeMinor: Int64 { totals(inMonthContaining: .now).incomeMinor }
    var knownMonthlyBalanceMinor: Int64 { totals(inMonthContaining: .now).balanceMinor }
    var variableExpenseCount: Int { totals(inMonthContaining: .now).variableExpenseCount }
    var variableIncomeCount: Int { totals(inMonthContaining: .now).variableIncomeCount }

    func totals(inMonthContaining date: Date, calendar: Calendar = .current) -> PeriodTotals {
        totals { $0.occurrenceCount(inMonthContaining: date, calendar: calendar) }
    }

    func totals(inYearContaining date: Date, calendar: Calendar = .current) -> PeriodTotals {
        totals { $0.occurrenceCount(inYearContaining: date, calendar: calendar) }
    }

    private func totals(count: (Expense) -> Int) -> PeriodTotals {
        var result = PeriodTotals()
        for entry in expenses {
            let occurrences = count(entry)
            guard occurrences > 0 else { continue }
            guard let amount = entry.amountMinor else {
                if entry.kind == .income { result.variableIncomeCount += occurrences }
                else { result.variableExpenseCount += occurrences }
                continue
            }
            let (periodAmount, productOverflow) = amount.multipliedReportingOverflow(by: Int64(occurrences))
            let previous = entry.kind == .income ? result.incomeMinor : result.expenseMinor
            let (sum, additionOverflow) = previous.addingReportingOverflow(periodAmount)
            // Codec bounds make overflow impossible for a valid ledger.
            let total = productOverflow || additionOverflow ? Int64.max : sum
            if entry.kind == .income { result.incomeMinor = total }
            else { result.expenseMinor = total }
        }
        return result
    }
}

nonisolated enum Currency {
    static let supportedCodes = ["USD", "EUR", "GBP", "CAD", "AUD", "JPY", "CHF", "CNY", "INR", "NZD", "SGD", "KRW", "KWD", "BHD"]

    static func fractionDigits(for code: String) -> Int? {
        guard supportedCodes.contains(code) else { return nil }
        switch code {
        case "JPY", "KRW": return 0
        case "KWD", "BHD": return 3
        default: return 2
        }
    }
}
