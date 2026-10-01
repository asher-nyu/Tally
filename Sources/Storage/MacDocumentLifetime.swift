#if os(macOS)
import AppKit
import Darwin
import OSLog
import SwiftUI
import UniformTypeIdentifiers

nonisolated private enum DocumentLifetimeLog {
    static let logger = Logger(subsystem: "com.asherbloom.Tally", category: "DocumentLifetime")
}

nonisolated enum MacDocumentLifetimePolicy {
    enum FileState: Equatable, Sendable {
        case present, inTrash, missing, unknown, evicted
    }

    enum Decision: Equatable, Sendable {
        case keepOpen, verifyAgain, showTrashRecovery, closeWindow
    }

    static func decision(
        fileState: FileState,
        deletionRequested: Bool,
        missingConfirmed: Bool,
        isCurrent: Bool = true
    ) -> Decision {
        guard isCurrent else { return .keepOpen }
        switch fileState {
        case .present, .unknown, .evicted:
            return .keepOpen
        case .inTrash:
            return .showTrashRecovery
        case .missing:
            guard deletionRequested else { return .keepOpen }
            guard missingConfirmed else { return .verifyAgain }
        }
        return .closeWindow
    }
}

/// Moves the existing file rather than saving a replacement. FileManager's
/// move refuses an occupied destination; NSDocument.move(to:) would replace it.
nonisolated enum MacDocumentRestore {
    static func move(
        from source: URL, to destination: URL,
        startAccessing: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccessing: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) throws {
        // A document created inside Tally's iCloud container can carry scoped
        // URLs without an active grant after Finder moves it into iCloud Trash.
        // Keep both grants active through coordination and the filesystem move.
        let sourceAccess = startAccessing(source)
        let destinationAccess = startAccessing(destination)
        defer {
            if sourceAccess { stopAccessing(source) }
            if destinationAccess { stopAccessing(destination) }
        }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(
            writingItemAt: source, options: .forMoving,
            writingItemAt: destination, options: [], error: &coordinationError
        ) { currentSource, currentDestination in
            do {
                coordinator.item(at: currentSource, willMoveTo: currentDestination)
                try FileManager.default.moveItem(at: currentSource, to: currentDestination)
                coordinator.item(at: currentSource, didMoveTo: currentDestination)
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }

    static func recoveryMessage(for error: Error) -> String {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: error.code) {
            case .fileWriteFileExists:
                return "A file with this name already exists in that location. Choose another name or location. The existing file will be kept."
            case .fileWriteNoPermission, .fileReadNoPermission:
                return "Tally couldn’t access the file or the destination folder. Choose another location, or restore the file in Finder."
            default:
                break
            }
        }
        return "Tally couldn’t restore this file. Choose another location, or restore it in Finder."
    }
}

nonisolated enum MacDocumentLifetimeInspection {
    static func isInsideTrash(_ url: URL, trashDirectory: URL) -> Bool {
        let item = url.standardizedFileURL.pathComponents
        let trash = trashDirectory.standardizedFileURL.pathComponents
        return item.count > trash.count && item.starts(with: trash)
    }

    /// Metadata-only inspection: reading document contents could download an
    /// evicted iCloud file. Provider or permission failures are inconclusive.
    static func inspect(
        _ url: URL,
        trashDirectory suppliedTrash: URL? = nil
    ) -> MacDocumentLifetimePolicy.FileState {
        do {
            var freshURL = url
            freshURL.removeAllCachedResourceValues()
            let values = try freshURL.resourceValues(forKeys: [
                .isRegularFileKey, .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey
            ])
            if values.isUbiquitousItem == true,
               values.ubiquitousItemDownloadingStatus == .notDownloaded {
                return .evicted
            }
            // A Trash URL is still a live document until its file is actually
            // removed. Classify location only after checking fresh metadata, so
            // emptying Trash cannot leave a missing path classified as live.
            if let trash = suppliedTrash ?? resolveTrashDirectory(for: url),
               isInsideTrash(url, trashDirectory: trash) {
                return .inTrash
            }
            return .present
        } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            // Older iCloud stores a not-yet-downloaded item under this sibling
            // name. Its absence from the ordinary path is not a deletion.
            let placeholder = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).icloud")
            if FileManager.default.fileExists(atPath: placeholder.path) { return .unknown }
            return .missing
        } catch {
            let error = error as NSError
            DocumentLifetimeLog.logger.notice("File metadata unavailable: domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public)")
            return .unknown
        }
    }

    private static func resolveTrashDirectory(for url: URL) -> URL? {
        // appropriateFor resolves iCloud Drive's own Trash as well as local and
        // external-volume Trash. The generic user-domain relationship alone
        // does not recognize iCloud's separate Trash directory.
        var existingParent = url.deletingLastPathComponent()
        for _ in 0..<64 {
            if FileManager.default.fileExists(atPath: existingParent.path) {
                return try? FileManager.default.url(
                    for: .trashDirectory, in: .userDomainMask,
                    appropriateFor: existingParent, create: false
                )
            }
            let parent = existingParent.deletingLastPathComponent()
            guard parent != existingParent else { break }
            existingParent = parent
        }
        return nil
    }
}

