import Core
import CoreData
import Foundation

/// One tile of the Summary's balance sheet: Cash, Investments, … Owed.
public enum BalanceTile: String, CaseIterable, Identifiable, Hashable, Sendable {
    case cash
    case investments
    case retirement
    case health
    case metals
    case fixed
    case owed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cash: "Cash"
        case .investments: "Investments"
        case .retirement: "Retirement"
        case .health: "Health"
        case .metals: "Gold & silver"
        case .fixed: "Cars & property"
        case .owed: "Owed"
        }
    }

    public var symbolName: String {
        switch self {
        case .cash: AccountCategory.cash.symbolName
        case .investments: AccountCategory.investments.symbolName
        case .retirement: AccountCategory.retirement.symbolName
        case .health: AccountCategory.health.symbolName
        case .metals: "circle.hexagongrid"
        case .fixed: AccountCategory.fixed.symbolName
        case .owed: AccountCategory.card.symbolName
        }
    }

    /// Owed is the only liability: going down is the good direction.
    public var isAsset: Bool { self != .owed }

    /// The tile's figure — what `MonthSummary` added up for it.
    public func value(in summary: MonthSummary) -> Double {
        switch self {
        case .cash: summary.cash
        case .investments: summary.investments
        case .retirement: summary.retirement
        case .health: summary.health
        case .metals: summary.metals
        case .fixed: summary.fixed
        case .owed: summary.owed
        }
    }

    /// The account categories whose balances make up the tile. None for
    /// gold & silver, which are items, not accounts.
    var categories: [AccountCategory] {
        switch self {
        case .cash: [.cash]
        case .investments: [.investments]
        case .retirement: [.retirement]
        case .health: [.health]
        case .metals: []
        case .fixed: [.fixed]
        case .owed: [.card, .loan]
        }
    }
}

/// Everything behind one Summary tile for a month, ready for its detail
/// screen: the figure and its change, a year of it, and the accounts or items
/// it adds up — each with what it was the month before.
///
/// Built from the same inputs as `MonthSummary` and added up the same way, so
/// the lines always sum to the tile: balances by their account's category and
/// owner, cards by their spend in the month, metals at the month's prices
/// (live while it's open).
public struct BalanceTileDetail {
    public struct Line: Identifiable {
        public let id: NSManagedObjectID
        public let title: String
        /// "Bhavik · 12 transactions", "31.1 g · Safe · Saloni".
        public let subtitle: String?
        public let amount: Double
        /// The same account's or item's figure the month before; nil when
        /// there was no month before, or the account had no balance in it.
        public let previous: Double?
        /// For a metal whose cost is known: value less cost.
        public let gain: Double?

        public var change: Double? { previous.map { amount - $0 } }
    }

    public struct Group: Identifiable {
        public let title: String
        /// By amount, largest first.
        public let lines: [Line]
        public var total: Double { lines.reduce(0) { $0 + $1.amount } }
        public var id: String { title }
    }

    public let tile: BalanceTile
    public let month: SharedFinanceMonth
    public let total: Double
    /// The tile's figure the month before; nil for the first month.
    public let previousTotal: Double?
    /// Of the month's total assets, 0…1; nil for Owed.
    public let shareOfAssets: Double?
    public let groups: [Group]
    /// Up to a year of the tile's figure, oldest first, ending with `month`.
    public let series: [FinanceHistory.Value]
    /// Gold & silver only: what the items are valued at, and whether those
    /// are today's prices (the month is still open) or the month's own.
    public let prices: MetalPrices?
    public let pricesAreLive: Bool

    public var change: Double? { previousTotal.map { total - $0 } }
    public var isEmpty: Bool { groups.allSatisfy(\.lines.isEmpty) }

    /// `cards` and `metals` are the household's, as `MonthSummary` takes
    /// them; `months` every month, for the year's series.
    public init(
        tile: BalanceTile,
        month: SharedFinanceMonth,
        months: [SharedFinanceMonth],
        cards: [SharedFinanceAccount],
        metals: [SharedFinanceMetalItem],
        filter: OwnerFilter = .all,
        live: MetalPrices? = nil
    ) {
        self.tile = tile
        self.month = month
        let history = FinanceHistory(months: months, filter: filter, live: live)
        let summary = MonthSummary(month: month, cards: cards, metals: metals, filter: filter, live: live)
        let previousMonth = month.period.flatMap { history.point(before: $0)?.month }
        total = tile.value(in: summary)
        previousTotal = previousMonth.map {
            tile.value(in: MonthSummary(month: $0, cards: cards, metals: metals, filter: filter, live: live))
        }
        shareOfAssets = tile.isAsset ? (summary.totalAssets > 0 ? total / summary.totalAssets : 0) : nil
        series = month.period.map { period in
            history.points
                .filter { $0.period <= period }
                .suffix(12)
                .map { FinanceHistory.Value(period: $0.period, value: tile.value(in: $0.summary)) }
        } ?? []

        switch tile {
        case .metals:
            let prices = MetalPriceFeed.effectivePrices(for: month, live: live)
            let previousPrices = previousMonth.map { MetalPriceFeed.effectivePrices(for: $0, live: live) }
            self.prices = prices
            pricesAreLive = MetalPriceFeed.usesLivePrices(month, live: live)
            groups = Self.metalGroups(metals.filter { filter.includes($0.owner) }, prices: prices, previousPrices: previousPrices)
        case .owed:
            prices = nil
            pricesAreLive = false
            groups = [
                Group(title: "Cards", lines: Self.cardLines(cards, in: month, previous: previousMonth, filter: filter)),
                Group(title: "Loans", lines: Self.balanceLines(.loan, in: month, previous: previousMonth, filter: filter, showsOwner: true)),
            ].filter { !$0.lines.isEmpty }
        default:
            prices = nil
            pricesAreLive = false
            groups = Self.ownerGroups(tile.categories, in: month, previous: previousMonth, filter: filter)
        }
    }

