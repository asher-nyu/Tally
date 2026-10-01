import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Opens a user-supplied website without fetching it or discovering a provider.
@MainActor
struct ProviderWebsiteOpener {
    private let openWebsite: @MainActor (URL) async -> Bool

    init(openWebsite: @escaping @MainActor (URL) async -> Bool) {
        self.openWebsite = openWebsite
    }

    func open(_ url: URL) async -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let website = try? ProviderLink.websiteURL(url.absoluteString)
        else { return false }
        return await openWebsite(website)
    }

    static let live: ProviderWebsiteOpener = {
        #if os(macOS)
        defaultBrowser(
            resolveApplication: { NSWorkspace.shared.urlForApplication(toOpen: $0) },
            openInApplication: { website, browser in
                await withCheckedContinuation { continuation in
                    NSWorkspace.shared.open(
                        [website],
                        withApplicationAt: browser,
                        configuration: NSWorkspace.OpenConfiguration()
                    ) { application, error in
                        continuation.resume(returning: application != nil && error == nil)
                    }
                }
            }
        )
        #elseif os(iOS)
        ProviderWebsiteOpener { website in
            await UIApplication.shared.open(website, options: [:])
        }
        #endif
    }()

    /// Resolves the user's browser separately from the destination so a
    /// provider's associated app cannot become the macOS launch target.
    static func defaultBrowser(
        resolveApplication: @escaping @MainActor (URL) -> URL?,
        openInApplication: @escaping @MainActor (URL, URL) async -> Bool
    ) -> ProviderWebsiteOpener {
        ProviderWebsiteOpener { website in
            // This reserved URL is only a local handler lookup. It is never
            // opened or requested; only the user's website goes to the browser.
            guard let lookupURL = URL(string: "https://example.invalid"),
                  let browser = resolveApplication(lookupURL)
            else { return false }
            return await openInApplication(website, browser)
        }
    }
}
