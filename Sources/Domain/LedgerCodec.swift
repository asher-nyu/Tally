import Foundation

nonisolated enum LedgerError: Error, LocalizedError, Equatable, Sendable {
    case fileTooLarge, corruptFile
    case unsupportedVersion(Int)
    case unsupportedCurrency(String)
    case tooManyExpenses, duplicateExpenseID, invalidMerchant, amountOutOfRange, invalidBillingDay, notesTooLong, invalidSchedule, invalidCustomRecurrence, invalidReminder

    var errorDescription: String? {
        switch self {
        case .fileTooLarge: "This document exceeds the 10 MB size limit."
        case .corruptFile: "This document could not be read. Choose a valid Tally document."
        case .unsupportedVersion: "Update Tally to open this document."
        case .unsupportedCurrency(let code): "The currency \(code) is not supported by this version of Tally."
        case .tooManyExpenses: "This document has reached its limit of \(LedgerCodec.maximumExpenseCount.formatted()) income and expense items. Create another document to add more."
        case .duplicateExpenseID: "This document contains conflicting data and can’t be opened. Restore a previous version or choose another document."
        case .invalidMerchant: "Enter a name of 1–\(LedgerCodec.maximumMerchantLength) characters."
        case .amountOutOfRange: "An amount in this document is outside the supported range."
        case .invalidBillingDay: "Choose a monthly date between 1 and 31, or leave the date variable."
        case .notesTooLong: "Keep additional text to \(LedgerCodec.maximumNotesLength.formatted()) characters or fewer."
        case .invalidSchedule: "Choose a valid date for this schedule."
        case .invalidCustomRecurrence: "Choose a custom interval between 1 and 999, valid repeat dates, and an end date on or after the start date."
        case .invalidReminder: "Choose a valid reminder time and a scheduled date."
        }
    }
}

nonisolated enum LedgerCodec {
    static let currentFormatVersion = 6
    static let maximumFileBytes = 10 * 1_024 * 1_024
    static let maximumExpenseCount = 10_000
    static let maximumMerchantLength = 160
    static let maximumNotesLength = 4_000
    static let maximumAmountMinor: Int64 = 999_999_999_999

    static func encode(_ ledger: Ledger) throws -> Data {
        try validate(ledger)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(ledger)
        guard data.count <= maximumFileBytes else { throw LedgerError.fileTooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> Ledger {
        guard data.count <= maximumFileBytes else { throw LedgerError.fileTooLarge }
        let decoder = JSONDecoder()
        // Read the version before the payload so newer schemas get a useful error.
        struct Header: Decodable { let formatVersion: Int }
        let header: Header
        do { header = try decoder.decode(Header.self, from: data) }
        catch { throw LedgerError.corruptFile }
        guard (1...currentFormatVersion).contains(header.formatVersion) else { throw LedgerError.unsupportedVersion(header.formatVersion) }
        var ledger: Ledger
        do { ledger = try decoder.decode(Ledger.self, from: data) }
        catch { throw LedgerError.corruptFile }
        // Version one used only monthly schedules; missing fields decode to
        // monthly defaults. Version two introduced calendar-only anchors.
        // Version three introduced custom recurrence. All migrate without
        // changing entries. Version four added optional websites; version five
        // added opt-in reminders without enabling them in existing documents.
        // Version six adds a sound choice, retaining the default for old reminders.
        ledger.formatVersion = currentFormatVersion
        try validate(ledger)
        return ledger
    }

    static func validate(_ ledger: Ledger) throws {
        guard ledger.formatVersion == currentFormatVersion else { throw LedgerError.unsupportedVersion(ledger.formatVersion) }
        guard Currency.fractionDigits(for: ledger.currencyCode) != nil else { throw LedgerError.unsupportedCurrency(ledger.currencyCode) }
        guard ledger.expenses.count <= maximumExpenseCount else { throw LedgerError.tooManyExpenses }
        var ids = Set<UUID>()
        for expense in ledger.expenses {
            guard ids.insert(expense.id).inserted else { throw LedgerError.duplicateExpenseID }
            guard !expense.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  expense.merchant.count <= maximumMerchantLength else { throw LedgerError.invalidMerchant }
            if let amount = expense.amountMinor, !(0...maximumAmountMinor).contains(amount) { throw LedgerError.amountOutOfRange }
            if let day = expense.billingDay, !(1...31).contains(day) { throw LedgerError.invalidBillingDay }
            if let anchor = expense.anchorDate, !anchor.isValid { throw LedgerError.invalidSchedule }
            if expense.recurrence != .monthly && expense.anchorDate == nil { throw LedgerError.invalidSchedule }
            if expense.recurrence == .monthly && expense.anchorDate != nil { throw LedgerError.invalidSchedule }
            if expense.recurrence != .monthly && expense.billingDay != nil { throw LedgerError.invalidSchedule }
            if expense.recurrence == .custom {
                guard let rule = expense.customRecurrence, let anchor = expense.anchorDate,
                      rule.isValid(anchor: anchor) else { throw LedgerError.invalidCustomRecurrence }
            } else if expense.customRecurrence != nil { throw LedgerError.invalidCustomRecurrence }
            guard expense.notes.count <= maximumNotesLength else { throw LedgerError.notesTooLong }
            _ = try ProviderLink.normalizeWebsite(expense.websiteLink)
            if let reminder = expense.reminder {
                guard reminder.isValid, expense.recurrence != .monthly || expense.billingDay != nil else { throw LedgerError.invalidReminder }
            }
        }
    }
}
