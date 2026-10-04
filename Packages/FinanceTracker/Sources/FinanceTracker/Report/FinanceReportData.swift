import Foundation

/// Everything a Finance report shows, already added up and worded: one
/// `Sendable` value built on the main actor from the household's Core Data
/// objects (`FinanceReportData.build`, in FinanceReportDataBuilder.swift), so
/// the HTML builder, the review and the views never touch the store.
///
/// The figures are the app's own: the month is `FinanceHome.reportedMonth`'s
/// unless a scope names another, balances are added up by `MonthSummary`,
/// budgets by `BudgetStatus` (so a category at `SharedFinanceBudget.noLimit`
/// is an unbudgeted line, never a -$1 budget), metals at
/// `MetalPriceFeed.effectivePrices` (live only for the latest open month),
/// months one per period through `FinanceFold.distinctMonths`. A report that
/// disagreed with Summary, Spending or Holdings would be worse than none.
///
/// Every money figure keeps its raw `Double` next to the text it reads as;
/// the text is always `FinanceFormat`'s.
public struct FinanceReportData: Sendable, Equatable {
    public let scope: ReportScope
    /// The month whose balance sheet the report shows: the scope's month, or
    /// a year's last month (the month before it while that one is still
    /// being filled in).
    public let period: YearMonth
    /// What `period` is compared with: the month before, or for a year the
    /// month before the year began (its first month when there's none).
    /// nil for a household's first month.
    public let comparisonPeriod: YearMonth?
    public let header: Header
    public let hero: Hero
    /// Total assets, owed, liquid cash, retirement, card use — in that order.
    public let kpis: [KPI]
    /// Every asset kind with a value now or then, largest first.
    public let mix: [MixLine]
    public let mixLede: String
    /// Each line's effect on net worth since `comparisonPeriod`; adds up to
    /// `hero.delta` exactly. Empty with nothing to compare against.
    public let moved: [MovedLine]
    public let movedLede: String
    /// Up to twelve months of net worth ending with `period`, or for a year
    /// every month of it, after the month it's compared with.
    public let trend: Trend
    /// Accounts by category (cards are `cards`), biggest category first and
    /// loans last.
    public let accountGroups: [AccountGroupSection]
    public let metals: MetalsSection
    public let spending: SpendingSection
    public let cards: CardsSection
    /// Year scope only.
    public let year: YearSection?
    /// What `MonthCheck` or `YearCheck` found, unordered.
    public internal(set) var findings: [ReportFinding]

    /// The report's "Worth fixing", most distorting first.
    public var worthFixing: [ReportFinding] { findings.worthFixing }

    /// "3 went well · 2 to watch · 2 to try" — the Summary card's chips.
    public var toneCounts: ToneCounts {
        ToneCounts(
            wentWell: findings.count { $0.tone == .wentWell },
            watch: findings.count { $0.tone == .watch },
            tryNext: findings.count { $0.tone == .tryNext }
        )
    }

    /// The section ids the HTML uses, in page order, with their titles — the
    /// viewer's "Jump to Section" and the Mac contents sidebar.
    public var sections: [ReportSection] {
        var sections: [ReportSection] = [
            ReportSection(id: "brief", title: scope.isYear ? "The year in brief" : "The month in brief"),
            ReportSection(id: "networth", title: "Net worth"),
            ReportSection(id: "figures", title: "Key figures"),
            ReportSection(id: "mix", title: "Where the money sits"),
        ]
        if !moved.isEmpty {
            sections.append(ReportSection(id: "moved", title: comparisonPeriod.map { "What moved since \($0.monthName)" } ?? "What moved"))
        }
        sections.append(ReportSection(id: "trend", title: scope.isYear ? "Month by month" : "The last 12 months"))
        if !accountGroups.isEmpty { sections.append(ReportSection(id: "accounts", title: "Accounts")) }
        if !metals.items.isEmpty { sections.append(ReportSection(id: "metals", title: "Gold and silver")) }
        sections.append(ReportSection(id: "spending", title: "Spending"))
        if !cards.cards.isEmpty { sections.append(ReportSection(id: "cards", title: "Cards")) }
        if !worthFixing.isEmpty { sections.append(ReportSection(id: "fixing", title: "Worth fixing")) }
        return sections
    }

