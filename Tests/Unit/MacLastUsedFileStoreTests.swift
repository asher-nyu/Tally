#if os(macOS)
import Foundation
import Testing
@testable import Tally

nonisolated struct MacLastUsedFileStoreTests {
    @Test func genuineBookmarkPersistsAcrossStoreInstancesWithoutReadingDocumentContents() throws {
        let fixture = try LastFileFixture()
        defer { fixture.cleanUp() }
        let file = try fixture.makeFile("Last file.tally")
        let store = MacLastUsedFileStore(defaults: fixture.defaults)

        try store.remember(file)

        let bookmark = try #require(fixture.defaults.data(forKey: MacLastUsedFileStore.bookmarkKey))
        #expect(!bookmark.isEmpty)
        #expect(bookmark.range(of: LastFileFixture.contents) == nil)
        let newStore = MacLastUsedFileStore(defaults: fixture.defaults)
        let resolved = try #require(try newStore.resolve())
        defer { resolved.stopAccessing() }
        #expect(sameFile(resolved.url, file))
        #expect(try Data(contentsOf: file) == LastFileFixture.contents)
    }

    @Test func genuineBookmarkFollowsAFileRenameAndMove() throws {
        let fixture = try LastFileFixture()
        defer { fixture.cleanUp() }
        let original = try fixture.makeFile("Before.tally")
        let store = MacLastUsedFileStore(defaults: fixture.defaults)
        try store.remember(original)
        let folder = fixture.directory.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let renamed = folder.appendingPathComponent("After.tally")
        try FileManager.default.moveItem(at: original, to: renamed)

        let resolved = try #require(try store.resolve())
        defer { resolved.stopAccessing() }
        #expect(sameFile(resolved.url, renamed))
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(try Data(contentsOf: renamed) == LastFileFixture.contents)
        let reopened = try #require(try MacLastUsedFileStore(defaults: fixture.defaults).resolve())
        defer { reopened.stopAccessing() }
        #expect(sameFile(reopened.url, renamed))
    }

    @Test func permanentlyDeletedGenuineBookmarkCannotReturnAnOpenableFile() throws {
        let fixture = try LastFileFixture()
        defer { fixture.cleanUp() }
        let file = try fixture.makeFile("Deleted.tally")
        let store = MacLastUsedFileStore(defaults: fixture.defaults)
        try store.remember(file)
        try FileManager.default.removeItem(at: file)

        // Foundation can either reject the bookmark itself or resolve its old
        // path. Neither outcome may produce a usable file lease.
        let resolved = try? store.resolve()
        #expect(resolved == nil)
        #expect(fixture.defaults.data(forKey: MacLastUsedFileStore.bookmarkKey) != nil)
    }

    @Test func movingAGenuineBookmarkToAnIsolatedTrashRejectsItWithoutDeletingIt() throws {
        let fixture = try LastFileFixture()
        defer { fixture.cleanUp() }
        let file = try fixture.makeFile("Discarded.tally")
        let trash = fixture.directory.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        var dependencies = MacLastUsedFileStore.Dependencies.live
        dependencies.inspect = { MacDocumentLifetimeInspection.inspect($0, trashDirectory: trash) }
        let store = MacLastUsedFileStore(defaults: fixture.defaults, dependencies: dependencies)
        try store.remember(file)
        let discarded = trash.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.moveItem(at: file, to: discarded)

        #expect(try store.resolve() == nil)
        #expect(FileManager.default.fileExists(atPath: discarded.path))
        #expect(fixture.defaults.data(forKey: MacLastUsedFileStore.bookmarkKey) != nil)
    }

    @Test func aDirectoryWithATallySuffixCannotBeRememberedOrResolvedAsAFile() throws {
        let fixture = try LastFileFixture()
        defer { fixture.cleanUp() }
        let directory = fixture.directory.appendingPathComponent("Directory.tally", isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let store = MacLastUsedFileStore(defaults: fixture.defaults)
        #expect(throws: MacLastUsedFileStore.StoreError.unavailableFile) { try store.remember(directory) }
        #expect(fixture.defaults.data(forKey: MacLastUsedFileStore.bookmarkKey) == nil)

        let system = FakeLastFileSystem(url: directory)
        fixture.defaults.set(Data("directory bookmark".utf8), forKey: MacLastUsedFileStore.bookmarkKey)
        #expect(try system.store(defaults: fixture.defaults).resolve() == nil)
        #expect(system.startCount == 1 && system.stopCount == 1)
    }

    @Test func unsupportedURLsNeverReplaceThePreviousBookmarkOrStartAccess() throws {
        let fixture = try LastFileFixture()
        defer { fixture.cleanUp() }
        let system = FakeLastFileSystem(url: fixture.directory.appendingPathComponent("Known.tally"))
        let store = system.store(defaults: fixture.defaults)
        let previous = Data("previous selection".utf8)
        fixture.defaults.set(previous, forKey: MacLastUsedFileStore.bookmarkKey)
        for url in [URL(string: "https://example.invalid/File.tally")!, fixture.directory.appendingPathComponent("Other.txt")] {
            #expect(throws: MacLastUsedFileStore.StoreError.unsupportedFile) { try store.remember(url) }
        }
        #expect(system.startCount == 0)
        #expect(system.makeCount == 0)
        #expect(fixture.defaults.data(forKey: MacLastUsedFileStore.bookmarkKey) == previous)
    }

    @Test(arguments: [MacDocumentLifetimePolicy.FileState.missing, .inTrash])
    func unavailableSelectionsAreRejectedAndTheirTemporaryAccessIsBalanced(_ state: MacDocumentLifetimePolicy.FileState) throws {
        let fixture = try LastFileFixture()
        defer { fixture.cleanUp() }
        let system = FakeLastFileSystem(url: fixture.directory.appendingPathComponent("Unavailable.tally"))
        system.state = state
        let store = system.store(defaults: fixture.defaults)

        #expect(throws: MacLastUsedFileStore.StoreError.unavailableFile) { try store.remember(system.url) }
        #expect(system.makeCount == 0)
        #expect(system.startCount == 1)
        #expect(system.stopCount == 1)
        #expect(fixture.defaults.data(forKey: MacLastUsedFileStore.bookmarkKey) == nil)
    }

    @Test(arguments: [MacDocumentLifetimePolicy.FileState.evicted, .unknown])
    func cloudEvictionAndInconclusiveMetadataAreLeftForDocumentOpening(_ state: MacDocumentLifetimePolicy.FileState) throws {
        let fixture = try LastFileFixture()
        defer { fixture.cleanUp() }
        let system = FakeLastFileSystem(url: fixture.directory.appendingPathComponent("Cloud.tally"))
        system.state = state
        let store = system.store(defaults: fixture.defaults)
        try store.remember(system.url)

        let resolved = try #require(try store.resolve())
        #expect(resolved.url == system.url)
        #expect(resolved.startedSecurityScope)
        resolved.stopAccessing()
        #expect(system.startCount == 2)
        #expect(system.stopCount == 2)
    }

    @Test func staleBookmarkIsRefreshedWhileItsResolvedScopeIsActive() throws {
        let fixture = try LastFileFixture()
        defer { fixture.cleanUp() }
        let system = FakeLastFileSystem(url: fixture.directory.appendingPathComponent("Renamed.tally"))
        system.isStale = true
        fixture.defaults.set(Data("stale".utf8), forKey: MacLastUsedFileStore.bookmarkKey)
        let resolved = try #require(try system.store(defaults: fixture.defaults).resolve())

        #expect(system.makeCount == 1)
        #expect(system.scopeWasActiveWhileMakingBookmark)
        #expect(fixture.defaults.data(forKey: MacLastUsedFileStore.bookmarkKey) == system.createdData)
        #expect(system.stopCount == 0)
        resolved.stopAccessing()
        #expect(system.stopCount == 1)
    }

    @Test func corruptBookmarkDoesNotStartAccessOrEraseTheStoredSelection() throws {
        let fixture = try LastFileFixture()
        defer { fixture.cleanUp() }
        let data = Data("not a Foundation bookmark".utf8)
        fixture.defaults.set(data, forKey: MacLastUsedFileStore.bookmarkKey)
        let store = MacLastUsedFileStore(defaults: fixture.defaults)

        #expect(throws: (any Error).self) { _ = try store.resolve() }
        #expect(fixture.defaults.data(forKey: MacLastUsedFileStore.bookmarkKey) == data)
    }

    @Test func staleRefreshFailureReleasesAccessAndPreservesTheOldBookmark() throws {
        let fixture = try LastFileFixture()
        defer { fixture.cleanUp() }
        let system = FakeLastFileSystem(url: fixture.directory.appendingPathComponent("Known.tally"))
        system.isStale = true
        system.failCreation = true
        let previous = Data("stale but retained".utf8)
        fixture.defaults.set(previous, forKey: MacLastUsedFileStore.bookmarkKey)

        #expect(throws: FakeLastFileSystem.TestError.creationFailed) { _ = try system.store(defaults: fixture.defaults).resolve() }
        #expect(system.startCount == 1)
        #expect(system.stopCount == 1)
        #expect(fixture.defaults.data(forKey: MacLastUsedFileStore.bookmarkKey) == previous)
    }

    @Test func rememberFailureRetainsThePreviousSelectionAndBalancesAccess() throws {
        let fixture = try LastFileFixture()
        defer { fixture.cleanUp() }
        let system = FakeLastFileSystem(url: fixture.directory.appendingPathComponent("Known.tally"))
        system.failCreation = true
        let previous = Data("previous".utf8)
        fixture.defaults.set(previous, forKey: MacLastUsedFileStore.bookmarkKey)

        #expect(throws: FakeLastFileSystem.TestError.creationFailed) { try system.store(defaults: fixture.defaults).remember(system.url) }
        #expect(system.startCount == 1 && system.stopCount == 1)
        #expect(fixture.defaults.data(forKey: MacLastUsedFileStore.bookmarkKey) == previous)
    }

    @Test(arguments: [MacDocumentLifetimePolicy.FileState.missing, .inTrash])
    func rejectedResolvedTargetsReleaseTheirScope(_ state: MacDocumentLifetimePolicy.FileState) throws {
        let fixture = try LastFileFixture()
        defer { fixture.cleanUp() }
        let system = FakeLastFileSystem(url: fixture.directory.appendingPathComponent("Removed.tally"))
        system.state = state
        fixture.defaults.set(Data("bookmark".utf8), forKey: MacLastUsedFileStore.bookmarkKey)

        #expect(try system.store(defaults: fixture.defaults).resolve() == nil)
        #expect(system.startCount == 1 && system.stopCount == 1)
    }

    @Test func unsupportedResolvedTargetIsRejectedBeforeStartingAccess() throws {
        let fixture = try LastFileFixture()
        defer { fixture.cleanUp() }
        let system = FakeLastFileSystem(url: fixture.directory.appendingPathComponent("Renamed.txt"))
        fixture.defaults.set(Data("bookmark".utf8), forKey: MacLastUsedFileStore.bookmarkKey)

        #expect(try system.store(defaults: fixture.defaults).resolve() == nil)
        #expect(system.startCount == 0)
    }

    @Test func scopeReleaseIsExactlyOnceAcrossConcurrentCallsAndDeinitialization() throws {
        let fixture = try LastFileFixture()
        defer { fixture.cleanUp() }
        let system = FakeLastFileSystem(url: fixture.directory.appendingPathComponent("Scoped.tally"))
        fixture.defaults.set(Data("bookmark".utf8), forKey: MacLastUsedFileStore.bookmarkKey)
        do {
            let resolved = try #require(try system.store(defaults: fixture.defaults).resolve())
            #expect(resolved.startedSecurityScope)
            DispatchQueue.concurrentPerform(iterations: 50) { _ in resolved.stopAccessing() }
        }
        #expect(system.startCount == 1)
        #expect(system.stopCount == 1)
        #expect(fixture.defaults.data(forKey: MacLastUsedFileStore.bookmarkKey) != nil)
    }

    @Test func deinitializingAnUnreleasedLeaseBalancesItsScope() throws {
        let fixture = try LastFileFixture()
        defer { fixture.cleanUp() }
        let system = FakeLastFileSystem(url: fixture.directory.appendingPathComponent("Scoped.tally"))
        fixture.defaults.set(Data("bookmark".utf8), forKey: MacLastUsedFileStore.bookmarkKey)
        var resolved = try system.store(defaults: fixture.defaults).resolve()
        #expect(resolved?.startedSecurityScope == true)
        resolved = nil
        #expect(system.stopCount == 1)
    }

    @Test func filesWithoutANewSecurityScopeAreNotStopped() throws {
        let fixture = try LastFileFixture()
        defer { fixture.cleanUp() }
        let system = FakeLastFileSystem(url: fixture.directory.appendingPathComponent("Container.tally"))
        system.startsScope = false
        fixture.defaults.set(Data("bookmark".utf8), forKey: MacLastUsedFileStore.bookmarkKey)
        let resolved = try #require(try system.store(defaults: fixture.defaults).resolve())
        #expect(!resolved.startedSecurityScope)
        resolved.stopAccessing()
        #expect(system.stopCount == 0)
    }

    @Test func clearOnlyRemovesTheBookmarkAndDoesNotEraseAnOpenLease() throws {
        let fixture = try LastFileFixture()
        defer { fixture.cleanUp() }
        let system = FakeLastFileSystem(url: fixture.directory.appendingPathComponent("Open.tally"))
        let store = system.store(defaults: fixture.defaults)
        fixture.defaults.set(Data("bookmark".utf8), forKey: MacLastUsedFileStore.bookmarkKey)
        fixture.defaults.set("kept", forKey: "unrelatedPreference")
        let resolved = try #require(try store.resolve())

        store.clear()

        #expect(try store.resolve() == nil)
        #expect(fixture.defaults.string(forKey: "unrelatedPreference") == "kept")
        #expect(system.stopCount == 0)
        resolved.stopAccessing()
        #expect(system.stopCount == 1)
    }

    private func sameFile(_ first: URL, _ second: URL) -> Bool {
        first.standardizedFileURL.resolvingSymlinksInPath() == second.standardizedFileURL.resolvingSymlinksInPath()
    }
}

nonisolated private struct LastFileFixture {
    static let contents = Data("Isolated opaque fixture content; no financial records are used.".utf8)
    let directory: URL
    let suiteName: String
    let defaults: UserDefaults

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TallyLastFile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        suiteName = "com.asherbloom.Tally.tests.lastFile.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    func makeFile(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Self.contents.write(to: url)
        return url
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

nonisolated private final class FakeLastFileSystem: @unchecked Sendable {
    enum TestError: Error, Equatable { case creationFailed }

    let url: URL
    let createdData = Data("refreshed scope bookmark".utf8)
    var state: MacDocumentLifetimePolicy.FileState = .present
    var isStale = false
    var failCreation = false
    var startsScope = true
    var makeCount = 0
    var startCount = 0
    var scopeWasActiveWhileMakingBookmark = false
    private let lock = NSLock()
    private var stopped = 0
    var stopCount: Int { lock.withLock { stopped } }

    init(url: URL) { self.url = url }

    func store(defaults: UserDefaults) -> MacLastUsedFileStore {
        MacLastUsedFileStore(defaults: defaults, dependencies: .init(
            makeBookmark: { [self] _ in
                makeCount += 1
                scopeWasActiveWhileMakingBookmark = startCount > stopCount
                if failCreation { throw TestError.creationFailed }
                return createdData
            },
            resolveBookmark: { [self] _ in
                .init(url: url, isStale: isStale)
            },
            inspect: { [self] _ in state },
            startAccessing: { [self] _ in
                startCount += 1
                return startsScope
            },
            stopAccessing: { [self] _ in lock.withLock { stopped += 1 } }
        ))
    }
}
#endif
