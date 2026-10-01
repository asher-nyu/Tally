import Foundation

nonisolated enum MoneyError: Error, LocalizedError, Equatable, Sendable {
    case invalidNumber
    case tooManyFractionDigits(Int)
    case amountOutOfRange, unsupportedCurrency

    var errorDescription: String? {
        switch self {
        case .invalidNumber: "Enter an amount using your region’s decimal separator."
        case .tooManyFractionDigits(let count): count == 0 ? "This currency uses whole units. Enter an amount without decimals." : "This currency allows up to \(count) decimal places."
        case .amountOutOfRange: "This amount is too large. Enter a smaller amount."
        case .unsupportedCurrency: "Choose a supported currency."
        }
    }
}

nonisolated enum Money {
    /// Parses decimal digits directly into integer minor units, never through a
    /// floating-point value. Grouping, when supplied, must match the locale.
    static func parse(_ input: String, currencyCode: String, locale: Locale = .current) throws -> Int64? {
        guard let fractionDigits = Currency.fractionDigits(for: currencyCode) else { throw MoneyError.unsupportedCurrency }
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let formatter = formatter(currencyCode: currencyCode, locale: locale)
        let decimalSeparator = formatter.decimalSeparator ?? "."
        let groupingSeparator = formatter.groupingSeparator ?? ","
        // Space-grouping locales commonly receive ordinary or nonbreaking spaces.
        if groupingSeparator.allSatisfy({ $0.isWhitespace }) {
            for separator in [" ", "\u{00A0}", "\u{202F}"] {
                value = value.replacingOccurrences(of: separator, with: groupingSeparator)
            }
        }
        let parts = value.components(separatedBy: decimalSeparator)
        guard parts.count <= 2 else { throw MoneyError.invalidNumber }
        let fraction = parts.count == 2 ? parts[1] : ""
        if parts.count == 2 && fractionDigits == 0 { throw MoneyError.tooManyFractionDigits(0) }
        guard fraction.count <= fractionDigits else { throw MoneyError.tooManyFractionDigits(fractionDigits) }
        guard fraction.allSatisfy(isDigit) else { throw MoneyError.invalidNumber }
        let groups = parts[0].components(separatedBy: groupingSeparator)
        let whole: String
        if groups.count > 1 {
            let primary = max(1, formatter.groupingSize)
            let secondary = formatter.secondaryGroupingSize > 0 ? formatter.secondaryGroupingSize : primary
            guard let first = groups.first, let last = groups.last,
                  (1...secondary).contains(first.count), last.count == primary,
                  groups.dropFirst().dropLast().allSatisfy({ $0.count == secondary }),
                  groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy(isDigit) })
            else { throw MoneyError.invalidNumber }
            whole = groups.joined()
        } else {
            guard parts[0].allSatisfy(isDigit) else { throw MoneyError.invalidNumber }
            whole = parts[0]
        }
        guard !whole.isEmpty || !fraction.isEmpty else { throw MoneyError.invalidNumber }
        let digits = whole + fraction + String(repeating: "0", count: fractionDigits - fraction.count)
        var minor: Int64 = 0
        for character in digits {
            guard let digit = character.wholeNumberValue, (0...9).contains(digit) else { throw MoneyError.invalidNumber }
            let (multiplied, multiplyOverflow) = minor.multipliedReportingOverflow(by: 10)
            let (next, additionOverflow) = multiplied.addingReportingOverflow(Int64(digit))
            guard !multiplyOverflow, !additionOverflow, next <= LedgerCodec.maximumAmountMinor else { throw MoneyError.amountOutOfRange }
            minor = next
        }
        return minor
    }

    static func format(_ amountMinor: Int64?, currencyCode: String, locale: Locale = .current) -> String {
        guard let amountMinor else { return "Variable" }
        guard let digits = Currency.fractionDigits(for: currencyCode) else { return "—" }
        let exact = NSDecimalNumber(string: decimalString(amountMinor, fractionDigits: digits), locale: Locale(identifier: "en_US_POSIX"))
        return formatter(currencyCode: currencyCode, locale: locale).string(from: exact)
            ?? "\(currencyCode) \(inputString(amountMinor, currencyCode: currencyCode, locale: locale))"
    }

    /// An ungrouped, exact value suitable for an editable amount field.
    static func inputString(_ amountMinor: Int64?, currencyCode: String, locale: Locale = .current) -> String {
        guard let amountMinor, let digits = Currency.fractionDigits(for: currencyCode) else { return "" }
        let separator = formatter(currencyCode: currencyCode, locale: locale).decimalSeparator ?? "."
        return decimalString(amountMinor, fractionDigits: digits).replacingOccurrences(of: ".", with: separator)
    }

    private static func isDigit(_ character: Character) -> Bool {
        guard let digit = character.wholeNumberValue else { return false }
        return (0...9).contains(digit)
    }

    private static func decimalString(_ value: Int64, fractionDigits: Int) -> String {
        let sign = value < 0 ? "-" : ""
        let magnitude = String(value.magnitude)
        guard fractionDigits > 0 else { return sign + magnitude }
        let padded = String(repeating: "0", count: max(0, fractionDigits + 1 - magnitude.count)) + magnitude
        let split = padded.index(padded.endIndex, offsetBy: -fractionDigits)
        return sign + padded[..<split] + "." + padded[split...]
    }

    private static func formatter(currencyCode: String, locale: Locale) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        let digits = Currency.fractionDigits(for: currencyCode) ?? 2
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter
    }
}
