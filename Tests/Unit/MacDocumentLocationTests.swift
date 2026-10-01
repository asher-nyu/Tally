#if os(macOS)
import Foundation
import Testing
@testable import Tally

nonisolated struct MacDocumentLocationTests {
    @Test func duplicateNamesNeverOverwriteExistingDocumentBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("Cash Flow.tally")
        let saved = Data("Existing financial document — preserve every byte.".utf8)
        try saved.write(to: existing)

        let first = try MacDocumentLocationReservation.reserve(in: directory)
        let firstMarker = try Data(contentsOf: first.url)
        let second = try MacDocumentLocationReservation.reserve(in: directory)

        #expect(first.url != existing)
        #expect(second.url != existing)
        #expect(first.url != second.url)
        #expect(first.url.pathExtension == "tally")
        #expect(second.url.pathExtension == "tally")
        #expect(try Data(contentsOf: existing) == saved)
        #expect(try Data(contentsOf: first.url) == firstMarker)
        #expect(try LedgerCodec.decode(firstMarker).expenses.isEmpty)
        #expect(try first.isUnused())
        #expect(try second.isUnused())
    }

    @Test func simultaneousReservationsHaveUniquePathsAndIndependentMarkers() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let count = 24
        let reservations = try await withThrowingTaskGroup(
            of: MacDocumentLocationReservation.self
        ) { group in
            for _ in 0..<count {
                group.addTask {
                    try MacDocumentLocationReservation.reserve(in: directory)
                }
            }
            var results: [MacDocumentLocationReservation] = []
            for try await reservation in group { results.append(reservation) }
            return results
        }

        #expect(reservations.count == count)
        #expect(Set(reservations.map(\.url)).count == count)
        let markers = try reservations.map { try Data(contentsOf: $0.url) }
        #expect(Set(markers).count == count)
        let ledgers = try markers.map { try LedgerCodec.decode($0) }
        #expect(ledgers.allSatisfy { $0.expenses.isEmpty })
        #expect(Set(ledgers.map(\.id)).count == count)
        for reservation in reservations {
            #expect(try reservation.isUnused())
            try reservation.removeIfUnused()
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func cleanupRemovesOnlyItsOwnUnusedReservation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try MacDocumentLocationReservation.reserve(in: directory)
        let second = try MacDocumentLocationReservation.reserve(in: directory)
        let secondMarker = try Data(contentsOf: second.url)

        try first.removeIfUnused()

        #expect(!FileManager.default.fileExists(atPath: first.url.path))
        #expect(try Data(contentsOf: second.url) == secondMarker)
        #expect(try second.isUnused())
        // Cancellation and teardown may both attempt cleanup.
        try first.removeIfUnused()
        #expect(try Data(contentsOf: second.url) == secondMarker)
    }

    @Test func staleReservationCannotRemoveANewerReservationAtTheSamePath() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stale = try MacDocumentLocationReservation.reserve(in: directory)
        let staleMarker = try Data(contentsOf: stale.url)
        try stale.removeIfUnused()
        let current = try MacDocumentLocationReservation.reserve(in: directory)
        let currentMarker = try Data(contentsOf: current.url)
        try #require(current.url == stale.url)
        #expect(currentMarker != staleMarker)

        #expect(try !stale.isUnused())
        try stale.removeIfUnused()

        #expect(try Data(contentsOf: current.url) == currentMarker)
        #expect(try current.isUnused())
    }

    @Test(arguments: [false, true])
    func cleanupPreservesSavedContentForInPlaceAndAtomicWrites(atomic: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reservation = try MacDocumentLocationReservation.reserve(in: directory)
        let saved = try LedgerCodec.encode(Ledger(expenses: [
            Expense(merchant: "Saved payment", amountMinor: 12345, billingDay: 15)
        ]))
        try saved.write(to: reservation.url, options: atomic ? .atomic : [])

        #expect(try !reservation.isUnused())
        try reservation.removeIfUnused()

        #expect(try Data(contentsOf: reservation.url) == saved)
        #expect(try LedgerCodec.decode(Data(contentsOf: reservation.url)).expenses.count == 1)
    }

    @Test func cleanupComparesContentEvenWhenTheFileSizeStillMatches() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reservation = try MacDocumentLocationReservation.reserve(in: directory)
        var changed = try Data(contentsOf: reservation.url)
        try #require(!changed.isEmpty)
        changed[changed.startIndex] ^= 0x01
        try changed.write(to: reservation.url)

        #expect(try !reservation.isUnused())
        try reservation.removeIfUnused()

        #expect(try Data(contentsOf: reservation.url) == changed)
    }

    @Test func occupiedDirectoriesAndSymbolicLinksAreNotReplaced() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = FileManager.default
        let occupiedDirectory = directory.appendingPathComponent("Household.tally", isDirectory: true)
        try manager.createDirectory(at: occupiedDirectory, withIntermediateDirectories: false)
        let nested = occupiedDirectory.appendingPathComponent("keep.txt")
        let saved = Data("Keep existing contents".utf8)
        try saved.write(to: nested)
        let linked = directory.appendingPathComponent("Household 2.tally")
        try manager.createSymbolicLink(at: linked, withDestinationURL: nested)
        let dangling = directory.appendingPathComponent("Household 3.tally")
        let absentTarget = directory.appendingPathComponent("absent-target")
        try manager.createSymbolicLink(at: dangling, withDestinationURL: absentTarget)

        let reservation = try MacDocumentLocationReservation.reserve(in: directory, baseName: "Household")

        #expect(![occupiedDirectory, linked, dangling].contains(reservation.url))
        #expect(try Data(contentsOf: nested) == saved)
        #expect(try manager.destinationOfSymbolicLink(atPath: linked.path) == nested.path)
        #expect(try manager.destinationOfSymbolicLink(atPath: dangling.path) == absentTarget.path)
        #expect(!manager.fileExists(atPath: absentTarget.path))
        #expect(try reservation.isUnused())
    }

    @Test func invalidDestinationFailsWithoutChangingExistingFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blockedParent = directory.appendingPathComponent("ordinary-file")
        let saved = Data("Not a directory; must not be replaced.".utf8)
        try saved.write(to: blockedParent)

        #expect(throws: (any Error).self) {
            try MacDocumentLocationReservation.reserve(in: blockedParent)
        }
        #expect(try Data(contentsOf: blockedParent) == saved)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["ordinary-file"])

        let missingParent = directory.appendingPathComponent("missing", isDirectory: true)
        #expect(throws: (any Error).self) {
            try MacDocumentLocationReservation.reserve(in: missingParent)
        }
        #expect(!FileManager.default.fileExists(atPath: missingParent.path))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tally-MacDocumentLocationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
#endif
