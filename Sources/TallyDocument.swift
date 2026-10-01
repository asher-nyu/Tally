import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class TallyDocument: Document {
    static let readableContentTypes: [UTType] = [.tallyDocument]

    private(set) var ledger: Ledger {
        didSet { ledgerDidChange?(ledger) }
    }
    /// UIKit's document adapter captures changes synchronously before autosave.
    @ObservationIgnored var ledgerDidChange: ((Ledger) -> Void)?
    var mutationError: String?
    let configuration: URLDocumentConfiguration?

    init(ledger: Ledger = Ledger(), configuration: URLDocumentConfiguration? = nil) {
        self.ledger = ledger
        self.configuration = configuration
    }

    func updateExpense(_ expense: Expense, original: Expense? = nil, undoManager: UndoManager?) {
        var updated = ledger
        let isNew = !updated.expenses.contains { $0.id == expense.id }
        if let index = updated.expenses.firstIndex(where: { $0.id == expense.id }) {
            updated.expenses[index] = expense
        } else {
            updated.expenses.append(expense)
        }
        if let original {
            guard original.id == expense.id else {
                mutationError = "This payment changed while you were editing. Close the editor and try again."
                return
            }
            // The editor may have opened before an incoming file version arrived.
            // Reconstruct its starting row without reverting any unrelated rows.
            var base = ledger
            if let index = base.expenses.firstIndex(where: { $0.id == original.id }) {
                base.expenses[index] = original
            } else {
                base.expenses.append(original)
            }
            do {
                updated = try LedgerMerger.merge(base: base, local: updated, remote: ledger)
            } catch {
                mutationError = error.localizedDescription
                return
            }
        }
        replaceLedger(updated, undoManager: undoManager, actionName: "\(isNew ? "Add" : "Edit") \(expense.kind.title)")
    }

    func deleteExpenses(ids: Set<UUID>, undoManager: UndoManager?) {
        let deleted = ledger.expenses.filter { ids.contains($0.id) }
        let actionName = deleted.count == 1 ? "Delete \(deleted[0].kind.title)" : "Delete Payments"
        var updated = ledger
        updated.expenses.removeAll { ids.contains($0.id) }
        replaceLedger(updated, undoManager: undoManager, actionName: actionName)
    }

    private func replaceLedger(_ updated: Ledger, undoManager: UndoManager?, actionName: String) {
        guard updated != ledger else { return }
        do {
            try LedgerCodec.validate(updated)
        } catch {
            mutationError = error.localizedDescription
            return
        }
        let previous = ledger
        // Registering each edit with the document's undo manager also schedules native autosave.
        undoManager?.registerUndo(withTarget: self) { document in
            document.reverseChange(from: updated, to: previous, undoManager: undoManager, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        ledger = updated
    }

    private func reverseChange(from base: Ledger, to previous: Ledger, undoManager: UndoManager?, actionName: String) {
        do {
            // Rebase undo onto current data so another device's edits survive.
            let restored = try LedgerMerger.merge(base: base, local: ledger, remote: previous)
            replaceLedger(restored, undoManager: undoManager, actionName: actionName)
        } catch {
            mutationError = error.localizedDescription
        }
    }

    nonisolated func reader(configuration: sending ReadConfiguration) -> sending FileWrapperDocumentReader<Ledger> {
        FileWrapperDocumentReader(configuration) { wrapper in
            guard let data = wrapper.regularFileContents else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try LedgerCodec.decode(data)
        }
    }

    nonisolated func writer(configuration: sending WriteConfiguration) -> sending FileWrapperDocumentWriter<Ledger> {
        FileWrapperDocumentWriter(configuration) { ledger, _ in
            FileWrapper(regularFileWithContents: try LedgerCodec.encode(ledger))
        }
    }

    func snapshot(contentType: UTType) async throws -> sending Ledger {
        ledger
    }

    func apply(snapshot: sending Ledger, previous: sending Ledger?) async throws {
        try applySnapshot(snapshot, previous: previous)
    }

    func applySnapshot(_ snapshot: Ledger, previous: Ledger?) throws {
        if let previous {
            ledger = try LedgerMerger.merge(base: previous, local: ledger, remote: snapshot)
        } else {
            ledger = snapshot
        }
    }
}

extension UTType {
    static var tallyDocument: UTType {
        UTType(exportedAs: "com.asherbloom.tally.document")
    }
}