/// A passive observer. It never writes, saves, closes a document, or waits for
/// UI from a file-presenter callback. That work happens after acknowledgement.
nonisolated final class MacDocumentLifetimePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    enum Event: Equatable, Sendable {
        case changed, moved, deletion, evicted
    }

    private let lock = NSLock()
    private let lifecycleLock = NSLock()
    private var url: URL
    private var registered = false
    private let onEvent: @Sendable (Event, URL) -> Void
    let presentedItemOperationQueue: OperationQueue

    var presentedItemURL: URL? { lock.withLock { url } }

    init(url: URL, onEvent: @escaping @Sendable (Event, URL) -> Void) {
        self.url = url
        self.onEvent = onEvent
        let queue = OperationQueue()
        queue.name = "Tally document lifetime"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        presentedItemOperationQueue = queue
        super.init()
    }

    func start() {
        lifecycleLock.withLock {
            guard !registered else { return }
            registered = true
            NSFileCoordinator.addFilePresenter(self)
        }
    }

    func stop() {
        lifecycleLock.withLock {
            guard registered else { return }
            registered = false
            NSFileCoordinator.removeFilePresenter(self)
        }
    }

    func presentedItemDidMove(to newURL: URL) {
        lock.withLock { url = newURL }
        onEvent(.moved, newURL)
    }

    func presentedItemDidChange() {
        onEvent(.changed, lock.withLock { url })
    }

    func accommodatePresentedItemDeletion(
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        let currentURL = lock.withLock { url }
        completionHandler(nil)
        onEvent(.deletion, currentURL)
    }

    func accommodatePresentedItemEviction(
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        let currentURL = lock.withLock { url }
        stop()
        completionHandler(nil)
        onEvent(.evicted, currentURL)
    }
}

/// Watches the open inode without reading file contents or polling. Presenter
/// notifications cover coordinated moves; this also catches a direct unlink.
nonisolated final class MacDocumentLifetimeVnodeMonitor: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    private let descriptorState: DescriptorState

    init?(url: URL, onEvent: @escaping @Sendable (Bool) -> Void) {
        let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            DocumentLifetimeLog.logger.debug("File event monitor could not reopen moved item: errno=\(errno, privacy: .public)")
            return nil
        }
        let descriptorState = DescriptorState(descriptor)
        self.descriptorState = descriptorState
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.delete, .rename, .revoke, .write, .attrib],
            queue: DispatchQueue(label: "Tally document file events", qos: .utility)
        )
        source.setCancelHandler { descriptorState.close() }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            onEvent(self.source.data.contains(.delete))
        }
        source.resume()
    }

    var isUnlinked: Bool { descriptorState.isUnlinked }
    func stop() { source.cancel() }
    deinit { source.cancel() }

    private final class DescriptorState: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32

        init(_ descriptor: Int32) { self.descriptor = descriptor }

        var isUnlinked: Bool {
            lock.withLock {
                guard descriptor >= 0 else { return false }
                var attributes = stat()
                return fstat(descriptor, &attributes) == 0 && attributes.st_nlink == 0
            }
        }

        func close() {
            lock.withLock {
                guard descriptor >= 0 else { return }
                Darwin.close(descriptor)
                descriptor = -1
            }
        }
    }
}

/// Keeps native save and document ownership in AppKit. Only a confirmed
/// externally deleted source changes the usual document workflow.
struct MacDocumentLifetime: NSViewRepresentable {
    let document: TallyDocument

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    func makeNSView(context: Context) -> MacDocumentLocation.AttachmentView {
        let view = MacDocumentLocation.AttachmentView()
        view.onWindowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ view: MacDocumentLocation.AttachmentView, context: Context) {
        context.coordinator.attach(to: view.window)
    }

