#if os(iOS)
import Foundation
import Testing
@testable import Tally

nonisolated struct MobileLastUsedFileStoreTests {
    @Test func genuineBookmarkPersistsAcrossStoreInstancesWithoutReadingDocumentContents() throws {
        let fixture = try MobileLastFileFixture()
        defer { fixture.cleanUp() }
        let file = try fixture.makeFile("Last file.tally")
        let store = MobileLastUsedFileStore(defaults: fixture.defaults)

        try store.remember(file)

        let bookmark = try #require(fixture.defaults.data(forKey: MobileLastUsedFileStore.bookmarkKey))
        #expect(!bookmark.isEmpty)
        #expect(bookmark.range(of: MobileLastFileFixture.contents) == nil)
        let newStore = MobileLastUsedFileStore(defaults: fixture.defaults)
        let resolved = try #require(try newStore.resolve())
        defer { resolved.stopAccessing() }
        #expect(sameFile(resolved.url, file))
        #expect(try Data(contentsOf: file) == MobileLastFileFixture.contents)
    }

    @Test func genuineBookmarkFollowsAFileRenameAndMove() throws {
        let fixture = try MobileLastFileFixture()
        defer { fixture.cleanUp() }
        let original = try fixture.makeFile("Before.tally")
        let store = MobileLastUsedFileStore(defaults: fixture.defaults)
        try store.remember(original)
        let folder = fixture.directory.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let renamed = folder.appendingPathComponent("After.tally")
        try FileManager.default.moveItem(at: original, to: renamed)

        let resolved = try #require(try store.resolve())
        defer { resolved.stopAccessing() }
        #expect(sameFile(resolved.url, renamed))
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(try Data(contentsOf: renamed) == MobileLastFileFixture.contents)
        let reopened = try #require(try MobileLastUsedFileStore(defaults: fixture.defaults).resolve())
        defer { reopened.stopAccessing() }
        #expect(sameFile(reopened.url, renamed))
    }

    @Test func permanentlyDeletedGenuineBookmarkCannotReturnAnOpenableFile() throws {
        let fixture = try MobileLastFileFixture()
        defer { fixture.cleanUp() }
        let file = try fixture.makeFile("Deleted.tally")
        let store = MobileLastUsedFileStore(defaults: fixture.defaults)
        try store.remember(file)
        try FileManager.default.removeItem(at: file)

        // Foundation can either reject the bookmark itself or resolve its old
        // path. Neither outcome may produce a usable file lease.
        let resolved = try? store.resolve()
        #expect(resolved == nil)
        #expect(fixture.defaults.data(forKey: MobileLastUsedFileStore.bookmarkKey) != nil)
    }

    @Test func movingAGenuineBookmarkToAnIsolatedTrashRejectsItWithoutDeletingIt() throws {
        let fixture = try MobileLastFileFixture()
        defer { fixture.cleanUp() }
        let file = try fixture.makeFile("Discarded.tally")
        let trash = fixture.directory.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        var dependencies = MobileLastUsedFileStore.Dependencies.live
        dependencies.inspect = { MobileFileAvailability.inspect($0) }
        let store = MobileLastUsedFileStore(defaults: fixture.defaults, dependencies: dependencies)
        try store.remember(file)
        let discarded = trash.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.moveItem(at: file, to: discarded)

        #expect(try store.resolve() == nil)
        #expect(FileManager.default.fileExists(atPath: discarded.path))
        #expect(fixture.defaults.data(forKey: MobileLastUsedFileStore.bookmarkKey) != nil)
    }

    @Test func aDirectoryWithATallySuffixCannotBeRememberedOrResolvedAsAFile() throws {
        let fixture = try MobileLastFileFixture()
        defer { fixture.cleanUp() }
        let directory = fixture.directory.appendingPathComponent("Directory.tally", isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let store = MobileLastUsedFileStore(defaults: fixture.defaults)
        #expect(throws: MobileLastUsedFileStore.StoreError.unavailableFile) { try store.remember(directory) }
        #expect(fixture.defaults.data(forKey: MobileLastUsedFileStore.bookmarkKey) == nil)

        let system = FakeMobileLastFileSystem(url: directory)
        fixture.defaults.set(Data("directory bookmark".utf8), forKey: MobileLastUsedFileStore.bookmarkKey)
        #expect(try system.store(defaults: fixture.defaults).resolve() == nil)
        #expect(system.startCount == 1 && system.stopCount == 1)
    }

    @Test func unsupportedURLsNeverReplaceThePreviousBookmarkOrStartAccess() throws {
        let fixture = try MobileLastFileFixture()
        defer { fixture.cleanUp() }
        let system = FakeMobileLastFileSystem(url: fixture.directory.appendingPathComponent("Known.tally"))
        let store = system.store(defaults: fixture.defaults)
        let previous = Data("previous selection".utf8)
        fixture.defaults.set(previous, forKey: MobileLastUsedFileStore.bookmarkKey)
        for url in [URL(string: "https://example.invalid/File.tally")!, fixture.directory.appendingPathComponent("Other.txt")] {
            #expect(throws: MobileLastUsedFileStore.StoreError.unsupportedFile) { try store.remember(url) }
        }
        #expect(system.startCount == 0)
        #expect(system.makeCount == 0)
        #expect(fixture.defaults.data(forKey: MobileLastUsedFileStore.bookmarkKey) == previous)
    }

    @Test(arguments: [MobileFileAvailability.removed, .inTrash])
    func unavailableSelectionsAreRejectedAndTheirTemporaryAccessIsBalanced(_ state: MobileFileAvailability) throws {
        let fixture = try MobileLastFileFixture()
        defer { fixture.cleanUp() }
        let system = FakeMobileLastFileSystem(url: fixture.directory.appendingPathComponent("Unavailable.tally"))
        system.state = state
        let store = system.store(defaults: fixture.defaults)

        #expect(throws: MobileLastUsedFileStore.StoreError.unavailableFile) { try store.remember(system.url) }
        #expect(system.makeCount == 0)
        #expect(system.startCount == 1)
        #expect(system.stopCount == 1)
        #expect(fixture.defaults.data(forKey: MobileLastUsedFileStore.bookmarkKey) == nil)
    }

    @Test(arguments: [MobileFileAvailability.unavailable, .available])
    func cloudEvictionAndInconclusiveMetadataAreLeftForDocumentOpening(_ state: MobileFileAvailability) throws {
        let fixture = try MobileLastFileFixture()
        defer { fixture.cleanUp() }
        let system = FakeMobileLastFileSystem(url: fixture.directory.appendingPathComponent("Cloud.tally"))
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
        let fixture = try MobileLastFileFixture()
        defer { fixture.cleanUp() }
        let system = FakeMobileLastFileSystem(url: fixture.directory.appendingPathComponent("Renamed.tally"))
        system.isStale = true
        fixture.defaults.set(Data("stale".utf8), forKey: MobileLastUsedFileStore.bookmarkKey)
        let resolved = try #require(try system.store(defaults: fixture.defaults).resolve())

        #expect(system.makeCount == 1)
        #expect(system.scopeWasActiveWhileMakingBookmark)
        #expect(fixture.defaults.data(forKey: MobileLastUsedFileStore.bookmarkKey) == system.createdData)
        #expect(system.stopCount == 0)
        resolved.stopAccessing()
        #expect(system.stopCount == 1)
    }

    @Test func corruptBookmarkDoesNotStartAccessOrEraseTheStoredSelection() throws {
        let fixture = try MobileLastFileFixture()
        defer { fixture.cleanUp() }
        let data = Data("not a Foundation bookmark".utf8)
        fixture.defaults.set(data, forKey: MobileLastUsedFileStore.bookmarkKey)
        let store = MobileLastUsedFileStore(defaults: fixture.defaults)

        #expect(throws: (any Error).self) { _ = try store.resolve() }
        #expect(fixture.defaults.data(forKey: MobileLastUsedFileStore.bookmarkKey) == data)
    }

    @Test func staleRefreshFailureReleasesAccessAndPreservesTheOldBookmark() throws {
        let fixture = try MobileLastFileFixture()
        defer { fixture.cleanUp() }
        let system = FakeMobileLastFileSystem(url: fixture.directory.appendingPathComponent("Known.tally"))
        system.isStale = true
        system.failCreation = true
        let previous = Data("stale but retained".utf8)
        fixture.defaults.set(previous, forKey: MobileLastUsedFileStore.bookmarkKey)

        #expect(throws: FakeMobileLastFileSystem.TestError.creationFailed) { _ = try system.store(defaults: fixture.defaults).resolve() }
        #expect(system.startCount == 1)
        #expect(system.stopCount == 1)
        #expect(fixture.defaults.data(forKey: MobileLastUsedFileStore.bookmarkKey) == previous)
    }

    @Test func rememberFailureRetainsThePreviousSelectionAndBalancesAccess() throws {
        let fixture = try MobileLastFileFixture()
        defer { fixture.cleanUp() }
        let system = FakeMobileLastFileSystem(url: fixture.directory.appendingPathComponent("Known.tally"))
        system.failCreation = true
        let previous = Data("previous".utf8)
        fixture.defaults.set(previous, forKey: MobileLastUsedFileStore.bookmarkKey)

        #expect(throws: FakeMobileLastFileSystem.TestError.creationFailed) { try system.store(defaults: fixture.defaults).remember(system.url) }
        #expect(system.startCount == 1 && system.stopCount == 1)
        #expect(fixture.defaults.data(forKey: MobileLastUsedFileStore.bookmarkKey) == previous)
    }

    @Test(arguments: [MobileFileAvailability.removed, .inTrash])
    func rejectedResolvedTargetsReleaseTheirScope(_ state: MobileFileAvailability) throws {
        let fixture = try MobileLastFileFixture()
        defer { fixture.cleanUp() }
        let system = FakeMobileLastFileSystem(url: fixture.directory.appendingPathComponent("Removed.tally"))
        system.state = state
        fixture.defaults.set(Data("bookmark".utf8), forKey: MobileLastUsedFileStore.bookmarkKey)

        #expect(try system.store(defaults: fixture.defaults).resolve() == nil)
        #expect(system.startCount == 1 && system.stopCount == 1)
    }

    @Test func unsupportedResolvedTargetIsRejectedBeforeStartingAccess() throws {
        let fixture = try MobileLastFileFixture()
        defer { fixture.cleanUp() }
        let system = FakeMobileLastFileSystem(url: fixture.directory.appendingPathComponent("Renamed.txt"))
        fixture.defaults.set(Data("bookmark".utf8), forKey: MobileLastUsedFileStore.bookmarkKey)

        #expect(try system.store(defaults: fixture.defaults).resolve() == nil)
        #expect(system.startCount == 0)
    }

    @Test func scopeReleaseIsExactlyOnceAcrossConcurrentCallsAndDeinitialization() throws {
        let fixture = try MobileLastFileFixture()
        defer { fixture.cleanUp() }
        let system = FakeMobileLastFileSystem(url: fixture.directory.appendingPathComponent("Scoped.tally"))
        fixture.defaults.set(Data("bookmark".utf8), forKey: MobileLastUsedFileStore.bookmarkKey)
        do {
            let resolved = try #require(try system.store(defaults: fixture.defaults).resolve())
            #expect(resolved.startedSecurityScope)
            DispatchQueue.concurrentPerform(iterations: 50) { _ in resolved.stopAccessing() }
        }
        #expect(system.startCount == 1)
        #expect(system.stopCount == 1)
        #expect(fixture.defaults.data(forKey: MobileLastUsedFileStore.bookmarkKey) != nil)
    }

    @Test func deinitializingAnUnreleasedLeaseBalancesItsScope() throws {
        let fixture = try MobileLastFileFixture()
        defer { fixture.cleanUp() }
        let system = FakeMobileLastFileSystem(url: fixture.directory.appendingPathComponent("Scoped.tally"))
        fixture.defaults.set(Data("bookmark".utf8), forKey: MobileLastUsedFileStore.bookmarkKey)
        var resolved = try system.store(defaults: fixture.defaults).resolve()
        #expect(resolved?.startedSecurityScope == true)
        resolved = nil
        #expect(system.stopCount == 1)
    }

    @Test func filesWithoutANewSecurityScopeAreNotStopped() throws {
        let fixture = try MobileLastFileFixture()
        defer { fixture.cleanUp() }
        let system = FakeMobileLastFileSystem(url: fixture.directory.appendingPathComponent("Container.tally"))
        system.startsScope = false
        fixture.defaults.set(Data("bookmark".utf8), forKey: MobileLastUsedFileStore.bookmarkKey)
        let resolved = try #require(try system.store(defaults: fixture.defaults).resolve())
        #expect(!resolved.startedSecurityScope)
        resolved.stopAccessing()
        #expect(system.stopCount == 0)
    }

    @Test func clearOnlyRemovesTheBookmarkAndDoesNotEraseAnOpenLease() throws {
        let fixture = try MobileLastFileFixture()
        defer { fixture.cleanUp() }
        let system = FakeMobileLastFileSystem(url: fixture.directory.appendingPathComponent("Open.tally"))
        let store = system.store(defaults: fixture.defaults)
        fixture.defaults.set(Data("bookmark".utf8), forKey: MobileLastUsedFileStore.bookmarkKey)
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

nonisolated private struct MobileLastFileFixture {
    static let contents = Data("Isolated opaque fixture content; no financial records are used.".utf8)
    let directory: URL
    let suiteName: String
    let defaults: UserDefaults

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TallyMobileLastFile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        suiteName = "com.asherbloom.Tally.tests.mobileLastFile.\(UUID().uuidString)"
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

nonisolated private final class FakeMobileLastFileSystem: @unchecked Sendable {
    enum TestError: Error, Equatable { case creationFailed }

    let url: URL
    let createdData = Data("refreshed scope bookmark".utf8)
    var state: MobileFileAvailability = .available
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

    func store(defaults: UserDefaults) -> MobileLastUsedFileStore {
        MobileLastUsedFileStore(defaults: defaults, dependencies: .init(
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
