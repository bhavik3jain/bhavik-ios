import Foundation

/// The expense editor's working copy, as plain values: whether Save is on,
/// what's left to assign and the per-person preview are worked out here, so
/// they're tested while the view stays declarative.
///
/// Amounts are kept as the text typed, not as numbers: a decimal pad has no
/// Return key, so a `TextField(value:)` never commits and Save would read the
/// figure from before the last keystroke (see `TripMoney.parse`).
public struct ExpenseEditorState: Equatable, Sendable {
    public var title: String
    public var amountText: String
    /// Never "" — resolved when the editor opens.
    public var currencyCode: String
    public var category: ExpenseCategory
    public var date: Date
    public var payer: PersonKey?
    public var mode: ExpenseSplitMode
    /// Who's in the split, in the order listed.
    public var included: [PersonKey]
    /// Each person's text in `.exact` (an amount) and `.percent` (a
    /// percentage, to two places).
    public var texts: [PersonKey: String]
    /// Each person's weight in `.shares`.
    public var weights: [PersonKey: Int64]
    public var note: String

    /// A new expense: everyone splittable in, equally, paid by `payer`.
    public init(currencyCode: String, payer: PersonKey?, people: [PersonKey], date: Date) {
        title = ""
        amountText = ""
        self.currencyCode = currencyCode
        category = .food
        self.date = date
        self.payer = payer
        mode = .equal
        included = people
        texts = [:]
        weights = [:]
        note = ""
    }

    /// An existing expense, as stored. A split that didn't read as stored
    /// opens as the equal split it's being counted as, so saving it fixes it.
    public init(record: ExpenseRecord, note: String, locale: Locale = .current) {
        title = record.title
        currencyCode = record.currencyCode
        amountText = TripMoney.editable(record.amountMinor, code: record.currencyCode, locale: locale)
        category = record.category
        date = record.date
        payer = record.payer.isEmpty ? nil : record.payer
        self.note = note
        let split = record.splitReadsAsStored ? record.split : .equal(record.split.keys)
        mode = split.mode
        included = split.keys
        texts = [:]
        weights = [:]
        for entry in split.entries {
            switch split.mode {
            case .exact: texts[entry.key] = TripMoney.editable(entry.value, code: record.currencyCode, locale: locale)
            case .percent: texts[entry.key] = Self.percentText(entry.value, locale: locale)
            case .shares: weights[entry.key] = entry.value
            case .equal: break
            }
        }
    }

    /// A new expense's date: now while the trip is on, else its first day.
    /// Not clamped — something booked before the trip is still an expense.
    public static func defaultDate(for dates: TripDates, asOf now: Date = .now) -> Date {
        (0..<dates.dayCount).contains(dates.offset(of: now)) ? now : dates.date(forDay: 0)
    }

    // MARK: Reading

    public func amountMinor(locale: Locale = .current) -> Int64? {
        TripMoney.parse(amountText, code: currencyCode, locale: locale)
    }

