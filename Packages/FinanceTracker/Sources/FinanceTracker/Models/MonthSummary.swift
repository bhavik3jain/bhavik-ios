import CoreData
import Foundation

/// Whose money the Summary is showing. Joint is an owner like any other, so
/// filtering on it shows the joint accounts only — not everyone's.
public enum OwnerFilter: Hashable {
    case all
    case owner(SharedFinanceOwner)

    /// Whether something held by `owner` counts. Under a filter, things with
    /// no owner at all belong to no one and are left out.
    public func includes(_ owner: SharedFinanceOwner?) -> Bool {
        switch self {
        case .all: true
        case .owner(let wanted): owner == wanted
        }
    }
}

/// One month's balance sheet, added up — the Summary tab's tiles and the
/// Months tab's figures.
///
/// Assets are cash, investments, retirement, cars & property and gold &
/// silver. Liabilities are short-term (this month's card spend) plus
/// long-term (what's left on the loans).
public struct MonthSummary: Equatable, Sendable {
    public var cash = 0.0
    public var investments = 0.0
    public var retirement = 0.0
    /// Cars & property.
    public var fixed = 0.0
    /// Gold & silver — "Personal Items" in the Numbers sheet.
    public var metals = 0.0
    /// Short-term liabilities: every card's spend this month.
    public var cardSpend = 0.0
    /// Long-term liabilities: remaining principal.
    public var loans = 0.0

    public init() {}

    /// Everything from the month's own household.
    public init(month: SharedFinanceMonth, filter: OwnerFilter = .all) {
        let household = month.household
        self.init(
            month: month,
            cards: Array(household?.accounts ?? []).filter { $0.category == .card },
            metals: Array(household?.metalItems ?? []),
            filter: filter
        )
    }

    /// Accounts are filtered by their owner, metals by theirs, and cards by
    /// the card's owner — a charge on Bhavik's card is Bhavik's.
    public init(
        month: SharedFinanceMonth,
        cards: [SharedFinanceAccount],
        metals: [SharedFinanceMetalItem],
        filter: OwnerFilter = .all
    ) {
        for balance in month.balances ?? [] {
            guard let account = balance.account, filter.includes(account.owner) else { continue }
            add(balance.amount, to: account.category)
        }
        if let period = month.period {
            for card in cards where card.category == .card && filter.includes(card.owner) {
                cardSpend += card.spend(in: period)
            }
        }
        let prices = month.metalPrices
        for item in metals where filter.includes(item.owner) {
            self.metals += item.value(at: prices)
        }
    }

    mutating func add(_ amount: Double, to category: AccountCategory) {
        switch category {
        case .cash: cash += amount
        case .investments: investments += amount
        case .retirement: retirement += amount
        case .fixed: fixed += amount
        case .loan: loans += amount
        // A card's figure is its transactions, never a typed balance; one
        // left over from before an account became a card is ignored.
        case .card: break
        }
    }

    public var totalAssets: Double { cash + investments + retirement + fixed + metals }
    public var totalLiabilities: Double { cardSpend + loans }
    public var netWorth: Double { totalAssets - totalLiabilities }

    /// The "Owed" tile: cards plus loans.
    public var owed: Double { totalLiabilities }

    public func value(for metric: FinanceMetric) -> Double {
        switch metric {
        case .netWorth: netWorth
        case .cash: cash
        case .investments: investments
        case .retirement: retirement
        case .metals: metals
        case .fixed: fixed
        case .cardSpend: cardSpend
        }
    }
}

/// Every month in order, added up — the net-worth chart and the Months list.
public struct FinanceHistory {
    public struct Point: Identifiable {
        public let period: YearMonth
        public let month: SharedFinanceMonth
        public let summary: MonthSummary

        public var id: String { period.rawValue }
    }

    /// One value on a chart.
    public struct Value: Identifiable, Equatable, Sendable {
        public let period: YearMonth
        public let value: Double

        public var id: String { period.rawValue }
    }

    /// Oldest first.
    public let points: [Point]

    /// A month duplicated by two devices counts once — the one
    /// `FinanceFold` keeps. Two rows of one period gave the Months list
    /// duplicate IDs until the fold caught up (and in a view-only share, it
    /// never can).
    public init(months: [SharedFinanceMonth], filter: OwnerFilter = .all) {
        points = FinanceFold.distinctMonths(months)
            .compactMap { month in month.period.map { (period: $0, month: month) } }
            .sorted { $0.period < $1.period }
            .map { Point(period: $0.period, month: $0.month, summary: MonthSummary(month: $0.month, filter: filter)) }
    }

    public var latest: Point? { points.last }

    /// The month before `period`'s, if there is one.
    public func point(before period: YearMonth) -> Point? {
        points.last { $0.period < period }
    }

    public func series(_ metric: FinanceMetric, last count: Int? = nil) -> [Value] {
        let values = points.map { Value(period: $0.period, value: $0.summary.value(for: metric)) }
        guard let count else { return values }
        return Array(values.suffix(count))
    }

    /// Change from the month before; nil for the first month.
    public func delta(_ metric: FinanceMetric, at period: YearMonth) -> Double? {
        guard let current = points.first(where: { $0.period == period }),
              let previous = point(before: period)
        else { return nil }
        return current.summary.value(for: metric) - previous.summary.value(for: metric)
    }
}

/// The home screen's line and peek for Finance.
public enum FinanceHome {
    /// "Net worth $557,506" for the latest month, or "No months yet".
    @MainActor
    public static func homeDetail(for months: [SharedFinanceMonth], container: NSPersistentCloudKitContainer?) -> String {
        guard let latest = latestMonth(months, container: container) else { return "No months yet" }
        return "Net worth \(FinanceFormat.money(MonthSummary(month: latest).netWorth))"
    }

    /// The latest month of the household the module itself shows
    /// (`FinanceHouseholdResolver.forDisplay`). The app shell fetches every
    /// household's months, and taking the newest across all of them put this
    /// person's own household on the home screen while the module showed the
    /// partner's share — or a duplicate household the module had hidden.
    @MainActor
    public static func latestMonth(_ months: [SharedFinanceMonth], container: NSPersistentCloudKitContainer?) -> SharedFinanceMonth? {
        guard let context = months.first?.managedObjectContext else { return nil }
        let households = (try? context.fetch(SharedFinanceHousehold.fetchRequest())) ?? []
        let shown = FinanceHouseholdResolver.forDisplay(among: households, container: container)
        return FinanceFold.distinctMonths(months.filter { $0.household == shown && $0.period != nil }).last
    }
}
