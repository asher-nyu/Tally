import Foundation
import Testing
@testable import Tally

@MainActor
struct ProviderWebsiteOpenerTests {
    @Test func macUsesTheDefaultBrowserForTheActualWebsite() async throws {
        let website = try #require(URL(string: "https://provider.example/account?view=bills#current"))
        let browser = URL(fileURLWithPath: "/Applications/Example Browser.app")
        var lookedUpURLs: [URL] = []
        var openedURLs: [URL] = []
        var openedApplications: [URL] = []
        let opener = ProviderWebsiteOpener.defaultBrowser(
            resolveApplication: { url in
                lookedUpURLs.append(url)
                return browser
            },
            openInApplication: { url, application in
                openedURLs.append(url)
                openedApplications.append(application)
                return true
            }
        )

        #expect(await opener.open(website))
        #expect(lookedUpURLs.count == 1)
        #expect(lookedUpURLs.first?.scheme == "https")
        #expect(lookedUpURLs.first?.host == "example.invalid")
        #expect(openedURLs == [website])
        #expect(openedApplications == [browser])
    }

    @Test func missingBrowserDoesNotAttemptAnotherApplication() async throws {
        let website = try #require(URL(string: "https://provider.example"))
        var didOpen = false
        let opener = ProviderWebsiteOpener.defaultBrowser(
            resolveApplication: { _ in nil },
            openInApplication: { _, _ in
                didOpen = true
                return true
            }
        )

        #expect(await opener.open(website) == false)
        #expect(!didOpen)
    }

    @Test func failedBrowserLaunchIsReported() async throws {
        let website = try #require(URL(string: "http://provider.example/account"))
        let browser = URL(fileURLWithPath: "/Applications/Example Browser.app")
        var attempts = 0
        let opener = ProviderWebsiteOpener.defaultBrowser(
            resolveApplication: { _ in browser },
            openInApplication: { _, _ in
                attempts += 1
                return false
            }
        )

        #expect(await opener.open(website) == false)
        #expect(attempts == 1)
    }

    @Test(arguments: [
        "provider://account", "file:///tmp/example.html", "javascript:alert(1)",
        "https:///", "https://user:secret@provider.example", "https://provider.example/%0A"
    ])
    func invalidDestinationsNeverReachThePlatform(_ text: String) async throws {
        let url = try #require(URL(string: text))
        var didOpen = false
        let opener = ProviderWebsiteOpener { _ in
            didOpen = true
            return true
        }

        #expect(await opener.open(url) == false)
        #expect(!didOpen)
    }

    @Test(arguments: [true, false])
    func normalPlatformOpeningPreservesTheResult(_ platformResult: Bool) async throws {
        let website = try #require(URL(string: "https://provider.example/account"))
        var openedURLs: [URL] = []
        let opener = ProviderWebsiteOpener { url in
            openedURLs.append(url)
            return platformResult
        }

        #expect(await opener.open(website) == platformResult)
        #expect(openedURLs == [website])
    }
}