    static func dismantleNSView(_ view: MacDocumentLocation.AttachmentView, coordinator: Coordinator) {
        view.onWindowChanged = nil
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        let document: TallyDocument
        private weak var window: NSWindow?
        private weak var nativeDocument: NSDocument?
        private var nativeURLObservation: NSKeyValueObservation?
        private var activationObservation: NSObjectProtocol?
        private var attachmentTask: Task<Void, Never>?
        private var attachmentID = UUID()
        private var validationTask: Task<Void, Never>?
        private var reactivationTask: Task<Void, Never>?
        private var reactivationID = UUID()
        private var presenter: MacDocumentLifetimePresenter?
        private var vnode: MacDocumentLifetimeVnodeMonitor?
        private var materializationMonitor: MacDocumentLifetimeVnodeMonitor?
        private var vnodeID = UUID()
        private var trackedURL: URL?
        private var generation = UUID()
        private var deletionRequested = false
        private var evicted = false
        private let deletionAlert = MacDocumentDeletedAlert()
        private(set) var deletionPending = false
        private var lastLiveURL: URL?
        private var hadPendingChangesAtTrash = false
        private var restorationTask: Task<Void, Never>?
        private var restorePanel: NSSavePanel?
        private let inspectFile: @Sendable (URL) -> MacDocumentLifetimePolicy.FileState

        init(
            document: TallyDocument,
            inspectFile: @escaping @Sendable (URL) -> MacDocumentLifetimePolicy.FileState = {
                MacDocumentLifetimeInspection.inspect($0)
            }
        ) {
            self.document = document
            self.inspectFile = inspectFile
        }

        func attach(to window: NSWindow?) {
            guard let window else { return }
            if self.window === window, nativeDocument != nil {
                if evicted { scheduleReactivation() }
                return
            }
            if self.window !== window {
                stop()
                self.window = window
            }
            guard attachmentTask == nil else { return }
            let attachmentID = UUID()
            self.attachmentID = attachmentID
            attachmentTask = Task { [weak self, weak window] in
                guard let self, let window else { return }
                for _ in 0..<100 {
                    guard !Task.isCancelled, self.window === window else { return }
                    if let native = NSDocumentController.shared.document(for: window) {
                        self.connect(to: native)
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if self.attachmentID == attachmentID { self.attachmentTask = nil }
            }
        }

        func connect(to native: NSDocument) {
            nativeDocument = native
            activationObservation = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleReactivation()
                }
            }
            nativeURLObservation = native.observe(\.fileURL, options: [.initial, .new]) { [weak self] native, change in
                let url = change.newValue ?? nil
                Task { @MainActor [weak self] in
                    guard let self, self.nativeDocument === native else { return }
                    self.follow(url)
                    MacLaunchCoordinator.shared.documentLocationChanged(native)
                }
            }
        }

        func stop() {
            deletionAlert.stop()
            if let restorePanel {
                self.restorePanel = nil
                if let parent = restorePanel.sheetParent { parent.endSheet(restorePanel, returnCode: .abort) }
                restorePanel.orderOut(nil)
            }
            restorationTask?.cancel()
            restorationTask = nil
            deletionPending = false
            hadPendingChangesAtTrash = false
            lastLiveURL = nil
            trackedURL = nil
            generation = UUID()
            attachmentID = UUID()
            attachmentTask?.cancel()
            attachmentTask = nil
            validationTask?.cancel()
            validationTask = nil
            reactivationTask?.cancel()
            reactivationTask = nil
            materializationMonitor?.stop()
            materializationMonitor = nil
            if let activationObservation {
                NotificationCenter.default.removeObserver(activationObservation)
            }
            activationObservation = nil
            nativeURLObservation = nil
            presenter?.stop()
            presenter = nil
            vnode?.stop()
            vnode = nil
            vnodeID = UUID()
            nativeDocument = nil
            window = nil
        }

        private func follow(_ url: URL?, restart: Bool = false) {
            guard let url else { return }
            if trackedURL == nil { lastLiveURL = url }
            if !restart, trackedURL == url, presenter != nil {
                // The presenter can report a move before NSDocument updates its
                // URL. Revalidate when KVO catches up, even at the same path.
                if evicted { scheduleReactivation() }
                else { scheduleValidation() }
                return
            }
            generation = UUID()
            validationTask?.cancel()
            reactivationTask?.cancel()
            reactivationTask = nil
            materializationMonitor?.stop()
            materializationMonitor = nil
            presenter?.stop()
            trackedURL = url
            deletionRequested = false
            evicted = false
            let token = generation
            let observer = MacDocumentLifetimePresenter(url: url) { [weak self] event, eventURL in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.receive(event, at: eventURL)
                }
            }
            presenter = observer
            observer.start()
            armVnode(url)
            scheduleValidation()
        }

