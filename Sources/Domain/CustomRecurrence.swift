import Foundation

/// A calendar-only rule. Weekdays use Gregorian numbering (Sunday = 1).
/// Monthly days clamp to month-end; a missing fifth weekday skips that month.
nonisolated struct CustomRecurrence: Codable, Equatable, Sendable {
    nonisolated enum Frequency: String, Codable, CaseIterable, Identifiable, Sendable {
        case daily, weekly, monthly, yearly

        var id: String { rawValue }
        var title: String {
            switch self {
            case .daily: "Daily"
            case .weekly: "Weekly"
            case .monthly: "Monthly"
            case .yearly: "Yearly"
            }
        }
    }

    var frequency: Frequency
    var interval: Int
    var weekdays: [Int]
    var monthDays: [Int]
    var months: [Int]
    /// First through fifth, or -1 for last. Always paired with ordinalWeekday.
    var ordinal: Int?
    var ordinalWeekday: Int?
    var endDate: ScheduleDate?

    init(frequency: Frequency = .daily, interval: Int = 1, weekdays: [Int] = [],
         monthDays: [Int] = [], months: [Int] = [], ordinal: Int? = nil,
         ordinalWeekday: Int? = nil, endDate: ScheduleDate? = nil) {
        self.frequency = frequency
        self.interval = interval
        self.weekdays = weekdays
        self.monthDays = monthDays
        self.months = months
        self.ordinal = ordinal
        self.ordinalWeekday = ordinalWeekday
        self.endDate = endDate
    }

    func isValid(anchor: ScheduleDate) -> Bool {
        guard anchor.isValid, (1...999).contains(interval),
              Self.validSelection(weekdays, within: 1...7),
              Self.validSelection(monthDays, within: 1...31),
              Self.validSelection(months, within: 1...12) else { return false }
        if let ordinal {
            guard [-1, 1, 2, 3, 4, 5].contains(ordinal),
                  let ordinalWeekday, (1...7).contains(ordinalWeekday) else { return false }
        } else if ordinalWeekday != nil { return false }
        if let endDate {
            guard endDate.isValid,
                  (endDate.year, endDate.month, endDate.day) >= (anchor.year, anchor.month, anchor.day) else { return false }
        }
        switch frequency {
        case .daily:
            return weekdays.isEmpty && monthDays.isEmpty && months.isEmpty && ordinal == nil
        case .weekly:
            return !weekdays.isEmpty && monthDays.isEmpty && months.isEmpty && ordinal == nil
        case .monthly:
            return weekdays.isEmpty && months.isEmpty && (ordinal == nil ? !monthDays.isEmpty : monthDays.isEmpty)
        case .yearly:
            return weekdays.isEmpty && monthDays.isEmpty && !months.isEmpty
        }
    }

    func nextDue(onOrAfter date: Date, anchor: ScheduleDate, calendar requestedCalendar: Calendar) -> Date? {
        let calendar = ScheduleDate.gregorian(in: requestedCalendar)
        guard isValid(anchor: anchor), let first = anchor.date(calendar: calendar) else { return nil }
        let lower = max(calendar.startOfDay(for: date), first)
        let queryYear = calendar.component(.year, from: lower)
        guard calendar.component(.era, from: lower) == 1, (1...9_999).contains(queryYear) else { return nil }
        let end = endDate?.date(calendar: calendar)
        if let end, lower > end { return nil }

        func acceptable(_ candidate: Date?) -> Date? {
            guard let candidate, candidate >= lower,
                  calendar.component(.era, from: candidate) == 1,
                  calendar.component(.year, from: candidate) <= 9_999 else { return nil }
            if let end, candidate > end { return nil }
            return candidate
        }

        switch frequency {
        case .daily:
            return acceptable(Self.nextCadence(first: first, step: interval, lower: lower, calendar: calendar))
        case .weekly:
            guard let weekStart = sunday(onOrBefore: first, calendar: calendar) else { return nil }
            // Each selected weekday is an independent interval-week series.
            // Sunday is fixed here rather than using the device's firstWeekday.
            return weekdays.compactMap { weekday -> Date? in
                guard let seed = calendar.date(byAdding: .day, value: weekday - 1, to: weekStart) else { return nil }
                return acceptable(Self.nextCadence(first: seed, step: interval * 7, lower: lower, calendar: calendar))
            }.min()
        case .monthly:
            let queryMonth = calendar.component(.month, from: lower)
            let elapsed = (queryYear - anchor.year) * 12 + queryMonth - anchor.month
            var monthIndex = (anchor.year - 1) * 12 + anchor.month - 1 + (elapsed / interval) * interval
            // Gregorian weekday patterns repeat every 4,800 months. Searching
            // one complete cycle also terminates impossible fifth-weekday rules.
            for _ in 0..<4_800 {
                let year = monthIndex / 12 + 1
                let month = monthIndex % 12 + 1
                guard year <= 9_999,
                      let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return nil }
                if let end, monthStart > end { return nil }
                if let due = dates(inYear: year, month: month, anchorDay: anchor.day, calendar: calendar)
                    .first(where: { $0 >= lower }) { return acceptable(due) }
                monthIndex += interval
            }
            return nil
        case .yearly:
            var year = anchor.year + ((queryYear - anchor.year) / interval) * interval
            // A Gregorian cycle contains every possible selected-month weekday
            // pattern, even when the interval skips over many years at a time.
            for _ in 0..<400 {
                guard year <= 9_999,
                      let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else { return nil }
                if let end, yearStart > end { return nil }
                for month in months.sorted() {
                    if let due = dates(inYear: year, month: month, anchorDay: anchor.day, calendar: calendar)
                        .first(where: { $0 >= lower }) { return acceptable(due) }
                }
                year += interval
            }
            return nil
        }
    }

    /// Fast arithmetic counts for dense daily/weekly rules keep a 10,000-entry
    /// ledger bounded without allocating millions of intermediate dates.
    func occurrenceCount(in period: DateInterval, anchor: ScheduleDate, calendar requestedCalendar: Calendar) -> Int {
        let calendar = ScheduleDate.gregorian(in: requestedCalendar)
        guard isValid(anchor: anchor), let first = anchor.date(calendar: calendar),
              let finalDay = calendar.date(byAdding: .day, value: -1, to: period.end) else { return 0 }
        let lower = max(period.start, first)
        let upper = min(finalDay, endDate?.date(calendar: calendar) ?? finalDay)
        guard lower <= upper else { return 0 }
        func count(first seed: Date, step: Int) -> Int {
            guard let next = Self.nextCadence(first: seed, step: step, lower: lower, calendar: calendar), next <= upper,
                  let days = calendar.dateComponents([.day], from: next, to: upper).day else { return 0 }
            return days / step + 1
        }
        switch frequency {
        case .daily:
            return count(first: first, step: interval)
        case .weekly:
            guard let weekStart = sunday(onOrBefore: first, calendar: calendar) else { return 0 }
            return weekdays.reduce(0) { total, weekday in
                guard let seed = calendar.date(byAdding: .day, value: weekday - 1, to: weekStart) else { return total }
                return total + count(first: seed, step: interval * 7)
            }
        case .monthly, .yearly:
            var total = 0
            var next = nextDue(onOrAfter: lower, anchor: anchor, calendar: calendar)
            while let due = next, due <= upper, total < 366 {
                total += 1
                guard let followingDay = calendar.date(byAdding: .day, value: 1, to: due) else { break }
                next = nextDue(onOrAfter: followingDay, anchor: anchor, calendar: calendar)
            }
            return total
        }
    }

    var intervalDescription: String {
        let unit: String
        switch frequency {
        case .daily: unit = "day"
        case .weekly: unit = "week"
        case .monthly: unit = "month"
        case .yearly: unit = "year"
        }
        return interval == 1 ? "Every \(unit)" : "Every \(interval) \(unit)s"
    }

    func summary(anchor: ScheduleDate?) -> String {
        var parts = [intervalDescription]
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = .current
        let weekdayNames = formatter.shortWeekdaySymbols ?? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        if frequency == .weekly {
            parts.append(weekdays.sorted().filter { (1...7).contains($0) }.map { weekdayNames[$0 - 1] }.joined(separator: ", "))
        }
        if frequency == .yearly {
            let monthNames = formatter.shortMonthSymbols ?? ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            parts.append(months.sorted().filter { (1...12).contains($0) }.map { monthNames[$0 - 1] }.joined(separator: ", "))
        }
        if let ordinal, let ordinalWeekday, (1...7).contains(ordinalWeekday) {
            let ordinalNames = [-1: "Last", 1: "First", 2: "Second", 3: "Third", 4: "Fourth", 5: "Fifth"]
            parts.append("\(ordinalNames[ordinal] ?? String(ordinal)) \(weekdayNames[ordinalWeekday - 1])")
        } else if frequency == .monthly {
            parts.append("\(monthDays.count == 1 ? "Day" : "Days") \(monthDays.sorted().map(String.init).joined(separator: ", "))")
        } else if frequency == .yearly, let anchor {
            parts.append("Day \(anchor.day)")
        }
        if let endDate, let end = endDate.date() {
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            parts.append("Through \(formatter.string(from: end))")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func validSelection(_ selection: [Int], within range: ClosedRange<Int>) -> Bool {
        selection.count <= range.count && selection.allSatisfy(range.contains) && Set(selection).count == selection.count
    }

    private static func nextCadence(first: Date, step: Int, lower: Date, calendar: Calendar) -> Date? {
        guard lower > first else { return first }
        guard let days = calendar.dateComponents([.day], from: first, to: lower).day, days >= 0 else { return nil }
        let periods = days / step + (days.isMultiple(of: step) ? 0 : 1)
        return calendar.date(byAdding: .day, value: periods * step, to: first)
    }

    private func sunday(onOrBefore date: Date, calendar: Calendar) -> Date? {
        calendar.date(byAdding: .day, value: -(calendar.component(.weekday, from: date) - 1), to: date)
    }

    private func dates(inYear year: Int, month: Int, anchorDay: Int, calendar: Calendar) -> [Date] {
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: start) else { return [] }
        let days: [Int]
        if let ordinal, let ordinalWeekday {
            let firstWeekday = calendar.component(.weekday, from: start)
            let firstMatch = 1 + (ordinalWeekday - firstWeekday + 7) % 7
            let day = ordinal == -1
                ? firstMatch + ((range.count - firstMatch) / 7) * 7
                : firstMatch + (ordinal - 1) * 7
            guard range.contains(day) else { return [] }
            days = [day]
        } else {
            let selected = frequency == .monthly ? monthDays : [anchorDay]
            days = Set(selected.map { min($0, range.count) }).sorted()
        }
        return days.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: start) }
    }
}
