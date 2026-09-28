import Foundation

/// How money reads everywhere in Finance: whole dollars on summaries, cents
/// on transactions. Always US dollars — the sheet this replaces was.
public enum FinanceFormat {
    /// "$557,506".
    public static func money(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }

    /// "$4.35".
    public static func cents(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    /// "+$1,204" / "−$310" — a change from last month. Zero reads "+$0".
    public static func signedMoney(_ value: Double) -> String {
        let rounded = value.rounded()
        return (rounded < 0 ? "−" : "+") + money(abs(rounded))
    }

    /// "27 g", "100 g", "28.35 g".
    public static func grams(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...2)))) g"
    }

    /// "0.952 oz" — regular ounces, the ones `MetalValuation` values in.
    public static func ounces(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...3)))) oz"
    }

    /// A figure for a text field: no currency sign or grouping, so it reads
    /// straight back through `FinanceInput.parse`. Zero is an empty field.
    public static func editable(_ value: Double) -> String {
        guard value != 0 else { return "" }
        // POSIX, so a comma-decimal locale can't write "12,5" that the
        // parser would then read as 125.
        return value.formatted(
            .number.grouping(.never).precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX"))
        )
    }
}

/// Reads money typed by hand. Text-backed rather than
/// `TextField(value:format:)`, which only writes its binding on commit — and
/// a decimal pad has no Return key, so tapping Save straight after typing
/// would save the old figure (the same bug Points hit with an opening balance).
public enum FinanceInput {
    /// "$1,234.56", "1234.56", "-20" and "(20)" all read; nil for nothing
    /// numeric at all.
    public static func parse(_ text: String, locale: Locale = .current) -> Double? {
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
        guard kept.contains(where: \.isNumber), let value = Double(kept) else { return nil }
        return negative ? -value : value
    }
}
