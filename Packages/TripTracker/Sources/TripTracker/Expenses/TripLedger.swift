import Foundation

/// A `SharedTripExpense` as plain values — what the ledger, settle-up and
/// day groups work from, so none of them needs a context.
public struct ExpenseRecord: Identifiable, Sendable, Equatable {
    public let id: String
    public var title: String
    public var amountMinor: Int64
    /// Already resolved: never "" (see `TripMoney.resolvedCode`).
    public var currencyCode: String
    public var payer: PersonKey
    public var kind: ExpenseKind
    public var category: ExpenseCategory
    public var split: ExpenseSplit
    public var date: Date

    public init(
        id: String,
        title: String,
        amountMinor: Int64,
        currencyCode: String,
        payer: PersonKey,
        kind: ExpenseKind = .expense,
        category: ExpenseCategory = .other,
        split: ExpenseSplit,
        date: Date
    ) {
        self.id = id
        self.title = title
        self.amountMinor = amountMinor
        self.currencyCode = currencyCode
        self.payer = payer
        self.kind = kind
        self.category = category
        self.split = split
        self.date = date
    }

    public var isPayment: Bool { kind == .payment }

    /// Whether the stored split reads as written — false shows "Split needs a
    /// look" (it's then counted as an equal split).
    public var splitReadsAsStored: Bool { split.readsAsStored(total: amountMinor) }
}

/// What one expense means for one person, for "you lent / you borrowed".
public enum ExpenseInvolvement: Sendable, Equatable {
    case notInvolved
    /// Paid more than their share: others owe them this much for it.
    case lent(Int64)
    /// Their share of something someone else paid.
    case borrowed(Int64)
    /// Paid exactly their own share.
    case even
    /// A payment they made.
    case paid(Int64)
    /// A payment made to them.
    case received(Int64)
}

/// Who owes what on a trip, one currency at a time — there's no conversion in
/// v1, so euros and yen never meet.
///
/// A balance is what someone has paid minus their share of everything:
/// positive means they're owed, negative that they owe. Payments go through
/// the same path (the payer's balance rises, the person paid's falls), so
/// every currency's balances sum to zero. Keys are resolved through
/// `TripPeople.resolve` first, so a manual person linked to a participant is
/// counted as them without any expense being rewritten.
public struct TripLedger: Sendable, Equatable {
    public let people: TripPeople?
    /// Every currency any expense or payment uses, sorted.
    public let currencies: [String]
    /// `[currency: [person: minor units]]`. Positive: owed. Zero entries kept
    /// for anyone involved.
    public let balances: [String: [PersonKey: Int64]]
    /// What the trip cost, per currency — payments excluded.
    public let totals: [String: Int64]
    /// What each person paid for expenses, per currency (payments excluded).
    public let paid: [String: [PersonKey: Int64]]
    /// Each person's share of expenses, per currency (payments excluded).
    public let shares: [String: [PersonKey: Int64]]

    public init(expenses: [ExpenseRecord], people: TripPeople? = nil) {
        self.people = people
        let resolve: (PersonKey) -> PersonKey = { people?.resolve($0) ?? $0 }
        var balances: [String: [PersonKey: Int64]] = [:]
        var totals: [String: Int64] = [:]
        var paid: [String: [PersonKey: Int64]] = [:]
        var shares: [String: [PersonKey: Int64]] = [:]

        for expense in expenses {
            let currency = expense.currencyCode
            let payer = resolve(expense.payer)
            let allocation = Self.allocation(of: expense, resolve: resolve)
            // An expense split between nobody is the payer's own: nothing owed.
            guard !allocation.isEmpty, !payer.isEmpty else { continue }
            let allocated = allocation.values.reduce(0, +)
            balances[currency, default: [:]][payer, default: 0] += allocated
            for (key, amount) in allocation {
                balances[currency, default: [:]][key, default: 0] -= amount
            }
            if !expense.isPayment {
                totals[currency, default: 0] += expense.amountMinor
                paid[currency, default: [:]][payer, default: 0] += allocated
                for (key, amount) in allocation {
                    shares[currency, default: [:]][key, default: 0] += amount
                }
            }
        }
        self.balances = balances
        self.totals = totals
        self.paid = paid
        self.shares = shares
        self.currencies = Set(balances.keys).union(totals.keys).sorted()
    }

    /// Each person's minor units of one expense, keys resolved.
    public func allocation(of expense: ExpenseRecord) -> [PersonKey: Int64] {
        Self.allocation(of: expense, resolve: { people?.resolve($0) ?? $0 })
    }

