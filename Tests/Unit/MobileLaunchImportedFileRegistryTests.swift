#if DEBUG && os(iOS)
import Foundation
import Testing
@testable import Tally

nonisolated struct MobileLaunchImportedFileRegistryTests {
    @Test func cleanupRemovesOnlyAnUnchangedRecordedCopy() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let copied = try fixture.copyToDocuments("Launch-B 2.tally")
        let unrelated = fixture.documents.appendingPathComponent("Unrelated.tally")
        try Data("unrelated file".utf8).write(to: unrelated)
        try fixture.record(copied)
        try fixture.cleanup()
        #expect(!FileManager.default.fileExists(atPath: copied.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    @Test func changingAnImportedFilePreventsItsRemoval() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let copied = try fixture.copyToDocuments("Launch-B.tally")
        try fixture.record(copied)
        let changed = Data("changed after import".utf8)
        try changed.write(to: copied)
        #expect(throws: MobileLaunchImportedFileRegistry.RegistryError.self) { try fixture.cleanup() }
        #expect(try Data(contentsOf: copied) == changed)
    }

    @Test func aDifferentFileCannotBeClaimedAsAnImport() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let unrelated = fixture.documents.appendingPathComponent("Launch-B.tally")
        try Data("not the source fixture".utf8).write(to: unrelated)
        #expect(throws: MobileLaunchImportedFileRegistry.RegistryError.self) { try fixture.record(unrelated) }
        try fixture.cleanup()
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func destinationsOutsideTheOwnedDocumentsDirectoryAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.base.appendingPathComponent("Outside.tally")
        try FileManager.default.copyItem(at: fixture.source, to: outside)
        #expect(throws: MobileLaunchImportedFileRegistry.RegistryError.self) { try fixture.record(outside) }
        let link = fixture.documents.appendingPathComponent("Link.tally")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: MobileLaunchImportedFileRegistry.RegistryError.self) { try fixture.record(link) }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func aRecordedImportThatWasAlreadyRemovedDoesNotPreventCleanup() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let copied = try fixture.copyToDocuments("Launch-B.tally")
        try fixture.record(copied)
        try FileManager.default.removeItem(at: copied)
        try fixture.cleanup()
        #expect(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    private struct Fixture {
        let base: URL
        let root: URL
        let documents: URL
        var source: URL { root.appendingPathComponent("Launch-B.tally") }

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("TallyImportRegistryUnit-\(UUID().uuidString)", isDirectory: true)
                .resolvingSymlinksInPath()
            root = base.appendingPathComponent("Fixtures", isDirectory: true)
            documents = base.appendingPathComponent("Documents", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            try Data("synthetic fixture \(UUID().uuidString)".utf8).write(to: root.appendingPathComponent("Launch-B.tally"))
        }

        func copyToDocuments(_ name: String) throws -> URL {
            let destination = documents.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        }

        func record(_ destination: URL) throws {
            try MobileLaunchImportedFileRegistry.record(source: source, destination: destination, fixtureRoot: root, documentsRoot: documents)
        }

        func cleanup() throws {
            try MobileLaunchImportedFileRegistry.removeRecordedImports(fixtureRoot: root, documentsRoot: documents)
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }
}
#endif
