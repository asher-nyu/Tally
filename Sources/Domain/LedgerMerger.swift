import CryptoKit
import Foundation

nonisolated enum LedgerMergeError: Error, LocalizedError, Equatable, Sendable {
    case differentLedger, differentCurrencies

    var errorDescription: String? {
        switch self {
        case .differentLedger: "These are separate documents and can’t be combined automatically. Open the version you want to use."
        case .differentCurrencies: "Both versions changed and use different currencies. Choose the version to keep before continuing."
        }
    }
}

nonisolated enum LedgerMerger {
    /// Three-way merging preserves changes to separate expenses. Competing
    /// changes retain the incoming expense as an explicitly marked copy.
    static func merge(base: Ledger, local: Ledger, remote: Ledger) throws -> Ledger {
        try LedgerCodec.validate(base)
        try LedgerCodec.validate(local)
        try LedgerCodec.validate(remote)
        guard base.id == local.id, base.id == remote.id else { throw LedgerMergeError.differentLedger }
        if local == remote { return local }
        if local == base { return remote }
        if remote == base { return local }
        guard local.currencyCode == remote.currencyCode else { throw LedgerMergeError.differentCurrencies }
        let baseRows = Dictionary(uniqueKeysWithValues: base.expenses.map { ($0.id, $0) })
        let localRows = Dictionary(uniqueKeysWithValues: local.expenses.map { ($0.id, $0) })
        let remoteRows = Dictionary(uniqueKeysWithValues: remote.expenses.map { ($0.id, $0) })
        var result = local
        result.expenses = []
        var visited = Set<UUID>()
        var outputIDs = Set<UUID>()
        let originalIDs = Set(localRows.keys).union(remoteRows.keys)
        // A conflict copy may already be a real row from an earlier merge.
        // Its final merged value, rather than either side in isolation, decides
        // whether reusing its ID is safe.
        func resolvedPrimaryRow(for id: UUID) -> Expense? {
            let previous = baseRows[id]
            let ours = localRows[id]
            let theirs = remoteRows[id]
            if ours == theirs { return ours }
            if ours == previous { return theirs }
            if theirs == previous { return ours }
            return ours ?? theirs
        }
        func append(_ expense: Expense?) {
            guard let expense, outputIDs.insert(expense.id).inserted else { return }
            result.expenses.append(expense)
        }
        for id in local.expenses.map(\.id) + remote.expenses.map(\.id) {
            guard visited.insert(id).inserted else { continue }
            let previous = baseRows[id]
            let ours = localRows[id]
            let theirs = remoteRows[id]
            if ours == theirs { append(ours) }
            else if ours == previous { append(theirs) }
            else if theirs == previous { append(ours) }
            else if let ours, let theirs {
                append(ours)
                var copy = theirs
                let suffix = " (conflicting copy)"
                copy.merchant = String(theirs.merchant.prefix(LedgerCodec.maximumMerchantLength - suffix.count)) + suffix
                var attempt = 0
                repeat {
                    copy.id = try conflictID(ledgerID: local.id, expense: theirs, attempt: attempt)
                    attempt += 1
                } while originalIDs.contains(copy.id) && resolvedPrimaryRow(for: copy.id) != copy
                append(copy)
            } else {
                // Deleting an expense must not discard concurrent edits to it.
                append(ours ?? theirs)
            }
        }
        try LedgerCodec.validate(result)
        return result
    }

    private static func conflictID(ledgerID: UUID, expense: Expense, attempt: Int) throws -> UUID {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var payload = Data("Tally conflict \(ledgerID.uuidString) \(attempt) ".utf8)
        payload.append(try encoder.encode(expense))
        var bytes = Array(SHA256.hash(data: payload).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