    static func allocation(of expense: ExpenseRecord, resolve: (PersonKey) -> PersonKey) -> [PersonKey: Int64] {
        var merged: [PersonKey: Int64] = [:]
        for (key, amount) in expense.split.allocate(total: expense.amountMinor) {
            merged[resolve(key), default: 0] += amount
        }
        return merged
    }

    public func balance(of key: PersonKey, in currency: String) -> Int64 {
        balances[currency]?[resolve(key)] ?? 0
    }

    /// `key`'s non-zero balances, by currency.
    public func balances(of key: PersonKey) -> [String: Int64] {
        let resolved = resolve(key)
        return balances.compactMapValues { $0[resolved].flatMap { $0 == 0 ? nil : $0 } }
    }

    /// Whether everyone is square in every currency.
    public var isSettled: Bool {
        balances.values.allSatisfy { $0.values.allSatisfy { $0 == 0 } }
    }

    /// The fewest-ish transfers that square everyone up — see `SettleUp`.
    public var transfers: [SettleUp.Transfer] { SettleUp.transfers(balances: balances) }

    public func involvement(of key: PersonKey, in expense: ExpenseRecord) -> ExpenseInvolvement {
        let me = resolve(key)
        let payer = resolve(expense.payer)
        let allocation = allocation(of: expense)
        let share = allocation[me] ?? 0
        let paidAmount = payer == me ? allocation.values.reduce(0, +) : 0
        if expense.isPayment {
            if payer == me, share == 0 { return .paid(paidAmount) }
            if payer != me, share > 0 { return .received(share) }
            return .notInvolved
        }
        if paidAmount == 0 && share == 0 { return .notInvolved }
        let net = paidAmount - share
        if net > 0 { return .lent(net) }
        if net < 0 { return .borrowed(-net) }
        return .even
    }

    private func resolve(_ key: PersonKey) -> PersonKey { people?.resolve(key) ?? key }

    /// Every key any expense mentions, unresolved — a manual person nobody
    /// mentions can be deleted; anyone else can only be hidden.
    public static func mentionedKeys(in expenses: [ExpenseRecord]) -> Set<PersonKey> {
        var keys: Set<PersonKey> = []
        for expense in expenses {
            keys.insert(expense.payer)
            keys.formUnion(expense.split.keys)
        }
        keys.remove(PersonKey(""))
        return keys
    }

    // MARK: Days

    /// Expenses grouped by the day they were spent, latest day first: "After
    /// the trip", the trip's days, "Before the trip". By date, not a stored day
    /// index, so the ideas sentinel never comes into it. Latest first within a
    /// day too.
    public static func dayGroups(_ expenses: [ExpenseRecord], dates: TripDates) -> [ExpenseDayGroup] {
        var groups: [ExpenseDayGroup.Placement: [ExpenseRecord]] = [:]
        for expense in expenses {
            let offset = dates.offset(of: expense.date)
            let placement: ExpenseDayGroup.Placement
            if offset < 0 {
                placement = .before
            } else if offset >= dates.dayCount {
                placement = .after
            } else {
                placement = .day(offset)
            }
            groups[placement, default: []].append(expense)
        }
        return groups
            .map { placement, expenses in
                ExpenseDayGroup(
                    placement: placement,
                    date: placement.dayIndex.map(dates.date(forDay:)),
                    expenses: expenses.sorted { $0.date != $1.date ? $0.date > $1.date : $0.id < $1.id }
                )
            }
            .sorted { $0.placement.rank > $1.placement.rank }
    }
}

/// One day's expenses on the Split face.
public struct ExpenseDayGroup: Identifiable, Sendable, Equatable {
    public enum Placement: Sendable, Hashable {
        case before
        case day(Int)
        case after

        public var dayIndex: Int? {
            if case .day(let index) = self { index } else { nil }
        }

        var rank: Int {
            switch self {
            case .before: Int.min
            case .day(let index): index
            case .after: Int.max
            }
        }
    }

    public let placement: Placement
    /// The start of the day, for a trip day.
    public let date: Date?
    public let expenses: [ExpenseRecord]

    public var id: String {
        switch placement {
        case .before: "before"
        case .day(let index): "day-\(index)"
        case .after: "after"
        }
    }

    /// "Day 2 · Fri, Mar 13", "Before the trip", "After the trip".
    public func title(locale: Locale = .current) -> String {
        switch placement {
        case .before: return "Before the trip"
        case .after: return "After the trip"
        case .day(let index):
            guard let date else { return "Day \(index + 1)" }
            let formatted = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(locale))
            return "Day \(index + 1) · \(formatted)"
        }
    }
}
