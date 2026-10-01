import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
enum NotificationSettingsOpener {
    static func open() async -> Bool {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"),
           NSWorkspace.shared.open(url) {
            return true
        }
        guard let settings = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else {
            return false
        }
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: settings, configuration: NSWorkspace.OpenConfiguration()) { app, error in
                continuation.resume(returning: app != nil && error == nil)
            }
        }
        #else
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return false }
        return await UIApplication.shared.open(url)
        #endif
    }
}
