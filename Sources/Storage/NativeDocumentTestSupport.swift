#if DEBUG && os(macOS)
import AppKit
import CryptoKit
import Foundation

/// A test-only bootstrap. The fixtures still open through the production
/// DocumentGroup, including its NSDocument and file-presenter lifecycle.
@MainActor
final class NativeDocumentTestSupport: NSObject {
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing")
            && arguments.contains("--ui-testing-native-documents")
    }

    /// Keeps any new native document created during an explicit fixture launch
    /// inside the disposable directory instead of the user's iCloud Drive.
    static var fixtureDirectoryURL: URL? {
        isEnabled ? shared.fixtureDirectory : nil
    }

    private static let shared = NativeDocumentTestSupport()
    private var launchObserver: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?
    private var panel: NSWindow?
    private var fields: [String: NSTextField] = [:]
    private var documents: [String: WeakDocument] = [:]
    private var hasStarted = false
    private var fixtureDirectory: URL?
    private var fixtureSession: UUID?
    private var trashedFixture: NativeFixtureTrash?
    private var mutationInFlight = false

    static func install() {
        guard isEnabled else { return }
        shared.launchObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await shared.start() }
        }
    }

    private func start() async {
        guard Self.isEnabled, !hasStarted else { return }
        hasStarted = true
        makeInspector()
        do {
            guard let token = ProcessInfo.processInfo.environment["TALLY_NATIVE_TEST_SESSION"],
                  let session = UUID(uuidString: token) else {
                throw FixtureError.missingSession
            }
            let manager = FileManager.default
            let cache = try manager.url(for: .cachesDirectory, in: .userDomainMask,
                                        appropriateFor: nil, create: true)
            let root = cache.appendingPathComponent("TallyNativeDocumentTests-\(session.uuidString)", isDirectory: true)
            // A fresh UUID directory is mandatory; never reuse another run's data.
            try manager.createDirectory(at: root, withIntermediateDirectories: false)
            try Data(session.uuidString.utf8).write(to: root.appendingPathComponent(".test-owner"), options: .withoutOverwriting)
            fixtureDirectory = root
            fixtureSession = session
            set("nativeTestRootPath", root.path)

            // Make the dirty-document test deterministic without bypassing real
            // model edits or saving. This changes only this test app process.
            NSDocumentController.shared.autosavingDelay = 300
            for name in ["A", "B"] {
                let ledger = Ledger(expenses: [
                    Expense(merchant: "Native fixture \(name)", amountMinor: 12_345,
                            billingDay: 15, category: .other)
                ])
                let url = root.appendingPathComponent("Native-\(name)-\(session.uuidString.prefix(8)).tally")
                try LedgerCodec.encode(ledger).write(to: url, options: .withoutOverwriting)
                let document = try await openDocument(at: url)
                documents[name] = WeakDocument(document)
                document.windowControllers.first?.window?.setAccessibilityIdentifier("nativeDocumentWindow\(name)")
            }
            refresh()
            set("nativeTestStatus", "ready")
            refreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.refresh()
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            documents["A"]?.value?.showWindows()
        } catch {
            set("nativeTestStatus", "error: \(error.localizedDescription)")
        }
    }

    private func openDocument(at url: URL) async throws -> NSDocument {
        try await withCheckedThrowingContinuation { continuation in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let document {
                    continuation.resume(returning: document)
                } else {
                    continuation.resume(throwing: FixtureError.openFailed)
                }
            }
        }
    }

    private func refresh() {
        let openDocuments = NSDocumentController.shared.documents
        set("nativeTestOpenPaths", openDocuments.compactMap { $0.fileURL?.path }.sorted().joined(separator: "\n"))
        set("nativeTestOpenCount", String(openDocuments.count))
        for name in ["A", "B"] {
            let document = documents[name]?.value
            let isOpen = document.map { candidate in openDocuments.contains { $0 === candidate } } ?? false
            set("nativeTest\(name)Open", isOpen ? "true" : "false")
            set("nativeTest\(name)URL", document?.fileURL?.path ?? "")
            set("nativeTest\(name)Edited", document?.isDocumentEdited == true ? "true" : "false")
        }
    }

    private func makeInspector() {
        let panel = NSWindow(contentRect: NSRect(x: 20, y: 40, width: 590, height: 385),
                             styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Native document test status"
        panel.setAccessibilityIdentifier("nativeTestInspector")
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isRestorable = false
        panel.isExcludedFromWindowsMenu = true
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 590, height: 385))
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for identifier in ["nativeTestStatus", "nativeTestRootPath", "nativeTestOpenPaths", "nativeTestOpenCount", "nativeTestMutationStatus", "nativeTestTrashURL", "nativeTestTrashState",
                           "nativeTestAOpen", "nativeTestAURL", "nativeTestAEdited",
                           "nativeTestBOpen", "nativeTestBURL", "nativeTestBEdited"] {
            let field = NSTextField(labelWithString: identifier == "nativeTestStatus" ? "starting" : "")
            field.setAccessibilityIdentifier(identifier)
            field.font = .systemFont(ofSize: 11)
            field.lineBreakMode = .byTruncatingMiddle
            field.maximumNumberOfLines = 1
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            fields[identifier] = field
            stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        for (action, title) in [("rename", "Rename A"), ("move", "Move A"),
                                ("replace", "Replace A"), ("trash", "Trash A"), ("delete", "Delete A"),
                                ("cleanup", "Clean up")] {
            let button = NSButton(title: title, target: self, action: #selector(runFixtureAction(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(action)
            button.setAccessibilityIdentifier("nativeTestAction-\(action)")
            actions.addArrangedSubview(button)
        }
        stack.addArrangedSubview(actions)
        let trashActions = NSStackView()
        trashActions.orientation = .horizontal
        trashActions.spacing = 8
        for (action, title) in [("verifyTrash", "Verify Trash"), ("restore", "Restore A")] {
            let button = NSButton(title: title, target: self, action: #selector(runFixtureAction(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(action)
            button.setAccessibilityIdentifier("nativeTestAction-\(action)")
            trashActions.addArrangedSubview(button)
        }
        stack.addArrangedSubview(trashActions)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
        ])
        panel.contentView = container
        if let visible = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - panel.frame.width - 16,
                                               y: visible.maxY - 16))
        }
        panel.orderFront(nil)
        self.panel = panel
    }

    @objc private func runFixtureAction(_ sender: NSButton) {
        guard Self.isEnabled, let action = sender.identifier?.rawValue,
              let root = fixtureDirectory, let session = fixtureSession else { return }
        guard !mutationInFlight else { return }
        mutationInFlight = true
        let source = documents["A"]?.value?.fileURL
        let trashedFixture = self.trashedFixture
        set("nativeTestMutationStatus", "running:\(action)")
        Task {
            defer { mutationInFlight = false }
            if action == "trash" {
                do {
                    try NativeFixtureFileMutation.validate(source: source, root: root, session: session, trashedFixture: nil)
                    guard let source else { throw CocoaError(.fileNoSuchFile) }
                    let token = try Data(contentsOf: source)
                    // AppKit performs the same Trash operation as Finder and
                    // returns this item's exact destination; never empty Trash.
                    let destination: URL = try await withCheckedThrowingContinuation { continuation in
                        NSWorkspace.shared.recycle([source]) { destinations, error in
                            if let error { continuation.resume(throwing: error) }
                            else if let destination = destinations[source] { continuation.resume(returning: destination) }
                            else { continuation.resume(throwing: CocoaError(.fileNoSuchFile)) }
                        }
                    }
                    self.trashedFixture = NativeFixtureTrash(url: destination, token: token)
                    set("nativeTestTrashURL", destination.path)
                    set("nativeTestMutationStatus", "complete:trash")
                } catch {
                    set("nativeTestMutationStatus", "error:trash:\(NativeFixtureFileMutation.describe(error as NSError))")
                }
                return
            }
            // The Xcode UI runner has read-only access outside its sandbox.
            // Execute real file mutations here; never invoke the lifetime bridge.
            let failure = await Task.detached(priority: .userInitiated) {
                do {
                    try NativeFixtureFileMutation.perform(action, source: source, root: root, session: session, trashedFixture: trashedFixture)
                    return Optional<String>.none
                } catch {
                    return NativeFixtureFileMutation.describe(error as NSError)
                }
            }.value
            set("nativeTestMutationStatus", failure.map { "error:\(action):\($0)" } ?? "complete:\(action)")
            if failure == nil, action == "verifyTrash" { set("nativeTestTrashState", "present") }
            if failure == nil, action == "delete", trashedFixture != nil { set("nativeTestTrashState", "missing") }
            if failure == nil, action == "restore" {
                self.trashedFixture = nil
                set("nativeTestTrashURL", "")
                set("nativeTestTrashState", "restored")
            }
            if let failure { print("Native fixture mutation \(action) failed: \(failure)") }
        }
    }

    private func set(_ identifier: String, _ value: String) {
        fields[identifier]?.stringValue = value
    }

    private final class WeakDocument {
        weak var value: NSDocument?
        init(_ value: NSDocument) { self.value = value }
    }

    private enum FixtureError: LocalizedError {
        case missingSession, openFailed
        var errorDescription: String? {
            switch self {
            case .missingSession: "Native document tests require an explicit UUID session."
            case .openFailed: "The native document controller did not open the fixture."
            }
        }
    }
}

