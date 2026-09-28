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
    public init(month: SharedFinanceMonth, filter: OwnerFilter = .all, live: MetalPrices? = nil) {
        let household = month.household
        self.init(
            month: month,
            cards: Array(household?.accounts ?? []).filter { $0.category == .card },
            metals: Array(household?.metalItems ?? []),
            filter: filter,
            live: live
        )
    }

    /// Accounts are filtered by their owner, metals by theirs, and cards by
    /// the card's owner — a charge on Bhavik's card is Bhavik's.
    public init(
        month: SharedFinanceMonth,
        cards: [SharedFinanceAccount],
        metals: [SharedFinanceMetalItem],
        filter: OwnerFilter = .all,
        live: MetalPrices? = nil
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
        // `live` (MetalPriceFeed's) only counts for the latest open month.
        let prices = MetalPriceFeed.effectivePrices(for: month, live: live)
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
    public init(months: [SharedFinanceMonth], filter: OwnerFilter = .all, live: MetalPrices? = nil) {
        points = FinanceFold.distinctMonths(months)
            .compactMap { month in month.period.map { (period: $0, month: month) } }
            .sorted { $0.period < $1.period }
            .map { Point(period: $0.period, month: $0.month, summary: MonthSummary(month: $0.month, filter: filter, live: live)) }
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

    /// The months a chart of `series` spans: at least `minimumMonths`,
    /// ending with the latest. Left to itself Swift Charts fits the axis to
    /// the data, so a household's first month was one bar the width of the
    /// window.
    public static func chartDomain(_ series: [Value], minimumMonths: Int = 12) -> ClosedRange<Date>? {
        guard let first = series.map(\.period).min(), let last = series.map(\.period).max() else { return nil }
        let earliest = YearMonth(year: last.year, month: last.month - (minimumMonths - 1))
        return min(first, earliest).start...last.end
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
        return "Net worth \(FinanceFormat.money(MonthSummary(month: latest, live: MetalPriceFeed.shared.live).netWorth))"
    }

    /// How `latest`'s net worth moved on the month before it in its
    /// household, and which month that was — the Mac Overview's "+$1,204
    /// since August". nil when there is no earlier month.
    ///
    /// Adds up just those two months. The Overview card used to build a
    /// `FinanceHistory` of every month the household has — each one walking
    /// every card's transactions — on each render, for one subtraction.
    public static func netWorthChange(for latest: SharedFinanceMonth, live: MetalPrices?) -> (delta: Double, previous: YearMonth)? {
        guard let period = latest.period else { return nil }
        // Folded first, so a period two devices both created counts as the
        // one row `FinanceHistory` would have kept.
        let earlier = FinanceFold.distinctMonths(Array(latest.household?.months ?? []))
            .filter { ($0.period).map { $0 < period } ?? false }
        guard let previous = earlier.last, let previousPeriod = previous.period else { return nil }
        let history = FinanceHistory(months: [previous, latest], live: live)
        return history.delta(.netWorth, at: period).map { ($0, previousPeriod) }
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
