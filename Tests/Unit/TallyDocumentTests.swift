import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Tally

@MainActor
struct TallyDocumentTests {
    @Test func addingAnEntrySupportsUndoAndRedo() {
        let initial = Ledger()
        let document = TallyDocument(ledger: initial)
        let undo = makeUndoManager()
        let entry = Expense(merchant: "Fictional salary", amountMinor: 250_000, billingDay: 1, category: .income, kind: .income)

        performUndoableChange(undo) { document.updateExpense(entry, undoManager: undo) }
        #expect(document.ledger.expenses == [entry])
        #expect(undo.canUndo)
        undo.undo()
        #expect(document.ledger == initial)
        #expect(undo.canRedo)
        undo.redo()
        #expect(document.ledger.expenses == [entry])
        #expect(document.ledger.id == initial.id)
    }

    @Test func editingAnEntryRestoresAllFieldsAndPosition() {
        let initial = Ledger(expenses: [
            Expense(merchant: "Fictional first entry", amountMinor: 120_000, billingDay: 2, category: .housing),
            Expense(merchant: "Fictional second entry", amountMinor: nil, notes: "Variable amount")
        ])
        let document = TallyDocument(ledger: initial)
        let undo = makeUndoManager()
        var edited = initial.expenses[0]
        edited.merchant = "Fictional revised entry"
        edited.amountMinor = 130_000
        edited.billingDay = 3
        edited.category = .income
        edited.kind = .income
        edited.notes = "Changed locally"

        performUndoableChange(undo) { document.updateExpense(edited, undoManager: undo) }
        #expect(document.ledger.expenses == [edited, initial.expenses[1]])
        undo.undo()
        #expect(document.ledger == initial)
        undo.redo()
        #expect(document.ledger.expenses == [edited, initial.expenses[1]])
    }

    @Test func deletingMultipleEntriesRestoresTheirOrderOnUndo() {
        let initial = Ledger(expenses: (1...4).map { Expense(merchant: "Fictional entry \($0)", amountMinor: Int64($0 * 100)) })
        let document = TallyDocument(ledger: initial)
        let undo = makeUndoManager()
        let deletedIDs = Set([initial.expenses[0].id, initial.expenses[2].id])

        performUndoableChange(undo) { document.deleteExpenses(ids: deletedIDs, undoManager: undo) }
        #expect(document.ledger.expenses == [initial.expenses[1], initial.expenses[3]])
        undo.undo()
        #expect(document.ledger == initial)
        undo.redo()
        #expect(document.ledger.expenses == [initial.expenses[1], initial.expenses[3]])
    }

    @Test func unchangedOperationsDoNotCreateUndoActions() {
        let initial = Ledger(expenses: [Expense(merchant: "Fictional entry")])
        let document = TallyDocument(ledger: initial)
        let undo = makeUndoManager()
        // With event grouping disabled, unchanged operations need no undo group.
        // Opening an empty explicit group can itself produce an undo action.
        document.updateExpense(initial.expenses[0], undoManager: undo)
        document.deleteExpenses(ids: [UUID()], undoManager: undo)
        #expect(document.ledger == initial)
        #expect(!undo.canUndo)
    }

    @Test func snapshotIsAnIndependentValue() async throws {
        let initial = Ledger(expenses: [Expense(merchant: "Fictional saved entry", amountMinor: 123_456)])
        let document = TallyDocument(ledger: initial)
        let captured = try await document.snapshot(contentType: .tallyDocument)
        document.updateExpense(Expense(merchant: "Fictional later entry"), undoManager: nil)
        #expect(captured == initial)
        #expect(document.ledger.expenses.count == 2)
        #expect(try LedgerCodec.decode(LedgerCodec.encode(captured)) == initial)
    }

    @Test func initialSnapshotReplacesTheNewDocument() async throws {
        let document = TallyDocument()
        let incoming = Ledger(currencyCode: "EUR", expenses: [Expense(merchant: "Fictional opened entry", amountMinor: 500)])
        try await document.apply(snapshot: incoming, previous: nil)
        #expect(document.ledger == incoming)
    }

    @Test func incomingSnapshotUpdatesAnUnchangedDocument() async throws {
        let initial = Ledger(expenses: [Expense(merchant: "Fictional entry", amountMinor: 100)])
        let document = TallyDocument(ledger: initial)
        var incoming = initial
        incoming.expenses[0].amountMinor = 200
        try await document.apply(snapshot: incoming, previous: initial)
        #expect(document.ledger == incoming)
    }