    public struct ToneCounts: Sendable, Equatable {
        public let wentWell: Int
        public let watch: Int
        public let tryNext: Int

        public var total: Int { wentWell + watch + tryNext }

        /// "3 went well · 2 to watch · 2 to try", leaving out the zeros.
        public var label: String {
            [
                wentWell > 0 ? "\(wentWell) went well" : nil,
                watch > 0 ? "\(watch) to watch" : nil,
                tryNext > 0 ? "\(tryNext) to try" : nil,
            ].compactMap(\.self).joined(separator: " · ")
        }
    }

    public struct ReportSection: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
    }

    // MARK: - Header and hero

    public struct Header: Sendable, Equatable {
        /// "September 2026", "2026 in review".
        public let title: String
        /// "Everyone", or the owner's name.
        public let ownerLabel: String
        /// "Multitrack · Finance · Net worth summary · Everyone".
        public let kicker: String
        public let builtAt: Date
        /// "October 3, 2026", in the reader's locale.
        public let builtAtText: String
        /// "Bhavik's iPhone" — passed in by the caller; Finance never asks.
        public let deviceName: String
        /// "Built on Bhavik's iPhone on October 3, 2026 from the household's own figures."
        public let builtNote: String
        /// Which month this is and how finished: "October is 3 of 13 filled
        /// in, so this covers September, which was finished on October 2 and
        /// keeps the metal prices saved that day."
        public let coverageNote: String
        /// The month shown is still open: balances may be partial.
        public let isPartial: Bool
        /// Gold and silver are at today's prices, not saved ones.
        public let pricesAreLive: Bool
        /// When the month shown was finished; nil while open.
        public let closedAt: Date?
        /// The latest month, when it's open and not yet complete — and so
        /// not the one shown on a month scope that defaulted past it.
        public let openMonth: OpenMonth?
    }

    /// A month still being filled in.
    public struct OpenMonth: Sendable, Equatable {
        public let period: YearMonth
        public let progress: MonthProgress
        /// "3 of 13 filled in".
        public var progressText: String { "\(progress.updated) of \(progress.total) filled in" }
    }

    public struct Hero: Sendable, Equatable {
        public let netWorth: Double
        public let netWorthText: String
        /// Against `comparisonPeriod`; nil without one.
        public let delta: Double?
        /// "+$5,565".
        public let deltaText: String?
        /// Of the comparison's net worth; nil when that was zero or negative.
        public let deltaFraction: Double?
        /// "1.5%" (unsigned; `deltaText` carries the sign).
        public let deltaPercentText: String?
        /// "August", "December 2025".
        public let comparisonName: String?
        /// "+$5,565 · 1.5% on August", or "First month" with nothing to compare.
        public let deltaLine: String
        public let assets: Double
        public let assetsText: String
        /// Cards plus loans.
        public let owed: Double
        public let owedText: String
        /// "$404,318 assets − $16,643 owed".
        public let assetsLine: String
    }

    public struct KPI: Sendable, Equatable, Identifiable {
        /// "assets", "owed", "cash", "retirement", "cardUse".
        public let id: String
        public let label: String
        public let value: Double
        public let valueText: String
        /// "6 categories", "Cards $2,263 · loans $14,380".
        public let detail: String
    }

    // MARK: - Mix and moves

    public struct MixLine: Sendable, Equatable, Identifiable {
        public let metric: FinanceMetric
        public let name: String
        public let value: Double
        public let valueText: String
        /// Of total assets, 0…1 (0 for a negative balance).
        public let share: Double
        public let shareText: String
        public let previous: Double?
        public let delta: Double?
        /// "+$2,300", "no change"; nil with nothing to compare.
        public let deltaText: String?
        /// 1…6: the design's `--s1`…`--s6` series colour, fixed per kind so a
        /// kind keeps its colour from report to report.
        public let colorIndex: Int

        public var id: String { metric.rawValue }
    }

    public struct MovedLine: Sendable, Equatable, Identifiable {
        public enum Source: Sendable, Equatable {
            case asset(FinanceMetric)
            case loans
            case cards
        }

        public let id: String
        public let source: Source
        /// "Retirement", "Car loan paid down", "Card spend".
        public let name: String
        /// Signed effect on net worth: a loan paid down is positive, more
        /// card spend negative.
        public let impact: Double
        /// "+$2,300", "−$310".
        public let impactText: String
    }

    public struct Trend: Sendable, Equatable {
        public let points: [TrendPoint]
        /// Last minus first; nil with fewer than two points.
        public let change: Double?
        public let changeText: String?
        /// `change` spread over the months between the first and last point.
        public let perMonth: Double?
        /// The months net worth fell on the month before.
        public let dips: [YearMonth]
        /// "Up $56,435 since October 2025, about $5,100 a month. The only dips were December and April."
        public let lede: String
    }

    public struct TrendPoint: Sendable, Equatable, Identifiable {
        public let period: YearMonth
        /// "Oct".
        public let label: String
        public let value: Double
        public let valueText: String

        public var id: String { period.rawValue }
    }

    // MARK: - Accounts

    public struct AccountGroupSection: Sendable, Equatable, Identifiable {
        public let category: AccountCategory
        /// "Retirement", "Loans".
        public let title: String
        public let total: Double
        public let totalText: String
        public let previousTotal: Double?
        public let change: Double?
        /// "2 accounts. Bhavik $144,100, Saloni $58,100. Up $2,300 on August."
        public let lede: String
        /// Largest first.
        public let rows: [AccountRow]
        /// The owners in `rows`, for the legend.
        public let owners: [OwnerChip]

        public var id: String { category.rawValue }
    }

    public struct AccountRow: Sendable, Equatable, Identifiable {
        /// The account's object URI — stable, opaque.
        public let id: String
        /// "Plan Provider - 401(k)".
        public let name: String
        public let ownerName: String?
        public let owner: OwnerChip?
        public let category: AccountCategory
        public let value: Double
        public let valueText: String
        /// The same account the month before; nil when it had no balance then.
        public let previous: Double?
        /// Matches `previous` to the dollar, and isn't zero.
        public let isUnchanged: Bool
        /// Typed in for this month, or the month is finished. An open month
        /// starts every balance at a zero nobody typed (`MonthRollover`), and
        /// a check reading that zero as real called a loan "paid off".
        public let isFilledIn: Bool

        public var change: Double? { previous.map { value - $0 } }
    }

    /// An owner's name and badge colour, for legends and bars.
    public struct OwnerChip: Sendable, Equatable, Hashable, Identifiable {
        public let name: String
        public let colorName: String
        /// "#2a78d6" — for a light page.
        public let colorHex: String
        /// The same colour for a dark page.
        public let colorHexDark: String

        public var id: String { name }
    }

    // MARK: - Metals

    public struct MetalsSection: Sendable, Equatable {
        public let total: Double
        public let totalText: String
        public let totalGrams: Double
        public let gold: MetalTotal
        public let silver: MetalTotal
        /// Biggest value first.
        public let locations: [LocationTotal]
        /// Biggest value first.
        public let items: [MetalRow]
        /// What every item that follows the price is valued at.
        public let prices: MetalPrices
        /// "$4,420.00" / "$50.50" an ounce.
        public let goldPriceText: String
        public let silverPriceText: String
        /// Today's prices (the latest month is still open), not saved ones.
        public let pricesAreLive: Bool
        /// Items whose cost is known: what they cost, and what they're worth now less that.
        public let paid: Double
        public let gainOnCosted: Double
        /// "5 items, 214 g. Valued at the prices saved when September was
        /// finished: gold $4,420.00 and silver $50.50 an ounce. Four follow the
        /// price; Gold - Ring holds a typed value."
        public let lede: String

        public var typedItems: [MetalRow] { items.filter(\.isTyped) }
        public var costedItems: [MetalRow] { items.filter { $0.cost != nil } }
    }

    public struct MetalTotal: Sendable, Equatable {
        public let metal: MetalKind
        public let value: Double
        public let valueText: String
        public let grams: Double
        public let gramsText: String
        public let count: Int
        /// "164 g · 4 items".
        public let detail: String
    }

    public struct LocationTotal: Sendable, Equatable, Identifiable {
        public let name: String
        public let value: Double
        public let valueText: String
        public let share: Double
        /// "72% of holdings".
        public let detail: String

        public var id: String { name }
    }

    public struct MetalRow: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let metal: MetalKind
        public let grams: Double
        public let gramsText: String
        /// Empty when not set.
        public let location: String
        public let ownerName: String?
        public let owner: OwnerChip?
        public let value: Double
        public let valueText: String
        /// Holds a typed value rather than weight × price.
        public let isTyped: Bool
        /// What it cost, when that was recorded.
        public let cost: Double?
        public let costText: String?
        public let gain: Double?
        /// Value over cost, less one — 0.92 is +92%.
        public let gainFraction: Double?
        /// "100 g · Locker", "typed value · Home".
        public let detail: String
    }

    // MARK: - Spending

    public struct SpendingSection: Sendable, Equatable {
        /// For a year, every month of it; otherwise the one month.
        public let periods: [YearMonth]
        public let total: Double
        public let totalText: String
        /// Charged to cards — the part that's owed.
        public let onCards: Double
        public let onCardsText: String
        /// Paid straight from cash accounts (rent by Zelle).
        public let fromCash: Double
        public let fromCashText: String
        public let transactionCount: Int
        /// The average month over the three before (a month scope only; nil
        /// with no earlier transactions).
        public let average: Double?
        public let averageText: String?
        /// The months `average` is over, oldest first.
        public let averageMonths: [YearMonth]
        /// Of `average`: 0.03 is 3% more than usual.
        public let changeVsAverage: Double?
        /// Every category, biggest first.
        public let categories: [CategorySpend]
        /// Categories furthest from their average, biggest change first.
        public let biggestChanges: [CategorySpend]
        /// The month's budgets with a limit, in category order (empty for a year).
        public let budgets: [BudgetRow]
        /// Categories kept with "No budget" and those spent on with none, biggest first.
        public let unbudgeted: [UnbudgetedRow]
        public let unbudgetedTotal: Double
        public let unbudgetedTotalText: String
        /// How much the over-budget lines are over, together.
        public let overBudgetTotal: Double
        public let overBudgetCount: Int
        /// Budgets compare the household's limits with the household's
        /// spending, whoever the report is for: under an owner filter they
        /// still count everyone's.
        public let budgetsAreHouseholdWide: Bool
        /// By card or cash account, biggest first.
        public let byAccount: [AccountSpend]
        /// By total, the top ten.
        public let topMerchants: [MerchantRow]
        /// Card charges that come round every month, biggest first.
        public let recurring: [RecurringCharge]
        public let recurringMonthly: Double
        public let recurringMonthlyText: String
        /// "$2,263 on cards and $2,400 paid from cash accounts, across 23
        /// transactions. Only the card share is owed. $100 over budget in 2 of
        /// 6 categories."
        public let lede: String

        public var newRecurring: [RecurringCharge] { recurring.filter(\.isNew) }
        public var overBudget: [BudgetRow] { budgets.filter(\.isOver) }
    }

    public struct CategorySpend: Sendable, Equatable, Identifiable {
        public let name: String
        public let total: Double
        public let totalText: String
        public let count: Int
        /// Of positive spending, 0…1.
        public let share: Double
        /// The three months before (month scope); nil with none.
        public let average: Double?
        public let averageText: String?
        public let change: Double?
        /// `change` of `average`; nil when the average is zero.
        public let changeFraction: Double?
        /// "+22%", or "none in July or August" when there was no spend before.
        public let changeText: String?

        public var id: String { SpendingSummary.key(name) }
    }

    public struct BudgetRow: Sendable, Equatable, Identifiable {
        public let category: String
        public let limit: Double
        public let spent: Double
        public let isOver: Bool
        /// How far over; 0 when within.
        public let over: Double
        /// "$684 of $600 · $84 over".
        public let label: String
        /// The same category the month before, when it had a limit then.
        public let previousSpent: Double?
        public let previousLimit: Double?
        /// Months in a row this one was over, counting this one.
        public let overStreak: Int
        /// Months in a row it came in under with something spent, counting this one.
        public let underStreak: Int

        public var id: String { SpendingSummary.key(category) }
    }

    public struct UnbudgetedRow: Sendable, Equatable, Identifiable {
        public let category: String
        public let spent: Double
        public let spentText: String
        /// No category typed ("Other").
        public let isUncategorised: Bool
        /// Kept on purpose with "No budget", rather than never given one.
        public let isKeptWithNoBudget: Bool

        public var id: String { isUncategorised ? "" : SpendingSummary.key(category) }
    }

    public struct AccountSpend: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let ownerName: String?
        public let owner: OwnerChip?
        public let isCard: Bool
        public let total: Double
        public let totalText: String
        public let count: Int
    }

    public struct MerchantRow: Sendable, Equatable, Identifiable {
        public let name: String
        public let visits: Int
        public let total: Double
        /// Cents, as the Transactions screen shows a charge.
        public let totalText: String

        public var id: String { name.lowercased() }
    }

    public struct RecurringCharge: Sendable, Equatable, Identifiable {
        public let merchant: String
        public let category: String
        /// This month's charge.
        public let amount: Double
        /// "$9.99".
        public let amountText: String
        /// Of the months looked at (this one and up to five before), how many
        /// it was charged in.
        public let monthsSeen: Int
        /// Charged this month and not the month before.
        public let isNew: Bool
        public let accountName: String?

        public var id: String { merchant.lowercased() }
    }

    // MARK: - Cards

    public struct CardsSection: Sendable, Equatable {
        public let cards: [CardRow]
        public let totalLimit: Double
        public let totalLimitText: String
        public let totalFees: Double
        public let totalFeesText: String
        public let totalSpend: Double
        public let totalSpendText: String
        /// The spend on cards that have a limit set — what `use` is of
        /// `totalLimit`. Equal to `totalSpend` unless a card has no limit.
        public let limitedSpend: Double
        public let limitedSpendText: String
        /// `limitedSpend` (a month's, for a year) of the combined limit; nil
        /// with no limits set.
        public let use: Double?
        public let useText: String?
        /// "3 cards, $45,000 of combined limit, $95 a year in fees. $2,263
        /// charged this month: 5.0% of the limit."
        public let lede: String
    }

    public struct CardRow: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let ownerName: String?
        public let owner: OwnerChip?
        public let limit: Double
        public let limitText: String
        public let fee: Double
        /// "—" for none.
        public let feeText: String
        /// This month's, or a year's.
        public let spend: Double
        public let spendText: String
        public let use: Double?
        public let useText: String?
        public let transactionCount: Int
    }

    // MARK: - Year

    public struct YearSection: Sendable, Equatable {
        public let year: Int
        /// Every month of the year the household has, oldest first.
        public let months: [YearMonthRow]
        public let startPeriod: YearMonth?
        public let startNetWorth: Double?
        public let endNetWorth: Double
        public let change: Double?
        public let changeText: String?
        /// The month net worth rose most on the month before.
        public let bestMonth: YearMonthRow?
        /// The month it fell most (or rose least) on the month before.
        public let worstMonth: YearMonthRow?
        public let spendTotal: Double
        public let spendTotalText: String
        /// Per month with any transactions.
        public let spendAverage: Double?
        public let spendAverageText: String?
        /// Biggest first.
        public let categories: [YearCategory]
        /// One per category budgeted in any month, most months over first.
        public let budgets: [YearBudget]
        /// What loans came down by over the year; negative if they rose.
        public let debtPaidDown: Double?
        public let recurringMonthly: Double
        /// Last year's spend per month, for "up 12% on 2025"; nil with none.
        public let previousYearMonthlyAverage: Double?
    }

    public struct YearMonthRow: Sendable, Equatable, Identifiable {
        public let period: YearMonth
        public let label: String
        public let netWorth: Double
        public let netWorthText: String
        /// On the month before; nil for the household's first.
        public let change: Double?
        public let changeText: String?
        public let spend: Double
        public let spendText: String
        public let cardSpend: Double
        public let budgetsOver: Int
        public let isClosed: Bool

        public var id: String { period.rawValue }
    }

    public struct YearCategory: Sendable, Equatable, Identifiable {
        public let name: String
        public let total: Double
        public let totalText: String
        /// One per month in `YearSection.months`, in order.
        public let monthly: [Double]
        public let share: Double
        /// Average per month this year against last year's; nil without last year.
        public let previousYearMonthlyAverage: Double?

        public var id: String { SpendingSummary.key(name) }
    }

    public struct YearBudget: Sendable, Equatable, Identifiable {
        public let category: String
        public let monthsBudgeted: Int
        public let monthsOver: Int
        public let totalLimit: Double
        public let totalSpent: Double
        /// How much the over months were over, together.
        public let totalOver: Double

        public var id: String { SpendingSummary.key(category) }
    }
}

