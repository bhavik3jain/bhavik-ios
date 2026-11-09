import Foundation

/// Money on the Split face: `Int64` minor units in an ISO currency, formatted
/// and parsed without ever passing through a `Double`.
///
/// Ported from Finance's `FinanceFormat`/`FinanceInput` (feature packages
/// can't import each other), but per currency rather than always dollars: a
/// trip's yen have no cents, and its euros may be typed with a comma.
public enum TripMoney {
    /// The currency a figure is in: the expense's own code, else the trip's,
    /// else the device locale's, else US dollars.
    public static func resolvedCode(_ code: String, tripCode: String = "", locale: Locale = .current) -> String {
        for candidate in [code, tripCode] {
            let trimmed = candidate.trimmingCharacters(in: .whitespaces).uppercased()
            if !trimmed.isEmpty { return trimmed }
        }
        return locale.currency?.identifier ?? "USD"
    }

    /// Digits after the decimal point: 2 for EUR, 0 for JPY, 3 for KWD. From
    /// ISO 4217 as Foundation has it, read in a fixed locale so it can't vary
    /// by device.
    public static func fractionDigits(for code: String) -> Int {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        return max(0, formatter.maximumFractionDigits)
    }

    /// `minor` as a `Decimal` in whole units: 23640 EUR is 236.40.
    public static func decimal(_ minor: Int64, code: String) -> Decimal {
        Decimal(sign: minor < 0 ? .minus : .plus, exponent: -fractionDigits(for: code), significand: Decimal(minor.magnitude))
    }

    /// "€236.40", "¥4,800" — in the reader's locale, always with the
    /// currency's own number of decimals.
    public static func format(_ minor: Int64, code: String, locale: Locale = .current) -> String {
        let digits = fractionDigits(for: code)
        return decimal(minor, code: code).formatted(
            .currency(code: code).precision(.fractionLength(digits)).locale(locale)
        )
    }

    /// A figure for a text field: no currency sign or grouping, so it reads
    /// straight back through `parse` in the same locale. Zero is an empty field.
    public static func editable(_ minor: Int64, code: String, locale: Locale = .current) -> String {
        guard minor != 0 else { return "" }
        let digits = fractionDigits(for: code)
        // In the reader's own locale, never POSIX: `parse` takes "." for the
        // grouping separator wherever the decimal is a comma, so a POSIX
        // "236.4" prefilled on a German phone saved as €2,364.00, a Settle Up
        // suggestion of €38.50 as €385.00, and a 3-way "33.33" percent split
        // could never add up to 100.
        return decimal(minor, code: code).formatted(
            .number.grouping(.never).precision(.fractionLength(0...digits)).locale(locale)
        )
    }

    /// Reads money typed by hand into minor units of `code`: "€1.234,56" in a
    /// comma-decimal locale, "1234.56", "-20" and "(20)" all read; extra
    /// decimals round half up; nil for nothing numeric at all.
    ///
    /// Text-backed rather than `TextField(value:format:)`, which only writes
    /// its binding on commit — and a decimal pad has no Return key, so tapping
    /// Save straight after typing would save the old figure (the bug Points hit
    /// with an opening balance).
    public static func parse(_ text: String, code: String, locale: Locale = .current) -> Int64? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        // The decimal pad types the region's own separator. Where that's a
        // comma, keeping only digits and "." read "12,5" as 125.
        if let decimal = locale.decimalSeparator, decimal != "." {
            if let grouping = locale.groupingSeparator, !grouping.isEmpty {
                trimmed = trimmed.replacingOccurrences(of: grouping, with: "")
            }
            trimmed = trimmed.replacingOccurrences(of: decimal, with: ".")
        }
        var negative = false
        if trimmed.hasPrefix("(") && trimmed.hasSuffix(")") {
            negative = true
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        if trimmed.hasPrefix("-") || trimmed.hasPrefix("−") {
            negative = true
            trimmed = String(trimmed.dropFirst())
        }
        let kept = trimmed.filter { $0.isASCII && ($0.isNumber || $0 == ".") }
        guard kept.contains(where: \.isNumber),
              kept.filter({ $0 == "." }).count <= 1,
              let value = Decimal(string: kept, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }

        var scaled = value * Decimal(sign: .plus, exponent: fractionDigits(for: code), significand: 1)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        // Past this a figure is a typo, and Int64 conversion would wrap.
        guard rounded < Decimal(1_000_000_000_000_000) else { return nil }
        let minor = NSDecimalNumber(decimal: rounded).int64Value
        return negative ? -minor : minor
    }

    /// Common ISO codes for a currency menu, the locale's own first.
    public static func menuCodes(locale: Locale = .current) -> [String] {
        let own = locale.currency?.identifier
        let common = ["USD", "EUR", "GBP", "JPY", "CAD", "AUD", "CHF", "INR", "MXN", "CNY", "SGD", "NZD", "THB", "AED"]
        var seen: Set<String> = []
        return ([own].compactMap { $0 } + common).filter { seen.insert($0).inserted }
    }
}
