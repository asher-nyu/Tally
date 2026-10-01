#if os(macOS)
import AppKit

/// A recoverable Trash state belongs to its document window. The lifetime
/// observer remains active so restoration or permanent deletion can dismiss it.
@MainActor
final class MacDocumentDeletedAlert {
    private var alert: NSAlert?

    func present(
        in window: NSWindow,
        restore: @escaping @MainActor () -> Void,
        close: @escaping @MainActor () -> Void,
        recoveryError: String? = nil
    ) {
        guard alert == nil else { return }
        let alert = NSAlert()
        alert.messageText = recoveryError == nil ? "File in Trash" : "Couldn’t Restore File"
        alert.informativeText = recoveryError
            ?? "Restore this file to keep working, or close this window."
        // A deletion must also be announced while an editor sheet is open.
        // AppKit's critical-sheet presentation can appear above that sheet.
        alert.alertStyle = window.attachedSheet == nil ? .informational : .critical
        alert.icon = NSApp.applicationIconImage
        let restoreButton = alert.addButton(withTitle: recoveryError == nil ? "Restore File" : "Choose Location…")
        restoreButton.setAccessibilityIdentifier("documentDeletedRestore")
        let closeButton = alert.addButton(withTitle: "Close Window")
        closeButton.setAccessibilityIdentifier("documentDeletedClose")
        closeButton.keyEquivalent = "\u{1b}"
        alert.window.setAccessibilityIdentifier("documentDeletedAlert")
        self.alert = alert
        alert.beginSheetModal(for: window) { [weak self, weak alert] response in
            guard let self, let alert, self.alert === alert else { return }
            self.alert = nil
            if response == .alertFirstButtonReturn { restore() }
            if response == .alertSecondButtonReturn { close() }
        }
    }

    func stop() {
        let previous = alert
        alert = nil
        if let sheet = previous?.window, let parent = sheet.sheetParent {
            parent.endSheet(sheet, returnCode: .abort)
        }
    }
}
#endif
