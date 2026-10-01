import Foundation
import Observation
import UserNotifications

/// The operating system owns delivery. This service reconciles saved schedules
/// after edits, activation, and system-granted background maintenance.
@MainActor
@Observable
final class NotificationCoordinator {
    nonisolated enum Authorization: Equatable, Sendable {
        case notDetermined, denied, authorized, provisional, ephemeral, unknown

        var allowsScheduling: Bool {
            self == .authorized || self == .provisional || self == .ephemeral
        }

        init(_ status: UNAuthorizationStatus) {
            switch status {
            case .notDetermined: self = .notDetermined
            case .denied: self = .denied
            case .authorized: self = .authorized
            case .provisional: self = .provisional
            #if os(iOS)
            case .ephemeral: self = .ephemeral
            #endif
            @unknown default: self = .unknown
            }
        }
    }

    nonisolated struct Coverage: Equatable, Sendable {
        var enabledEntryCount = 0
        var pendingCount = 0
        var repeatingEntryCount = 0
        var unscheduledEntryCount = 0
        /// Earliest known reminder that is not in the operating system's queue.
        /// Used internally to plan automatic queue maintenance.
        var nextUnscheduledDate: Date?
        var capacityLimited = false

        var hasFiniteSchedule: Bool { nextUnscheduledDate != nil }
        var finiteThroughDate: Date? { nextUnscheduledDate?.addingTimeInterval(-1) }
    }

    struct Dependencies {
        var authorization: @MainActor () async -> Authorization
        var requestAuthorization: @MainActor () async throws -> Bool
        var pendingIdentifiers: @MainActor () async -> [String]
        var add: @MainActor (UNNotificationRequest) async throws -> Void
        var remove: @MainActor ([String]) -> Void
        var configure: @MainActor (any UNUserNotificationCenterDelegate) -> Void
        var loadCache: @MainActor () throws -> [Ledger]
        var saveCache: @MainActor ([Ledger]) throws -> Void
        var openWebsite: @MainActor (URL) async -> Bool
        var now: @MainActor () -> Date = { .now }
        var calendar: @MainActor () -> Calendar = { .current }
        var scheduleBackgroundRefresh: @MainActor (Date?, Date) -> Void = { _, _ in }
    }

    static let shared: NotificationCoordinator = {
        let disabled = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--ui-testing") }
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        return NotificationCoordinator(dependencies: disabled ? .inert : .live, disabled: disabled)
    }()

    private(set) var authorizationStatus: Authorization = .notDetermined
    private(set) var schedulingError: String?
    private(set) var coverage = Coverage()
    private(set) var isScheduling = false

    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private let disabled: Bool
    @ObservationIgnored private let debounceNanoseconds: UInt64
    @ObservationIgnored private var cachedLedgers: [UUID: Ledger] = [:]
    @ObservationIgnored private var delegate: PaymentNotificationDelegate?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var cacheAvailable = true
    @ObservationIgnored private var cacheError: String?
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var permissionTask: Task<Bool, Never>?

    nonisolated static let requestPrefix = "tally.payment."
    nonisolated static let websiteAction = "tally.payment.openWebsite"
    nonisolated static let websiteCategory = "tally.payment.withWebsite"
    nonisolated static let maximumPendingRequests = 64

    init(dependencies: Dependencies, disabled: Bool = false, debounceNanoseconds: UInt64 = 200_000_000) {
        self.dependencies = dependencies
        self.disabled = disabled
        self.debounceNanoseconds = debounceNanoseconds
        if disabled { authorizationStatus = .authorized }
    }

