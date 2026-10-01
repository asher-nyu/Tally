import Foundation
import Testing
import UserNotifications
@testable import Tally

@MainActor
struct ReminderSoundMigrationTests {
    @Test func mixedLegacyCacheRefreshesClosedDocumentsAndPreservesExplicitSilence() async throws {
        let fixtures: [(stored: String, expected: PaymentReminderSound)] = [
            ("triTone", .ripple), ("glass", .ripple), ("note", .ripple),
            ("pulse", .ripple), ("systemDefault", .ripple),
            ("rebound", .ripple), ("bamboo", .pebble), ("chord", .glow),
            ("chime", .lift), ("bell", .signal), ("none", .none)
        ]
        let original = Ledger(expenses: fixtures.indices.map { index in
            Expense(merchant: "Fictional reminder \(index + 1)", amountMinor: 1_200,
                    billingDay: 15, reminder: .init(daysBefore: 1, hour: 9, minute: 41))
        })
        let bytes = try cacheData(original, storedSounds: fixtures.map(\.stored))
        let system = SerializedReminderCacheSystem(data: bytes)
        let coordinator = system.coordinator()

        // Restore the serialized device cache without opening any document.
        coordinator.start()
        await coordinator.reconcileNow()

        #expect(coordinator.schedulingError == nil)
        #expect(system.permissionRequests == 0)
        #expect(system.requests.count == fixtures.count)
        let decoded = try #require(JSONDecoder().decode([Ledger].self, from: bytes).first)
        #expect(decoded.id == original.id)
        for (index, fixture) in fixtures.enumerated() {
            let before = original.expenses[index]
            let migrated = decoded.expenses[index]
            #expect(migrated.id == before.id)
            #expect(migrated.merchant == before.merchant)
            #expect(migrated.amountMinor == before.amountMinor)
            #expect(migrated.billingDay == before.billingDay)
            #expect(migrated.reminder == PaymentReminder(daysBefore: 1, hour: 9, minute: 41, sound: fixture.expected))
            let request = try #require(system.requests.values.first {
                $0.content.userInfo["expenseID"] as? String == before.id.uuidString
            })
            #expect(request.content.userInfo["ledgerID"] as? String == original.id.uuidString)
            let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
            #expect(trigger.repeats)
            #expect(trigger.dateComponents.day == 14)
            #expect(trigger.dateComponents.hour == 9)
            #expect(trigger.dateComponents.minute == 41)
            if let resource = fixture.expected.bundledFilename {
                #expect(request.content.sound?.isEqual(UNNotificationSound(named: UNNotificationSoundName(resource))) == true)
            } else {
                #expect(fixture.expected == .none)
                #expect(request.content.sound == nil)
            }
        }

        // The next normal save canonicalizes migrated choices and keeps all rows.
        var edited = decoded
        edited.expenses[0].amountMinor = 1_300
        let requestIDs = Set(system.requests.keys)
        coordinator.attach(edited)
        await coordinator.reconcileNow()
        let persisted = try JSONDecoder().decode([Ledger].self, from: system.data)
        #expect(persisted == [edited])
        #expect(Set(system.requests.keys) == requestIDs)
        let payload = try #require(JSONSerialization.jsonObject(with: system.data) as? [[String: Any]])
        let expenses = try #require(payload.first?["expenses"] as? [[String: Any]])
        let sounds = expenses.compactMap { ($0["reminder"] as? [String: Any])?["sound"] as? String }
        #expect(sounds == fixtures.map { $0.expected.rawValue })
    }

    @Test func unknownCachedSoundPreservesPendingRequestsAndCacheBytes() async throws {
        let ledger = Ledger(expenses: [Expense(merchant: "Fictional bill", billingDay: 15, reminder: .init())])
        let bytes = try cacheData(ledger, storedSounds: ["futureUnknownSound"])
        let system = SerializedReminderCacheSystem(data: bytes)
        let pending = UNNotificationRequest(identifier: "tally.payment.existing", content: UNMutableNotificationContent(), trigger: nil)
        system.requests[pending.identifier] = pending
        let coordinator = system.coordinator()

        coordinator.start()
        await coordinator.reconcileNow()

        #expect(coordinator.schedulingError != nil)
        #expect(system.permissionRequests == 0)
        #expect(system.addedCount == 0)
        #expect(system.removedIDs.isEmpty)
        #expect(system.saveCount == 0)
        #expect(system.data == bytes)
        #expect(system.requests.count == 1)
        #expect(system.requests[pending.identifier] === pending)
    }

    private func cacheData(_ ledger: Ledger, storedSounds: [String]) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as? [String: Any])
        var expenses = try #require(object["expenses"] as? [[String: Any]])
        #expect(expenses.count == storedSounds.count)
        for index in expenses.indices {
            var reminder = try #require(expenses[index]["reminder"] as? [String: Any])
            reminder["sound"] = storedSounds[index]
            expenses[index]["reminder"] = reminder
        }
        object["expenses"] = expenses
        return try JSONSerialization.data(withJSONObject: [object])
    }
}

@MainActor
private final class SerializedReminderCacheSystem {
    var data: Data
    var requests: [String: UNNotificationRequest] = [:]
    var permissionRequests = 0
    var addedCount = 0
    var saveCount = 0
    var removedIDs: [String] = []

    init(data: Data) { self.data = data }

    func coordinator() -> NotificationCoordinator {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 12))!
        return NotificationCoordinator(dependencies: .init(
            authorization: { .authorized },
            requestAuthorization: { self.permissionRequests += 1; return true },
            pendingIdentifiers: { Array(self.requests.keys) },
            add: { self.addedCount += 1; self.requests[$0.identifier] = $0 },
            remove: { ids in
                self.removedIDs += ids
                for id in ids { self.requests.removeValue(forKey: id) }
            },
            configure: { _ in },
            loadCache: { try JSONDecoder().decode([Ledger].self, from: self.data) },
            saveCache: { self.saveCount += 1; self.data = try JSONEncoder().encode($0) },
            openWebsite: { _ in true },
            now: { now },
            calendar: { calendar }
        ), debounceNanoseconds: 0)
    }
}
