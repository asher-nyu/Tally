import Foundation
import AudioToolbox
import AVFAudio
import Testing
import UserNotifications
@testable import Tally

@MainActor
struct NotificationCoordinatorTests {
    @Test func observationDoesNotPromptAndExplicitEnableRequestsPermissionOnce() async {
        let system = FakeNotificationSystem()
        system.authorization = .notDetermined
        let coordinator = system.coordinator()
        coordinator.attach(ledger())
        await coordinator.reconcileNow()
        #expect(system.permissionRequests == 0)
        #expect(system.requests.isEmpty)

        #expect(await coordinator.requestPermission())
        await coordinator.reconcileNow()
        #expect(system.permissionRequests == 1)
        #expect(system.requests.count == 1)
        #expect(await coordinator.requestPermission())
        #expect(system.permissionRequests == 1)
    }

    @Test func reopeningRestoresOtherDocumentsAndDeletingEntryCancelsOnlyItsRequests() async {
        let system = FakeNotificationSystem()
        let first = ledger(name: "First document")
        let other = ledger(name: "Closed document")
        system.cache = [other]
        system.requests["another-feature"] = request(id: "another-feature")
        let coordinator = system.coordinator()
        coordinator.attach(first)
        await coordinator.reconcileNow()
        #expect(coordinator.coverage.pendingCount == 2)
        #expect(Set(system.cache.map(\.id)) == [first.id, other.id])

        var deleted = first
        deleted.expenses.removeAll()
        coordinator.attach(deleted)
        await coordinator.reconcileNow()
        #expect(coordinator.coverage.pendingCount == 1)
        #expect(system.requests["another-feature"] != nil)
        #expect(system.requests.keys.contains { $0.contains(other.id.uuidString) })
        #expect(!system.requests.keys.contains { $0.contains(first.id.uuidString) })
        #expect(system.cache.map(\.id) == [other.id])

        // A new process can refill the closed document from the persisted snapshot.
        let relaunched = system.coordinator()
        relaunched.start()
        await relaunched.reconcileNow()
        #expect(relaunched.coverage.enabledEntryCount == 1)
        #expect(relaunched.coverage.pendingCount == 1)
        #expect(system.permissionRequests == 0)
    }

    @Test func disablingAndUndoingReminderReplacesTheOperatingSystemSchedule() async {
        let system = FakeNotificationSystem()
        let initial = ledger()
        let coordinator = system.coordinator()
        coordinator.attach(initial)
        await coordinator.reconcileNow()
        let initialIDs = Set(system.requests.keys)
        #expect(initialIDs.count == 1)

        var disabled = initial
        disabled.expenses[0].reminder = nil
        coordinator.attach(disabled)
        await coordinator.reconcileNow()
        #expect(system.requests.isEmpty)

        coordinator.attach(initial)
        await coordinator.reconcileNow()
        #expect(Set(system.requests.keys) == initialIDs)
    }

    @Test func deletingAnOpenDocumentRemovesOnlyItsRemindersAcrossRelaunch() async {
        let system = FakeNotificationSystem()
        let deleted = ledger(name: "Deleted document")
        let retained = ledger(name: "Retained document")
        system.requests["another-feature"] = request(id: "another-feature")
        let coordinator = system.coordinator()
        coordinator.attach(deleted)
        coordinator.attach(retained)
        await coordinator.reconcileNow()
        #expect(coordinator.coverage.pendingCount == 2)

        coordinator.forgetLedger(id: deleted.id)
        // Repeated file-system notifications must be harmless.
        coordinator.forgetLedger(id: deleted.id)
        await coordinator.reconcileNow()
        #expect(!system.requests.keys.contains { $0.contains(deleted.id.uuidString) })
        #expect(system.requests.keys.contains { $0.contains(retained.id.uuidString) })
        #expect(system.requests["another-feature"] != nil)
        #expect(system.cache.map(\.id) == [retained.id])

        let relaunched = system.coordinator()
        relaunched.start()
        await relaunched.reconcileNow()
        #expect(relaunched.coverage.pendingCount == 1)
        #expect(!system.requests.keys.contains { $0.contains(deleted.id.uuidString) })
        #expect(system.permissionRequests == 0)

        // Reopening an independently restored document resumes its reminders.
        relaunched.attach(deleted)
        await relaunched.reconcileNow()
        #expect(relaunched.coverage.pendingCount == 2)
        #expect(Set(system.cache.map(\.id)) == [deleted.id, retained.id])
    }

