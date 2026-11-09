import Foundation

/// How one expense is divided: a mode and one entry per person. Only this rule
/// is stored (`SharedTripExpense.splitEncoded`); the cents are worked out by
/// `allocate(total:)` each time, so every device gets the same answer from the
/// same record.
///
/// An entry's value depends on the mode: ignored for `.equal`, minor units for
/// `.exact`, a weight for `.shares`, basis points for `.percent`.
public struct ExpenseSplit: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Codable {
        public var key: PersonKey
        public var value: Int64

        public init(key: PersonKey, value: Int64) {
            self.key = key
            self.value = value
        }

        enum CodingKeys: String, CodingKey {
            case key = "k"
            case value = "v"
        }
    }

    public var mode: ExpenseSplitMode
    /// One per person, in the order they were listed; no key twice.
    public var entries: [Entry]
    /// True when what was stored couldn't be read as written — bad JSON, an
    /// exact split that doesn't sum to the total, percentages that don't make
    /// 100 % — and so reads as an equal split over the keys that could be read.
    /// The row shows "Split needs a look".
    public private(set) var isFallback = false

    public init(mode: ExpenseSplitMode, entries: [Entry]) {
        self.mode = mode
        var seen: Set<PersonKey> = []
        self.entries = entries.filter { !$0.key.isEmpty && seen.insert($0.key).inserted }
    }

    public static let percentWhole: Int64 = 10_000

    public static func equal(_ keys: [PersonKey]) -> ExpenseSplit {
        ExpenseSplit(mode: .equal, entries: keys.map { Entry(key: $0, value: 1) })
    }

    /// The whole amount to one person — what a payment's split is.
    public static func payment(to key: PersonKey, amountMinor: Int64) -> ExpenseSplit {
        ExpenseSplit(mode: .exact, entries: [Entry(key: key, value: amountMinor)])
    }

    public var keys: [PersonKey] { entries.map(\.key) }

    public func value(for key: PersonKey) -> Int64? {
        entries.first { $0.key == key }?.value
    }

    // MARK: Encoding

    /// `[{"k":"owner","v":1},…]`, keys in listed order.
    public var encoded: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads a stored split without ever failing: entries that can't be read
    /// are skipped (a missing or empty key, a value that isn't a number), a
    /// value with a fraction is truncated, and anything unreadable as a whole
    /// is an empty split.
    public static func decode(_ encoded: String, mode: ExpenseSplitMode) -> ExpenseSplit {
        guard let data = encoded.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else {
            var split = ExpenseSplit(mode: .equal, entries: [])
            split.isFallback = !encoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return split
        }
        var dropped = false
        let entries: [Entry] = array.compactMap { element in
            guard let object = element as? [String: Any],
                  let key = object["k"] as? String, !key.isEmpty
            else {
                dropped = true
                return nil
            }
            let value: Int64
            switch object["v"] {
            case let number as NSNumber:
                let double = number.doubleValue
                guard double.isFinite, abs(double) < 9e15 else { dropped = true; return nil }
                value = number.int64Value
            case nil where mode == .equal:
                value = 1
            default:
                dropped = true
                return nil
            }
            return Entry(key: PersonKey(key), value: value)
        }
        var split = ExpenseSplit(mode: mode, entries: entries)
        if dropped, mode != .equal {
            split = ExpenseSplit(mode: .equal, entries: split.entries.map { Entry(key: $0.key, value: 1) })
            split.isFallback = true
        } else if dropped {
            split.isFallback = true
        }
        return split
    }

    // MARK: Checking

    /// What is still to assign, for the editor: minor units for `.exact`
    /// ("€0.00 left to assign"), basis points for `.percent`, zero otherwise.
    /// Negative when over.
    public func remaining(total: Int64) -> Int64 {
        switch mode {
        case .exact: total - entries.reduce(0) { $0 + $1.value }
        case .percent: Self.percentWhole - entries.reduce(0) { $0 + $1.value }
        case .equal, .shares: 0
        }
    }

    /// Whether the split can be saved as it stands for `total`.
    public func isValid(total: Int64) -> Bool {
        guard !entries.isEmpty, total >= 0 else { return false }
        switch mode {
        case .equal:
            return true
        case .shares:
            return entries.allSatisfy { $0.value >= 0 } && entries.contains { $0.value > 0 }
        case .exact, .percent:
            return entries.allSatisfy { $0.value >= 0 } && remaining(total: total) == 0
        }
    }

    /// Whether this split reads as stored for `total` — false means the row
    /// should say "Split needs a look", and `allocate` falls back to equal.
    public func readsAsStored(total: Int64) -> Bool {
        !isFallback && (entries.isEmpty || isValid(total: total))
    }

    // MARK: Allocating

    /// Each person's minor units, summing to `total` exactly.
    ///
    /// Everyone gets the floor of their share; the cents left over go one each
    /// to the largest fractional parts, ties broken by ascending
    /// `PersonKey.raw`, so every device produces the same answer. A split that
    /// isn't valid for `total` is allocated equally over its keys. An empty
    /// split allocates nothing.
    public func allocate(total: Int64) -> [PersonKey: Int64] {
        Dictionary(uniqueKeysWithValues: allocation(total: total).map { ($0.key, $0.value) })
    }

    /// `allocate`, as entries in listed order — for a preview.
    public func allocation(total: Int64) -> [Entry] {
        guard !entries.isEmpty else { return [] }
        let weights: [Int64]
        if !isValid(total: total) {
            weights = entries.map { _ in 1 }
        } else {
            switch mode {
            case .equal: weights = entries.map { _ in 1 }
            case .exact: return entries
            case .shares, .percent: weights = entries.map(\.value)
            }
        }
        let amounts = Self.largestRemainder(total: total, weights: weights, keys: keys)
        return zip(keys, amounts).map { Entry(key: $0, value: $1) }
    }

    /// `total` divided in proportion to `weights` — see `allocate`.
    static func largestRemainder(total: Int64, weights: [Int64], keys: [PersonKey]) -> [Int64] {
        let sum = weights.reduce(0, +)
        guard sum > 0 else { return weights.map { _ in 0 } }
        let sign: Int64 = total < 0 ? -1 : 1
        let magnitude = total.magnitude
        var floors: [Int64] = []
        var remainders: [UInt64] = []
        for weight in weights {
            // Full width, so a large total times a large weight can't overflow.
            let product = magnitude.multipliedFullWidth(by: UInt64(weight))
            let (quotient, remainder) = UInt64(sum).dividingFullWidth(product)
            floors.append(Int64(quotient))
            remainders.append(remainder)
        }
        var leftover = Int64(magnitude) - floors.reduce(0, +)
        let order = weights.indices.sorted {
            remainders[$0] != remainders[$1] ? remainders[$0] > remainders[$1] : keys[$0] < keys[$1]
        }
        for index in order where leftover > 0 && weights[index] > 0 {
            floors[index] += 1
            leftover -= 1
        }
        return floors.map { $0 * sign }
    }
}
