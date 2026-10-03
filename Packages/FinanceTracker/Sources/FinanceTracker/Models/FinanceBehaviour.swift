import CoreData
import Foundation

// MARK: - Household

public extension SharedFinanceHousehold {
    var id: NSManagedObjectID { objectID }

    var sortedOwners: [SharedFinanceOwner] {
        (owners ?? []).sorted(by: SharedFinanceOwner.displayOrder)
    }

    /// Every account, category by category, then by institution.
    var sortedAccounts: [SharedFinanceAccount] {
        (accounts ?? []).sorted(by: SharedFinanceAccount.displayOrder)
    }

    /// Oldest first.
    var sortedMonths: [SharedFinanceMonth] {
        (months ?? []).filter { $0.period != nil }.sorted { $0.yearMonth < $1.yearMonth }
    }

    var latestMonth: SharedFinanceMonth? { sortedMonths.last }

    /// The month for `period` — the one `FinanceFold` keeps if sync left two.
    /// Picking any from the unordered set let Spending's budgets, rollover
    /// and the JSON import work on the duplicate the fold then deleted, and
    /// show different budgets from the month the Months list shows.
    func month(for period: YearMonth) -> SharedFinanceMonth? {
        (months ?? [])
            .filter { !$0.isDeleted && $0.yearMonth == period.rawValue }
            .min(by: FinanceFold.Tiebreak.local.months)
    }

    var sortedMetals: [SharedFinanceMetalItem] {
        (metalItems ?? []).sorted(by: SharedFinanceMetalItem.displayOrder)
    }

    /// Whether there's anything in it at all — the seeder's no-op test.
    var isEmpty: Bool {
        (accounts ?? []).isEmpty && (months ?? []).isEmpty && (metalItems ?? []).isEmpty && (transactions ?? []).isEmpty
    }
}

// MARK: - Owner

public extension SharedFinanceOwner {
    var id: NSManagedObjectID { objectID }

    var kind: OwnerKind {
        get { OwnerKind(rawValue: kindRaw) ?? .person }
        set { kindRaw = newValue.rawValue }
    }

    /// "B" for Bhavik, "J" for Joint — the badge on every row.
    var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    static func displayOrder(_ lhs: SharedFinanceOwner, _ rhs: SharedFinanceOwner) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

// MARK: - Account

public extension SharedFinanceAccount {
    var id: NSManagedObjectID { objectID }

    var category: AccountCategory {
        get { AccountCategory(rawValue: categoryRaw) ?? .cash }
        set { categoryRaw = newValue.rawValue }
    }

    /// "Capital One - Checkings", or just the name with no institution. This
    /// is how the Numbers sheet names rows, and how a transaction's `card`
    /// refers to its card in the JSON document.
    var displayName: String {
        Self.displayName(institution: institution, name: name)
    }

    static func displayName(institution: String, name: String) -> String {
        let institution = institution.trimmingCharacters(in: .whitespaces)
        let name = name.trimmingCharacters(in: .whitespaces)
        return institution.isEmpty ? name : "\(institution) - \(name)"
    }

    /// Category order, then institution and name, A to Z. An account with
    /// no institution sorts by its name among them. Added order is only the
    /// last tiebreak: lists in the order accounts were typed in put a
    /// household's two Chase accounts screens apart.
    static func displayOrder(_ lhs: SharedFinanceAccount, _ rhs: SharedFinanceAccount) -> Bool {
        if lhs.category != rhs.category { return lhs.category.sortIndex < rhs.category.sortIndex }
        return institutionOrder(lhs, rhs)
    }

    /// Institution, then name, then the order they were added.
    static func institutionOrder(_ lhs: SharedFinanceAccount, _ rhs: SharedFinanceAccount) -> Bool {
        let byName = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if byName != .orderedSame { return byName == .orderedAscending }
        return lhs.sortOrder < rhs.sortOrder
    }

    /// A card's balance for a month: what was charged to it that month,
    /// counting only our share of each charge — the sheet's SUMIFS.
    func spend(in period: YearMonth) -> Double {
        (transactions ?? [])
            .filter { period.contains($0.date) }
            .reduce(0) { $0 + $1.actualCost }
    }

    func balance(in month: SharedFinanceMonth) -> SharedFinanceBalance? {
        (balances ?? []).first { $0.month == month }
    }

    /// What this account stood at in `month`: the typed balance, or for a
    /// card that month's spend.
    func value(in month: SharedFinanceMonth) -> Double {
        if category == .card {
            guard let period = month.period else { return 0 }
            return spend(in: period)
        }
        return balance(in: month)?.amount ?? 0
    }