    @Test func globalBudgetReservesUnrelatedRequestsAndReportsUnscheduledEntries() async {
        let system = FakeNotificationSystem()
        system.requests["another-feature"] = request(id: "another-feature")
        let coordinator = system.coordinator()
        let many = Ledger(expenses: (0..<65).map {
            Expense(merchant: "Entry \($0)", amountMinor: 100, billingDay: 15, reminder: PaymentReminder())
        })
        coordinator.attach(many)
        await coordinator.reconcileNow()

        #expect(system.requests.count == 64)
        #expect(system.requests["another-feature"] != nil)
        #expect(coordinator.coverage.pendingCount == 63)
        #expect(coordinator.coverage.unscheduledEntryCount == 2)
        #expect(coordinator.coverage.capacityLimited)
        #expect(coordinator.coverage.nextUnscheduledDate != nil)
        #expect(coordinator.schedulingError == nil)
    }

    @Test func denseScheduleDoesNotCrowdOutAnnualOrOneTimeReminders() async throws {
        let system = FakeNotificationSystem()
        let coordinator = system.coordinator()
        let dense = Expense(
            merchant: "Fictional frequent payment", amountMinor: 100, recurrence: .custom,
            anchorDate: ScheduleDate(year: 2026, month: 9, day: 1),
            customRecurrence: .init(frequency: .daily, interval: 2), reminder: PaymentReminder()
        )
        let annual = Expense(
            merchant: "Fictional annual subscription", amountMinor: 100, recurrence: .annual,
            anchorDate: ScheduleDate(year: 2026, month: 3, day: 20), reminder: PaymentReminder()
        )
        let single = Expense(
            merchant: "Fictional future payment", amountMinor: 100, recurrence: .oneTime,
            anchorDate: ScheduleDate(year: 2027, month: 6, day: 1), reminder: PaymentReminder()
        )
        coordinator.attach(Ledger(expenses: [dense, annual, single]))
        await coordinator.reconcileNow()

        let annualRequest = try #require(system.requests.values.first {
            $0.content.userInfo["expenseID"] as? String == annual.id.uuidString
        })
        #expect((annualRequest.trigger as? UNCalendarNotificationTrigger)?.repeats == true)
        #expect(system.requests.values.contains {
            $0.content.userInfo["expenseID"] as? String == single.id.uuidString
        })
        #expect(system.requests.count == 64)
        #expect(coordinator.coverage.unscheduledEntryCount == 0)
        #expect(coordinator.coverage.repeatingEntryCount == 1)
    }

    @Test func rollingScheduleReportsWhenTheQueueNeedsRefilling() async {
        let system = FakeNotificationSystem()
        let coordinator = system.coordinator()
        let schedule = Ledger(expenses: [Expense(
            merchant: "Every two weeks", amountMinor: 100, recurrence: .everyTwoWeeks,
            anchorDate: ScheduleDate(year: 2026, month: 9, day: 2), reminder: PaymentReminder()
        )])
        coordinator.attach(schedule)
        await coordinator.reconcileNow()

        #expect(coordinator.coverage.pendingCount == 64)
        #expect(coordinator.coverage.repeatingEntryCount == 0)
        #expect(coordinator.coverage.finiteThroughDate != nil)
        #expect(coordinator.coverage.unscheduledEntryCount == 0)
        #expect(system.requests.values.allSatisfy { ($0.trigger as? UNCalendarNotificationTrigger)?.repeats == false })
        #expect(system.backgroundRefreshes.last! == coordinator.coverage.nextUnscheduledDate)
    }

    @Test func automaticMaintenanceStopsWhenDatedRemindersAreDisabled() async {
        let system = FakeNotificationSystem()
        let coordinator = system.coordinator()
        var document = Ledger(expenses: [Expense(
            merchant: "Fictional custom subscription", amountMinor: 100, recurrence: .everyTwoWeeks,
            anchorDate: ScheduleDate(year: 2026, month: 9, day: 2), reminder: PaymentReminder()
        )])
        coordinator.attach(document)
        await coordinator.reconcileNow()
        #expect(system.backgroundRefreshes.contains { $0 != nil })

        document.expenses[0].reminder = nil
        coordinator.attach(document)
        await coordinator.reconcileNow()
        #expect(system.requests.isEmpty)
        #expect(!system.backgroundRefreshes.isEmpty)
        #expect(system.backgroundRefreshes.last! == nil)
    }

    @Test func maintenanceReplenishesAnArbitraryCustomScheduleFromItsPrivateCache() async throws {
        let system = FakeNotificationSystem()
        let custom = Expense(
            merchant: "Fictional sixteen-day schedule", amountMinor: 100, recurrence: .custom,
            anchorDate: ScheduleDate(year: 2026, month: 9, day: 1),
            customRecurrence: .init(frequency: .daily, interval: 16), reminder: PaymentReminder()
        )
        system.cache = [Ledger(expenses: [custom])]
        let coordinator = system.coordinator()
        coordinator.start()
        await coordinator.reconcileNow()
        let previousDeadline = try #require(coordinator.coverage.nextUnscheduledDate)
        let previousIDs = Set(system.requests.keys)

        // Simulate the maintenance callback after time passes. No document is
        // opened or attached, and scheduling uses only the device-local cache.
        system.now = previousDeadline.addingTimeInterval(-86_400)
        await coordinator.reconcileNow()
        let newDeadline = try #require(coordinator.coverage.nextUnscheduledDate)
        #expect(newDeadline > previousDeadline)
        #expect(Set(system.requests.keys) != previousIDs)
        #expect(system.requests.count == 64)
        #expect(system.cache.first?.expenses == [custom])
        #expect(system.permissionRequests == 0)
        #expect(system.backgroundRefreshes.last! == newDeadline)
    }

    @Test func editDuringAnInFlightAddIsReconciledBeforeTheWorkerFinishes() async {
        let system = FakeNotificationSystem()
        let initial = ledger()
        let coordinator = system.coordinator()
        var changed = false
        system.onAdd = { _ in
            guard !changed else { return }
            changed = true
            var deleted = initial
            deleted.expenses.removeAll()
            coordinator.attach(deleted)
        }
        coordinator.attach(initial)
        await coordinator.reconcileNow()

        #expect(changed)
        #expect(system.requests.isEmpty)
        #expect(coordinator.coverage.enabledEntryCount == 0)
    }

    @Test func failedAddClearsStaleContentAndReportsMissingCoverage() async {
        let system = FakeNotificationSystem()
        let initial = ledger()
        let coordinator = system.coordinator()
        coordinator.attach(initial)
        await coordinator.reconcileNow()
        #expect(system.requests.count == 1)
        system.failAdds = true
        var edited = initial
        edited.expenses[0].merchant = "Changed merchant"
        coordinator.attach(edited)
        await coordinator.reconcileNow()

        #expect(system.requests.isEmpty)
        #expect(coordinator.coverage.unscheduledEntryCount == 1)
        #expect(coordinator.schedulingError != nil)
    }

    @Test func websiteActionAndRippleResourceAreAvailable() async {
        let system = FakeNotificationSystem()
        let coordinator = system.coordinator()
        coordinator.start()
        var document = ledger()
        document.expenses[0].websiteLink = "https://provider.example/account"
        coordinator.attach(document)
        await coordinator.reconcileNow()
        let content = system.requests.values.first?.content
        #expect(content?.body == "Payment of \(Money.format(1_200, currencyCode: "USD")) is due today.")
        #expect(content?.categoryIdentifier == NotificationCoordinator.websiteCategory)
        #expect(content?.userInfo["website"] as? String == "https://provider.example/account")
        #expect(content?.sound?.isEqual(UNNotificationSound(named: UNNotificationSoundName("Rebound.caf"))) == true)
        #expect(Bundle.main.url(forResource: "Rebound", withExtension: "caf") != nil)

        document.expenses[0].amountMinor = nil
        coordinator.attach(document)
        await coordinator.reconcileNow()
        #expect(system.requests.values.first?.content.body == "Payment with a variable amount is due today.")
    }

    @Test func incomeReminderDescribesExpectedFixedAndVariableAmounts() async throws {
        let system = FakeNotificationSystem()
        let coordinator = system.coordinator()
        var document = ledger(name: "Fictional salary")
        document.expenses[0].kind = .income
        document.expenses[0].category = .income
        document.expenses[0].reminder?.daysBefore = 1
        coordinator.attach(document)
        await coordinator.reconcileNow()
        let fixed = try #require(system.requests.values.first)

        #expect(fixed.content.title == "Fictional salary")
        #expect(fixed.content.body == "Income of \(Money.format(1_200, currencyCode: "USD")) is expected tomorrow.")

        document.expenses[0].amountMinor = nil
        coordinator.attach(document)
        await coordinator.reconcileNow()
        let variable = try #require(system.requests.values.first)

        #expect(variable.identifier == fixed.identifier)
        #expect(variable.content.body == "Income with a variable amount is expected tomorrow.")
        #expect(system.requests.count == 1)
        #expect(system.permissionRequests == 0)
    }

    @Test(arguments: PaymentReminderSound.allCases)
    func requestPayloadUsesTheSavedSoundChoice(_ sound: PaymentReminderSound) async throws {
        let system = FakeNotificationSystem()
        let coordinator = system.coordinator()
        var document = ledger()
        document.expenses[0].reminder?.sound = sound
        coordinator.attach(document)
        await coordinator.reconcileNow()
        let request = try #require(system.requests.values.first)
        if let filename = sound.bundledFilename {
            #expect(request.content.sound?.isEqual(UNNotificationSound(named: UNNotificationSoundName(filename))) == true)
        } else {
            #expect(request.content.sound == nil)
        }
    }

    @Test func bundledAudioContainsExactlyTheFiveSelectableTones() {
        let resources = Bundle.main.urls(forResourcesWithExtension: "caf", subdirectory: nil) ?? []
        let expected = Set(PaymentReminderSound.allCases.compactMap(\.bundledFilename))
        #expect(Set(resources.map(\.lastPathComponent)) == expected)
        #expect(expected.count == 5)
    }

    @Test(arguments: PaymentReminderSound.allCases.filter { $0.bundledFilename != nil })
    func bundledTonesAreReadableShortNotificationAudio(_ sound: PaymentReminderSound) throws {
        let filename = try #require(sound.bundledFilename)
        let url = try #require(Bundle.main.url(forResource: filename, withExtension: nil))
        let audio = try AVAudioFile(forReading: url)
        #expect(audio.processingFormat.sampleRate == 44_100)
        #expect(audio.processingFormat.channelCount == 1)
        #expect(audio.length > 0)
        #expect(Double(audio.length) / audio.processingFormat.sampleRate < 5)
        #expect(audio.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM)
        #expect(audio.fileFormat.streamDescription.pointee.mBitsPerChannel == 16)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
                                                 frameCapacity: AVAudioFrameCount(audio.length)))
        try audio.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        let peak = samples.reduce(Float.zero) { max($0, abs($1)) }
        let rms = sqrt(samples.reduce(Double.zero) { $0 + Double($1) * Double($1) } / Double(samples.count))
        // Catch silent/corrupt resources, accidental clipping, and abrupt edges.
        #expect(peak > 0.50 && peak < 0.60)
        #expect(rms > 0.05 && rms < 0.20)
        #expect(samples.first == 0 && samples.last == 0)
    }

    @Test(arguments: PaymentReminderSound.allCases.filter { $0.bundledFilename != nil })
    func relaunchRefreshesClosedDocumentRemindersWithoutChangingTheirSoundResource(_ sound: PaymentReminderSound) async throws {
        let system = FakeNotificationSystem()
        var document = ledger(name: "Fictional subscription")
        document.expenses[0].reminder?.sound = sound
        let initialCoordinator = system.coordinator()
        initialCoordinator.attach(document)
        await initialCoordinator.reconcileNow()
        let previous = try #require(system.requests.values.first)
        let oldContent = try #require(previous.content.mutableCopy() as? UNMutableNotificationContent)
        oldContent.title = "Previously scheduled reminder"
        system.requests[previous.identifier] = UNNotificationRequest(
            identifier: previous.identifier, content: oldContent, trigger: previous.trigger
        )
        system.addedRequests.removeAll()

        // No document is opened or attached: launching restores the saved cache.
        let relaunchedCoordinator = system.coordinator()
        relaunchedCoordinator.start()
        await relaunchedCoordinator.reconcileNow()
        let refreshed = try #require(system.requests.values.first)
        #expect(refreshed.identifier == previous.identifier)
        #expect(refreshed.content.title == "Fictional subscription")
        #expect(refreshed.content.sound?.isEqual(previous.content.sound) == true)
        #expect(system.cache.first?.expenses.first?.reminder?.sound.rawValue == sound.rawValue)
        #expect(system.addedRequests.contains { $0.identifier == previous.identifier })
        #expect(system.requests.count == 1)
        #expect(system.permissionRequests == 0)
        #expect(relaunchedCoordinator.schedulingError == nil)
    }

    @Test func soundOnlyEditsReplaceTheExistingRequestAndPersistTheChoice() async throws {
        let system = FakeNotificationSystem()
        let coordinator = system.coordinator()
        var document = ledger()
        coordinator.attach(document)
        await coordinator.reconcileNow()
        let initial = try #require(system.requests.values.first)
        let initialAdds = system.addedRequests.count

        document.expenses[0].reminder?.sound = .lift
        coordinator.attach(document)
        await coordinator.reconcileNow()
        let chime = try #require(system.requests.values.first)
        #expect(chime.identifier == initial.identifier)
        #expect(chime.content.sound?.isEqual(UNNotificationSound(named: UNNotificationSoundName("Chime.caf"))) == true)
        #expect(system.cache.first?.expenses.first?.reminder?.sound == PaymentReminderSound.lift)

        document.expenses[0].reminder?.sound = .none
        coordinator.attach(document)
        await coordinator.reconcileNow()
        let silent = try #require(system.requests.values.first)
        #expect(system.addedRequests.count > initialAdds)
        #expect(system.requests.count == 1)
        #expect(silent.identifier == initial.identifier)
        #expect(silent.content.title == initial.content.title)
        #expect(silent.content.body == initial.content.body)
        #expect(silent.content.sound == nil)
        #expect((silent.trigger as? UNCalendarNotificationTrigger)?.dateComponents
            == (initial.trigger as? UNCalendarNotificationTrigger)?.dateComponents)
        #expect(system.cache.first?.expenses.first?.reminder?.sound == PaymentReminderSound.none)

        document.expenses[0].reminder?.sound = .signal
        coordinator.attach(document)
        await coordinator.reconcileNow()
        let restored = try #require(system.requests.values.first)
        #expect(restored.identifier == initial.identifier)
        #expect(restored.content.sound?.isEqual(UNNotificationSound(named: UNNotificationSoundName("Bell.caf"))) == true)
        #expect(system.cache.first?.expenses.first?.reminder?.sound == PaymentReminderSound.signal)
    }

    @Test func olderCachedRemindersMigrateAndKeepRippleWhenTheirDocumentIsClosed() async throws {
        let system = FakeNotificationSystem()
        var old = ledger()
        old.formatVersion = 5
        system.cache = [old]
        let coordinator = system.coordinator()
        coordinator.start()
        await coordinator.reconcileNow()

        let request = try #require(system.requests.values.first)
        #expect(coordinator.schedulingError == nil)
        #expect(system.cache.first?.id == old.id)
        #expect(system.cache.first?.formatVersion == LedgerCodec.currentFormatVersion)
        #expect(system.cache.first?.expenses.first?.reminder?.sound == PaymentReminderSound.ripple)
        #expect(request.content.sound?.isEqual(UNNotificationSound(named: UNNotificationSoundName("Rebound.caf"))) == true)
    }

    private func ledger(name: String = "Example") -> Ledger {
        Ledger(expenses: [Expense(merchant: name, amountMinor: 1_200, billingDay: 15, reminder: PaymentReminder())])
    }

    private func request(id: String) -> UNNotificationRequest {
        UNNotificationRequest(identifier: id, content: UNMutableNotificationContent(), trigger: nil)
    }
}

