import Foundation

nonisolated enum ProviderLinkError: Error, LocalizedError, Equatable, Sendable {
    case tooLong, invalidWebsite, credentialsNotAllowed, unsafeCharacters

    var errorDescription: String? {
        switch self {
        case .tooLong: "This website link is too long. Use a shorter, direct link to the provider’s website."
        case .invalidWebsite: "Enter a valid website, such as example.com or https://example.com/account."
        case .credentialsNotAllowed: "Use a website link without an embedded username or password."
        case .unsafeCharacters: "The website link contains hidden characters. Paste a clean copy of the website address."
        }
    }
}

/// Parses user-provided websites locally. This does not discover providers,
/// perform network requests, or turn an app name into a destination.
nonisolated enum ProviderLink {
    static let maximumLength = 2_048

    static func normalizeWebsite(_ text: String?) throws -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.utf8.count <= maximumLength else { throw ProviderLinkError.tooLong }
        guard !containsControls(text) else { throw ProviderLinkError.unsafeCharacters }
        guard !trimmed.contains(where: { $0.isWhitespace }), !trimmed.contains("\\"), validPercentEscapes(trimmed),
              let decoded = trimmed.removingPercentEncoding else { throw ProviderLinkError.invalidWebsite }
        guard !containsControls(decoded) else { throw ProviderLinkError.unsafeCharacters }

        let candidate: String
        let suppliedScheme = URLComponents(string: trimmed)?.scheme?.lowercased()
        if trimmed.hasPrefix("//") {
            candidate = "https:" + trimmed
        } else if let suppliedScheme, !isBareHostWithPort(trimmed) {
            guard suppliedScheme == "http" || suppliedScheme == "https" else { throw ProviderLinkError.invalidWebsite }
            candidate = trimmed
        } else {
            candidate = "https://" + trimmed
        }

        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "@/\\?#"))) == nil
        else { throw ProviderLinkError.invalidWebsite }
        guard components.user == nil, components.password == nil else { throw ProviderLinkError.credentialsNotAllowed }
        if let port = components.port, !(1...65_535).contains(port) { throw ProviderLinkError.invalidWebsite }
        if !host.contains(":") {
            let hostname = host.hasSuffix(".") ? String(host.dropLast()) : host
            let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
            guard labels.allSatisfy({ label in
                !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-")
                    && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            }) else { throw ProviderLinkError.invalidWebsite }
        }
        // A bare word is usually a provider's name, not a supplied host. Explicit
        // http(s) URLs still support legitimate single-label intranet hosts.
        if suppliedScheme == nil, !trimmed.hasPrefix("//"),
           !host.contains("."), !host.contains(":"), host.lowercased() != "localhost" {
            throw ProviderLinkError.invalidWebsite
        }
        components.scheme = scheme
        components.host = host.lowercased()
        guard let url = components.url, url.host != nil else { throw ProviderLinkError.invalidWebsite }
        let normalized = url.absoluteString
        guard normalized.utf8.count <= maximumLength else { throw ProviderLinkError.tooLong }
        return normalized
    }

    static func websiteURL(_ text: String?) throws -> URL? {
        guard let normalized = try normalizeWebsite(text), let url = URL(string: normalized) else { return nil }
        return url
    }

    private static func containsControls(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func validPercentEscapes(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        func isHex(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
        var index = 0
        while index < bytes.count {
            if bytes[index] == 37 {
                guard index + 2 < bytes.count, isHex(bytes[index + 1]), isHex(bytes[index + 2]) else { return false }
                index += 3
            } else {
                index += 1
            }
        }
        return true
    }

    private static func isBareHostWithPort(_ text: String) -> Bool {
        let authority = text.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard let colon = authority.lastIndex(of: ":") else { return false }
        let host = authority[..<colon]
        let port = authority[authority.index(after: colon)...]
        return !port.isEmpty && port.allSatisfy(\.isNumber)
            && (host.contains(".") || host.lowercased() == "localhost" || host.hasPrefix("["))
    }
}
