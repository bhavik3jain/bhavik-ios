import Foundation

/// What sort of account a row in the balance sheet is. Stored as a raw string
/// on `SharedFinanceAccount`, so adding a case is not a schema change.
///
/// The raw values are also the `category` strings in the JSON month document
/// that `scripts/finance/*.py` read and write — never rename one.
public enum AccountCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case cash
    case investments
    case retirement
    /// Cars and property: things owned outright that hold a value.
    case fixed
    /// A credit card. Its balance for a month is never typed in — it's the
    /// sum of that month's transactions on it.
    case card
    /// Remaining principal on a loan, typed in each month like an asset.
    case loan

    public var id: String { rawValue }

    /// Section heading.
    public var displayName: String {
        switch self {
        case .cash: "Cash"
        case .investments: "Investments"
        case .retirement: "Retirement"
        case .fixed: "Cars & property"
        case .card: "Cards"
        case .loan: "Loans"
        }
    }

    /// One account of this kind, for the category grid in the editor.
    public var singularName: String {
        switch self {
        case .cash: "Cash"
        case .investments: "Investment"
        case .retirement: "Retirement"
        case .fixed: "Car / property"
        case .card: "Card"
        case .loan: "Loan"
        }
    }

    public var symbolName: String {
        switch self {
        case .cash: "banknote"
        case .investments: "chart.line.uptrend.xyaxis"
        case .retirement: "beach.umbrella"
        case .fixed: "car"
        case .card: "creditcard"
        case .loan: "building.columns"
        }
    }

    public var isAsset: Bool {
        switch self {
        case .cash, .investments, .retirement, .fixed: true
        case .card, .loan: false
        }
    }

    public var isLiability: Bool { !isAsset }

    /// Everything but cards has a balance typed in once a month.
    public var hasMonthlyBalance: Bool { self != .card }

    /// The categories whose balances are typed in each month, in the order
    /// the month entry screen lists them.
    public static let monthlyCases: [AccountCategory] = [.cash, .investments, .retirement, .fixed, .loan]

    /// Position in `allCases`, for sorting accounts category by category.
    var sortIndex: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// Whether an owner is one person or the two of them together. Joint is a
/// real owner, not "no one": a filter on Joint shows only joint accounts.
public enum OwnerKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case person
    case joint

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .person: "Person"
        case .joint: "Joint"
        }
    }
}

/// Gold or silver. Stored as a raw string on `SharedFinanceMetalItem`.
public enum MetalKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case gold
    case silver

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gold: "Gold"
        case .silver: "Silver"
        }
    }

    /// The chemical symbol, for the little chip on each row.
    public var symbol: String {
        switch self {
        case .gold: "Au"
        case .silver: "Ag"
        }
    }
}

/// Which figure the Months tab charts.
public enum FinanceMetric: String, CaseIterable, Identifiable, Sendable {
    case netWorth
    case cash
    case investments
    case retirement
    case metals
    case fixed
    case cardSpend

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .netWorth: "Net worth"
        case .cash: "Cash"
        case .investments: "Investments"
        case .retirement: "Retirement"
        case .metals: "Gold & silver"
        case .fixed: "Cars"
        case .cardSpend: "Card spend"
        }
    }
}