        private func armVnode(_ url: URL) {
            let token = UUID()
            let replacement = MacDocumentLifetimeVnodeMonitor(url: url) { [weak self] deleted in
                Task { @MainActor [weak self] in
                    // A retained inode remains valid after rename even if a new
                    // path is inaccessible. Its lifetime is independent of URL
                    // revalidation generations.
                    guard let self, self.vnodeID == token else { return }
                    DocumentLifetimeLog.logger.debug("File event delivered: deleted=\(deleted, privacy: .public)")
                    self.deletionRequested = self.deletionRequested || deleted
                    self.scheduleValidation()
                }
            }
            guard let replacement else {
                DocumentLifetimeLog.logger.debug("Retaining original file event monitor after move; retained=\(self.vnode != nil, privacy: .public)")
                return
            }
            vnodeID = token
            let previous = vnode
            vnode = replacement
            previous?.stop()
        }

        private func receive(_ event: MacDocumentLifetimePresenter.Event, at url: URL) {
            switch event {
            case .moved:
                // The presenter and NSDocument receive separate move callbacks;
                // defer the decision until the native URL has caught up.
                trackedURL = url
                deletionRequested = false
                armVnode(url)
            case .deletion:
                guard trackedURL == url else { return }
                deletionRequested = true
            case .evicted:
                guard trackedURL == url else { return }
                evicted = true
                deletionRequested = false
                validationTask?.cancel()
                vnode?.stop()
                vnode = nil
                vnodeID = UUID()
                // Watching only the parent does not hold an evicted file open
                // or request a download. Its events let observation resume when
                // a provider materializes the same URL again.
                let token = generation
                materializationMonitor?.stop()
                materializationMonitor = MacDocumentLifetimeVnodeMonitor(
                    url: url.deletingLastPathComponent()
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token else { return }
                        self.scheduleReactivation()
                    }
                }
                return
            case .changed:
                break
            }
            scheduleValidation()
        }

        private func scheduleReactivation() {
            guard evicted,
                  let url = trackedURL, let native = nativeDocument else { return }
            reactivationTask?.cancel()
            let requestID = UUID()
            reactivationID = requestID
            let token = generation
            let inspectFile = inspectFile
            reactivationTask = Task { [weak self, weak native] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                defer {
                    if self.reactivationID == requestID { self.reactivationTask = nil }
                }
                guard let native, !Task.isCancelled else { return }
                let state = await Task.detached(priority: .utility) {
                    inspectFile(url)
                }.value
                guard !Task.isCancelled, self.generation == token,
                      self.evicted, self.trackedURL == url,
                      self.nativeDocument === native, native.fileURL == url else { return }
                guard state == .present || state == .inTrash else { return }
                self.follow(url, restart: true)
            }
        }

        private func scheduleValidation() {
            guard !evicted,
                  let url = trackedURL, let native = nativeDocument else { return }
            validationTask?.cancel()
            let token = generation
            let inspectFile = inspectFile
            validationTask = Task { [weak self, weak native] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let native, !Task.isCancelled else { return }
                var missingConfirmed = false
                for _ in 0..<2 {
                    let state = await Task.detached(priority: .utility) {
                        inspectFile(url)
                    }.value
                    guard !Task.isCancelled, !self.evicted, self.generation == token,
                          self.trackedURL == url, self.nativeDocument === native,
                          native.fileURL == url else { return }
                    DocumentLifetimeLog.logger.debug("Deletion validation: state=\(String(describing: state), privacy: .public) requested=\(self.deletionRequested, privacy: .public) unlinked=\(self.vnode?.isUnlinked ?? false, privacy: .public)")
                    switch MacDocumentLifetimePolicy.decision(
                        fileState: state,
                        // A move callback can arrive after the final unlink
                        // event. The retained descriptor preserves that evidence
                        // even if the URL transition reset the earlier hint.
                        deletionRequested: self.deletionRequested || (self.vnode?.isUnlinked ?? false),
                        missingConfirmed: missingConfirmed
                    ) {
                    case .keepOpen:
                        if state == .present {
                            self.lastLiveURL = url
                            self.resumeAfterRestoration(native)
                            self.deletionRequested = false
                            // Atomic saves replace the inode; observe its replacement.
                            self.armVnode(url)
                        }
                        return
                    case .verifyAgain:
                        missingConfirmed = true
                        try? await Task.sleep(for: .milliseconds(350))
                    case .showTrashRecovery:
                        self.presentDeletion(for: native)
                        return
                    case .closeWindow:
                        self.closeDocument(native)
                        return
                    }
                }
            }
        }

        private func presentDeletion(for native: NSDocument) {
            guard !deletionPending else { return }
            deletionPending = true
            if lastLiveURL == trackedURL { lastLiveURL = nil }
            // The sheet suspends editing. Preserve change bookkeeping so an
            // external restore can resume the same session without losing edits.
            hadPendingChangesAtTrash = native.isDocumentEdited
            native.updateChangeCount(.changeCleared)
            NotificationCoordinator.shared.forgetLedger(id: document.ledger.id)
            showRecoveryAlert()
        }

        private func showRecoveryAlert(recoveryError: String? = nil) {
            guard deletionPending else { return }
            if let window {
                deletionAlert.present(in: window, restore: { [weak self] in
                    guard let self else { return }
                    if recoveryError == nil { self.restoreFile() }
                    else { self.chooseRestoreLocation() }
                }, close: { [weak self] in
                    self?.closeDeletedWindow()
                }, recoveryError: recoveryError)
            }
        }

        private func resumeAfterRestoration(_ native: NSDocument) {
            guard deletionPending else { return }
            deletionAlert.stop()
            if let panel = restorePanel {
                restorePanel = nil
                if let parent = panel.sheetParent { parent.endSheet(panel, returnCode: .abort) }
                panel.orderOut(nil)
            }
            deletionPending = false
            if hadPendingChangesAtTrash { native.updateChangeCount(.changeDone) }
            hadPendingChangesAtTrash = false
            NotificationCoordinator.shared.attach(document.ledger)
        }

        func closeDeletedWindow() {
            guard deletionPending, let native = nativeDocument else { return }
            closeDocument(native)
        }

        private func closeDocument(_ native: NSDocument) {
            NotificationCoordinator.shared.forgetLedger(id: document.ledger.id)
            native.updateChangeCount(.changeCleared)
            stop()
            // Direct close ends all of this file's windows and sheets without
            // saving into a location the user has deliberately removed.
            native.close()
        }

        private func restoreFile(to selectedDestination: URL? = nil) {
            guard deletionPending, restorationTask == nil,
                  let native = nativeDocument, let source = trackedURL else { return }
            guard let destination = selectedDestination ?? lastLiveURL else {
                chooseRestoreLocation()
                return
            }
            restorationTask = Task { [weak self, weak native] in
                guard let self, let native else { return }
                defer { self.restorationTask = nil }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try MacDocumentRestore.move(from: source, to: destination)
                    }.value
                    guard !Task.isCancelled, self.nativeDocument === native else { return }
                    // Native presenters normally update first; this also keeps
                    // a delayed native move callback on the restored URL.
                    if native.fileURL == source { native.fileURL = destination }
                    self.follow(destination)
                } catch {
                    guard !Task.isCancelled, self.nativeDocument === native,
                          self.deletionPending else { return }
                    let failure = error as NSError
                    let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
                    DocumentLifetimeLog.logger.error("Restore failed: domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public) underlyingDomain=\(underlying?.domain ?? "none", privacy: .public) underlyingCode=\(underlying?.code ?? 0, privacy: .public)")
                    self.showRecoveryAlert(recoveryError: MacDocumentRestore.recoveryMessage(for: error))
                    self.scheduleValidation()
                }
            }
        }

        private func chooseRestoreLocation() {
            guard deletionPending, restorePanel == nil, let window, let source = trackedURL else { return }
            let panel = NSSavePanel()
            panel.title = "Restore File"
            panel.prompt = "Restore"
            panel.nameFieldStringValue = lastLiveURL?.lastPathComponent ?? source.lastPathComponent
            panel.directoryURL = lastLiveURL?.deletingLastPathComponent()
            panel.allowedContentTypes = [.tallyDocument]
            panel.canCreateDirectories = true
            panel.message = "Choose a name and location for this file. Existing files will be kept."
            restorePanel = panel
            panel.beginSheetModal(for: window) { [weak self, weak panel] response in
                guard let self, let panel, self.restorePanel === panel else { return }
                self.restorePanel = nil
                guard self.deletionPending else { return }
                if response == .OK, let destination = panel.url {
                    self.restoreFile(to: destination)
                } else {
                    self.showRecoveryAlert()
                }
            }
        }

    }
}
#endif