@MainActor
private final class FakeNotificationSystem {
    enum Failure: Error { case refused }
    var authorization: NotificationCoordinator.Authorization = .authorized
    var permissionRequests = 0
    var requests: [String: UNNotificationRequest] = [:]
    var addedRequests: [UNNotificationRequest] = []
    var cache: [Ledger] = []
    var failAdds = false
    var onAdd: ((UNNotificationRequest) -> Void)?
    var backgroundRefreshes: [Date?] = []
    var now: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 12))!
    }()

    func coordinator() -> NotificationCoordinator {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dependencies = NotificationCoordinator.Dependencies(
            authorization: { self.authorization },
            requestAuthorization: {
                self.permissionRequests += 1
                self.authorization = .authorized
                return true
            },
            pendingIdentifiers: { Array(self.requests.keys) },
            add: { request in
                self.addedRequests.append(request)
                self.onAdd?(request)
                await Task.yield()
                if self.failAdds { throw Failure.refused }
                self.requests[request.identifier] = request
            },
            remove: { identifiers in
                for identifier in identifiers { self.requests.removeValue(forKey: identifier) }
            },
            configure: { _ in },
            loadCache: { self.cache },
            saveCache: { self.cache = $0 },
            openWebsite: { _ in true },
            now: { self.now },
            calendar: { calendar },
            scheduleBackgroundRefresh: { date, _ in self.backgroundRefreshes.append(date) }
        )
        return NotificationCoordinator(dependencies: dependencies, debounceNanoseconds: 0)
    }
}
