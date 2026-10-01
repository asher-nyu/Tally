#if os(macOS)
import AppKit
import SwiftUI

/// Reserves the destination before NSDocument's first save, which may replace
/// an existing file. Exclusive creation protects simultaneous new windows and
/// existing filenames. The native save coordinates its own operation; it cannot
/// atomically share this reservation check with unrelated external writers.
nonisolated struct MacDocumentLocationReservation: Sendable {
    let url: URL
    private let token: Data

    static func reserve(
        in directory: URL,
        baseName: String = "Cash Flow"
    ) throws -> Self {
        // A unique ledger ID makes the bytes an ownership token. Keeping them a
        // valid empty document also makes interruption before native save safe
        // for other devices that may already have received the cloud file.
        let token = try LedgerCodec.encode(Ledger())
        for suffix in 1...10_000 {
            let name = suffix == 1 ? baseName : "\(baseName) \(suffix)"
            let candidate = directory.appendingPathComponent(name).appendingPathExtension("tally")
            do {
                // Exclusive creation is the atomic reservation. Coordinating a
                // replacement before this check would ask an existing open
                // document to accommodate deletion merely to probe its name.
                try token.write(to: candidate, options: .withoutOverwriting)
                return Self(url: candidate, token: token)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw LocationError.noAvailableName
    }

    func isUnused() throws -> Bool {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<Bool, Error>?
        coordinator.coordinate(readingItemAt: url, error: &coordinationError) { coordinatedURL in
            result = Result { try tokenMatches(at: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        return try result?.get() ?? false
    }

    /// Never deletes content written by NSDocument, even if its save reported an
    /// error after writing. Only this reservation's exact token can be removed.
    func removeIfUnused() throws {
        // Avoid a no-op write coordination against a now-open saved document.
        // Ownership is checked again inside the coordinated operation below.
        do {
            guard try tokenMatches(at: url) else { return }
        } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return
        }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var removalError: Error?
        coordinator.coordinate(
            writingItemAt: url, options: [], error: &coordinationError
        ) { coordinatedURL in
            do {
                if try tokenMatches(at: coordinatedURL) {
                    try FileManager.default.removeItem(at: coordinatedURL)
                }
            } catch let error as CocoaError
                where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                // A completed save/move may already have removed the placeholder.
            } catch {
                removalError = error
            }
        }
        if let coordinationError {
            if coordinationError.domain == NSCocoaErrorDomain,
               [CocoaError.fileReadNoSuchFile.rawValue, CocoaError.fileNoSuchFile.rawValue]
                .contains(coordinationError.code) { return }
            throw coordinationError
        }
        if let removalError { throw removalError }
    }

    private func tokenMatches(at candidate: URL) throws -> Bool {
        let values = try candidate.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.fileSize == token.count else { return false }
        return try Data(contentsOf: candidate) == token
    }

    enum LocationError: LocalizedError {
        case noAvailableName
        case reservationChanged

        var errorDescription: String? {
            switch self {
            case .noAvailableName:
                "A new filename could not be created in iCloud Drive. Choose another name or location."
            case .reservationChanged:
                "The destination changed before your document could be saved. Try again to use a new filename."
            }
        }
    }
}

/// This is attached only to the real DocumentGroup, never the UI-test WindowGroup.
/// It does not become a document owner or write the document's contents itself.
struct MacDocumentLocation: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.onWindowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ view: AttachmentView, context: Context) {
        context.coordinator.attach(to: view.window)
    }

    static func dismantleNSView(_ view: AttachmentView, coordinator: Coordinator) {
        view.onWindowChanged = nil
        coordinator.detach()
    }

    final class AttachmentView: NSView {
        var onWindowChanged: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(window)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var task: Task<Void, Never>?
        private var taskID = UUID()
        private var finished = false

        func attach(to window: NSWindow?) {
            guard let window, !finished else { return }
            if self.window !== window {
                task?.cancel()
                task = nil
                self.window = window
            }
            guard task == nil else { return }
            let taskID = UUID()
            self.taskID = taskID
            task = Task { [weak self, weak window] in
                guard let self, let window else { return }
                await self.establishLocation(in: window)
                if self.taskID == taskID { self.task = nil }
            }
        }

        func detach() {
            task?.cancel()
            task = nil
            taskID = UUID()
            window = nil
        }

        private func establishLocation(in window: NSWindow) async {
            // SwiftUI can attach the view before registering the window with its
            // NSDocument. Yield until that registration is complete.
            var nativeDocument: NSDocument?
            for _ in 0..<100 {
                if Task.isCancelled { return }
                nativeDocument = NSDocumentController.shared.document(for: window)
                if nativeDocument != nil { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let nativeDocument else { return }
            guard nativeDocument.fileURL == nil else {
                finished = true
                return
            }

            var refreshCloud = false
            while !Task.isCancelled {
                do {
                    let directory = try await cloudDirectory(refresh: refreshCloud)
                    guard stillUntitled(nativeDocument, in: window) else { return }

                    let reservation = try await Task.detached(priority: .utility) {
                        try MacDocumentLocationReservation.reserve(in: directory)
                    }.value
                    do {
                        let unused = try await Task.detached(priority: .utility) {
                            try reservation.isUnused()
                        }.value
                        guard unused else {
                            throw MacDocumentLocationReservation.LocationError.reservationChanged
                        }
                        guard stillUntitled(nativeDocument, in: window) else {
                            await discard(reservation)
                            return
                        }
                        // AppKit saves an untitled document using its own type,
                        // writer, file coordination, and autosave bookkeeping.
                        try await nativeDocument.move(to: reservation.url)
                        finished = true
                        return
                    } catch {
                        await discard(reservation)
                        throw error
                    }
                } catch {
                    guard stillUntitled(nativeDocument, in: window) else { return }
                    switch await present(error, in: window) {
                    case .alertFirstButtonReturn:
                        refreshCloud = true
                    case .alertSecondButtonReturn:
                        finished = true
                        nativeDocument.save(nil)
                        return
                    default:
                        finished = true
                        return
                    }
                }
            }
        }

        private func stillUntitled(_ document: NSDocument, in window: NSWindow) -> Bool {
            guard !Task.isCancelled, self.window === window,
                  NSDocumentController.shared.document(for: window) === document else { return false }
            guard document.fileURL == nil else {
                finished = true
                return false
            }
            return true
        }

        private func cloudDirectory(refresh: Bool) async throws -> URL {
            #if DEBUG
            if MacLaunchTestSupport.isEnabled, let directory = MacLaunchTestSupport.fixtureDirectoryURL { return directory }
            #endif
            let cloud = CloudDocuments.shared
            // Also handles launch before start()'s preparation Task has begun.
            if !cloud.isPreparing, refresh || cloud.documentsURL == nil {
                await cloud.prepare()
            }
            while cloud.isPreparing {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
            switch cloud.state {
            case .available(let directory): return directory
            case .unavailable:
                throw CloudLocationError.unavailable
            case .failed(let reason):
                throw CloudLocationError.failed(reason)
            }
        }

        private func discard(_ reservation: MacDocumentLocationReservation) async {
            // A failed cleanup can leave only a recognizable placeholder; it must
            // never replace the original save error or delete a completed save.
            _ = try? await Task.detached(priority: .utility) {
                try reservation.removeIfUnused()
            }.value
        }

        private func present(_ error: Error, in window: NSWindow) async -> NSApplication.ModalResponse {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t save to iCloud Drive"
            alert.informativeText = "\(error.localizedDescription) Your document is still open. Try again, or choose a location with Save Elsewhere."
            alert.addButton(withTitle: "Retry")
            alert.addButton(withTitle: "Save Elsewhere…")
            alert.addButton(withTitle: "Not Now")
            return await alert.beginSheetModal(for: window)
        }
    }

    private enum CloudLocationError: LocalizedError {
        case unavailable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "Turn on iCloud Drive in System Settings and check your connection."
            case .failed(let reason):
                "iCloud Drive could not prepare the Tally folder. \(reason)"
            }
        }
    }
}
#endif
