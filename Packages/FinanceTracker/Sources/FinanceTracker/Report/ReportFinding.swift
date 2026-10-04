import Foundation

/// One thing the app's own checks (`MonthCheck`, `YearCheck`) found in a
/// report: worked out and worded in Swift, with every figure it quotes.
///
/// The same rule as Trips' `PlanCheck`: Swift decides every fact and every
/// fix, and the on-device model only ranks and rewords them (`ReportBrief`,
/// `ReportReview`). A model note is kept only if every string in `figures`
/// and `names` survives into it; otherwise `plainText` is shown instead. So
/// `figures` must be formatted exactly as `plainText` writes them.
public struct ReportFinding: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        // Month
        case netWorthMove
        case topMovers
        case assetFell
        case debtPaidDown
        case overBudget
        case budgetsSummary
        case underBudgetStreak
        case categorySpike
        case staleBalances
        case typedMetalValue
        case metalWithoutCost
        case unbudgetedSpend
        case newRecurring
        case recurringTotal
        case overBudgetRepeat
        case uncategorisedSpend
        case openMonthUnfinished
        case reportedMonthFallback
        case highCardUse
        // Year
        case yearNetWorth
        case yearBestMonth
        case yearWorstMonth
        case yearOverBudget
        case yearSpendingIncrease
        case yearSpendingTotal
        case yearDebtPaidDown
        case yearRecurring

        /// The small heading over a finding — the badge in Worth fixing.
        public var badge: String {
            switch self {
            case .staleBalances: "May be stale"
            case .typedMetalValue: "Frozen value"
            case .openMonthUnfinished, .reportedMonthFallback: "Not finished"
            case .netWorthMove, .yearNetWorth: "Net worth"
            case .topMovers, .assetFell: "Moved"
            case .debtPaidDown, .yearDebtPaidDown: "Debt"
            case .overBudget, .overBudgetRepeat, .yearOverBudget, .budgetsSummary: "Budget"
            case .underBudgetStreak: "Under budget"
            case .categorySpike, .yearSpendingIncrease: "Spending"
            case .newRecurring, .recurringTotal, .yearRecurring: "Recurring"
            case .highCardUse: "Cards"
            case .yearBestMonth, .yearWorstMonth, .yearSpendingTotal: "Year"
            case .metalWithoutCost, .unbudgetedSpend, .uncategorisedSpend: "Worth knowing"
            }
        }

        public var symbolName: String {
            switch self {
            case .netWorthMove, .yearNetWorth: "chart.line.uptrend.xyaxis"
            case .topMovers: "arrow.up.right"
            case .assetFell: "arrow.down.right"
            case .debtPaidDown, .yearDebtPaidDown: "building.columns"
            case .overBudget, .overBudgetRepeat, .yearOverBudget: "exclamationmark.circle"
            case .budgetsSummary: "chart.bar"
            case .underBudgetStreak: "checkmark.circle"
            case .categorySpike, .yearSpendingIncrease: "chart.bar.xaxis"
            case .staleBalances: "clock.arrow.circlepath"
            case .typedMetalValue: "lock"
            case .metalWithoutCost: "questionmark.circle"
            case .unbudgetedSpend: "tray"
            case .newRecurring, .recurringTotal, .yearRecurring: "repeat"
            case .uncategorisedSpend: "tag"
            case .openMonthUnfinished, .reportedMonthFallback: "hourglass"
            case .highCardUse: "creditcard"
            case .yearBestMonth: "arrow.up.circle"
            case .yearWorstMonth: "arrow.down.circle"
            case .yearSpendingTotal: "cart"
            }
        }
    }

    /// Which part of the review a finding belongs in.
    public enum Tone: String, Sendable, CaseIterable {
        case wentWell
        case watch
        case tryNext
        /// A fact worth stating (the net worth's move) that's neither good
        /// nor bad news — background for the headline.
        case info

        public var title: String {
            switch self {
            case .wentWell: "Went well"
            case .watch: "To watch"
            case .tryNext: "To try"
            case .info: "Background"
            }
        }
    }

    /// How much a Worth-fixing finding changes the report's own figures: the
    /// order that section lists them in.
    public enum Severity: Int, Sendable, Comparable, CaseIterable {
        /// The headline may be wrong by this much (a balance that wasn't
        /// looked up, a month still half typed in).
        case distorts = 0
        /// Right today, but won't follow the market (a typed value).
        case fragile = 1
        /// Worth knowing; changes no figure.
        case note = 2

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Stable within one report: kind plus whatever it's about
    /// ("overBudget:food"), so a cached review can point back at it.
    public let id: String
    public let kind: Kind
    public let tone: Tone
    public let severity: Severity
    /// Whether it's listed under the report's "Worth fixing".
    public let isWorthFixing: Bool
    /// The short heading: "2 balances match August to the dollar".
    public let title: String
    /// Swift's own full sentence, shown whenever the model is off or a note
    /// about this finding fails `ReportReview.isFaithful`.
    public let plainText: String
    /// The longer paragraph under `title` in Worth fixing; empty when
    /// `plainText` says it all.
    public let detail: String
    /// Every money, percent and count string that must survive into a model
    /// note, exactly as `plainText` writes it.
    public let figures: [String]
    /// Every account, category, merchant or month name that must survive.
    public let names: [String]
    public let fix: ReportFix?
    /// How much it matters, for ranking facts into the brief: roughly the
    /// dollars involved, scaled up for the things that distort the headline.
    public let weight: Double

    public init(
        id: String,
        kind: Kind,
        tone: Tone,
        severity: Severity = .note,
        isWorthFixing: Bool = false,
        title: String,
        plainText: String,
        detail: String = "",
        figures: [String] = [],
        names: [String] = [],
        fix: ReportFix? = nil,
        weight: Double = 0
    ) {
        self.id = id
        self.kind = kind
        self.tone = tone
        self.severity = severity
        self.isWorthFixing = isWorthFixing
        self.title = title
        self.plainText = plainText
        self.detail = detail
        self.figures = figures
        self.names = names
        self.fix = fix
        self.weight = weight
    }
}

