#if DEBUG && os(iOS)
import Foundation
import CryptoKit
import UIKit

/// Relaunchable files and preferences owned only by the dedicated UI test session.
@MainActor
enum MobileLaunchTestSupport {
    static var isEnabled: Bool { MobileLaunchEnvironment.isLaunchTestEnabled }
    static private(set) var fixtureDirectoryURL: URL?
    static private(set) var explicitRequestedURL: URL?
    static private(set) var status = "unprepared"
    static var fixtureAURL: URL? { fixtureDirectoryURL?.appendingPathComponent("Launch-A.tally") }
    static var fixtureBURL: URL? { fixtureDirectoryURL?.appendingPathComponent("Launch-B.tally") }
    private static var didPrepare = false

    static func prepare() throws {
        guard isEnabled, !didPrepare, let session = MobileLaunchEnvironment.testSessionID else { return }
        let manager = FileManager.default
        let cache = try manager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .resolvingSymlinksInPath()
        let root = cache.appendingPathComponent("TallyMobileLaunchSettingsTests-\(session.uuidString)", isDirectory: true)
        let action = ProcessInfo.processInfo.environment["TALLY_MOBILE_LAUNCH_TEST_ACTION"] ?? ""
        if action == "cleanup" || action == "reset" {
            if manager.fileExists(atPath: root.path) {
                try validate(root, session: session)
                let documents = try manager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                try MobileLaunchImportedFileRegistry.removeRecordedImports(fixtureRoot: root, documentsRoot: documents)
                let allowed = Set([".test-owner", ".imports.json", "Launch-A.tally", "Launch-B.tally", "Renamed-A.tally"])
                let names = try manager.contentsOfDirectory(atPath: root.path)
                guard Set(names).isSubset(of: allowed) else { throw FixtureError.unexpectedFiles }
                try manager.removeItem(at: root)
            }
            MobileLaunchEnvironment.defaults.removePersistentDomain(forName: MobileLaunchEnvironment.suiteName(for: session))
            if action == "cleanup" {
                didPrepare = true
                status = "cleaned"
                return
            }
        }
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
        fixtureDirectoryURL = root
        let a = root.appendingPathComponent("Launch-A.tally")
        switch action {
        case "", "reset": break
        case "seedA":
            try MobileLastUsedFileStore(defaults: MobileLaunchEnvironment.defaults).remember(a)
        case "seedCorruptA":
            try Data("Invalid fictional Tally document".utf8).write(to: a, options: .atomic)
            try MobileLastUsedFileStore(defaults: MobileLaunchEnvironment.defaults).remember(a)
        case "deleteA":
            try manager.removeItem(at: a)
        case "renameA":
            try manager.moveItem(at: a, to: root.appendingPathComponent("Renamed-A.tally"))
        case "explicitB":
            explicitRequestedURL = fixtureBURL
        default:
            throw FixtureError.unknownAction
        }
        didPrepare = true
        status = "ready"
    }

    /// Makes the pending native launch screen observable without delaying any
    /// ordinary Debug or production launch. Cancellation still ends the wait.
    static func delayRestorationIfRequested() async {
        await delayIfRequested("TALLY_MOBILE_LAUNCH_TEST_RESTORE_DELAY_MS")
    }

    static func delayEditorPresentationIfRequested() async {
        await delayIfRequested("TALLY_MOBILE_LAUNCH_TEST_PRESENT_DELAY_MS")
    }