    var transactionCount: Int { transactions?.count ?? 0 }
}

// MARK: - Month

public extension SharedFinanceMonth {
    var id: NSManagedObjectID { objectID }

    /// nil only for a malformed `yearMonth`, which nothing here writes.
    var period: YearMonth? { YearMonth(yearMonth) }

    var title: String { period?.title ?? yearMonth }
    var monthName: String { period?.monthName ?? yearMonth }

    var isClosed: Bool { closedAt != nil }

    var metalPrices: MetalPrices {
        MetalPrices(gold: goldPricePerOz, silver: silverPricePerOz)
    }

    /// The household's month before this one, if there is one.
    /// Among duplicates of that period, the one `FinanceFold` keeps — as
    /// `SharedFinanceHousehold.month(for:)` picks.
    var previousMonth: SharedFinanceMonth? {
        FinanceFold.distinctMonths(
            (household?.months ?? []).filter { !$0.isDeleted && $0.yearMonth < yearMonth && $0.period != nil }
        ).last
    }

    func balance(for account: SharedFinanceAccount) -> SharedFinanceBalance? {
        (balances ?? []).first { $0.account == account }
    }

    /// Types in a balance, making one if this account has none this month
    /// (an account added after the month began).
    @discardableResult
    func setBalance(_ amount: Double, for account: SharedFinanceAccount) -> SharedFinanceBalance {
        let balance = balance(for: account) ?? SharedFinanceBalance(account: account, month: self, amount: amount, edited: true)
        balance.amount = amount
        balance.edited = true
        return balance
    }

    /// Balances in the order the month entry lists them.
    var sortedBalances: [SharedFinanceBalance] {
        (balances ?? [])
            .filter { $0.account != nil }
            .sorted { lhs, rhs in
                guard let left = lhs.account, let right = rhs.account else { return false }
                return SharedFinanceAccount.displayOrder(left, right)
            }
    }

    var sortedBudgets: [SharedFinanceBudget] {
        (budgets ?? []).sorted { $0.category.localizedStandardCompare($1.category) == .orderedAscending }
    }

    func budget(for category: String) -> SharedFinanceBudget? {
        let key = SpendingSummary.key(category)
        return (budgets ?? []).first { SpendingSummary.key($0.category) == key }
    }

    /// The household's transactions dated in this month.
    var transactionsInMonth: [SharedFinanceTransaction] {
        guard let period else { return [] }
        return Array(household?.transactions ?? []).filter { period.contains($0.date) }
    }

    func close(asOf now: Date = .now) {
        closedAt = now
    }

    func reopen() {
        closedAt = nil
    }
}

// MARK: - Balance

public extension SharedFinanceBalance {
    var id: NSManagedObjectID { objectID }
}

// MARK: - Budget

public extension SharedFinanceBudget {
    var id: NSManagedObjectID { objectID }
}

// MARK: - Metal

public extension SharedFinanceMetalItem {
    var id: NSManagedObjectID { objectID }

    var metal: MetalKind {
        get { MetalKind(rawValue: metalRaw) ?? .gold }
        set { metalRaw = newValue.rawValue }
    }

    var ounces: Double { MetalValuation.ounces(grams: grams) }

    /// What it's worth at `prices`: the hand-set value if there is one,
    /// otherwise its weight at the spot price for its metal.
    func value(at prices: MetalPrices) -> Double {
        MetalValuation.value(
            grams: grams,
            metal: metal,
            manualValue: hasManualValue ? manualValue : nil,
            prices: prices
        )
    }

    /// What it cost, if that's known: the purchase value, or failing that
    /// its weight at the price paid per ounce.
    var cost: Double? {
        MetalValuation.cost(grams: grams, pricePaidPerOz: pricePaidPerOz, purchaseValue: purchaseValue)
    }

    /// Value minus cost, or nil when nothing was recorded about the cost.
    func gain(at prices: MetalPrices) -> Double? {
        guard let cost else { return nil }
        return value(at: prices) - cost
    }

    static func displayOrder(_ lhs: SharedFinanceMetalItem, _ rhs: SharedFinanceMetalItem) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

// MARK: - Transaction

public extension SharedFinanceTransaction {
    var id: NSManagedObjectID { objectID }

    /// Whether only part of it is ours.
    var isSplit: Bool { actualCost != cost }

    var isRefund: Bool { actualCost < 0 }

    /// "Food · Dinner · Chase - Sapphire Preferred", leaving out whatever's blank.
    var detailLine: String {
        [category, expense, card?.displayName ?? ""]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