    /// Call synchronously from app initialization, before launch finishes.
    /// Observation and restoring the cache never request notification permission.
    func start() {
        guard !started else { return }
        started = true
        guard !disabled else { return }
        let delegate = PaymentNotificationDelegate { [weak self] action, website in
            await self?.handleResponse(action: action, website: website)
        }
        self.delegate = delegate
        dependencies.configure(delegate)
        do {
            var migratedCache = false
            for var ledger in try dependencies.loadCache() {
                if ledger.formatVersion != LedgerCodec.currentFormatVersion {
                    // Cached documents need the same migration as files. In
                    // particular, retired sounds must resolve to a supported choice.
                    ledger = try LedgerCodec.decode(JSONEncoder().encode(ledger))
                    migratedCache = true
                }
                try LedgerCodec.validate(ledger)
                cachedLedgers[ledger.id] = ledger
            }
            if migratedCache { persistCache() }
        } catch {
            // An unreadable cache must not make existing reminders look deleted.
            cacheAvailable = false
            cacheError = "Saved reminders could not be restored: \(error.localizedDescription)"
            schedulingError = cacheError
        }
        enqueue()
    }

    /// Attach the current value after saves, edits, undo, deletes and cloud merges.
    /// Other documents stay cached even when they are not open in this session.
    func attach(_ ledger: Ledger) {
        start()
        guard !disabled else { return }
        do {
            try LedgerCodec.validate(ledger)
        } catch {
            schedulingError = "This document’s reminders could not be updated: \(error.localizedDescription)"
            return
        }
        var snapshot = ledger
        snapshot.expenses = ledger.expenses.filter { $0.reminder != nil }
        guard cachedLedgers[ledger.id] != snapshot else { return }
        if snapshot.expenses.isEmpty {
            cachedLedgers.removeValue(forKey: ledger.id)
        } else {
            cachedLedgers[ledger.id] = snapshot
        }
        persistCache()
        enqueue()
    }

    /// Explicitly stop this device's cached reminders for a removed document.
    func forgetLedger(id: UUID) {
        start()
        guard !disabled, cachedLedgers.removeValue(forKey: id) != nil else { return }
        persistCache()
        enqueue()
    }

    func forget(ledgerID: UUID) { forgetLedger(id: ledgerID) }

    func refreshAuthorizationStatus() async {
        start()
        guard !disabled else { return }
        authorizationStatus = await dependencies.authorization()
        enqueue()
    }

    /// Only call in response to the user's explicit reminder-enable/save action.
    /// Simultaneous saves share one permission request.
    func requestPermission() async -> Bool {
        start()
        guard !disabled else { return true }
        if let permissionTask { return await permissionTask.value }
        let task = Task { @MainActor in
            authorizationStatus = await dependencies.authorization()
            if authorizationStatus == .notDetermined {
                do {
                    _ = try await dependencies.requestAuthorization()
                } catch {
                    schedulingError = "Notification permission could not be requested: \(error.localizedDescription)"
                    return false
                }
                authorizationStatus = await dependencies.authorization()
            }
            enqueue()
            return authorizationStatus.allowsScheduling
        }
        permissionTask = task
        let result = await task.value
        permissionTask = nil
        return result
    }

    /// Useful when a caller needs the current reconciliation to finish.
    func reconcileNow() async {
        start()
        guard !disabled else { return }
        enqueue()
        await worker?.value
    }

    private func persistCache() {
        guard cacheAvailable else { return }
        do {
            try dependencies.saveCache(cachedLedgers.values.sorted { $0.id.uuidString < $1.id.uuidString })
            cacheError = nil
        } catch {
            cacheError = "Reminders could not be saved on this device: \(error.localizedDescription)"
            schedulingError = cacheError
        }
    }

