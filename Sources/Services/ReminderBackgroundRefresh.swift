import Foundation
#if os(iOS)
import BackgroundTasks
#endif

/// Requests system-managed opportunities to replenish the local reminder queue.
/// Delivery of notifications remains the responsibility of UserNotifications.
@MainActor
final class ReminderBackgroundRefresh {
    typealias Refresh = @MainActor @Sendable () async -> Void
    typealias Launch = @MainActor @Sendable (Execution) -> Void

    @MainActor struct Execution {
        var installExpirationHandler: (@escaping @Sendable () -> Void) -> Void
        var complete: (Bool) -> Void
    }

    @MainActor struct Dependencies {
        var register: @MainActor (@escaping Launch) -> Bool
        var submit: @MainActor (Date) async throws -> Void
        var cancel: @MainActor () -> Void
        var now: @MainActor () -> Date = { .now }
    }

    nonisolated static let identifier = "com.asherbloom.Tally.reminderRefresh"
    nonisolated static let minimumDelay: TimeInterval = 15 * 60
    nonisolated static let maintenanceInterval: TimeInterval = 6 * 60 * 60
    nonisolated static let coverageMargin: TimeInterval = 24 * 60 * 60

    static let shared: ReminderBackgroundRefresh = {
        let disabled = ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--ui-testing") })
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        return ReminderBackgroundRefresh(dependencies: disabled ? .inert : .live, disabled: disabled)
    }()

    private let dependencies: Dependencies
    private let disabled: Bool
    private var registered = false
    private var attemptedRegistration = false
    private var refresh: Refresh?
    private var nextUnscheduledDate: Date?
    private var coverageKnown = false
    private var active: ActiveExecution?
    private var submission: Task<Void, Never>?
    private var desiredDate: Date?
    private var submittingDate: Date?
    private var cancellationRevision: UInt64 = 0
    private var submittingRevision: UInt64 = 0

    private(set) var scheduledDate: Date?
    private(set) var lastSubmissionError: String?
    var isRefreshing: Bool { active != nil }

    private struct ActiveExecution {
        let id: UUID
        let complete: (Bool) -> Void
        var task: Task<Void, Never>?
    }

    init(dependencies: Dependencies, disabled: Bool = false) {
        self.dependencies = dependencies
        self.disabled = disabled
    }

    /// Register during app initialization, before the launch sequence finishes.
    func start(refresh: @escaping Refresh) {
        guard !disabled else { return }
        self.refresh = refresh
        guard !attemptedRegistration else { return }
        attemptedRegistration = true
        registered = dependencies.register { [weak self] execution in
            guard let self else { execution.complete(false); return }
            self.receive(execution)
        }
        if registered, coverageKnown { arm(now: dependencies.now()) }
    }

    /// Repeated foreground reconciliations must not push an existing request back.
    func schedule(nextUnscheduledDate: Date?, now: Date) {
        guard !disabled else { return }
        self.nextUnscheduledDate = nextUnscheduledDate
        coverageKnown = true
        guard registered else { return }
        arm(now: now)
    }

    func stop() {
        guard !disabled else { return }
        nextUnscheduledDate = nil
        coverageKnown = true
        cancellationRevision &+= 1
        desiredDate = nil
        dependencies.cancel()
        scheduledDate = nil
        if let id = active?.id { finish(id: id, success: false, cancel: true) }
    }

    nonisolated static func requestedDate(nextUnscheduledDate: Date?, now: Date) -> Date? {
        guard let nextUnscheduledDate else { return nil }
        return max(now.addingTimeInterval(minimumDelay),
                   min(now.addingTimeInterval(maintenanceInterval),
                       nextUnscheduledDate.addingTimeInterval(-coverageMargin)))
    }

    /// Wait for an asynchronous system submission, without cancelling it if the
    /// caller expires. Its result still needs to reconcile a concurrent stop.
    func waitForScheduling() async { await submission?.value }