/// File-operation seam only. Decisions about closing windows remain entirely
/// in the production document lifecycle and are observed by the UI test.
nonisolated private enum NativeFixtureFileMutation {
    static func perform(_ action: String, source: URL?, root: URL, session: UUID, trashedFixture: NativeFixtureTrash?) throws {
        if action == "cleanup" {
            // XCTest can repeat a UI action if the last document disappears
            // during the click. The UUID directory is owned by this launch;
            // absence is already the required cleanup result.
            if !FileManager.default.fileExists(atPath: root.path) { return }
            try validateRoot(root, session: session)
            if let trashedFixture {
                try externalTrashOperation("deleteTrash", fixture: trashedFixture, root: root, session: session)
            }
            try FileManager.default.removeItem(at: root)
            return
        }
        try validateRoot(root, session: session)
        if action == "restore", let trashedFixture {
            try externalTrashOperation("restoreTrash", fixture: trashedFixture, root: root, session: session)
            return
        }
        if action == "verifyTrash", let trashedFixture {
            try externalTrashOperation("verifyTrash", fixture: trashedFixture, root: root, session: session)
            return
        }
        if action == "delete", let trashedFixture,
           source?.standardizedFileURL == trashedFixture.url.standardizedFileURL {
            try externalTrashOperation("deleteTrash", fixture: trashedFixture, root: root, session: session)
            return
        }
        try validate(source: source, root: root, session: session, trashedFixture: trashedFixture)
        guard let source else { throw CocoaError(.fileNoSuchFile) }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var accessorError: Error?
        switch action {
        case "rename", "move":
            let directory = action == "move" ? root.appendingPathComponent("Moved", isDirectory: true) : root
            if action == "move" { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
            let destination = directory.appendingPathComponent("Renamed-A.tally")
            coordinator.coordinate(writingItemAt: source, options: .forMoving,
                                   writingItemAt: destination, options: [], error: &coordinationError) { from, to in
                do {
                    coordinator.item(at: from, willMoveTo: to)
                    try FileManager.default.moveItem(at: from, to: to)
                    coordinator.item(at: from, didMoveTo: to)
                } catch { accessorError = error }
            }
        case "replace":
            let data = try Data(contentsOf: source)
            // Exercise an actual inode replacement. A .forReplacing claim
            // also asks NSDocument to accommodate deletion and synchronously
            // revert, which is a different native serialization path.
            try data.write(to: source, options: .atomic)
        case "delete":
            coordinator.coordinate(writingItemAt: source, options: .forDeleting, error: &coordinationError) { url in
                do { try FileManager.default.removeItem(at: url) }
                catch { accessorError = error }
            }
        default:
            throw CocoaError(.featureUnsupported)
        }
        if let coordinationError {
            throw NSError(domain: "NativeFixtureCoordination", code: 1,
                          userInfo: [NSUnderlyingErrorKey: coordinationError])
        }
        if let accessorError {
            throw NSError(domain: "NativeFixtureFileOperation", code: 1,
                          userInfo: [NSUnderlyingErrorKey: accessorError])
        }
    }

    private static func validateRoot(_ root: URL, session: UUID) throws {
        guard root.lastPathComponent == "TallyNativeDocumentTests-\(session.uuidString)",
              try String(contentsOf: root.appendingPathComponent(".test-owner"), encoding: .utf8) == session.uuidString else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    static func validate(source: URL?, root: URL, session: UUID, trashedFixture: NativeFixtureTrash?) throws {
        try validateRoot(root, session: session)
        guard let source, source.pathExtension == "tally" else {
            throw CocoaError(.fileWriteNoPermission)
        }
        if isOwned(source, root: root) { return }
        guard let trashedFixture,
              source.standardizedFileURL == trashedFixture.url.standardizedFileURL,
              try Data(contentsOf: source) == trashedFixture.token else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private static func isOwned(_ url: URL, root: URL) -> Bool {
        let parent = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let path = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return path.count > parent.count && path.starts(with: parent)
    }

    private static func externalTrashOperation(_ operation: String, fixture: NativeFixtureTrash, root: URL, session: UUID) throws {
        // Neither sandboxed test process may read or unlink ~/.Trash. The
        // separate host driver validates this ownership proof before acting.
        let requestID = UUID().uuidString
        let digest = SHA256.hash(data: fixture.token).map { String(format: "%02x", $0) }.joined()
        guard let ledger = try JSONSerialization.jsonObject(with: fixture.token) as? [String: Any],
              let ledgerID = ledger["id"] as? String else { throw CocoaError(.fileReadCorruptFile) }
        let request: [String: String] = [
            "requestID": requestID, "session": session.uuidString, "operation": operation,
            "path": fixture.url.path, "sha256": digest, "ledgerID": ledgerID
        ]
        let requestURL = root.appendingPathComponent(".native-request-\(requestID).json")
        let responseURL = root.appendingPathComponent(".native-response-\(requestID).json")
        try JSONSerialization.data(withJSONObject: request).write(to: requestURL, options: .atomic)
        let expectedState = switch operation {
        case "verifyTrash": "present"
        case "restoreTrash": "restored"
        default: "missing"
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let data = try? Data(contentsOf: responseURL),
               let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                guard response["requestID"] as? String == requestID,
                      response["session"] as? String == session.uuidString,
                      response["ok"] as? Bool == true,
                      response["state"] as? String == expectedState else {
                    throw NSError(domain: "NativeFixtureExternalDriver", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: response["error"] as? String ?? "Invalid fixture-driver response."])
                }
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw NSError(domain: "NativeFixtureExternalDriver", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Start Scripts/native_document_fixture_driver.py before running native document UI tests."])
    }

    static func describe(_ error: NSError) -> String {
        var text = "\(error.domain) code=\(error.code) \(error.localizedDescription); userInfo=\(error.userInfo)"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += "\nUnderlying: \(describe(underlying))"
        }
        return text
    }
}

nonisolated private struct NativeFixtureTrash: Sendable {
    let url: URL
    let token: Data
}
#endif