    private func enqueue() {
        revision &+= 1
        guard worker == nil, !disabled else { return }
        worker = Task { @MainActor in
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
            }
            isScheduling = true
            while true {
                let currentRevision = revision
                await reconcile(revision: currentRevision)
                if revision == currentRevision { break }
            }
            isScheduling = false
            worker = nil
        }
    }

    private struct Candidate {
        var reminder: PlannedPaymentReminder
        var ledger: Ledger
        var expense: Expense
        var entryKey: String { "\(ledger.id).\(expense.id)" }
    }

    private func reconcile(revision currentRevision: UInt64) async {
        guard cacheAvailable else { return }
        authorizationStatus = await dependencies.authorization()
        guard revision == currentRevision else { return }
        let pendingIDs = await dependencies.pendingIdentifiers()
        guard revision == currentRevision else { return }
        let ownedIDs = pendingIDs.filter { $0.hasPrefix(Self.requestPrefix) }
        let availableSlots = max(0, Self.maximumPendingRequests - (pendingIDs.count - ownedIDs.count))
        let now = dependencies.now()
        let calendar = dependencies.calendar()
        var candidates: [Candidate] = []
        var omittedDates: [Date] = []
        var futureEntryKeys = Set<String>()
        let ledgers = cachedLedgers.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let enabledCount = ledgers.reduce(0) { $0 + $1.expenses.count }

        for ledger in ledgers {
            let plan = ReminderPlanner.plan(for: ledger, now: now, calendar: calendar)
            let entries = Dictionary(uniqueKeysWithValues: ledger.expenses.map { ($0.id, $0) })
            for reminder in plan.reminders {
                guard let expense = entries[reminder.expenseID] else { continue }
                let candidate = Candidate(reminder: reminder, ledger: ledger, expense: expense)
                candidates.append(candidate)
                futureEntryKeys.insert(candidate.entryKey)
            }
            for (entryID, date) in plan.nextUnscheduledFireDateByEntry {
                futureEntryKeys.insert("\(ledger.id).\(entryID)")
                omittedDates.append(date)
            }
        }
        candidates.sort {
            if $0.reminder.fireDate != $1.reminder.fireDate { return $0.reminder.fireDate < $1.reminder.fireDate }
            return $0.reminder.identifier < $1.reminder.identifier
        }
        // Reserve each item's next reminder before filling the remaining slots.
        // Otherwise a dense custom schedule can consume the entire queue and
        // prevent a later annual or one-time reminder from ever being registered.
        var representedEntries = Set<String>()
        let nextPerEntry = candidates.filter { representedEntries.insert($0.entryKey).inserted }
        let firstIDs = Set(nextPerEntry.map { $0.reminder.identifier })
        let remaining = candidates.filter { !firstIDs.contains($0.reminder.identifier) }
        // Keep all recurring weekday/month patterns whenever capacity allows;
        // each one covers an ongoing series using only one system request.
        let prioritized = nextPerEntry + remaining.filter { $0.reminder.repeats }
            + remaining.filter { !$0.reminder.repeats }
        let selected = authorizationStatus.allowsScheduling ? Array(prioritized.prefix(availableSlots)) : []
        let selectedIDs = Set(selected.map { $0.reminder.identifier })
        omittedDates.append(contentsOf: candidates.filter { !selectedIDs.contains($0.reminder.identifier) }.map { $0.reminder.fireDate })

        // Never remove unrelated requests, and free obsolete slots before adding.
        dependencies.remove(ownedIDs.filter { !selectedIDs.contains($0) })
        var successful: [Candidate] = []
        var failure: String?
        for candidate in selected {
            guard revision == currentRevision else { return }
            do {
                try await dependencies.add(request(for: candidate))
                successful.append(candidate)
            } catch {
                // Do not leave an older request with the same identifier but stale content.
                dependencies.remove([candidate.reminder.identifier])
                omittedDates.append(candidate.reminder.fireDate)
                failure = "Some reminders could not be scheduled: \(error.localizedDescription)"
            }
        }
        guard revision == currentRevision else { return }
        let scheduledEntries = Set(successful.map(\.entryKey))
        coverage = Coverage(
            enabledEntryCount: enabledCount,
            pendingCount: successful.count,
            repeatingEntryCount: Set(successful.filter { $0.reminder.repeats }.map(\.entryKey)).count,
            unscheduledEntryCount: futureEntryKeys.subtracting(scheduledEntries).count,
            nextUnscheduledDate: omittedDates.min(),
            capacityLimited: candidates.count > availableSlots
        )
        schedulingError = cacheError ?? failure
        dependencies.scheduleBackgroundRefresh(
            authorizationStatus.allowsScheduling ? coverage.nextUnscheduledDate : nil, now
        )
    }

    private func request(for candidate: Candidate) -> UNNotificationRequest {
        let expense = candidate.expense
        let content = UNMutableNotificationContent()
        content.title = expense.merchant
        let subject = expense.kind == .income ? "Income" : "Payment"
        let timing = expense.kind == .income ? "is expected" : "is due"
        let amount = expense.amountMinor.map { Money.format($0, currencyCode: candidate.ledger.currencyCode) }
        let lead = expense.reminder?.daysBefore ?? 0
        let when = lead == 0 ? "today" : lead == 1 ? "tomorrow" : "in \(lead) days"
        content.body = amount.map { "\(subject) of \($0) \(timing) \(when)." } ?? "\(subject) with a variable amount \(timing) \(when)."
        let sound = expense.reminder?.sound ?? .ripple
        if let filename = sound.bundledFilename {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(filename))
        } else {
            content.sound = nil
        }
        content.threadIdentifier = candidate.ledger.id.uuidString
        content.userInfo = ["ledgerID": candidate.ledger.id.uuidString, "expenseID": expense.id.uuidString]
        if let website = try? ProviderLink.websiteURL(expense.websiteLink) {
            content.categoryIdentifier = Self.websiteCategory
            content.userInfo["website"] = website.absoluteString
        }
        let trigger = UNCalendarNotificationTrigger(dateMatching: candidate.reminder.dateComponents, repeats: candidate.reminder.repeats)
        return UNNotificationRequest(identifier: candidate.reminder.identifier, content: content, trigger: trigger)
    }

    private func handleResponse(action: String, website: String?) async {
        if action == Self.websiteAction, let url = try? ProviderLink.websiteURL(website) {
            if !(await dependencies.openWebsite(url)) {
                schedulingError = "The reminder’s website could not be opened. You can open or edit it in Tally."
            }
        }
        await refreshAuthorizationStatus()
    }
}

