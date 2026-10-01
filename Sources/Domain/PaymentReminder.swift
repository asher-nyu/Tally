import Foundation

nonisolated enum PaymentReminderSound: String, Codable, CaseIterable, Identifiable, Sendable {
    // Keep supported identifiers stable for saved documents and reminder caches.
    case ripple = "rebound"
    case pebble = "bamboo"
    case glow = "chord"
    case lift = "chime"
    case signal = "bell"
    case none

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let stored = try container.decode(String.self)
        if let sound = Self(rawValue: stored) {
            self = sound
        } else if ["triTone", "glass", "note", "pulse", "systemDefault"].contains(stored) {
            // Retired choices adopt the current default. Silence stays explicit.
            self = .ripple
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown reminder sound.")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var id: String { rawValue }
    var title: String {
        switch self {
        case .ripple: "Ripple"
        case .pebble: "Pebble"
        case .glow: "Glow"
        case .lift: "Lift"
        case .signal: "Signal"
        case .none: "None"
        }
    }

    // The notification coordinator refreshes cached requests with these resource
    // names on launch, including reminders whose documents are closed.
    var bundledFilename: String? {
        switch self {
        case .ripple: "Rebound.caf"
        case .pebble: "Bamboo.caf"
        case .glow: "Chord.caf"
        case .lift: "Chime.caf"
        case .signal: "Bell.caf"
        case .none: nil
        }
    }
}

/// Opt-in notification timing in the device's local time; no time zone is stored.
nonisolated struct PaymentReminder: Codable, Equatable, Sendable {
    static let supportedDaysBefore = [0, 1, 2, 7]

    var daysBefore: Int
    var hour: Int
    var minute: Int
    var sound: PaymentReminderSound

    init(daysBefore: Int = 0, hour: Int = 9, minute: Int = 0, sound: PaymentReminderSound = .ripple) {
        self.daysBefore = daysBefore
        self.hour = hour
        self.minute = minute
        self.sound = sound
    }

    private enum CodingKeys: String, CodingKey {
        case daysBefore, hour, minute, sound
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        daysBefore = try values.decode(Int.self, forKey: .daysBefore)
        hour = try values.decode(Int.self, forKey: .hour)
        minute = try values.decode(Int.self, forKey: .minute)
        // Reminders predating sound selection adopt the current default.
        sound = try values.decodeIfPresent(PaymentReminderSound.self, forKey: .sound) ?? .ripple
    }

    var isValid: Bool {
        Self.supportedDaysBefore.contains(daysBefore) && (0...23).contains(hour) && (0...59).contains(minute)
    }
}

nonisolated struct PlannedPaymentReminder: Equatable, Sendable {
    let identifier: String
    let expenseID: UUID
    /// For repeating triggers these describe their first future occurrence.
    let dueDate: Date
    let fireDate: Date
    let dateComponents: DateComponents
    let repeats: Bool
}

nonisolated struct ReminderPlan: Equatable, Sendable {
    var reminders: [PlannedPaymentReminder] = []
    var truncatedEntryIDs: Set<UUID> = []
    /// First excluded delivery, whether it exceeds the count limit or horizon.
    /// Completed schedules and complete repeating triggers have no entry here.
    var nextUnscheduledFireDateByEntry: [UUID: Date] = [:]
    let horizonEnd: Date
}

nonisolated enum ReminderPlanner {
    static let maximumOccurrencesPerEntry = 64
    static let horizonYears = 5

    static func plan(for ledger: Ledger, now: Date, calendar requestedCalendar: Calendar = .current) -> ReminderPlan {
        let calendar = ScheduleDate.gregorian(in: requestedCalendar)
        let horizon = calendar.date(byAdding: .year, value: horizonYears, to: now) ?? now
        var result = ReminderPlan(horizonEnd: horizon)
        // The planner must not schedule malformed or ambiguous imported data.
        guard (try? LedgerCodec.validate(ledger)) != nil else { return result }

        for expense in ledger.expenses {
            guard let reminder = expense.reminder else { continue }
            if let repeating = repeatingReminders(for: expense, ledgerID: ledger.id, now: now, calendar: calendar) {
                result.reminders.append(contentsOf: repeating)
                continue
            }
            var next = firstOccurrence(for: expense, now: now, calendar: calendar)
            var count = 0
            while let occurrence = next {
                // Keep each schedule’s next real reminder even beyond the
                // expansion horizon; only additional occurrences are bounded.
                if count == maximumOccurrencesPerEntry || (count > 0 && occurrence.fireDate > horizon) {
                    result.truncatedEntryIDs.insert(expense.id)
                    result.nextUnscheduledFireDateByEntry[expense.id] = occurrence.fireDate
                    break
                }
                let due = ScheduleDate(date: occurrence.dueDate, calendar: calendar)
                let suffix = String(format: "%04d%02d%02d", due.year, due.month, due.day)
                result.reminders.append(PlannedPaymentReminder(
                    identifier: identifier(ledgerID: ledger.id, expenseID: expense.id, suffix: suffix),
                    expenseID: expense.id, dueDate: occurrence.dueDate, fireDate: occurrence.fireDate,
                    dateComponents: components(for: occurrence.fireDate, calendar: calendar), repeats: false
                ))
                count += 1
                guard let followingDay = calendar.date(byAdding: .day, value: 1, to: occurrence.dueDate),
                      let dueDate = expense.nextDue(onOrAfter: followingDay, calendar: calendar), dueDate > occurrence.dueDate,
                      let fireDate = fireDate(for: dueDate, reminder: reminder, calendar: calendar), fireDate > now else { break }
                next = Occurrence(dueDate: dueDate, fireDate: fireDate)
            }
        }
        result.reminders.sort {
            $0.fireDate == $1.fireDate ? $0.identifier < $1.identifier : $0.fireDate < $1.fireDate
        }
        return result
    }

    private nonisolated struct Occurrence: Sendable {
        let dueDate: Date
        let fireDate: Date
    }

    private static func firstOccurrence(for expense: Expense, now: Date, calendar: Calendar) -> Occurrence? {
        guard let reminder = expense.reminder,
              let lower = calendar.date(byAdding: .day, value: reminder.daysBefore, to: calendar.startOfDay(for: now)) else { return nil }
        var due = expense.nextDue(onOrAfter: lower, calendar: calendar)
        // The first candidate can be today with an already-passed reminder time.
        // Its next occurrence must be on a later calendar day.
        for _ in 0..<2 {
            guard let dueDate = due, let fireDate = fireDate(for: dueDate, reminder: reminder, calendar: calendar) else { return nil }
            if fireDate > now { return Occurrence(dueDate: dueDate, fireDate: fireDate) }
            guard let followingDay = calendar.date(byAdding: .day, value: 1, to: dueDate) else { return nil }
            due = expense.nextDue(onOrAfter: followingDay, calendar: calendar)
        }
        return nil
    }

    private static func fireDate(for dueDate: Date, reminder: PaymentReminder, calendar: Calendar) -> Date? {
        guard let day = calendar.date(byAdding: .day, value: -reminder.daysBefore, to: dueDate) else { return nil }
        // Nonexistent times move to the next valid local time (e.g. 02:30 to
        // 03:00 at the spring change). An autumn overlap uses its first instance.
        return calendar.date(bySettingHour: reminder.hour, minute: reminder.minute, second: 0, of: day,
                             matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }

    private nonisolated struct RepeatingPattern {
        let suffix: String
        let components: DateComponents
    }

    private static func repeatingReminders(for expense: Expense, ledgerID: UUID, now: Date, calendar: Calendar) -> [PlannedPaymentReminder]? {
        // Native calendar-trigger probes agree with dated scheduling at 07:00–21:59
        // across the tested DST zones; overnight gap/overlap semantics remain dated.
        guard let reminder = expense.reminder, (7...21).contains(reminder.hour) else { return nil }
        let lead = reminder.daysBefore
        var patterns: [RepeatingPattern] = []
        switch expense.recurrence {
        case .monthly:
            guard let day = expense.billingDay, day <= 28, day > lead else { return nil }
            patterns = [.init(suffix: "repeat.monthly", components: DateComponents(day: day - lead))]
        case .annual:
            guard let anchor = expense.anchorDate,
                  let match = fixedAnnualPattern(month: anchor.month, day: anchor.day, lead: lead) else { return nil }
            patterns = [.init(suffix: "repeat.annual", components: match)]
        case .custom:
            guard let rule = expense.customRecurrence, rule.endDate == nil,
                  let anchor = expense.anchorDate else { return nil }
            switch rule.frequency {
            case .daily:
                guard rule.interval == 1 else { return nil }
                patterns = [.init(suffix: "repeat.daily", components: DateComponents())]
            case .weekly:
                guard rule.interval == 1 else { return nil }
                patterns = rule.weekdays.sorted().map { weekday in
                    let fireWeekday = ((weekday - 1 - lead % 7 + 7) % 7) + 1
                    return .init(suffix: "repeat.weekly.\(weekday)", components: DateComponents(weekday: fireWeekday))
                }
            case .monthly:
                // Only divisors of 12 preserve their month phase every year.
                guard 12.isMultiple(of: rule.interval) else { return nil }
                let months = (1...12).filter { ($0 - anchor.month + 12).isMultiple(of: rule.interval) }
                // Ordinal matching can normalize to a different calendar day
                // instead of skipping a missing match; retain exact dated alerts.
                guard rule.ordinal == nil else { return nil }
                if rule.interval == 1 && rule.monthDays.allSatisfy({ $0 <= 28 && $0 > lead }) {
                    patterns = rule.monthDays.sorted().map { day in
                        .init(suffix: "repeat.custom.monthly.day.\(day)", components: DateComponents(day: day - lead))
                    }
                } else {
                    for month in months {
                        for day in rule.monthDays.sorted() {
                            guard let match = fixedAnnualPattern(month: month, day: day, lead: lead) else { return nil }
                            patterns.append(.init(suffix: "repeat.custom.monthly.\(match.month!).\(match.day!)", components: match))
                        }
                    }
                }
            case .yearly:
                guard rule.interval == 1 else { return nil }
                for month in rule.months.sorted() {
                    guard rule.ordinal == nil,
                          let match = fixedAnnualPattern(month: month, day: anchor.day, lead: lead) else { return nil }
                    patterns.append(.init(suffix: "repeat.custom.yearly.\(match.month!).\(match.day!)", components: match))
                }
            }
        case .everyTwoWeeks, .oneTime:
            return nil
        }

        // Clamped selected days can coincide (e.g. April 30 and April 31).
        var seen = Set<String>()
        patterns = patterns.filter { seen.insert($0.suffix).inserted }
        guard !patterns.isEmpty, patterns.count <= maximumOccurrencesPerEntry else { return nil }
        var result: [PlannedPaymentReminder] = []
        for pattern in patterns {
            var match = pattern.components
            match.hour = reminder.hour
            match.minute = reminder.minute
            match.second = 0
            guard let fire = calendar.nextDate(after: now, matching: match, matchingPolicy: .nextTime, repeatedTimePolicy: .first),
                  let due = calendar.date(byAdding: .day, value: lead, to: calendar.startOfDay(for: fire)),
                  expense.nextDue(onOrAfter: due, calendar: calendar) == due,
                  fireDate(for: due, reminder: reminder, calendar: calendar) == fire else {
                // A repeating trigger has no separate start date. If it would
                // fire before this rule's first real occurrence, queue dates.
                return nil
            }
            match.calendar = triggerCalendar()
            result.append(PlannedPaymentReminder(
                identifier: identifier(ledgerID: ledgerID, expenseID: expense.id, suffix: pattern.suffix),
                expenseID: expense.id, dueDate: due, fireDate: fire, dateComponents: match, repeats: true
            ))
        }
        return result
    }

    /// Gregorian month lengths differ only in February. Checking a leap and
    /// common year proves whether the clamped date and lead have a stable
    /// month/day pattern; March reminders that move across leap day do not.
    private static func fixedAnnualPattern(month: Int, day: Int, lead: Int) -> DateComponents? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var result: DateComponents?
        for year in [2000, 2001] {
            guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  let days = calendar.range(of: .day, in: .month, for: first),
                  let due = calendar.date(from: DateComponents(year: year, month: month, day: min(day, days.count))),
                  let fire = calendar.date(byAdding: .day, value: -lead, to: due) else { return nil }
            let match = calendar.dateComponents([.month, .day], from: fire)
            if let result, result != match { return nil }
            result = match
        }
        return result
    }

    private static func components(for date: Date, calendar: Calendar) -> DateComponents {
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        components.calendar = triggerCalendar()
        return components
    }

    private static func triggerCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    private static func identifier(ledgerID: UUID, expenseID: UUID, suffix: String) -> String {
        "tally.payment.\(ledgerID.uuidString).\(expenseID.uuidString).\(suffix)"
    }
}
