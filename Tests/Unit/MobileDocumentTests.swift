#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import Tally

@MainActor
@Suite(.serialized)
struct MobileDocumentTests {
    @Test func creatingAnotherCashFlowNeverOverwritesAnExistingFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try TallyDocumentBrowserController.createNewFile(in: fixture.directory, ledger: fixture.ledger)
        let secondLedger = Ledger(expenses: [Expense(merchant: "Another fictional file")])
        let second = try TallyDocumentBrowserController.createNewFile(in: fixture.directory, ledger: secondLedger)
        #expect(first.lastPathComponent == "Cash Flow.tally")
        #expect(second.lastPathComponent == "Cash Flow 2.tally")
        #expect(try LedgerCodec.decode(Data(contentsOf: first)) == fixture.ledger)
        #expect(try LedgerCodec.decode(Data(contentsOf: second)) == secondLedger)
    }

    @Test func nativeSaveCloseAndReopenPreservesTheLedger() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let native = MobileTallyDocument(opening: fixture.url, ledger: fixture.ledger)
        #expect(await native.save(to: fixture.url, for: .forCreating))
        #expect(await native.closeFile())
        let reopened = MobileTallyDocument(opening: fixture.url)
        #expect(await reopened.open())
        #expect(reopened.model.ledger == fixture.ledger)
        #expect(await reopened.closeFile())
    }

    @Test func nativeCloseStopsAnInFlightReplacementCheck() async throws {
        let fixture = try Fixture(write: true)
        defer { fixture.remove() }
        let native = MobileTallyDocument(opening: fixture.url)
        #expect(await native.open())
        native.startWatching()
        try LedgerCodec.encode(fixture.ledger).write(to: fixture.url, options: .atomic)
        // Direct native close must perform the same teardown as closeFile.
        #expect(await native.close())
        try await Task.sleep(for: .milliseconds(650))
        #expect(native.documentState.contains(.closed))
        #expect(!native.isRemoved)
        #expect(try LedgerCodec.decode(Data(contentsOf: fixture.url)) == fixture.ledger)
    }

    @Test func nativeUndoAutosaveAndRedoPersistOnReopen() async throws {
        let fixture = try Fixture(write: true)
        defer { fixture.remove() }
        let native = MobileTallyDocument(opening: fixture.url)
        #expect(await native.open())
        let undo = try #require(native.undoManager)
        undo.groupsByEvent = false
        var edited = native.model.ledger.expenses[0]
        edited.amountMinor = 154_321
        undo.beginUndoGrouping()
        native.model.updateExpense(edited, undoManager: undo)
        undo.endUndoGrouping()
        #expect(await native.autosave())
        #expect(try LedgerCodec.decode(Data(contentsOf: fixture.url)).expenses[0].amountMinor == 154_321)
        undo.undo()
        #expect(await native.autosave())
        #expect(try LedgerCodec.decode(Data(contentsOf: fixture.url)) == fixture.ledger)
        undo.redo()
        #expect(await native.closeFile())
        let reopened = MobileTallyDocument(opening: fixture.url)
        #expect(await reopened.open())
        #expect(reopened.model.ledger.expenses[0] == edited)
        #expect(await reopened.closeFile())
    }

    @Test func nativeRevertMergesIndependentChanges() async throws {
        let fixture = try Fixture(write: true)
        defer { fixture.remove() }
        let native = MobileTallyDocument(opening: fixture.url)
        #expect(await native.open())
        var local = native.model.ledger.expenses[0]
        local.amountMinor = 190_000
        let undo = try #require(native.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        native.model.updateExpense(local, undoManager: undo)
        undo.endUndoGrouping()
        var remote = fixture.ledger
        remote.expenses[1].merchant = "Fictional revised utility"
        try LedgerCodec.encode(remote).write(to: fixture.url, options: .atomic)
        #expect(await native.revert(toContentsOf: fixture.url))
        #expect(native.model.ledger.expenses[0] == local)
        #expect(native.model.ledger.expenses[1] == remote.expenses[1])
        #expect(await native.closeFile())
        let reopened = MobileTallyDocument(opening: fixture.url)
        #expect(await reopened.open())
        #expect(reopened.model.ledger.expenses[0] == local)
        #expect(reopened.model.ledger.expenses[1] == remote.expenses[1])
        #expect(await reopened.closeFile())
    }

    @Test func externalDeletionPausesSavingAndRestorationResumesTheFile() async throws {
        let fixture = try Fixture(write: true)
        defer { fixture.remove() }
        let native = MobileTallyDocument(opening: fixture.url)
        #expect(await native.open())
        native.startWatching()
        try await Self.removeCoordinated(fixture.url)
        #expect(await waitUntil { native.isRemoved })
        #expect(await native.autosave())
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
        try LedgerCodec.encode(fixture.ledger).write(to: fixture.url, options: .atomic)
        #expect(await waitUntil { !native.isRemoved })
        #expect(native.model.ledger == fixture.ledger)
        #expect(await native.closeFile())
        #expect(FileManager.default.fileExists(atPath: fixture.url.path))
    }

    @Test func closingDeletedFileDoesNotRecreateIt() async throws {
        let fixture = try Fixture(write: true)
        defer { fixture.remove() }
        let native = MobileTallyDocument(opening: fixture.url)
        #expect(await native.open())
        native.startWatching()
        try await Self.removeCoordinated(fixture.url)
        #expect(await waitUntil { native.isRemoved })
        #expect(await native.closeFile())
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(native.documentState.contains(.closed))
    }

    @Test func atomicReplacementKeepsEditingAndLaterDeletionIsStillObserved() async throws {
        let fixture = try Fixture(write: true)
        defer { fixture.remove() }
        let native = MobileTallyDocument(opening: fixture.url)
        #expect(await native.open())
        native.startWatching()
        var replacement = fixture.ledger
        replacement.expenses[0].merchant = "Fictional updated rent"
        try LedgerCodec.encode(replacement).write(to: fixture.url, options: .atomic)
        #expect(await waitUntil { native.model.ledger.expenses[0].merchant == "Fictional updated rent" })
        #expect(!native.isRemoved)
        var local = native.model.ledger.expenses[1]
        local.amountMinor = 7_100
        native.model.updateExpense(local, undoManager: nil)
        #expect(await native.save(to: fixture.url, for: .forOverwriting))
        let saved = try LedgerCodec.decode(Data(contentsOf: fixture.url))
        #expect(saved.expenses[0].merchant == "Fictional updated rent")
        #expect(saved.expenses[1].amountMinor == 7_100)
        try await Self.removeCoordinated(fixture.url)
        #expect(await waitUntil { native.isRemoved })
        #expect(await native.closeFile())
    }

    @Test func moveToTrashAndRestoreFollowTheNativeURL() async throws {
        let fixture = try Fixture(write: true)
        defer { fixture.remove() }
        let native = MobileTallyDocument(opening: fixture.url)
        #expect(await native.open())
        native.startWatching()
        let trash = fixture.directory.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let trashedURL = trash.appendingPathComponent(fixture.url.lastPathComponent)
        try await Self.moveCoordinated(fixture.url, to: trashedURL)
        #expect(await waitUntil { native.isRemoved })
        #expect(native.fileURL == trashedURL)
        try await Self.moveCoordinated(trashedURL, to: fixture.url)
        #expect(await waitUntil { !native.isRemoved && native.fileURL == fixture.url })
        #expect(await native.closeFile())
    }

    @Test func directoryAndEvictionPlaceholderAreNotDeletion() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(MobileFileAvailability.inspect(fixture.directory) == .unavailable)
        let placeholder = fixture.directory.appendingPathComponent(".\(fixture.url.lastPathComponent).icloud")
        try Data().write(to: placeholder)
        #expect(MobileFileAvailability.inspect(fixture.url) == .unavailable)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<50 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return predicate()
    }

    private static func removeCoordinated(_ url: URL) async throws {
        try await Task.detached {
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var operationError: (any Error)?
            coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { safeURL in
                do { try FileManager.default.removeItem(at: safeURL) } catch { operationError = error }
            }
            if let error = operationError ?? coordinationError { throw error }
        }.value
    }

    private static func moveCoordinated(_ source: URL, to destination: URL) async throws {
        try await Task.detached {
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var operationError: (any Error)?
            coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: destination, options: .forReplacing, error: &coordinationError) { from, to in
                do {
                    try FileManager.default.moveItem(at: from, to: to)
                    coordinator.item(at: from, didMoveTo: to)
                } catch { operationError = error }
            }
            if let error = operationError ?? coordinationError { throw error }
        }.value
    }

    private struct Fixture {
        let directory: URL
        let url: URL
        let ledger: Ledger

        init(write: Bool = false) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("TallyMobileUnit-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("Fictional budget.tally")
            ledger = Ledger(expenses: [
                Expense(merchant: "Fictional rent", amountMinor: 123_456, billingDay: 1),
                Expense(merchant: "Fictional utility", amountMinor: 6_500, billingDay: 15)
            ])
            if write { try LedgerCodec.encode(ledger).write(to: url) }
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
#endif
