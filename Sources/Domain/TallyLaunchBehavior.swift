nonisolated enum TallyLaunchBehavior: String, CaseIterable {
    case lastUsedFile
    case fileBrowser

    static let preferenceKey = "launchBehavior"

    var title: String {
        switch self {
        case .lastUsedFile: "Open last used file"
        case .fileBrowser: "Show file browser"
        }
    }
}