    @Test func applyingIncomingSnapshotMergesIndependentEdits() async throws {
        let initial = twoEntryLedger()
        let document = TallyDocument(ledger: initial)
        var localEntry = initial.expenses[0]
        localEntry.amountMinor = 150
        document.updateExpense(localEntry, undoManager: nil)
        var incoming = initial
        incoming.expenses[1].amountMinor = 250
        let remoteAddition = Expense(merchant: "Fictional remote addition", amountMinor: 300)
        incoming.expenses.append(remoteAddition)

        try await document.apply(snapshot: incoming, previous: initial)
        #expect(document.ledger.expenses == [localEntry, incoming.expenses[1], remoteAddition])
    }

    @Test func applyingCompetingEditsRetainsBothValues() async throws {
        let initial = Ledger(expenses: [Expense(merchant: "Fictional entry", amountMinor: 100)])
        let document = TallyDocument(ledger: initial)
        var localEntry = initial.expenses[0]
        localEntry.amountMinor = 200
        document.updateExpense(localEntry, undoManager: nil)
        var incoming = initial
        incoming.expenses[0].amountMinor = 300

        try await document.apply(snapshot: incoming, previous: initial)
        let rows = document.ledger.expenses
        #expect(rows.count == 2)
        #expect(rows.first == localEntry)
        #expect(rows.last?.amountMinor == 300)
        #expect(rows.last?.merchant.hasSuffix(" (conflicting copy)") == true)
        #expect(rows.first?.id != rows.last?.id)
    }