// MARK: - Formatting

public extension FinanceFormat {
    /// "1.5%" — one decimal under 10%, whole above. Unsigned.
    static func percent(_ fraction: Double) -> String {
        let value = abs(fraction) * 100
        let digits = value < 10 ? 1 : 0
        return value.formatted(.number.precision(.fractionLength(digits))) + "%"
    }

    /// "+22%" / "−8%": a change, whole percent.
    static func signedPercent(_ fraction: Double) -> String {
        let rounded = (fraction * 100).rounded()
        return (rounded < 0 ? "−" : "+") + abs(rounded).formatted(.number.precision(.fractionLength(0))) + "%"
    }

    /// "+$1,204", "−$310", or "no change" at zero (after rounding).
    static func change(_ value: Double) -> String {
        value.rounded() == 0 ? "no change" : signedMoney(value)
    }
}

// MARK: - Owner colours

public extension OwnerColor {
    /// The badge colour as a hex string for HTML, close to the SwiftUI system
    /// colour each case is drawn with — light page.
    var hexLight: String {
        switch self {
        case .blue: "#2a78d6"
        case .pink: "#d55a8a"
        case .purple: "#8a5cd6"
        case .orange: "#e5761f"
        case .teal: "#1d9bb0"
        case .indigo: "#5856d6"
        case .red: "#d03b3b"
        case .yellow: "#d9a600"
        case .brown: "#9a7650"
        case .gray: "#8e8e93"
        case .green: "#1c8040"
        }
    }

    /// The same for a dark page.
    var hexDark: String {
        switch self {
        case .blue: "#3987e5"
        case .pink: "#e0709a"
        case .purple: "#9b72e6"
        case .orange: "#f08a3a"
        case .teal: "#3fb8cc"
        case .indigo: "#7a78f0"
        case .red: "#e05252"
        case .yellow: "#e6b800"
        case .brown: "#b8936a"
        case .gray: "#a0a0a6"
        case .green: "#3fae63"
        }
    }
}