private final class PaymentNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    nonisolated private let response: @MainActor @Sendable (String, String?) async -> Void

    init(response: @escaping @MainActor @Sendable (String, String?) async -> Void) {
        self.response = response
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let website = response.notification.request.content.userInfo["website"] as? String
        await self.response(action, website)
    }
}

extension NotificationCoordinator.Dependencies {
    static var live: Self {
        let center = UNUserNotificationCenter.current()
        let cacheKey = "Tally.paymentReminderSnapshots.v1"
        return Self(
            authorization: {
                await withCheckedContinuation { continuation in
                    center.getNotificationSettings { settings in
                        continuation.resume(returning: NotificationCoordinator.Authorization(settings.authorizationStatus))
                    }
                }
            },
            requestAuthorization: {
                try await withCheckedThrowingContinuation { continuation in
                    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: granted) }
                    }
                }
            },
            pendingIdentifiers: {
                await withCheckedContinuation { continuation in
                    center.getPendingNotificationRequests { requests in
                        continuation.resume(returning: requests.map(\.identifier))
                    }
                }
            },
            add: { request in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    center.add(request) { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
            },
            remove: { center.removePendingNotificationRequests(withIdentifiers: $0) },
            configure: { delegate in
                center.delegate = delegate
                let action = UNNotificationAction(identifier: NotificationCoordinator.websiteAction, title: "Open website", options: [.foreground])
                let category = UNNotificationCategory(identifier: NotificationCoordinator.websiteCategory, actions: [action], intentIdentifiers: [], options: [])
                center.setNotificationCategories([category])
            },
            loadCache: {
                guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return [] }
                return try JSONDecoder().decode([Ledger].self, from: data)
            },
            saveCache: { ledgers in
                UserDefaults.standard.set(try JSONEncoder().encode(ledgers), forKey: cacheKey)
            },
            openWebsite: { await ProviderWebsiteOpener.live.open($0) },
            scheduleBackgroundRefresh: { date, now in
                ReminderBackgroundRefresh.shared.schedule(nextUnscheduledDate: date, now: now)
            }
        )
    }

    static var inert: Self {
        Self(authorization: { .authorized }, requestAuthorization: { true }, pendingIdentifiers: { [] }, add: { _ in }, remove: { _ in }, configure: { _ in }, loadCache: { [] }, saveCache: { _ in }, openWebsite: { _ in false })
    }
}
