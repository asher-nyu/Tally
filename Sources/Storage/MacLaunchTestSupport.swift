#if DEBUG && os(macOS)
import AppKit
import Foundation

/// A relaunchable, app-owned fixture for the real DocumentGroup and Settings scene.
/// Neither fixtures nor launch preferences share the user's document/default stores.
@MainActor
final class MacLaunchTestSupport: NSObject {
    static var isEnabled: Bool {
        let process = ProcessInfo.processInfo
        return process.arguments.contains("--ui-testing")
            && process.arguments.contains("--ui-testing-launch-settings")
            && process.environment["TALLY_LAUNCH_TEST_SESSION"].flatMap(UUID.init(uuidString:)) != nil
    }

    static var fixtureDirectoryURL: URL? { isEnabled ? shared.root : nil }
    static var fixtureAURL: URL? { fixtureDirectoryURL?.appendingPathComponent("Launch-A.tally") }
    static var fixtureBURL: URL? { fixtureDirectoryURL?.appendingPathComponent("Launch-B.tally") }
    static var legacyRecentFileURL: URL? {
        isEnabled && ProcessInfo.processInfo.environment["TALLY_LAUNCH_TEST_ACTION"] == "legacyRecentA" ? fixtureAURL : nil
    }

    private static let shared = MacLaunchTestSupport()
    private var root: URL?
    private var launchObserver: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?
    private var panel: NSPanel?
    private var fields: [String: NSTextField] = [:]
    private var status = "ready"

    static func prepare() throws {
        guard isEnabled,
              let session = ProcessInfo.processInfo.environment["TALLY_LAUNCH_TEST_SESSION"].flatMap(UUID.init(uuidString:)) else { return }
        let manager = FileManager.default
        let cache = try manager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = cache.appendingPathComponent("TallyLaunchSettingsTests-\(session.uuidString)", isDirectory: true)
        let action = ProcessInfo.processInfo.environment["TALLY_LAUNCH_TEST_ACTION"] ?? ""
        let suiteName = "TallyLaunchSettingsTests.\(session.uuidString)"

        if action == "cleanup" {
            if manager.fileExists(atPath: root.path) {
                try validate(root, session: session)
                // A regression may create an unexpected file. Preserve that evidence.
                let allowed = Set([".test-owner", "Launch-A.tally", "Launch-B.tally", "Renamed-A.tally"])
                let contents = try manager.contentsOfDirectory(atPath: root.path)
                guard Set(contents).isSubset(of: allowed) else { throw FixtureError.unexpectedFiles }
                try manager.removeItem(at: root)
            }
            MacLaunchEnvironment.defaults.removePersistentDomain(forName: suiteName)
            shared.status = "cleaned"
        } else {
            if manager.fileExists(atPath: root.path) {
                try validate(root, session: session)
            } else {
                try manager.createDirectory(at: root, withIntermediateDirectories: false)
                try Data(session.uuidString.utf8).write(to: root.appendingPathComponent(".test-owner"), options: .withoutOverwriting)
                for name in ["A", "B"] {
                    let ledger = Ledger(expenses: [Expense(merchant: "Launch fixture \(name)", amountMinor: 12_345,
                                                          billingDay: 15, category: .other)])
                    try LedgerCodec.encode(ledger).write(to: root.appendingPathComponent("Launch-\(name).tally"),
                                                         options: .withoutOverwriting)
                }
            }
            shared.root = root
            let a = root.appendingPathComponent("Launch-A.tally")
            switch action {
            case "", "legacyRecentA": break
            case "seedA":
                try MacLastUsedFileStore(defaults: MacLaunchEnvironment.defaults).remember(a)
            case "deleteA":
                try manager.removeItem(at: a)
            case "renameA":
                try manager.moveItem(at: a, to: root.appendingPathComponent("Renamed-A.tally"))
            default: throw FixtureError.unknownAction
            }
        }

        // The inspection window is created only after launch classification. It
        // never opens a document or invokes the production launch coordinator.
        shared.launchObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in shared.installInspector(rootPath: root.path) }
        }
    }

    private static func validate(_ root: URL, session: UUID) throws {
        guard root.lastPathComponent == "TallyLaunchSettingsTests-\(session.uuidString)",
              root.standardizedFileURL == root.resolvingSymlinksInPath().standardizedFileURL,
              try String(contentsOf: root.appendingPathComponent(".test-owner"), encoding: .utf8) == session.uuidString else {
            throw FixtureError.invalidOwner
        }
    }

    private func installInspector(rootPath: String) {
        guard panel == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 18, y: 35, width: 390, height: 220),
                            styleMask: [.titled, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Launch test status"
        panel.setAccessibilityIdentifier("launchTestInspector")
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.isExcludedFromWindowsMenu = true
        panel.hidesOnDeactivate = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        for identifier in ["launchTestStatus", "launchTestRootPath", "launchTestBundlePath", "launchTestOpenPaths",
                           "launchTestOpenCount", "launchTestFileCount", "launchTestPreference", "launchTestHasBookmark"] {
            let field = NSTextField(labelWithString: "")
            field.setAccessibilityIdentifier(identifier)
            field.font = .systemFont(ofSize: 10)
            field.lineBreakMode = .byTruncatingMiddle
            field.maximumNumberOfLines = 1
            fields[identifier] = field
            stack.addArrangedSubview(field)
        }
        let buttons = NSStackView()
        for name in ["A", "B"] {
            let button = NSButton(title: "Open fixture \(name)", target: self, action: #selector(openFixture(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(name)
            button.setAccessibilityIdentifier("launchTestOpen\(name)")
            buttons.addArrangedSubview(button)
        }
        stack.addArrangedSubview(buttons)
        panel.contentView = stack
        set("launchTestRootPath", rootPath)
        set("launchTestBundlePath", Bundle.main.bundleURL.path)
        panel.orderFront(nil)
        self.panel = panel
        refresh()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    @objc private func openFixture(_ sender: NSButton) {
        guard let root, let name = sender.identifier?.rawValue, ["A", "B"].contains(name) else { return }
        let url = root.appendingPathComponent("Launch-\(name).tally")
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { self.status = "error: \(error.localizedDescription)" }
        }
    }

    private func refresh() {
        let documents = NSDocumentController.shared.documents
        set("launchTestStatus", status)
        set("launchTestOpenPaths", documents.compactMap { $0.fileURL?.path }.sorted().joined(separator: "\n"))
        set("launchTestOpenCount", String(documents.count))
        let files = root.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
        set("launchTestFileCount", String(files.filter { $0.hasSuffix(".tally") }.count))
        set("launchTestPreference", MacLaunchEnvironment.defaults.string(forKey: TallyLaunchBehavior.preferenceKey) ?? TallyLaunchBehavior.lastUsedFile.rawValue)
        set("launchTestHasBookmark", MacLaunchEnvironment.defaults.data(forKey: MacLastUsedFileStore.bookmarkKey) == nil ? "false" : "true")
        for document in documents {
            guard let url = document.fileURL, let root,
                  url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else { continue }
            for window in document.windowControllers.compactMap(\.window) {
                window.setAccessibilityIdentifier("launchDocument-\(url.lastPathComponent)")
            }
        }
    }

    private func set(_ identifier: String, _ value: String) { fields[identifier]?.stringValue = value }

    private enum FixtureError: Error {
        case invalidOwner, unexpectedFiles, unknownAction
    }
}
#endif
