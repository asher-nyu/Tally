import Foundation

nonisolated enum TallyFileNameError: Error, LocalizedError, Equatable, Sendable {
    case emptyName, reservedName, pathSeparators, controlCharacters, tooLong

    var errorDescription: String? {
        switch self {
        case .emptyName: "Enter a name for the Tally file."
        case .reservedName: "Choose a file name other than “.” or “..”."
        case .pathSeparators: "Use a file name without “/” or “:”."
        case .controlCharacters: "Remove line breaks and hidden control characters from the file name."
        case .tooLong: "Choose a shorter file name."
        }
    }
}

/// Validates one filename component without treating dots as other extensions.
nonisolated enum TallyFileName {
    static let maximumByteCount = 255
    private static let fileExtension = ".tally"

    static func baseName(from input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.lowercased().hasSuffix(fileExtension)
            ? String(trimmed.unicodeScalars.dropLast(fileExtension.utf8.count))
            : trimmed

        guard !name.isEmpty else { throw TallyFileNameError.emptyName }
        guard name != ".", name != ".." else { throw TallyFileNameError.reservedName }
        guard !name.contains("/"), !name.contains(":") else { throw TallyFileNameError.pathSeparators }
        guard !name.unicodeScalars.contains(where: {
            $0.properties.generalCategory == .control || CharacterSet.newlines.contains($0)
        }) else { throw TallyFileNameError.controlCharacters }
        guard name.utf8.count + fileExtension.utf8.count <= maximumByteCount
        else { throw TallyFileNameError.tooLong }

        return name
    }

    static func fileName(from input: String) throws -> String {
        try baseName(from: input) + fileExtension
    }
}