    private static func delayIfRequested(_ key: String) async {
        guard isEnabled,
              let value = ProcessInfo.processInfo.environment[key],
              let milliseconds = Int(value), (1...10_000).contains(milliseconds) else { return }
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    static func buttons(open: @escaping @MainActor (URL) -> Void) -> [UIBarButtonItem] {
        guard isEnabled else { return [] }
        return [("A", fixtureAURL), ("B", fixtureBURL)].compactMap { name, url in
            guard let url else { return nil }
            let item = UIBarButtonItem(title: name, primaryAction: UIAction { _ in open(url) })
            item.accessibilityIdentifier = "mobileLaunchOpen\(name)"
            item.accessibilityLabel = "Open fixture \(name)"
            return item
        }
    }

    /// Native browser reveal may copy a cache fixture into the app's Documents.
    /// Track only a byte-for-byte fixture copy so cleanup cannot touch user data.
    static func recordImport(sourceURL: URL, destinationURL: URL) throws {
        guard isEnabled, let root = fixtureDirectoryURL, let session = MobileLaunchEnvironment.testSessionID else { return }
        guard sourceURL.standardizedFileURL != destinationURL.standardizedFileURL else { return }
        try validate(root, session: session)
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        try MobileLaunchImportedFileRegistry.record(source: sourceURL, destination: destinationURL,
                                                    fixtureRoot: root, documentsRoot: documents)
    }

    private static func validate(_ root: URL, session: UUID) throws {
        guard root.lastPathComponent == "TallyMobileLaunchSettingsTests-\(session.uuidString)",
              root.standardizedFileURL == root.resolvingSymlinksInPath().standardizedFileURL,
              try String(contentsOf: root.appendingPathComponent(".test-owner"), encoding: .utf8) == session.uuidString else {
            throw FixtureError.invalidOwner
        }
    }

    enum FixtureError: Error { case invalidOwner, unexpectedFiles, unknownAction }
}

/// The registry deliberately requires exact content equality before taking
/// ownership of an import, and checks the recorded digest again before removal.
nonisolated enum MobileLaunchImportedFileRegistry {
    private struct Import: Codable {
        let relativePath: String
        let digest: String
    }

    enum RegistryError: Error { case unsafePath, unexpectedContents }

    static func record(source: URL, destination: URL, fixtureRoot: URL, documentsRoot: URL) throws {
        let source = source.standardizedFileURL
        let root = fixtureRoot.resolvingSymlinksInPath().standardizedFileURL
        guard source.deletingLastPathComponent() == root,
              ["Launch-A.tally", "Launch-B.tally", "Renamed-A.tally"].contains(source.lastPathComponent),
              source == source.resolvingSymlinksInPath().standardizedFileURL else { throw RegistryError.unsafePath }
        let relative = try relativePath(for: destination, in: documentsRoot)
        let sourceData = try Data(contentsOf: source)
        let destinationData = try Data(contentsOf: destination)
        guard sourceData == destinationData else { throw RegistryError.unexpectedContents }
        let manifest = root.appendingPathComponent(".imports.json")
        var imports = try read(manifest)
        let digest = hash(destinationData)
        if let previous = imports.first(where: { $0.relativePath == relative }), previous.digest != digest {
            throw RegistryError.unexpectedContents
        }
        imports.removeAll { $0.relativePath == relative }
        imports.append(Import(relativePath: relative, digest: digest))
        try JSONEncoder().encode(imports).write(to: manifest, options: .atomic)
    }

    static func removeRecordedImports(fixtureRoot: URL, documentsRoot: URL) throws {
        let manifest = fixtureRoot.appendingPathComponent(".imports.json")
        let imports = try read(manifest)
        var removals: [URL] = []
        let documents = documentsRoot.resolvingSymlinksInPath().standardizedFileURL
        for item in imports {
            guard !item.relativePath.hasPrefix("/"),
                  !item.relativePath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
                throw RegistryError.unsafePath
            }
            let url = documents.appendingPathComponent(item.relativePath)
            guard try relativePath(for: url, in: documents) == item.relativePath else { throw RegistryError.unsafePath }
            if !FileManager.default.fileExists(atPath: url.path) { continue }
            guard hash(try Data(contentsOf: url)) == item.digest else { throw RegistryError.unexpectedContents }
            removals.append(url)
        }
        // Validate the whole batch before removing any file.
        for url in removals { try FileManager.default.removeItem(at: url) }
    }

    private static func relativePath(for url: URL, in documentsRoot: URL) throws -> String {
        let url = url.standardizedFileURL
        let documents = documentsRoot.resolvingSymlinksInPath().standardizedFileURL
        let parentComponents = documents.pathComponents
        guard url.isFileURL, url.pathExtension.lowercased() == "tally",
              url == url.resolvingSymlinksInPath().standardizedFileURL,
              url.pathComponents.count > parentComponents.count,
              Array(url.pathComponents.prefix(parentComponents.count)) == parentComponents else {
            throw RegistryError.unsafePath
        }
        return url.pathComponents.dropFirst(parentComponents.count).joined(separator: "/")
    }

    private static func read(_ manifest: URL) throws -> [Import] {
        guard FileManager.default.fileExists(atPath: manifest.path) else { return [] }
        return try JSONDecoder().decode([Import].self, from: Data(contentsOf: manifest))
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
