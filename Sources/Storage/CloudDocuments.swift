import Foundation
import Observation

@MainActor
@Observable
final class CloudDocuments {
    nonisolated enum State: Equatable, Sendable {
        case available(URL)
        case unavailable
        case failed(String)
    }

    static let shared = CloudDocuments()

    private(set) var state: State = .unavailable
    private(set) var isPreparing = false

    @ObservationIgnored private var preparationID = UUID()
    @ObservationIgnored private var identityObserver: NSObjectProtocol?
    nonisolated private static let containerIdentifier = "iCloud.com.asherbloom.Tally"

    private init() { }

    var documentsURL: URL? {
        guard case .available(let url) = state else { return nil }
        return url
    }

    var statusDescription: String {
        if isPreparing { return "Checking iCloud Drive…" }
        switch state {
        case .available:
            return "Documents in iCloud Drive’s Tally folder stay up to date across your devices."
        case .unavailable:
            return "iCloud Drive is unavailable. Check your iCloud settings or choose another location."
        case .failed:
            return "Tally couldn’t open its iCloud Drive folder. Try again or choose another location."
        }
    }

    /// Start once from the app initializer, including launches with no open document.
    func start() {
        guard identityObserver == nil else { return }
        // The shared singleton retains this observer for the app's lifetime.
        identityObserver = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                await CloudDocuments.shared.prepare()
            }
        }
        Task { await prepare() }
    }

    func prepare() async {
        let requestID = UUID()
        preparationID = requestID
        isPreparing = true
        // An account change invalidates any previously resolved container URL.
        state = .unavailable

        let result = await Task.detached(priority: .utility) {
            Self.resolveDocumentsDirectory()
        }.value

        // A later account check owns the state if requests overlap.
        guard preparationID == requestID else { return }
        state = result
        isPreparing = false
    }

    nonisolated private static func resolveDocumentsDirectory() -> State {
        let fileManager = FileManager.default
        guard let containerURL = fileManager.url(
            forUbiquityContainerIdentifier: containerIdentifier
        ) else {
            return .unavailable
        }

        let documentsURL = containerURL.appendingPathComponent("Documents", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: documentsURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            return .available(documentsURL)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