/// One tap from a finding to the screen that changes it. Views route these to
/// the real editors; the report itself never edits anything.
public enum ReportFix: Sendable, Hashable {
    /// The budget editor for a category.
    case adjustBudget(category: String)
    /// The transactions list, narrowed to a category and/or a merchant.
    case showCharges(category: String?, merchant: String?)
    /// This month's charges from the recurring merchants — the design's
    /// "Review Them" beside the recurring total, which had no button while
    /// no fix could list more than one merchant.
    case showRecurring(merchants: [String])
    /// The month entry screen for a month, to type balances in.
    case updateBalances(YearMonth)
    /// Gold & silver.
    case openHoldings
    /// That month's report or screen.
    case openMonth(YearMonth)

    /// The button's title: "Adjust Food budget", "Show Music App charges".
    public var title: String {
        switch self {
        case .adjustBudget(let category): "Adjust \(category) Budget"
        case .showCharges(let category, let merchant):
            if let merchant { "Show \(merchant) Charges" } else if let category { "Show \(category) Charges" } else { "Show Charges" }
        case .showRecurring: "Review Recurring Charges"
        case .updateBalances(let period): "Update \(period.monthName) Balances"
        case .openHoldings: "Open Gold & Silver"
        case .openMonth(let period): "Open \(period.title)"
        }
    }

    public var symbolName: String {
        switch self {
        case .adjustBudget: "slider.horizontal.3"
        case .showCharges: "list.bullet"
        case .showRecurring: "repeat"
        case .updateBalances: "square.and.pencil"
        case .openHoldings: "circle.hexagongrid"
        case .openMonth: "calendar"
        }
    }
}

public extension Array where Element == ReportFinding {
    /// Worth fixing, as the report lists it: what most changes the headline
    /// first, then by weight.
    var worthFixing: [ReportFinding] {
        filter(\.isWorthFixing).sorted {
            $0.severity != $1.severity ? $0.severity < $1.severity : $0.weight > $1.weight
        }
    }

    func with(tone: ReportFinding.Tone) -> [ReportFinding] {
        filter { $0.tone == tone }.sorted { $0.weight > $1.weight }
    }
}
