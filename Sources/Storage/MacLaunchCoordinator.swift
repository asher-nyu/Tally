#if os(macOS)
import AppKit
import Foundation
import OSLog

enum MacLaunchEnvironment {
    static let defaults: UserDefaults = {
        #if DEBUG
        if MacLaunchTestSupport.isEnabled,
           let token = ProcessInfo.processInfo.environment["TALLY_LAUNCH_TEST_SESSION"],
           let session = UUID(uuidString: token) {
            return UserDefaults(suiteName: "TallyLaunchSettingsTests.\(session.uuidString)")!
        }
        #endif
        return .standard
    }()

    static var isEnabled: Bool {
        #if DEBUG
        if MacLaunchTestSupport.isEnabled { return true }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil { return false }
        #endif
        return true
    }
}

final class TallyMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = MacLaunchCoordinator.shared
        coordinator.startTracking()
        // Finder opens and printing are handled by the native document controller.
        // Only an ordinary app launch should apply the launch preference.
        let isDefaultLaunch = (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? NSNumber)?.boolValue ?? true
        if isDefaultLaunch { coordinator.openFromAppIcon() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard MacLaunchEnvironment.isEnabled else { return true }
        let documents = NSDocumentController.shared.documents
        if let document = documents.first(where: { $0.windowControllers.contains { $0.window?.isMainWindow == true } }) ?? documents.last {
            document.showWindows()
            return false
        }
        MacLaunchCoordinator.shared.openFromAppIcon()
        return false
    }
}

/// Owns the launch choice and file-access grants, while NSDocument owns the files.
@MainActor
final class MacLaunchCoordinator {
    static let shared = MacLaunchCoordinator()
    nonisolated private static let logger = Logger(subsystem: "com.asherbloom.Tally", category: "Launch")
    private let store = MacLastUsedFileStore(defaults: MacLaunchEnvironment.defaults)
    private let fileQueue = DispatchQueue(label: "com.asherbloom.Tally.last-file", qos: .utility)
    private var observers: [NSObjectProtocol] = []
    private weak var lastDocument: NSDocument?
    private var lastRecordedURL: URL?
    private var launchTask: Task<Void, Never>?
    private var browserPresented = false
    private var retainedAccess: [ObjectIdentifier: MacLastUsedFileStore.ResolvedFile] = [:]

    func startTracking() {
        guard MacLaunchEnvironment.isEnabled, observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor [weak self, weak window] in
                guard let window, let document = NSDocumentController.shared.document(for: window) else { return }
                self?.record(document)
            }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.releaseClosedDocuments()
            }
        })
    }

    /// Called when the native document becomes available or changes its location.
    func documentLocationChanged(_ document: NSDocument) {
        guard MacLaunchEnvironment.isEnabled else { return }
        if document === lastDocument || document.windowControllers.contains(where: { $0.window?.isMainWindow == true }) {
            record(document)
        }
    }

    private func record(_ document: NSDocument) {
        guard MacLaunchEnvironment.isEnabled, let url = document.fileURL else { return }
        guard document !== lastDocument || url != lastRecordedURL else { return }
        lastDocument = document
        lastRecordedURL = url
        let store = store
        // Keep requests ordered without blocking the interface on a file provider.
        fileQueue.async { [weak self, weak document] in
            do { try store.remember(url) }
            catch {
                Self.logger.notice("Could not remember a document: \(error.localizedDescription, privacy: .private)")
                Task { @MainActor [weak self, weak document] in
                    guard let self, let document, self.lastDocument === document,
                          self.lastRecordedURL == url else { return }
                    self.lastRecordedURL = nil
                }
            }
        }
        releaseClosedDocuments()
    }

    func openFromAppIcon() {
        guard MacLaunchEnvironment.isEnabled, launchTask == nil, !browserPresented else { return }
        guard NSDocumentController.shared.documents.isEmpty else { return }
        launchTask = Task { [weak self] in
            guard let self else { return }
            defer { self.launchTask = nil }
            let behavior = TallyLaunchBehavior(rawValue: MacLaunchEnvironment.defaults.string(forKey: TallyLaunchBehavior.preferenceKey) ?? "") ?? .lastUsedFile
            let hadBookmark = MacLaunchEnvironment.defaults.data(forKey: MacLastUsedFileStore.bookmarkKey) != nil
            if behavior == .lastUsedFile, let access = await self.resolveLastFile() {
                guard !Task.isCancelled, NSDocumentController.shared.documents.isEmpty else {
                    access.stopAccessing()
                    return
                }
                if let document = await self.open(access.url) {
                    self.retainedAccess[ObjectIdentifier(document)] = access
                    self.record(document)
                    return
                }
                access.stopAccessing()
            }
            // Earlier versions relied on AppKit's recent documents and did not
            // save our bookmark. Adopt that existing selection only on upgrade;
            // an unavailable saved bookmark must never open a different file.
            if behavior == .lastUsedFile, !hadBookmark,
               let recent = self.upgradeRecentFile(), await self.canReopen(recent) {
                guard !Task.isCancelled, NSDocumentController.shared.documents.isEmpty else { return }
                if let document = await self.open(recent) {
                    self.record(document)
                    return
                }
            }
            guard !Task.isCancelled, NSDocumentController.shared.documents.isEmpty else { return }
            self.showFileBrowser()
        }
    }

    private func resolveLastFile() async -> MacLastUsedFileStore.ResolvedFile? {
        let store = store
        return await withCheckedContinuation { continuation in
            fileQueue.async {
                do { continuation.resume(returning: try store.resolve()) }
                catch {
                    Self.logger.notice("Could not resolve the previous document: \(error.localizedDescription, privacy: .private)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func upgradeRecentFile() -> URL? {
        #if DEBUG
        // The native recent list belongs to the user even when preferences use
        // an isolated suite. Launch tests must never consume that history.
        if MacLaunchTestSupport.isEnabled { return MacLaunchTestSupport.legacyRecentFileURL }
        #endif
        guard let url = NSDocumentController.shared.recentDocumentURLs.first,
              url.isFileURL, url.pathExtension.lowercased() == "tally" else { return nil }
        return url
    }

    private func canReopen(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            fileQueue.async {
                switch MacDocumentLifetimeInspection.inspect(url) {
                case .missing, .inTrash: continuation.resume(returning: false)
                case .present, .evicted, .unknown: continuation.resume(returning: true)
                }
            }
        }
    }

    private func open(_ url: URL, presentErrors: Bool = false) async -> NSDocument? {
        await withCheckedContinuation { continuation in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
                if let error {
                    Self.logger.notice("Could not open a document: \(error.localizedDescription, privacy: .private)")
                    if presentErrors { NSApp.presentError(error) }
                }
                continuation.resume(returning: document)
            }
        }
    }

    private func showFileBrowser() {
        guard !browserPresented else { return }
        browserPresented = true
        NSDocumentController.shared.beginOpenPanel { [weak self] urls in
            guard let self else { return }
            self.browserPresented = false
            guard let urls else { return }
            Task { @MainActor in
                for url in urls { _ = await self.open(url, presentErrors: true) }
            }
        }
    }

    private func releaseClosedDocuments() {
        let openIDs = Set(NSDocumentController.shared.documents.map(ObjectIdentifier.init))
        for id in retainedAccess.keys where !openIDs.contains(id) {
            retainedAccess.removeValue(forKey: id)?.stopAccessing()
        }
    }
}
#endif