    // MARK: - Accounts

    /// The month's balances in `categories`, one group per owner in People's
    /// order, accounts with no owner last.
    private static func ownerGroups(
        _ categories: [AccountCategory],
        in month: SharedFinanceMonth,
        previous: SharedFinanceMonth?,
        filter: OwnerFilter
    ) -> [Group] {
        let balances = (month.balances ?? []).filter { balance in
            guard let account = balance.account else { return false }
            return categories.contains(account.category) && filter.includes(account.owner)
        }
        let owners = Set(balances.compactMap { $0.account?.owner }).sorted(by: SharedFinanceOwner.displayOrder)
        var groups = owners.map { owner in
            Group(title: owner.name, lines: lines(balances.filter { $0.account?.owner == owner }, previous: previous, showsOwner: false))
        }
        let unowned = balances.filter { $0.account?.owner == nil }
        if !unowned.isEmpty {
            groups.append(Group(title: "No one", lines: lines(unowned, previous: previous, showsOwner: false)))
        }
        return groups.filter { !$0.lines.isEmpty }
    }

    private static func balanceLines(
        _ category: AccountCategory,
        in month: SharedFinanceMonth,
        previous: SharedFinanceMonth?,
        filter: OwnerFilter,
        showsOwner: Bool
    ) -> [Line] {
        let balances = (month.balances ?? []).filter { balance in
            guard let account = balance.account else { return false }
            return account.category == category && filter.includes(account.owner)
        }
        return lines(balances, previous: previous, showsOwner: showsOwner)
    }

    /// An archived account at zero is left out — it's history, not a holding.
    /// One still open at zero stays: that's a balance not typed in yet.
    private static func lines(_ balances: some Sequence<SharedFinanceBalance>, previous: SharedFinanceMonth?, showsOwner: Bool) -> [Line] {
        balances.compactMap { balance -> Line? in
            guard let account = balance.account else { return nil }
            let previousAmount = previous.flatMap { account.balance(in: $0)?.amount }
            if account.isArchived, balance.amount == 0, (previousAmount ?? 0) == 0 { return nil }
            return Line(
                id: balance.objectID,
                title: account.displayName,
                subtitle: showsOwner ? account.owner?.name : nil,
                amount: balance.amount,
                previous: previousAmount,
                gain: nil
            )
        }
        .sorted(by: largestFirst)
    }

    /// Every card with spend this month, or last — a card paid off to zero
    /// this month still says what it was.
    private static func cardLines(
        _ cards: [SharedFinanceAccount],
        in month: SharedFinanceMonth,
        previous: SharedFinanceMonth?,
        filter: OwnerFilter
    ) -> [Line] {
        guard let period = month.period else { return [] }
        return cards.compactMap { card -> Line? in
            guard card.category == .card, filter.includes(card.owner) else { return nil }
            let spend = card.spend(in: period)
            let previousSpend = previous?.period.map { card.spend(in: $0) }
            guard spend != 0 || (previousSpend ?? 0) != 0 else { return nil }
            let count = (card.transactions ?? []).count { period.contains($0.date) }
            let subtitle = [card.owner?.name, counted(count, "transaction")].compactMap(\.self).joined(separator: " · ")
            return Line(id: card.objectID, title: card.displayName, subtitle: subtitle, amount: spend, previous: previousSpend, gain: nil)
        }
        .sorted(by: largestFirst)
    }

    // MARK: - Metals

    /// Gold, then silver, each item with its weight, where it's kept and
    /// whose it is.
    private static func metalGroups(_ items: [SharedFinanceMetalItem], prices: MetalPrices, previousPrices: MetalPrices?) -> [Group] {
        MetalKind.allCases.map { metal in
            Group(title: metal.displayName, lines: items.filter { $0.metal == metal }.map { item in
                let location = item.location.trimmingCharacters(in: .whitespaces)
                let subtitle = [
                    FinanceFormat.grams(item.grams),
                    location.isEmpty ? nil : location,
                    item.owner?.name,
                ].compactMap(\.self).joined(separator: " · ")
                return Line(
                    id: item.objectID,
                    title: item.name.isEmpty ? metal.displayName : item.name,
                    subtitle: subtitle,
                    amount: item.value(at: prices),
                    previous: previousPrices.map { item.value(at: $0) },
                    gain: item.gain(at: prices)
                )
            }
            .sorted(by: largestFirst))
        }
        .filter { !$0.lines.isEmpty }
    }

    private static func largestFirst(_ lhs: Line, _ rhs: Line) -> Bool {
        lhs.amount != rhs.amount ? lhs.amount > rhs.amount : lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}