    @Test func rejectedMergeLeavesTheCurrentDocumentIntact() async {
        let initial = twoEntryLedger()
        let document = TallyDocument(ledger: initial)
        var edited = initial.expenses[0]
        edited.amountMinor = 150
        document.updateExpense(edited, undoManager: nil)
        let current = document.ledger
        var incompatible = initial
        incompatible.currencyCode = "EUR"

        await #expect(throws: LedgerMergeError.differentCurrencies) {
            try await document.apply(snapshot: incompatible, previous: initial)
        }
        #expect(document.ledger == current)
    }

    @Test(arguments: [true, false])
    func repeatedConflictPreservesEditsToAnExistingConflictCopy(editCopyRemotely: Bool) async throws {
        let initial = Ledger(expenses: [Expense(merchant: "Fictional entry", amountMinor: 100)])
        var firstLocal = initial
        firstLocal.expenses[0].amountMinor = 200
        var firstRemote = initial
        firstRemote.expenses[0].amountMinor = 300
        let base = try LedgerMerger.merge(base: initial, local: firstLocal, remote: firstRemote)
        #expect(base.expenses.count == 2)
        let document = TallyDocument(ledger: base)
        var localEntry = base.expenses[0]
        localEntry.amountMinor = 400
        document.updateExpense(localEntry, undoManager: nil)
        var incoming = base
        incoming.expenses[0].amountMinor = 300
        var editedCopy = base.expenses[1]
        editedCopy.notes = "An edit to the existing conflict copy"
        if editCopyRemotely {
            incoming.expenses[1] = editedCopy
        } else {
            document.updateExpense(editedCopy, undoManager: nil)
        }

        try await document.apply(snapshot: incoming, previous: base)

        #expect(document.ledger.expenses.first { $0.id == localEntry.id } == localEntry)
        #expect(document.ledger.expenses.first { $0.id == editedCopy.id } == editedCopy)
        // The newly competing value also survives under a fresh, stable ID.
        #expect(document.ledger.expenses.contains {
            $0.id != incoming.expenses[1].id && $0.amountMinor == 300 && $0.notes.isEmpty
        })
        try LedgerCodec.validate(document.ledger)
    }

    @Test func undoingLocalAdditionPreservesAnIncomingAddition() async throws {
        let initial = Ledger()
        let document = TallyDocument(ledger: initial)
        let undo = makeUndoManager()
        let localEntry = Expense(merchant: "Fictional local addition", amountMinor: 100)
        performUndoableChange(undo) { document.updateExpense(localEntry, undoManager: undo) }
        var incoming = initial
        let remoteEntry = Expense(merchant: "Fictional incoming addition", amountMinor: 200)
        incoming.expenses = [remoteEntry]
        try await document.apply(snapshot: incoming, previous: initial)

        undo.undo()
        #expect(document.ledger.expenses == [remoteEntry])
        undo.redo()
        #expect(Set(document.ledger.expenses.map(\.id)) == [localEntry.id, remoteEntry.id])
        #expect(document.ledger.expenses.first { $0.id == remoteEntry.id } == remoteEntry)
    }

    @Test func undoingLocalEditPreservesUnrelatedIncomingChanges() async throws {
        let initial = twoEntryLedger()
        let document = TallyDocument(ledger: initial)
        let undo = makeUndoManager()
        var localEntry = initial.expenses[0]
        localEntry.amountMinor = 150
        performUndoableChange(undo) { document.updateExpense(localEntry, undoManager: undo) }
        var incoming = initial
        incoming.expenses[1].amountMinor = 250
        incoming.expenses.append(Expense(merchant: "Fictional incoming addition", amountMinor: 300))
        try await document.apply(snapshot: incoming, previous: initial)

        undo.undo()
        #expect(document.ledger.expenses == incoming.expenses)
        undo.redo()
        #expect(document.ledger.expenses == [localEntry, incoming.expenses[1], incoming.expenses[2]])
    }

    @Test func undoingLocalDeletionPreservesAnIncomingEdit() async throws {
        let initial = twoEntryLedger()
        let document = TallyDocument(ledger: initial)
        let undo = makeUndoManager()
        performUndoableChange(undo) { document.deleteExpenses(ids: [initial.expenses[0].id], undoManager: undo) }
        var incoming = initial
        incoming.expenses[1].amountMinor = 250
        try await document.apply(snapshot: incoming, previous: initial)

        undo.undo()
        #expect(document.ledger.expenses.count == incoming.expenses.count)
        for entry in incoming.expenses {
            #expect(document.ledger.expenses.first { $0.id == entry.id } == entry)
        }
        undo.redo()
        #expect(document.ledger.expenses == [incoming.expenses[1]])
    }

    @Test func savingAStaleEditorPreservesIncomingAndSubmittedValues() async throws {
        let initial = twoEntryLedger()
        let original = initial.expenses[0]
        let document = TallyDocument(ledger: initial)
        var incoming = initial
        incoming.expenses[0].amountMinor = 150
        incoming.expenses[1].notes = "An unrelated incoming change"
        try await document.apply(snapshot: incoming, previous: initial)
        var submitted = original
        submitted.billingDay = 15
        let undo = makeUndoManager()

        performUndoableChange(undo) {
            document.updateExpense(submitted, original: original, undoManager: undo)
        }

        #expect(document.ledger.expenses.first { $0.id == original.id } == submitted)
        #expect(document.ledger.expenses.first { $0.id == incoming.expenses[1].id } == incoming.expenses[1])
        let preservedIncoming = try #require(document.ledger.expenses.first {
            $0.id != original.id && $0.merchant.hasSuffix(" (conflicting copy)")
        })
        #expect(preservedIncoming.amountMinor == 150)
        #expect(preservedIncoming.billingDay == original.billingDay)
        let saved = document.ledger
        undo.undo()
        #expect(document.ledger == incoming)
        undo.redo()
        #expect(document.ledger == saved)
    }

    @Test func savingAnUnchangedStaleEditorKeepsIncomingChanges() async throws {
        let initial = twoEntryLedger()
        let document = TallyDocument(ledger: initial)
        var incoming = initial
        incoming.expenses[0].amountMinor = 150
        try await document.apply(snapshot: incoming, previous: initial)
        let undo = makeUndoManager()

        document.updateExpense(initial.expenses[0], original: initial.expenses[0], undoManager: undo)

        #expect(document.ledger == incoming)
        #expect(!undo.canUndo)
    }

    @Test func savingAnEditedEntryAfterRemoteDeletionRetainsTheEdit() async throws {
        let initial = twoEntryLedger()
        let original = initial.expenses[0]
        let document = TallyDocument(ledger: initial)
        var incoming = initial
        incoming.expenses.removeFirst()
        try await document.apply(snapshot: incoming, previous: initial)
        var submitted = original
        submitted.amountMinor = 175

        document.updateExpense(submitted, original: original, undoManager: nil)

        #expect(document.ledger.expenses.count == 2)
        #expect(document.ledger.expenses.first { $0.id == original.id } == submitted)
        #expect(document.ledger.expenses.first { $0.id == incoming.expenses[0].id } == incoming.expenses[0])
    }

    @Test func savingAnUnchangedEditorDoesNotUndoRemoteDeletion() async throws {
        let initial = twoEntryLedger()
        let document = TallyDocument(ledger: initial)
        var incoming = initial
        incoming.expenses.removeFirst()
        try await document.apply(snapshot: incoming, previous: initial)

        document.updateExpense(initial.expenses[0], original: initial.expenses[0], undoManager: nil)

        #expect(document.ledger == incoming)
    }

    private func makeUndoManager() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    private func performUndoableChange(_ undo: UndoManager, _ change: () -> Void) {
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        change()
    }

    private func twoEntryLedger() -> Ledger {
        Ledger(expenses: [
            Expense(merchant: "Fictional first entry", amountMinor: 100),
            Expense(merchant: "Fictional second entry", amountMinor: 200)
        ])
    }
}
