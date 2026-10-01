#if os(iOS)
import Foundation
import Observation
import Synchronization
import UIKit
import Darwin

nonisolated enum MobileFileAvailability: Equatable {
    case available, removed, inTrash, unavailable

    static func inspect(_ url: URL) -> Self {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        do {
            let values = try fresh.resourceValues(forKeys: [.isRegularFileKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus == .notDownloaded {
                return .unavailable
            }
            if fresh.pathComponents.contains(where: { $0 == ".Trash" || $0 == ".Trashes" }) {
                return .inTrash
            }
            return values.isRegularFile == true ? .available : .unavailable
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                let placeholder = fresh.deletingLastPathComponent().appendingPathComponent(".\(fresh.lastPathComponent).icloud")
                return FileManager.default.fileExists(atPath: placeholder.path) ? .unavailable : .removed
            }
            return .unavailable
        }
    }
}

/// The public UIDocument lifecycle is used on iPhone and iPad so deletion can
/// offer recovery instead of competing with SwiftUI's system-owned alert.
nonisolated final class MobileTallyDocument: UIDocument, @unchecked Sendable {
    @MainActor let model: TallyDocument
    @MainActor var onAvailabilityChange: (() -> Void)?
    @MainActor private(set) var isRemoved = false
    @MainActor private(set) var editingDisabled = false

    private struct SnapshotState: Sendable {
        var current: Ledger
        var saved: Ledger?
        var blocksSaving = false
    }
    nonisolated private let snapshots: Mutex<SnapshotState>
    private struct Callbacks: Sendable {
        var accept: (@MainActor @Sendable (Ledger) throws -> Void)?
        var event: (@MainActor @Sendable (Event) -> Void)?
    }
    private enum Event: Sendable { case deleted, changed, editing(Bool), reloaded, closing, closeFailed }
    nonisolated private let callbacks = Mutex(Callbacks())
    @MainActor private var originalURL: URL
    // These handles are mutated only on MainActor and canceled at deinit;
    // event handlers capture self weakly, so teardown cannot race a live call.
    nonisolated(unsafe) private var validationTask: Task<Void, Never>?
    nonisolated(unsafe) private var fileSource: (any DispatchSourceFileSystemObject)?
    nonisolated(unsafe) private var directorySource: (any DispatchSourceFileSystemObject)?
    @MainActor private var sourceURL: URL?
    @MainActor private var didStartWatching = false
    @MainActor private var isFinishing = false

    nonisolated override init(fileURL: URL) {
        let initial = Ledger()
        if Thread.isMainThread {
            model = MainActor.assumeIsolated { TallyDocument(ledger: initial) }
        } else {
            model = DispatchQueue.main.sync { TallyDocument(ledger: initial) }
        }
        snapshots = Mutex(SnapshotState(current: initial))
        originalURL = fileURL
        super.init(fileURL: fileURL)
        let setup: @MainActor @Sendable () -> Void = { [weak self] in self?.connectModel() }
        if Thread.isMainThread { MainActor.assumeIsolated { setup() } }
        else { DispatchQueue.main.sync { setup() } }
    }

    @MainActor
    convenience init(opening fileURL: URL, ledger: Ledger = Ledger()) {
        self.init(fileURL: fileURL)
        // No prior version exists during construction, so this is a direct
        // snapshot application, identical to a newly opened file.
        try? model.applySnapshot(ledger, previous: nil)
    }

    @MainActor
    private func connectModel() {
        callbacks.withLock {
            $0.accept = { [weak self] ledger in try self?.accept(ledger) }
            $0.event = { [weak self] event in
                guard let self else { return }
                switch event {
                case .deleted: validateSoon(deletionEvidence: true)
                case .changed: validateSoon(deletionEvidence: false)
                case .reloaded:
                    guard !isFinishing, !documentState.contains(.closed) else { return }
                    if snapshots.withLock({ $0.current != $0.saved }) { updateChangeCount(.done) }
                case .closing: stopWatchingForClose()
                case .closeFailed:
                    isFinishing = false
                    didStartWatching = false
                    sourceURL = nil
                    directoryURL = nil
                    startWatching()
                    validateSoon(deletionEvidence: false)
                case .editing(let disabled):
                    editingDisabled = disabled
                    onAvailabilityChange?()
                }
            }
        }
        model.ledgerDidChange = { [weak self] ledger in
            self?.snapshots.withLock { $0.current = ledger }
        }
    }

    nonisolated override func load(fromContents contents: Any, ofType typeName: String?) throws {
        let data: Data
        if let bytes = contents as? Data {
            data = bytes
        } else if let wrapper = contents as? FileWrapper, let bytes = wrapper.regularFileContents {
            data = bytes
        } else {
            throw LedgerError.corruptFile
        }
        let incoming = try LedgerCodec.decode(data)
        let accept = callbacks.withLock { $0.accept }
        // UIDocument calls this on the queue used for open/revert. All app
        // operations use the main queue; the fallback also supports a provider
        // invoking the reader from a background queue.
        if Thread.isMainThread {
            try MainActor.assumeIsolated { try accept?(incoming) }
        } else {
            try DispatchQueue.main.sync { try accept?(incoming) }
        }
    }

    @MainActor
    private func accept(_ incoming: Ledger) throws {
        let previous = snapshots.withLock { $0.saved }
        try model.applySnapshot(incoming, previous: previous)
        snapshots.withLock { $0.saved = incoming }
    }

    nonisolated override func contents(forType typeName: String) throws -> Any {
        try snapshots.withLock { try LedgerCodec.encode($0.current) }
    }

    nonisolated override func writeContents(_ contents: Any, to url: URL, for saveOperation: UIDocument.SaveOperation, originalContentsURL: URL?) throws {
        try super.writeContents(contents, to: url, for: saveOperation, originalContentsURL: originalContentsURL)
        if let data = contents as? Data {
            let saved = try LedgerCodec.decode(data)
            snapshots.withLock { $0.saved = saved }
        }
    }

    nonisolated override func autosave(completionHandler: (@Sendable (Bool) -> Void)? = nil) {
        guard !snapshots.withLock({ $0.blocksSaving }) else {
            completionHandler?(true)
            return
        }
        super.autosave(completionHandler: completionHandler)
    }

    nonisolated override func save(to url: URL, for saveOperation: UIDocument.SaveOperation, completionHandler: (@Sendable (Bool) -> Void)? = nil) {
        guard !snapshots.withLock({ $0.blocksSaving }) else {
            completionHandler?(true)
            return
        }
        super.save(to: url, for: saveOperation, completionHandler: completionHandler)
    }

    nonisolated override func revert(toContentsOf url: URL, completionHandler: (@Sendable (Bool) -> Void)? = nil) {
        let reloaded = callbacks.withLock { $0.event }
        super.revert(toContentsOf: url) { succeeded in
            Task { @MainActor in
                // UIKit clears its change count when reverting. A three-way
                // merge can preserve local changes that still need saving.
                if succeeded { reloaded?(.reloaded) }
                completionHandler?(succeeded)
            }
        }
    }

    nonisolated override func close(completionHandler: (@Sendable (Bool) -> Void)? = nil) {
        // Keep teardown on the native close entry point, including callers
        // that do not use the browser's recovery helper.
        let event = callbacks.withLock { $0.event }
        if Thread.isMainThread { MainActor.assumeIsolated { event?(.closing) } }
        else { DispatchQueue.main.sync { event?(.closing) } }
        if documentState.contains(.closed) { completionHandler?(true); return }
        super.close { success in
            Task { @MainActor in
                if !success { event?(.closeFailed) }
                completionHandler?(success)
            }
        }
    }

    nonisolated override func accommodatePresentedItemDeletion(completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        // Release the coordinator before any UI work. Keeping the in-memory
        // model makes recovery possible, while suppressing autosave prevents
        // recreating a file that another app has deliberately removed.
        snapshots.withLock { $0.blocksSaving = true }
        completionHandler(nil)
        send(.deleted)
    }

    nonisolated override func presentedItemDidMove(to newURL: URL) {
        super.presentedItemDidMove(to: newURL)
        send(.changed)
    }

    nonisolated override func presentedItemDidChange() {
        if !snapshots.withLock({ $0.blocksSaving }) { super.presentedItemDidChange() }
        send(.changed)
    }

    nonisolated override func disableEditing() {
        send(.editing(true))
    }

    nonisolated override func enableEditing() {
        send(.editing(false))
    }

    nonisolated private func send(_ event: Event) {
        let callback = callbacks.withLock { $0.event }
        Task { @MainActor in callback?(event) }
    }

    @MainActor
    func startWatching() {
        guard !didStartWatching else { return }
        didStartWatching = true
        watchDirectory(originalURL.deletingLastPathComponent())
        watchFile(fileURL)
    }

    @MainActor
    func checkAfterActivation() { validateSoon(deletionEvidence: isRemoved) }

    @MainActor
    private func validateSoon(deletionEvidence: Bool) {
        guard !isFinishing, !documentState.contains(.closed) else { return }
        validationTask?.cancel()
        validationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, !isFinishing, !documentState.contains(.closed) else { return }
            let currentURL = fileURL
            let availability = await Task.detached(priority: .utility) { MobileFileAvailability.inspect(currentURL) }.value
            guard !Task.isCancelled, currentURL == fileURL, !documentState.contains(.closed) else { return }
            if availability == .available {
                if isRemoved {
                    await resumeIfRestored(at: currentURL)
                } else {
                    // A vnode unlink can belong to atomic replacement. A
                    // changed callback may have arrived while saving was
                    // paused, so reload/merge the replacement before resuming.
                    if snapshots.withLock({ $0.blocksSaving }) {
                        guard await revert(toContentsOf: currentURL), !Task.isCancelled,
                              !isFinishing, !documentState.contains(.closed) else { return }
                    }
                    snapshots.withLock { $0.blocksSaving = false }
                    let locationChanged = originalURL != currentURL
                    originalURL = currentURL
                    watchDirectory(currentURL.deletingLastPathComponent())
                    watchFile(currentURL)
                    if locationChanged { onAvailabilityChange?() }
                }
            } else if availability == .inTrash || (availability == .removed && (deletionEvidence || isRemoved || snapshots.withLock({ $0.blocksSaving }))) {
                // Two fresh observations avoid treating atomic replacement as
                // deletion. Inaccessible or evicted provider files stay open.
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, !isFinishing, !documentState.contains(.closed) else { return }
                let second = await Task.detached(priority: .utility) { MobileFileAvailability.inspect(currentURL) }.value
                guard second == availability, currentURL == fileURL,
                      !isFinishing, !documentState.contains(.closed) else { return }
                markRemoved()
                if originalURL != currentURL { await resumeIfRestored(at: originalURL) }
            } else if isRemoved {
                await resumeIfRestored(at: originalURL)
            }
        }
    }

    @MainActor
    private func markRemoved() {
        snapshots.withLock { $0.blocksSaving = true }
        guard !isRemoved else { return }
        isRemoved = true
        editingDisabled = true
        NotificationCoordinator.shared.forgetLedger(id: model.ledger.id)
        onAvailabilityChange?()
    }

    @MainActor
    private func resumeIfRestored(at url: URL) async {
        guard isRemoved, !documentState.contains(.closed), MobileFileAvailability.inspect(url) == .available else { return }
        let identity = model.ledger.id
        let restoredID = await Task.detached(priority: .utility) {
            let coordinator = NSFileCoordinator()
            var readID: UUID?
            var coordinationError: NSError?
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { safeURL in
                readID = try? LedgerCodec.decode(Data(contentsOf: safeURL)).id
            }
            return readID
        }.value
        guard !isFinishing, isRemoved, restoredID == identity, !documentState.contains(.closed) else { return }
        // A provider may restore at the former path without sending a move to
        // the now-deleted URL. UIDocument's public presenter hook updates it.
        if fileURL != url { super.presentedItemDidMove(to: url) }
        snapshots.withLock { $0.blocksSaving = false }
        let succeeded = await revert(toContentsOf: url)
        guard !isFinishing, !documentState.contains(.closed) else { return }
        if succeeded {
            isRemoved = false
            editingDisabled = false
            originalURL = url
            watchFile(url)
            watchDirectory(url.deletingLastPathComponent())
            NotificationCoordinator.shared.attach(model.ledger)
            onAvailabilityChange?()
        } else {
            snapshots.withLock { $0.blocksSaving = true }
        }
    }

    @MainActor
    func closeFile() async -> Bool {
        // Deleted-file close cannot trigger an implicit write to its old URL.
        if isRemoved { updateChangeCount(.cleared) }
        return await close()
    }

    @MainActor
    private func stopWatchingForClose() {
        isFinishing = true
        validationTask?.cancel()
        fileSource?.cancel()
        directorySource?.cancel()
        fileSource = nil
        directorySource = nil
    }

    @MainActor
    private func watchFile(_ url: URL) {
        guard sourceURL != url || fileSource == nil else { return }
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.delete, .rename, .write, .revoke], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            let deleted = source?.data.contains(.delete) == true || source?.data.contains(.revoke) == true
            Task { @MainActor [weak self] in
                if deleted {
                    self?.snapshots.withLock { $0.blocksSaving = true }
                    self?.sourceURL = nil
                }
                self?.validateSoon(deletionEvidence: deleted)
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        fileSource?.cancel()
        fileSource = source
        sourceURL = url
    }

    @MainActor private var directoryURL: URL?
    @MainActor
    private func watchDirectory(_ url: URL) {
        guard directoryURL != url || directorySource == nil else { return }
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.validateSoon(deletionEvidence: false) }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        directorySource?.cancel()
        directorySource = source
        directoryURL = url
    }

    deinit {
        validationTask?.cancel()
        fileSource?.cancel()
        directorySource?.cancel()
    }
}
#endif
