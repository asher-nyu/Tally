#if os(macOS)
import Foundation

/// Retains access to the last opened file without reading or storing its contents.
/// The launch coordinator serializes remember, resolve, and clear operations.
nonisolated final class MacLastUsedFileStore: @unchecked Sendable {
    static let bookmarkKey = "lastUsedFileBookmark"

    enum StoreError: Error, Equatable {
        case unsupportedFile
        case unavailableFile
    }

    struct BookmarkResolution: Sendable {
        let url: URL
        let isStale: Bool
    }

    struct Dependencies: Sendable {
        var makeBookmark: @Sendable (URL) throws -> Data
        var resolveBookmark: @Sendable (Data) throws -> BookmarkResolution
        var inspect: @Sendable (URL) -> MacDocumentLifetimePolicy.FileState
        var startAccessing: @Sendable (URL) -> Bool
        var stopAccessing: @Sendable (URL) -> Void

        static let live = Dependencies(
            makeBookmark: {
                // Omitting allow-only-read-access preserves document editing.
                try $0.bookmarkData(options: [.withSecurityScope],
                                    includingResourceValuesForKeys: nil, relativeTo: nil)
            },
            resolveBookmark: { data in
                var stale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope, .withoutUI, .withoutMounting],
                    relativeTo: nil, bookmarkDataIsStale: &stale
                )
                return BookmarkResolution(url: url, isStale: stale)
            },
            inspect: { MacDocumentLifetimeInspection.inspect($0) },
            startAccessing: { $0.startAccessingSecurityScopedResource() },
            stopAccessing: { $0.stopAccessingSecurityScopedResource() }
        )
    }

    /// Keep this lease alive for as long as its reopened document needs access.
    /// Releasing it explicitly or through deinitialization balances the scope once.
    final class ResolvedFile: @unchecked Sendable {
        let url: URL
        let startedSecurityScope: Bool
        private let lock = NSLock()
        private var released = false
        private let stop: @Sendable (URL) -> Void

        fileprivate init(url: URL, startedSecurityScope: Bool, stop: @escaping @Sendable (URL) -> Void) {
            self.url = url
            self.startedSecurityScope = startedSecurityScope
            self.stop = stop
        }

        func stopAccessing() {
            let shouldStop = lock.withLock {
                guard startedSecurityScope, !released else { return false }
                released = true
                return true
            }
            if shouldStop { stop(url) }
        }

        deinit { stopAccessing() }
    }

    private let defaults: UserDefaults
    private let dependencies: Dependencies

    init(defaults: UserDefaults = .standard, dependencies: Dependencies = .live) {
        self.defaults = defaults
        self.dependencies = dependencies
    }

    func remember(_ url: URL) throws {
        guard Self.isSupported(url) else { throw StoreError.unsupportedFile }
        let started = dependencies.startAccessing(url)
        defer { if started { dependencies.stopAccessing(url) } }
        guard canOpen(url) else { throw StoreError.unavailableFile }
        // Replace the previous selection only after bookmark creation succeeds.
        let bookmark = try dependencies.makeBookmark(url)
        defaults.set(bookmark, forKey: Self.bookmarkKey)
    }

    func resolve() throws -> ResolvedFile? {
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        let resolved = try dependencies.resolveBookmark(data)
        guard Self.isSupported(resolved.url) else { return nil }
        let file = ResolvedFile(
            url: resolved.url,
            startedSecurityScope: dependencies.startAccessing(resolved.url),
            stop: dependencies.stopAccessing
        )
        guard canOpen(resolved.url) else {
            file.stopAccessing()
            return nil
        }
        if resolved.isStale {
            do {
                let refreshed = try dependencies.makeBookmark(resolved.url)
                defaults.set(refreshed, forKey: Self.bookmarkKey)
            } catch {
                file.stopAccessing()
                throw error
            }
        }
        return file
    }

    /// Used for an explicit reset, never merely because a document was closed.
    func clear() {
        defaults.removeObject(forKey: Self.bookmarkKey)
    }

    private static func isSupported(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == "tally"
    }

    private func canOpen(_ url: URL) -> Bool {
        // A directory can have a .tally suffix too. This metadata lookup does
        // not read file contents or demand a download from its cloud provider.
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return false }
        return switch dependencies.inspect(url) {
        case .present, .evicted, .unknown:
            // Metadata uncertainty and cloud eviction do not prove deletion.
            // NSDocument is responsible for access errors and downloading.
            true
        case .inTrash, .missing:
            false
        }
    }
}
#endif
