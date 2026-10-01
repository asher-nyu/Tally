import Foundation
import Testing
@testable import Tally

@MainActor
struct ReminderBackgroundRefreshTests {
    @Test func maintenanceAdvancesBeforeCoverageExpiresAndBoundsUrgentRetries() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ReminderBackgroundRefresh.requestedDate(nextUnscheduledDate: nil, now: now) == nil)
        #expect(ReminderBackgroundRefresh.requestedDate(nextUnscheduledDate: now.addingTimeInterval(7 * 86_400), now: now)
                == now.addingTimeInterval(6 * 3_600))
        #expect(ReminderBackgroundRefresh.requestedDate(nextUnscheduledDate: now.addingTimeInterval(25 * 3_600), now: now)
                == now.addingTimeInterval(3_600))
        #expect(ReminderBackgroundRefresh.requestedDate(nextUnscheduledDate: now.addingTimeInterval(300), now: now)
                == now.addingTimeInterval(15 * 60))
        #expect(ReminderBackgroundRefresh.requestedDate(nextUnscheduledDate: now.addingTimeInterval(-86_400), now: now)
                == now.addingTimeInterval(15 * 60))
    }

    @Test func foregroundReconciliationDoesNotPostponeQueuedWorkButCanAdvanceIt() async {
        let system = FakeReminderBackgroundSystem()
        let refresh = system.coordinator()
        refresh.start {}
        let initial = system.now
        refresh.schedule(nextUnscheduledDate: initial.addingTimeInterval(7 * 86_400), now: initial)
        await refresh.waitForScheduling()
        system.now = initial.addingTimeInterval(3_600)
        refresh.schedule(nextUnscheduledDate: initial.addingTimeInterval(8 * 86_400), now: system.now)
        await refresh.waitForScheduling()
        #expect(system.submittedDates == [initial.addingTimeInterval(6 * 3_600)])
        refresh.schedule(nextUnscheduledDate: system.now.addingTimeInterval(25 * 3_600), now: system.now)
        await refresh.waitForScheduling()
        #expect(system.submittedDates.last == initial.addingTimeInterval(2 * 3_600))
        #expect(system.submittedDates.count == 2)
    }

    @Test func completeCoverageCancelsMaintenanceAndLaterFiniteCoverageResumesIt() async {
        let system = FakeReminderBackgroundSystem()
        let refresh = system.coordinator()
        refresh.start {}
        refresh.schedule(nextUnscheduledDate: system.now, now: system.now)
        await refresh.waitForScheduling()
        #expect(system.pendingDate != nil)
        refresh.schedule(nextUnscheduledDate: nil, now: system.now)
        #expect(system.pendingDate == nil && refresh.scheduledDate == nil)
        refresh.schedule(nextUnscheduledDate: system.now.addingTimeInterval(4 * 86_400), now: system.now)
        await refresh.waitForScheduling()
        #expect(system.pendingDate == system.now.addingTimeInterval(6 * 3_600))
        #expect(system.registrations == 1)
    }

    @Test func registrationAndSubmissionsRemainInertDuringUIAndUnitTestMode() {
        let system = FakeReminderBackgroundSystem()
        let refresh = system.coordinator(disabled: true)
        refresh.start {}
        refresh.schedule(nextUnscheduledDate: system.now, now: system.now)
        refresh.stop()
        #expect(system.registrations == 0)
        #expect(system.submittedDates.isEmpty && system.cancellations == 0)
    }

    @Test func failedSubmissionCanRetryAndDoesNotDiscardAnEarlierRequest() async {
        let system = FakeReminderBackgroundSystem()
        let refresh = system.coordinator()
        refresh.start {}
        refresh.schedule(nextUnscheduledDate: system.now.addingTimeInterval(7 * 86_400), now: system.now)
        await refresh.waitForScheduling()
        let previous = system.pendingDate
        system.failSubmission = true
        refresh.schedule(nextUnscheduledDate: system.now, now: system.now)
        await refresh.waitForScheduling()
        #expect(refresh.scheduledDate == previous && system.pendingDate == previous)
        #expect(refresh.lastSubmissionError != nil)
        system.failSubmission = false
        refresh.schedule(nextUnscheduledDate: system.now, now: system.now)
        await refresh.waitForScheduling()
        #expect(system.pendingDate == system.now.addingTimeInterval(15 * 60))
        #expect(refresh.lastSubmissionError == nil)
    }

    @Test func expirationCompletesOnceCancelsWorkAndKeepsTheNextOpportunity() async {
        let system = FakeReminderBackgroundSystem()
        let refresh = system.coordinator()
        var began = false
        var cancelled = false
        refresh.start {
            began = true
            do { try await Task.sleep(for: .seconds(3_600)) }
            catch { cancelled = Task.isCancelled }
        }
        refresh.schedule(nextUnscheduledDate: system.now.addingTimeInterval(7 * 86_400), now: system.now)
        await refresh.waitForScheduling()
        system.now = system.now.addingTimeInterval(6 * 3_600)
        let run = system.fire()
        await refresh.waitForScheduling()
        #expect(system.pendingDate == system.now.addingTimeInterval(6 * 3_600))
        await settle(until: { began })
        run.expire?()
        await settle(until: { cancelled && !refresh.isRefreshing })
        #expect(run.completions == [false])
        #expect(system.pendingDate != nil)
        // A repeated expiry and the late return from cancelled work are harmless.
        run.expire?()
        await Task.yield()
        #expect(run.completions == [false])
    }

    @Test func coldBackgroundLaunchRearmsBeforeCacheLoadThenAcceptsCompleteCoverage() async {
        let system = FakeReminderBackgroundSystem()
        let refresh = system.coordinator()
        var hadNextOpportunityWhileLoading = false
        refresh.start {
            hadNextOpportunityWhileLoading = system.pendingDate != nil
            refresh.schedule(nextUnscheduledDate: nil, now: system.now)
        }
        let run = system.fire()
        await settle(until: { !run.completions.isEmpty })
        #expect(hadNextOpportunityWhileLoading)
        #expect(run.completions == [true])
        #expect(system.pendingDate == nil)
    }

    @Test func stoppingAnActiveRunCompletesOnceAndDoesNotCancelItsSuccessor() async {
        let system = FakeReminderBackgroundSystem()
        let refresh = system.coordinator()
        var began = false
        refresh.start {
            began = true
            try? await Task.sleep(for: .seconds(3_600))
        }
        refresh.schedule(nextUnscheduledDate: system.now, now: system.now)
        await refresh.waitForScheduling()
        let firstRun = system.fire()
        await settle(until: { began })
        refresh.stop()
        #expect(firstRun.completions == [false])
        #expect(system.pendingDate == nil && !refresh.isRefreshing)

        refresh.start {}
        refresh.schedule(nextUnscheduledDate: system.now, now: system.now)
        await refresh.waitForScheduling()
        let secondRun = system.fire()
        firstRun.expire?()
        await settle(until: { !secondRun.completions.isEmpty })
        #expect(firstRun.completions == [false])
        #expect(secondRun.completions == [true])
        #expect(system.registrations == 1)
    }

    @Test func aSubmissionAcceptedAfterStopCannotReplaceItsNewSuccessor() async {
        let system = FakeReminderBackgroundSystem()
        let refresh = system.coordinator()
        var continuation: CheckedContinuation<Void, Never>?
        system.beforeSubmission = { _ in
            system.beforeSubmission = nil
            await withCheckedContinuation { continuation = $0 }
        }
        refresh.start {}
        refresh.schedule(nextUnscheduledDate: system.now.addingTimeInterval(7 * 86_400), now: system.now)
        await settle(until: { continuation != nil })
        refresh.stop()
        refresh.schedule(nextUnscheduledDate: system.now, now: system.now)
        continuation?.resume()
        await refresh.waitForScheduling()
        #expect(system.submittedDates == [system.now.addingTimeInterval(6 * 3_600), system.now.addingTimeInterval(15 * 60)])
        #expect(system.pendingDate == system.now.addingTimeInterval(15 * 60))
        #expect(refresh.scheduledDate == system.pendingDate)
        #expect(system.cancellations >= 2)
    }

    @Test func completionWaitsForTheEarlierRequestDiscoveredDuringRefresh() async {
        let system = FakeReminderBackgroundSystem()
        let refresh = system.coordinator()
        var continuation: CheckedContinuation<Void, Never>?
        refresh.start {
            system.beforeSubmission = { _ in
                system.beforeSubmission = nil
                await withCheckedContinuation { continuation = $0 }
            }
            refresh.schedule(nextUnscheduledDate: system.now, now: system.now)
        }
        refresh.schedule(nextUnscheduledDate: system.now.addingTimeInterval(7 * 86_400), now: system.now)
        await refresh.waitForScheduling()
        let run = system.fire()
        await settle(until: { continuation != nil })
        #expect(system.pendingDate == system.now.addingTimeInterval(6 * 3_600))
        #expect(run.completions.isEmpty && refresh.isRefreshing)
        continuation?.resume()
        await settle(until: { !run.completions.isEmpty })
        #expect(system.pendingDate == system.now.addingTimeInterval(15 * 60))
        #expect(run.completions == [true] && !refresh.isRefreshing)
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        #expect(condition(), "The injected asynchronous operation should finish without a wall-clock wait.")
    }
}

@MainActor
private final class FakeReminderBackgroundSystem {
    final class Run {
        var expire: (@Sendable () -> Void)?
        var completions: [Bool] = []
    }

    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var registrations = 0
    var cancellations = 0
    var submittedDates: [Date] = []
    var pendingDate: Date?
    var failSubmission = false
    var beforeSubmission: ((Date) async -> Void)?
    private var launch: ReminderBackgroundRefresh.Launch?

    func coordinator(disabled: Bool = false) -> ReminderBackgroundRefresh {
        ReminderBackgroundRefresh(dependencies: .init(
            register: { self.registrations += 1; self.launch = $0; return true },
            submit: {
                await self.beforeSubmission?($0)
                if self.failSubmission { throw CocoaError(.fileWriteUnknown) }
                self.submittedDates.append($0)
                self.pendingDate = $0
            },
            cancel: { self.cancellations += 1; self.pendingDate = nil },
            now: { self.now }
        ), disabled: disabled)
    }

    func fire() -> Run {
        pendingDate = nil
        let run = Run()
        launch?(.init(installExpirationHandler: { run.expire = $0 }, complete: { run.completions.append($0) }))
        return run
    }
}