    private func arm(now: Date, coldLaunch: Bool = false) {
        // A background launch can arrive before the cached ledger has finished
        // loading. Reserve another opportunity first; reconciliation replaces or
        // cancels it once the actual coverage is known.
        let deadline = nextUnscheduledDate
            ?? (coldLaunch && !coverageKnown ? now.addingTimeInterval(2 * Self.coverageMargin) : nil)
        guard let requested = Self.requestedDate(nextUnscheduledDate: deadline, now: now) else {
            cancellationRevision &+= 1
            desiredDate = nil
            dependencies.cancel()
            scheduledDate = nil
            lastSubmissionError = nil
            return
        }
        if let scheduledDate, scheduledDate <= requested { return }
        if let desiredDate, desiredDate <= requested { return }
        if submittingRevision == cancellationRevision, let submittingDate, submittingDate <= requested { return }
        desiredDate = requested
        guard submission == nil else { return }
        submission = Task { @MainActor [weak self] in
            guard let self else { return }
            while let date = desiredDate {
                desiredDate = nil
                submittingDate = date
                submittingRevision = cancellationRevision
                let revision = cancellationRevision
                do {
                    try await dependencies.submit(date)
                    if revision == cancellationRevision {
                        scheduledDate = date
                        lastSubmissionError = nil
                        if let desiredDate, desiredDate >= date { self.desiredDate = nil }
                    }
                } catch {
                    if revision == cancellationRevision {
                        // A failed replacement must retain an earlier request.
                        lastSubmissionError = error.localizedDescription
                    }
                }
                if revision != cancellationRevision {
                    // The system may accept an in-flight request after stop().
                    // Remove that obsolete request before submitting a successor.
                    dependencies.cancel()
                    scheduledDate = nil
                }
                submittingDate = nil
            }
            submission = nil
        }
    }

    private func receive(_ execution: Execution) {
        guard !disabled, registered, let refresh, active == nil else {
            execution.complete(false)
            return
        }
        scheduledDate = nil
        arm(now: dependencies.now(), coldLaunch: true)
        let id = UUID()
        active = ActiveExecution(id: id, complete: execution.complete)
        execution.installExpirationHandler { [weak self] in
            Task { @MainActor in
                self?.finish(id: id, success: false, cancel: true)
            }
        }
        active?.task = Task { @MainActor [weak self] in
            await self?.waitForScheduling()
            guard !Task.isCancelled else { return }
            await refresh()
            // Reconciliation can advance the next refresh deadline. Keep the
            // background execution alive until that replacement is accepted.
            await self?.waitForScheduling()
            self?.finish(id: id, success: !Task.isCancelled, cancel: false)
        }
    }

    private func finish(id: UUID, success: Bool, cancel: Bool) {
        // Expiration and normal completion can race. The system receives one
        // completion, and a late return from cancelled work cannot end a new run.
        guard let execution = active, execution.id == id else { return }
        active = nil
        if cancel { execution.task?.cancel() }
        execution.complete(success)
    }
}

extension ReminderBackgroundRefresh.Dependencies {
    static var inert: Self {
        Self(register: { _ in false }, submit: { _ in }, cancel: {})
    }

    static var live: Self {
        #if os(iOS)
        return Self(
            register: { launch in
                BGTaskScheduler.shared.register(forTaskWithIdentifier: ReminderBackgroundRefresh.identifier, using: .main) { task in
                    MainActor.assumeIsolated {
                        guard let refreshTask = task as? BGAppRefreshTask else {
                            task.setTaskCompleted(success: false)
                            return
                        }
                        launch(.init(
                            installExpirationHandler: { refreshTask.expirationHandler = $0 },
                            complete: { refreshTask.setTaskCompleted(success: $0) }
                        ))
                    }
                }
            },
            submit: { date in
                let request = BGAppRefreshTaskRequest(identifier: ReminderBackgroundRefresh.identifier)
                request.earliestBeginDate = date
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            },
            cancel: { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: ReminderBackgroundRefresh.identifier) }
        )
        #else
        let driver = ReminderMacBackgroundDriver()
        return Self(register: { driver.register($0) }, submit: { driver.submit($0) }, cancel: { driver.cancel() })
        #endif
    }
}

#if os(macOS)
/// This maintenance activity exists only while the application process exists.
@MainActor
private final class ReminderMacBackgroundDriver {
    private var launch: ReminderBackgroundRefresh.Launch?
    private var activity: NSBackgroundActivityScheduler?
    private var activityID: UUID?

    func register(_ launch: @escaping ReminderBackgroundRefresh.Launch) -> Bool {
        self.launch = launch
        return true
    }

    func submit(_ date: Date) {
        cancel()
        let activity = NSBackgroundActivityScheduler(identifier: ReminderBackgroundRefresh.identifier)
        let id = UUID()
        activityID = id
        self.activity = activity
        activity.repeats = false
        activity.interval = max(1, date.timeIntervalSinceNow)
        activity.tolerance = min(15 * 60, activity.interval / 10)
        activity.qualityOfService = .background
        activity.schedule { [weak self] completion in
            Task { @MainActor in
                self?.perform(id: id, completion: completion) ?? completion(.finished)
            }
        }
    }

    func cancel() {
        activity?.invalidate()
        activity = nil
        activityID = nil
    }

    private func perform(id: UUID, completion: @escaping NSBackgroundActivityScheduler.CompletionHandler) {
        guard id == activityID, let activity, let launch else {
            completion(.finished)
            return
        }
        if activity.shouldDefer {
            completion(.deferred)
            return
        }
        launch(.init(installExpirationHandler: { _ in }, complete: { _ in completion(.finished) }))
    }
}
#endif
