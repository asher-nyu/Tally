#if os(macOS)
import AppKit
import Foundation
import Synchronization
import Testing
@testable import Tally

nonisolated struct MacDocumentLifetimeTests {
    @Test(arguments: [
        MacDocumentLifetimePolicy.FileState.present,
        .unknown,
        .evicted
    ])
    func existingUncertainOrEvictedFilesStayOpenDespiteADeletionHint(
        state: MacDocumentLifetimePolicy.FileState
    ) {
        #expect(MacDocumentLifetimePolicy.decision(
            fileState: state, deletionRequested: true, missingConfirmed: true
        ) == .keepOpen)
    }

    @Test func permanentDeletionRequiresASecondMissingObservationBeforeClosing() {
        #expect(MacDocumentLifetimePolicy.decision(
            fileState: .missing, deletionRequested: true, missingConfirmed: false
        ) == .verifyAgain)
        #expect(MacDocumentLifetimePolicy.decision(
            fileState: .missing, deletionRequested: true, missingConfirmed: true
        ) == .closeWindow)
    }

    @Test func missingFileWithoutDeletionEvidenceStaysOpen() {
        for confirmed in [false, true] {
            #expect(MacDocumentLifetimePolicy.decision(
                fileState: .missing, deletionRequested: false, missingConfirmed: confirmed
            ) == .keepOpen)
        }
    }

    @Test func movingToTrashImmediatelyOffersRecovery() {
        #expect(MacDocumentLifetimePolicy.decision(
            fileState: .inTrash, deletionRequested: false, missingConfirmed: false
        ) == .showTrashRecovery)
    }

    @Test(arguments: [MacDocumentLifetimePolicy.FileState.missing, .inTrash])
    func staleValidationCannotCloseADifferentDocument(
        state: MacDocumentLifetimePolicy.FileState
    ) {
        #expect(MacDocumentLifetimePolicy.decision(
            fileState: state, deletionRequested: true, missingConfirmed: true,
            isCurrent: false
        ) == .keepOpen)
    }

    @Test func trashDetectionUsesDirectoryComponentsRatherThanNamesOrPrefixes() {
        let base = URL(fileURLWithPath: "/isolated-lifetime-fixtures", isDirectory: true)
        let trash = base.appendingPathComponent("Trash", isDirectory: true)
        let inside = trash.appendingPathComponent("Nested/Finances.tally")
        let samePrefix = base.appendingPathComponent("Trash Backup/Finances.tally")
        let sameNameElsewhere = base.appendingPathComponent("Work/Trash/Finances.tally")
        let filenameOnly = base.appendingPathComponent("Work/My Trash.tally")

        #expect(MacDocumentLifetimeInspection.isInsideTrash(inside, trashDirectory: trash))
        #expect(!MacDocumentLifetimeInspection.isInsideTrash(samePrefix, trashDirectory: trash))
        #expect(!MacDocumentLifetimeInspection.isInsideTrash(sameNameElsewhere, trashDirectory: trash))
        #expect(!MacDocumentLifetimeInspection.isInsideTrash(filenameOnly, trashDirectory: trash))
        #expect(!MacDocumentLifetimeInspection.isInsideTrash(
            trash.appendingPathComponent("../Work/Finances.tally"), trashDirectory: trash
        ))
        #expect(MacDocumentLifetimeInspection.isInsideTrash(
            base.appendingPathComponent("Work/../Trash/Finances.tally"), trashDirectory: trash
        ))
    }

    @Test func inspectionDistinguishesRenameReplacementAbsenceAndActualTrash() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = FileManager.default
        let trash = directory.appendingPathComponent("Trash", isDirectory: true)
        try manager.createDirectory(at: trash, withIntermediateDirectories: false)
        let original = directory.appendingPathComponent("Finances.tally")
        let renamed = directory.appendingPathComponent("Renamed.tally")
        try Data("first saved version".utf8).write(to: original)
        #expect(MacDocumentLifetimeInspection.inspect(original, trashDirectory: trash) == .present)

        try Data("atomic replacement".utf8).write(to: original, options: .atomic)
        #expect(MacDocumentLifetimeInspection.inspect(original, trashDirectory: trash) == .present)

        try manager.moveItem(at: original, to: renamed)
        #expect(MacDocumentLifetimeInspection.inspect(original, trashDirectory: trash) == .missing)
        #expect(MacDocumentLifetimeInspection.inspect(renamed, trashDirectory: trash) == .present)

        try manager.removeItem(at: renamed)
        let transient = MacDocumentLifetimeInspection.inspect(renamed, trashDirectory: trash)
        #expect(transient == .missing)
        #expect(MacDocumentLifetimePolicy.decision(
            fileState: transient, deletionRequested: true, missingConfirmed: false
        ) == .verifyAgain)
        try Data("replacement after brief absence".utf8).write(to: renamed)
        #expect(MacDocumentLifetimePolicy.decision(
            fileState: MacDocumentLifetimeInspection.inspect(renamed, trashDirectory: trash),
            deletionRequested: true, missingConfirmed: true
        ) == .keepOpen)

        let trashed = trash.appendingPathComponent("Renamed.tally")
        try manager.moveItem(at: renamed, to: trashed)
        #expect(MacDocumentLifetimeInspection.inspect(trashed, trashDirectory: trash) == .inTrash)
        #expect(try Data(contentsOf: trashed) == Data("replacement after brief absence".utf8))
    }

    @Test func cloudPlaceholderIsInconclusiveRatherThanConfirmedDeletion() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("Finances.tally")
        let placeholder = directory.appendingPathComponent(".Finances.tally.icloud")
        let trash = directory.appendingPathComponent("Trash", isDirectory: true)
        try Data("local placeholder fixture".utf8).write(to: placeholder)

        let state = MacDocumentLifetimeInspection.inspect(document, trashDirectory: trash)
        #expect(state == .unknown)
        #expect(MacDocumentLifetimePolicy.decision(
            fileState: state, deletionRequested: true, missingConfirmed: true
        ) == .keepOpen)
        #expect(try Data(contentsOf: placeholder) == Data("local placeholder fixture".utf8))

        try FileManager.default.removeItem(at: placeholder)
        #expect(MacDocumentLifetimeInspection.inspect(document, trashDirectory: trash) == .missing)
    }

    @Test func permanentDeletionInsideTrashIsMissingRatherThanStillInTrash() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = FileManager.default
        let trash = directory.appendingPathComponent("Trash", isDirectory: true)
        try manager.createDirectory(at: trash, withIntermediateDirectories: false)
        let document = trash.appendingPathComponent("Finances.tally")
        try Data("file moved to Trash".utf8).write(to: document)

        let existingState = MacDocumentLifetimeInspection.inspect(document, trashDirectory: trash)
        #expect(existingState == .inTrash)
        #expect(MacDocumentLifetimePolicy.decision(
            fileState: existingState, deletionRequested: true, missingConfirmed: true
        ) == .showTrashRecovery)

        try manager.removeItem(at: document)
        // The path still lies under Trash. Fresh filesystem metadata, not its
        // location or cached earlier metadata, must establish permanent deletion.
        #expect(MacDocumentLifetimeInspection.isInsideTrash(document, trashDirectory: trash))
        let missingState = MacDocumentLifetimeInspection.inspect(document, trashDirectory: trash)
        #expect(missingState == .missing)
        #expect(MacDocumentLifetimePolicy.decision(
            fileState: missingState, deletionRequested: true, missingConfirmed: false
        ) == .verifyAgain)
        #expect(MacDocumentLifetimePolicy.decision(
            fileState: missingState, deletionRequested: true, missingConfirmed: true
        ) == .closeWindow)
    }

    @Test func deletionAccommodationAcknowledgesBeforePublishingTheHint() {
        let url = URL(fileURLWithPath: "/isolated-lifetime-fixtures/Finances.tally")
        let order = Mutex<[String]>([])
        let events = Mutex<[(MacDocumentLifetimePresenter.Event, URL)]>([])
        let presenter = MacDocumentLifetimePresenter(url: url) { event, eventURL in
            order.withLock { $0.append("event") }
            events.withLock { $0.append((event, eventURL)) }
        }

        presenter.accommodatePresentedItemDeletion { error in
            #expect(error == nil)
            order.withLock { $0.append("acknowledged") }
        }

        #expect(order.withLock { $0 } == ["acknowledged", "event"])
        let recorded = events.withLock { $0 }
        #expect(recorded.count == 1)
        #expect(recorded.first?.0 == .deletion)
        #expect(recorded.first?.1 == url)
        #expect(presenter.presentedItemURL == url)
    }

    @Test func presenterFollowsRenamesAndSubsequentEventsUseTheNewURL() {
        let oldURL = URL(fileURLWithPath: "/isolated-lifetime-fixtures/Original.tally")
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent("Renamed.tally")
        let events = Mutex<[(MacDocumentLifetimePresenter.Event, URL)]>([])
        let presenter = MacDocumentLifetimePresenter(url: oldURL) { event, eventURL in
            events.withLock { $0.append((event, eventURL)) }
        }

        presenter.presentedItemDidMove(to: newURL)
        presenter.presentedItemDidChange()
        presenter.accommodatePresentedItemDeletion { error in #expect(error == nil) }

        #expect(presenter.presentedItemURL == newURL)
        let recorded = events.withLock { $0 }
        #expect(recorded.map { $0.0 } == [.moved, .changed, .deletion])
        #expect(recorded.allSatisfy { $0.1 == newURL })
        #expect(presenter.presentedItemOperationQueue.maxConcurrentOperationCount == 1)
    }

    @Test func evictionUnregistersBeforeAcknowledgementAndDoesNotSignalDeletion() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Finances.tally")
        try Data("saved document".utf8).write(to: url)
        let order = Mutex<[String]>([])
        let events = Mutex<[MacDocumentLifetimePresenter.Event]>([])
        let presenter = MacDocumentLifetimePresenter(url: url) { event, _ in
            order.withLock { $0.append("event") }
            events.withLock { $0.append(event) }
        }
        defer { presenter.stop() }

        presenter.start()
        presenter.start()
        #expect(NSFileCoordinator.filePresenters.filter { $0 === presenter }.count == 1)
        presenter.accommodatePresentedItemEviction { error in
            #expect(error == nil)
            #expect(!NSFileCoordinator.filePresenters.contains { $0 === presenter })
            order.withLock { $0.append("acknowledged") }
        }

        #expect(order.withLock { $0 } == ["acknowledged", "event"])
        #expect(events.withLock { $0 } == [.evicted])
        presenter.stop()
        #expect(!NSFileCoordinator.filePresenters.contains { $0 === presenter })
        #expect(try Data(contentsOf: url) == Data("saved document".utf8))
    }

    @Test func inodeMonitorSurvivesRenameAndReportsDeletionAtTheNewPath() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = FileManager.default
        let movedDirectory = directory.appendingPathComponent("Moved", isDirectory: true)
        try manager.createDirectory(at: movedDirectory, withIntermediateDirectories: false)
        let original = directory.appendingPathComponent("Finances.tally")
        let moved = movedDirectory.appendingPathComponent("Renamed.tally")
        let contents = Data("Monitor this file through its move".utf8)
        try contents.write(to: original)
        let deletionEvent = DispatchSemaphore(value: 0)
        let monitor = try #require(MacDocumentLifetimeVnodeMonitor(url: original) { deleted in
            if deleted { deletionEvent.signal() }
        })
        defer { monitor.stop() }

        #expect(!monitor.isUnlinked)
        try manager.moveItem(at: original, to: moved)
        #expect(!manager.fileExists(atPath: original.path))
        #expect(try Data(contentsOf: moved) == contents)
        #expect(!monitor.isUnlinked, "Renaming preserves the monitored file even though its original path is gone.")

        // Keep the original monitor: observing deletion must not depend on
        // reopening the new path, which may be inaccessible after a Trash move.
        try manager.removeItem(at: moved)
        #expect(deletionEvent.wait(timeout: .now() + 3) == .success,
                "The existing monitor must deliver deletion after the file is renamed and then unlinked.")
        #expect(monitor.isUnlinked)
        #expect(!manager.fileExists(atPath: moved.path))
    }

    @Test @MainActor
    func nativeURLCatchupRevalidatesAFileDeletedAfterItsMove() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("Original.tally")
        let moved = directory.appendingPathComponent("Moved.tally")
        try Data("saved document".utf8).write(to: original)
        let native = LifetimeTestNativeDocument()
        native.fileURL = original
        let coordinator = MacDocumentLifetime.Coordinator(document: TallyDocument())
        coordinator.connect(to: native)
        defer { coordinator.stop() }
        try #require(try await waitUntil { lifetimePresenter(at: original) != nil })
        let presenter = try #require(lifetimePresenter(at: original))

        try FileManager.default.moveItem(at: original, to: moved)
        presenter.presentedItemDidMove(to: moved)
        try FileManager.default.removeItem(at: moved)
        // The native URL deliberately lags the presenter. Let the original
        // validation run and reject that mismatch before delivering native KVO.
        try await Task.sleep(for: .milliseconds(800))
        #expect(native.fileURL == original)
        #expect(native.closeCount == 0)

        native.fileURL = moved

        #expect(try await waitUntil { native.closeCount == 1 },
                "Native URL catch-up must retry validation and close a permanently removed file.")
        coordinator.closeDeletedWindow()
        #expect(native.closeCount == 1, "A stale alert action must not close twice.")
        #expect(!FileManager.default.fileExists(atPath: moved.path))
    }

    @Test @MainActor
    func rematerializedDocumentResumesObservationAfterEviction() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Finances.tally")
        let contents = Data("saved document".utf8)
        try contents.write(to: url)
        let native = LifetimeTestNativeDocument()
        native.fileURL = url
        let coordinator = MacDocumentLifetime.Coordinator(document: TallyDocument())
        coordinator.connect(to: native)
        defer { coordinator.stop() }
        try #require(try await waitUntil { lifetimePresenter(at: url) != nil })
        let originalPresenter = try #require(lifetimePresenter(at: url))

        originalPresenter.accommodatePresentedItemEviction { error in #expect(error == nil) }
        try FileManager.default.removeItem(at: url)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        // A missing evicted file must remain open, including after activation.
        try await Task.sleep(for: .milliseconds(800))
        #expect(native.closeCount == 0)
        #expect(lifetimePresenter(at: url) == nil)

        try contents.write(to: url)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try #require(try await waitUntil {
            guard let replacement = lifetimePresenter(at: url) else { return false }
            return replacement !== originalPresenter
        }, "Materializing the same URL must register a new presenter.")
        #expect(native.closeCount == 0)
        #expect(try Data(contentsOf: url) == contents)

        try FileManager.default.removeItem(at: url)

        #expect(try await waitUntil { native.closeCount == 1 },
                "A document restored after eviction must close on later permanent deletion.")
        #expect(!coordinator.deletionPending)
    }

    private func lifetimePresenter(at url: URL) -> MacDocumentLifetimePresenter? {
        NSFileCoordinator.filePresenters.compactMap { $0 as? MacDocumentLifetimePresenter }
            .first { $0.presentedItemURL == url }
    }

    @Test @MainActor
    func trashAlertContinuesObservingPermanentRemoval() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trash = directory.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        let original = directory.appendingPathComponent("Finances.tally")
        let trashed = trash.appendingPathComponent(original.lastPathComponent)
        try Data("saved fixture".utf8).write(to: original)
        let native = LifetimeTestNativeDocument()
        native.fileURL = original
        let coordinator = MacDocumentLifetime.Coordinator(document: TallyDocument()) {
            MacDocumentLifetimeInspection.inspect($0, trashDirectory: trash)
        }
        coordinator.connect(to: native)
        defer { coordinator.stop() }
        try #require(try await waitUntil { lifetimePresenter(at: original) != nil })
        let presenter = try #require(lifetimePresenter(at: original))
        try FileManager.default.moveItem(at: original, to: trashed)
        presenter.presentedItemDidMove(to: trashed)
        native.fileURL = trashed
        try #require(try await waitUntil { coordinator.deletionPending })
        #expect(native.closeCount == 0)
        #expect(lifetimePresenter(at: trashed) != nil,
                "Presenting recovery must not unregister the observer.")

        try FileManager.default.removeItem(at: trashed)
        #expect(try await waitUntil { native.closeCount == 1 },
                "Emptying Trash must close the document even with its recovery alert pending.")
        #expect(!coordinator.deletionPending)
    }

    @Test @MainActor
    func externalRestoreDismissesTrashStateAndRetainsTheEditor() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trash = directory.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        let original = directory.appendingPathComponent("Finances.tally")
        let trashed = trash.appendingPathComponent(original.lastPathComponent)
        let contents = Data("saved fixture".utf8)
        try contents.write(to: original)
        let native = LifetimeTestNativeDocument()
        native.fileURL = original
        let coordinator = MacDocumentLifetime.Coordinator(document: TallyDocument()) {
            MacDocumentLifetimeInspection.inspect($0, trashDirectory: trash)
        }
        coordinator.connect(to: native)
        defer { coordinator.stop() }
        try #require(try await waitUntil { lifetimePresenter(at: original) != nil })
        var presenter = try #require(lifetimePresenter(at: original))
        try FileManager.default.moveItem(at: original, to: trashed)
        presenter.presentedItemDidMove(to: trashed)
        native.fileURL = trashed
        try #require(try await waitUntil { coordinator.deletionPending })

        presenter = try #require(lifetimePresenter(at: trashed))
        try FileManager.default.moveItem(at: trashed, to: original)
        presenter.presentedItemDidMove(to: original)
        native.fileURL = original
        #expect(try await waitUntil { !coordinator.deletionPending })
        #expect(native.closeCount == 0)
        #expect(try Data(contentsOf: original) == contents)
        coordinator.closeDeletedWindow()
        #expect(native.closeCount == 0, "An action from a dismissed sheet must not close the restored file.")

        // Restoration must leave observation active for a future deletion too.
        try FileManager.default.removeItem(at: original)
        #expect(try await waitUntil { native.closeCount == 1 })
    }

    @Test func restoreMovesExistingBytesWithoutOverwritingAnotherFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Trashed.tally")
        let destination = directory.appendingPathComponent("Original.tally")
        let contents = Data("original contents".utf8)
        let otherContents = Data("another file".utf8)
        try contents.write(to: source)
        try otherContents.write(to: destination)
        #expect(throws: (any Error).self) {
            try MacDocumentRestore.move(from: source, to: destination)
        }
        #expect(try Data(contentsOf: source) == contents)
        #expect(try Data(contentsOf: destination) == otherContents)
        try FileManager.default.removeItem(at: destination)
        try MacDocumentRestore.move(from: source, to: destination)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: destination) == contents)
    }

    @Test(arguments: [true, false])
    func restoreBalancesScopedAccessWhenTheDestinationIsOccupied(_ destinationOccupied: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Trashed.tally")
        let destination = directory.appendingPathComponent("Original.tally")
        let contents = Data("source fixture".utf8)
        try contents.write(to: source)
        if destinationOccupied { try Data("existing fixture".utf8).write(to: destination) }
        var active = Set<URL>()
        var started: [URL] = []
        var stopped: [URL] = []
        var moveError: Error?
        do {
            try MacDocumentRestore.move(from: source, to: destination, startAccessing: { url in
                started.append(url)
                active.insert(url)
                return true
            }, stopAccessing: { url in
                // Grants must remain active until the move succeeds or fails.
                #expect(FileManager.default.fileExists(atPath: source.path) == destinationOccupied)
                stopped.append(url)
                active.remove(url)
            })
        } catch {
            moveError = error
        }
        #expect((moveError != nil) == destinationOccupied)
        #expect(started == [source, destination])
        #expect(stopped == [source, destination])
        #expect(active.isEmpty)
        #expect(try Data(contentsOf: destination) == (destinationOccupied ? Data("existing fixture".utf8) : contents))
    }

    @Test func restoreDoesNotReleaseAnUnacquiredScope() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Trashed.tally")
        let destination = directory.appendingPathComponent("Original.tally")
        try Data("fixture".utf8).write(to: source)
        var stopped: [URL] = []
        try MacDocumentRestore.move(from: source, to: destination,
                                    startAccessing: { $0 == source },
                                    stopAccessing: { stopped.append($0) })
        #expect(stopped == [source])
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func recoveryExplainsTheActualFailure() {
        let denied = CocoaError(.fileWriteNoPermission)
        let occupied = CocoaError(.fileWriteFileExists)
        #expect(MacDocumentRestore.recoveryMessage(for: denied).contains("couldn’t access"))
        #expect(!MacDocumentRestore.recoveryMessage(for: denied).contains("already exists"))
        #expect(MacDocumentRestore.recoveryMessage(for: occupied).contains("already exists"))
        #expect(!MacDocumentRestore.recoveryMessage(for: CocoaError(.fileWriteUnknown)).contains("already exists"))
    }

    @MainActor
    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(4))
        while !predicate() {
            guard clock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tally-MacDocumentLifetimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}

/// An AppKit document with no windows or disk writer. Manual KVO lets the test
/// order native URL catch-up independently from the real file-presenter event.
@MainActor
private final class LifetimeTestNativeDocument: NSDocument {
    nonisolated private let currentURL = Mutex<URL?>(nil)
    private(set) var closeCount = 0

    nonisolated override var fileURL: URL? {
        get { currentURL.withLock { $0 } }
        set {
            willChangeValue(forKey: "fileURL")
            currentURL.withLock { $0 = newValue }
            didChangeValue(forKey: "fileURL")
        }
    }

    nonisolated override class func automaticallyNotifiesObservers(forKey key: String) -> Bool {
        key == "fileURL" ? false : super.automaticallyNotifiesObservers(forKey: key)
    }

    override func close() { closeCount += 1 }
}
#endif