    /// The title saved: what was typed, else the category's name, so a
    /// notification never reads "added (€12.00)".
    public var resolvedTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? category.displayName : trimmed
    }

    /// The split as it stands. A person's text that isn't a number counts as
    /// zero here; `canSave` refuses it.
    public func split(locale: Locale = .current) -> ExpenseSplit {
        let entries: [ExpenseSplit.Entry] = included.map { key in
            switch mode {
            case .equal: ExpenseSplit.Entry(key: key, value: 1)
            case .exact: ExpenseSplit.Entry(key: key, value: value(of: key, locale: locale) ?? 0)
            case .percent: ExpenseSplit.Entry(key: key, value: value(of: key, locale: locale) ?? 0)
            case .shares: ExpenseSplit.Entry(key: key, value: weights[key] ?? 1)
            }
        }
        return ExpenseSplit(mode: mode, entries: entries)
    }

    /// One person's typed figure in minor units (`.exact`) or basis points
    /// (`.percent`); an empty field is zero, anything unreadable nil.
    func value(of key: PersonKey, locale: Locale) -> Int64? {
        let text = (texts[key] ?? "").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return 0 }
        switch mode {
        case .exact: return TripMoney.parse(text, code: currencyCode, locale: locale)
        case .percent: return Self.basisPoints(text, locale: locale)
        case .equal, .shares: return nil
        }
    }

    private func allTextsRead(locale: Locale) -> Bool {
        guard mode == .exact || mode == .percent else { return true }
        return included.allSatisfy { value(of: $0, locale: locale) != nil }
    }

    /// Save is on once there's an amount, a payer and a split that adds up.
    public func canSave(locale: Locale = .current) -> Bool {
        guard let amount = amountMinor(locale: locale), amount > 0, payer != nil, allTextsRead(locale: locale) else {
            return false
        }
        return split(locale: locale).isValid(total: amount)
    }

    /// Whether what's assigned matches the amount (`.exact`) or makes 100 %
    /// (`.percent`) — the footer's "left to assign" turns orange otherwise.
    public func addsUp(locale: Locale = .current) -> Bool {
        split(locale: locale).remaining(total: amountMinor(locale: locale) ?? 0) == 0
    }

    /// What each person pays, in listed order, for the live preview. Empty
    /// until there's an amount.
    public func preview(locale: Locale = .current) -> [ExpenseSplit.Entry] {
        guard let amount = amountMinor(locale: locale), amount > 0 else { return [] }
        return split(locale: locale).allocation(total: amount)
    }

    /// "€0.00 left to assign", "€3.00 over"; "40% left", "5% over". Nil for
    /// modes that always add up.
    public func remainingText(locale: Locale = .current) -> String? {
        switch mode {
        case .equal, .shares:
            return nil
        case .exact:
            let total = amountMinor(locale: locale) ?? 0
            let remaining = split(locale: locale).remaining(total: total)
            let figure = TripMoney.format(remaining.magnitude.clampedToInt64, code: currencyCode, locale: locale)
            return remaining < 0 ? "\(figure) over" : "\(figure) left to assign"
        case .percent:
            let remaining = split(locale: locale).remaining(total: 0)
            let figure = Self.percentText(Int64(remaining.magnitude.clampedToInt64), locale: locale) + "%"
            return remaining < 0 ? "\(figure) over" : "\(figure) left"
        }
    }

    // MARK: Changing

    /// Switches mode, filling the new mode's fields with the even split so a
    /// small change from it is a small edit: amounts already summing to the
    /// total, percentages to 100, everyone one share.
    public mutating func setMode(_ newMode: ExpenseSplitMode, locale: Locale = .current) {
        guard newMode != mode else { return }
        mode = newMode
        switch newMode {
        case .equal:
            break
        case .exact:
            texts = [:]
            if let amount = amountMinor(locale: locale), amount > 0 {
                let even = ExpenseSplit.largestRemainder(total: amount, weights: included.map { _ in 1 }, keys: included)
                for (key, value) in zip(included, even) { texts[key] = TripMoney.editable(value, code: currencyCode, locale: locale) }
            }
        case .percent:
            texts = [:]
            let even = ExpenseSplit.largestRemainder(total: ExpenseSplit.percentWhole, weights: included.map { _ in 1 }, keys: included)
            for (key, value) in zip(included, even) { texts[key] = Self.percentText(value, locale: locale) }
        case .shares:
            for key in included where weights[key] == nil { weights[key] = 1 }
        }
    }

    public func isIncluded(_ key: PersonKey) -> Bool { included.contains(key) }

    /// Ticks someone in or out of the split, keeping `order` (the roster's)
    /// for who's listed first.
    public mutating func toggle(_ key: PersonKey, order: [PersonKey]) {
        if let index = included.firstIndex(of: key) {
            included.remove(at: index)
            texts[key] = nil
        } else {
            included.append(key)
            let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            included.sort { (rank[$0] ?? .max, $0) < (rank[$1] ?? .max, $1) }
            if mode == .shares, weights[key] == nil { weights[key] = 1 }
        }
    }

    // MARK: Percent text

    /// Basis points as a percentage for a field: 3333 is "33.33" ("33,33" in
    /// a comma-decimal locale), 5000 "50".
    static func percentText(_ basisPoints: Int64, locale: Locale) -> String {
        // Basis points are hundredths of a percent, so they read and write
        // exactly like minor units of a two-decimal currency.
        TripMoney.editable(basisPoints, code: "USD", locale: locale).ifEmpty("0")
    }

    /// A typed percentage in basis points: "33.33" is 3333, "33,3" in a
    /// comma-decimal locale 3330.
    static func basisPoints(_ text: String, locale: Locale) -> Int64? {
        TripMoney.parse(text.replacingOccurrences(of: "%", with: ""), code: "USD", locale: locale)
    }
}

/// The Record Payment form's working copy.
public struct PaymentDraft: Equatable, Sendable {
    public var from: PersonKey?
    public var to: PersonKey?
    public var amountText: String
    public var currencyCode: String
    public var date: Date
    /// "Venmo", "cash" — kept in the payment's note, so never in a
    /// notification.
    public var via: String

    public init(from: PersonKey?, to: PersonKey?, amountMinor: Int64, currencyCode: String, date: Date, via: String = "", locale: Locale = .current) {
        self.from = from
        self.to = to
        self.amountText = TripMoney.editable(amountMinor, code: currencyCode, locale: locale)
        self.currencyCode = currencyCode
        self.date = date
        self.via = via
    }

    public func amountMinor(locale: Locale = .current) -> Int64? {
        TripMoney.parse(amountText, code: currencyCode, locale: locale)
    }

    /// Two different people and an amount above zero.
    public func canSave(locale: Locale = .current) -> Bool {
        guard let from, let to, from != to, let amount = amountMinor(locale: locale) else { return false }
        return amount > 0
    }
}

private extension UInt64 {
    var clampedToInt64: Int64 { self > UInt64(Int64.max) ? .max : Int64(self) }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
