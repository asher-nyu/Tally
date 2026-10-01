import Foundation
import Testing
@testable import Tally

nonisolated struct ProviderLinkTests {
    @Test func missingAndBlankWebsitesRemainOptional() throws {
        for text in [nil, "", "   ", " \n\t "] as [String?] {
            #expect(try ProviderLink.normalizeWebsite(text) == nil)
            #expect(try ProviderLink.websiteURL(text) == nil)
        }
    }

    @Test func websitesTrimAndNormalizeWithoutChangingTheirDestination() throws {
        #expect(try ProviderLink.normalizeWebsite("  Example.com/account  ") == "https://example.com/account")
        #expect(try ProviderLink.normalizeWebsite("HTTPS://EXAMPLE.COM/account?view=bills#current") == "https://example.com/account?view=bills#current")
        #expect(try ProviderLink.normalizeWebsite("http://example.com:8080/account") == "http://example.com:8080/account")
        #expect(try ProviderLink.normalizeWebsite("example.com:8443/account") == "https://example.com:8443/account")
        #expect(try ProviderLink.normalizeWebsite("//example.com/account") == "https://example.com/account")
    }

    @Test func normalizedURLsPreserveEscapedPathsAndNestedQueryValues() throws {
        let text = "https://example.com/account%20settings?return=https%3A%2F%2Fexample.org%2Fbilling%3Fa%3D1&literal=%2520"
        #expect(try ProviderLink.normalizeWebsite(text) == text)
        #expect(try ProviderLink.websiteURL(text)?.absoluteString == text)
    }

    @Test func internationalWebsitesAndExplicitLocalHostsRemainUsable() throws {
        let international = try #require(try ProviderLink.websiteURL("https://bücher.example/费用"))
        #expect(international.scheme == "https")
        #expect(international.host != nil)
        #expect(try ProviderLink.websiteURL(international.absoluteString) == international)
        #expect(try ProviderLink.normalizeWebsite("https://intranet/account") == "https://intranet/account")
        #expect(try ProviderLink.normalizeWebsite("localhost:8080/account") == "https://localhost:8080/account")
        #expect(try ProviderLink.websiteURL("http://[2001:db8::1]:8080/account")?.port == 8080)
    }

    @Test(arguments: ["ftp://example.com", "file:///tmp/bill", "javascript:alert(1)", "data:text/html,bill", "vbscript:msgbox(1)", "shell:open", "mailto:billing@example.com", "tel:5550100", "provider://account"])
    func websiteFieldRejectsOtherSchemes(_ text: String) {
        #expect(throws: ProviderLinkError.invalidWebsite) { try ProviderLink.normalizeWebsite(text) }
    }

    @Test(arguments: ["https://", "http:///account", "https:example.com", "Example", "/account", "#billing", "?account=1", "https://?account=1", "https://#billing", "https://.", "https://../billing", "https://-example.com", "https://example-.com", "https://example..com", "https://example.com/billing page", "https://example.com\\billing"])
    func websitesRequireAHostAndUnambiguousSyntax(_ text: String) {
        #expect(throws: ProviderLinkError.invalidWebsite) { try ProviderLink.normalizeWebsite(text) }
    }

    @Test(arguments: ["https://user@example.com", "https://user:password@example.com", "https://@example.com", "http://user%40name:pass@example.com"])
    func embeddedCredentialsAreRejected(_ text: String) {
        #expect(throws: ProviderLinkError.credentialsNotAllowed) { try ProviderLink.normalizeWebsite(text) }
    }

    @Test(arguments: ["https://example.com/\naccount", "https://example.com/\taccount", "\nhttps://example.com", "https://example.com\u{0}", "https://example.com/%0aaccount", "https://example.com/?value=%0D", "https://example.com/%09", "https://example.com/%7F", "https://example.com/%C2%85"])
    func rawAndEncodedControlsAreRejected(_ text: String) {
        #expect(throws: ProviderLinkError.unsafeCharacters) { try ProviderLink.normalizeWebsite(text) }
    }

    @Test(arguments: ["https://example.com/%", "https://example.com/%2", "https://example.com/%GG", "https://example.com/%FF", "https://example.com:0", "https://example.com:65536", "https://example.com:notaport"])
    func invalidEscapesAndPortsAreRejected(_ text: String) {
        #expect(throws: ProviderLinkError.invalidWebsite) { try ProviderLink.normalizeWebsite(text) }
    }

    @Test func lengthLimitAppliesToTheResultingURL() throws {
        let prefix = "https://example.com/"
        let limit = prefix + String(repeating: "a", count: ProviderLink.maximumLength - prefix.utf8.count)
        #expect(try ProviderLink.normalizeWebsite(limit) == limit)
        #expect(throws: ProviderLinkError.tooLong) { try ProviderLink.normalizeWebsite(limit + "a") }
        let bare = "example.com/" + String(repeating: "a", count: ProviderLink.maximumLength - "example.com/".utf8.count)
        #expect(throws: ProviderLinkError.tooLong) { try ProviderLink.normalizeWebsite(bare) }
    }

    @Test func codecRoundTripsEntriesWithAndWithoutWebsites() throws {
        let ledger = Ledger(expenses: [
            Expense(merchant: "Fictional provider", amountMinor: 1_001, billingDay: 15, websiteLink: "https://example.com/account"),
            Expense(merchant: "Fictional provider without a website", amountMinor: 2_002)
        ])
        let encoded = try LedgerCodec.encode(ledger)
        #expect(try LedgerCodec.decode(encoded) == ledger)
        #expect(try LedgerCodec.encode(LedgerCodec.decode(encoded)) == encoded)
        #expect(ledger.formatVersion == LedgerCodec.currentFormatVersion)
    }

    @Test func versionThreeMigrationPreservesCustomSchedulesWithoutInventingWebsites() throws {
        let original = Ledger(expenses: [
            Expense(merchant: "Fictional custom income", amountMinor: 100_001, kind: .income, recurrence: .custom,
                    anchorDate: .init(year: 2026, month: 1, day: 1), customRecurrence: .init(frequency: .monthly, monthDays: [1, 15])),
            Expense(merchant: "Fictional monthly expense", amountMinor: 50_001, billingDay: 31)
        ])
        var json = try #require(JSONSerialization.jsonObject(with: LedgerCodec.encode(original)) as? [String: Any])
        json["formatVersion"] = 3
        let upgraded = try LedgerCodec.decode(JSONSerialization.data(withJSONObject: json))
        #expect(upgraded == original)
        #expect(upgraded.expenses.allSatisfy { $0.websiteLink == nil })
        #expect(upgraded.formatVersion == LedgerCodec.currentFormatVersion)
    }

    @Test func missingAndNullWebsiteFieldsDecodeIdentically() throws {
        let original = Ledger(expenses: [Expense(merchant: "Fictional provider")])
        var json = try #require(JSONSerialization.jsonObject(with: LedgerCodec.encode(original)) as? [String: Any])
        var rows = try #require(json["expenses"] as? [[String: Any]])
        rows[0]["websiteLink"] = NSNull()
        json["expenses"] = rows
        #expect(try LedgerCodec.decode(JSONSerialization.data(withJSONObject: json)) == original)
        rows[0]["websiteLink"] = 123
        json["expenses"] = rows
        #expect(throws: LedgerError.corruptFile) { try LedgerCodec.decode(JSONSerialization.data(withJSONObject: json)) }
    }

    @Test func codecValidatesWebsitesOnBothReadAndWrite() throws {
        let original = Ledger(expenses: [Expense(merchant: "Fictional provider")])
        var invalid = original
        invalid.expenses[0].websiteLink = "javascript:alert(1)"
        #expect(throws: ProviderLinkError.invalidWebsite) { try LedgerCodec.encode(invalid) }
        var json = try #require(JSONSerialization.jsonObject(with: LedgerCodec.encode(original)) as? [String: Any])
        var rows = try #require(json["expenses"] as? [[String: Any]])
        rows[0]["websiteLink"] = "https://user:password@example.com"
        json["expenses"] = rows
        #expect(throws: ProviderLinkError.credentialsNotAllowed) { try LedgerCodec.decode(JSONSerialization.data(withJSONObject: json)) }
    }

    @Test func codecPreservesValidStoredTextWhileURLAccessNormalizesIt() throws {
        let original = Ledger(expenses: [Expense(merchant: "Fictional provider", websiteLink: "  Example.com/account  ")])
        #expect(try LedgerCodec.decode(LedgerCodec.encode(original)) == original)
        #expect(try ProviderLink.websiteURL(original.expenses[0].websiteLink)?.absoluteString == "https://example.com/account")
    }

    @Test func mergingIndependentChangesRetainsTheWebsite() throws {
        let base = Ledger(expenses: [Expense(merchant: "Fictional one"), Expense(merchant: "Fictional two", amountMinor: 100)])
        var local = base
        var remote = base
        local.expenses[0].websiteLink = "https://example.com/account"
        remote.expenses[1].amountMinor = 200
        let merged = try LedgerMerger.merge(base: base, local: local, remote: remote)
        #expect(merged.expenses == [local.expenses[0], remote.expenses[1]])
    }

    @Test func competingWebsiteEditsSurviveInDistinctConflictCopies() throws {
        let base = Ledger(expenses: [Expense(merchant: "Fictional provider", websiteLink: "https://example.com")])
        var local = base
        var remote = base
        local.expenses[0].websiteLink = "https://example.com/local-account"
        remote.expenses[0].websiteLink = "https://example.com/remote-account"
        let merged = try LedgerMerger.merge(base: base, local: local, remote: remote)
        #expect(merged.expenses.count == 2)
        #expect(merged.expenses[0] == local.expenses[0])
        #expect(merged.expenses[1].websiteLink == remote.expenses[0].websiteLink)
        #expect(merged.expenses[1].merchant.hasSuffix(" (conflicting copy)"))
        #expect(try LedgerMerger.merge(base: base, local: merged, remote: remote) == merged)
        #expect(try LedgerCodec.decode(LedgerCodec.encode(merged)) == merged)
    }
}
