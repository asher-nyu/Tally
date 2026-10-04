#if DEBUG && os(iOS)
import UIKit

/// Disposable native-document fixtures for UI automation. The operations touch
/// only the UUID directory created by this object, never browser-selected files.
@MainActor
final class MobileDocumentTestSupport {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--ui-testing-native-mobile") }
    static var isFileActionsEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--ui-testing-mobile-file-actions") }
    let directory: URL
    let url: URL
    private let contents: Data

    init() throws {
        if Self.isFileActionsEnabled {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            directory = documents.appendingPathComponent("TallyNativeMobileTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } else {
            directory = try TallyDocumentBrowserController.makeStagingDirectory(purpose: "NativeMobileTests")
        }
        url = directory.appendingPathComponent("Fictional Budget.tally")
        let ledger = Ledger(expenses: [Expense(merchant: "Fictional rent", amountMinor: 123_456, billingDay: 1)])
        contents = try LedgerCodec.encode(ledger)
        try contents.write(to: url, options: .withoutOverwriting)
    }

    func buttons() -> [UIBarButtonItem] {
        if Self.isFileActionsEnabled { return [] }
        let deletion = UIBarButtonItem(title: "Delete", image: UIImage(systemName: "trash"), primaryAction: UIAction(title: "Delete Fixture") { [weak self] _ in self?.delete(thenRestore: false) })
        deletion.accessibilityIdentifier = "nativeMobileDelete"
        let restoration = UIBarButtonItem(title: "Restore", image: UIImage(systemName: "arrow.uturn.backward"), primaryAction: UIAction(title: "Restore Fixture") { [weak self] _ in self?.delete(thenRestore: true) })
        restoration.accessibilityIdentifier = "nativeMobileRestore"
        return [deletion, restoration]
    }

    private func delete(thenRestore: Bool) {
        let url = url
        let contents = contents
        Task {
            let removed = await Task.detached(priority: .userInitiated) {
                let coordinator = NSFileCoordinator()
                var error: NSError?
                var success = false
                coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &error) { target in
                    do {
                        // No selected user file can enter this seam: exact
                        // fixture bytes must still match before removal.
                        guard try Data(contentsOf: target) == contents else {
                            print("Tally native UI fixture: contents changed; refusing removal")
                            return
                        }
                        try FileManager.default.removeItem(at: target)
                        success = true
                    } catch { print("Tally native UI fixture removal failed: \(error)") }
                }
                print("Tally native UI fixture removal completed: \(success)")
                return success
            }.value
            if removed && thenRestore {
                // Leave enough time for XCTest to observe the real alert
                // before the independent restoration takes place.
                try? await Task.sleep(for: .seconds(8))
                try? contents.write(to: url, options: .withoutOverwriting)
            }
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }

}
#endif
