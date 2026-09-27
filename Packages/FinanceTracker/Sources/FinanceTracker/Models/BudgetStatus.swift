import Foundation

/// How one budget line is doing.
public enum BudgetState: Sendable {
    /// Spent no faster than the month is passing.
    case onTrack
    /// Still under the limit, but spending faster than the month is passing.
    case aheadOfPace
    case over
}

/// One category's budget against what's been spent on it.
public struct BudgetLine: Identifiable, Equatable, Sendable {
    public let category: String
    public let limit: Double
    public let spent: Double

    public init(category: String, limit: Double, spent: Double) {
        self.category = category
        self.limit = limit
        self.spent = spent
    }

    public var id: String { category }

    public var remaining: Double { limit - spent }

    public var isOver: Bool { spent > limit }

    /// Share of the limit used, uncapped — 1.2 is 20% over.
    public var fractionSpent: Double {
        guard limit > 0 else { return spent > 0 ? 1 : 0 }
        return spent / limit
    }

    /// `pace` is the fraction of the month gone, 0 to 1.
    public func state(pace: Double) -> BudgetState {
        if isOver { return .over }
        if limit > 0, fractionSpent > pace { return .aheadOfPace }
        return .onTrack
    }
}

/// A month's budgets against its spending, and how far through the month we
/// are — the Budget screen.
public struct BudgetStatus: Equatable, Sendable {
    /// Fraction of the month elapsed, 0 to 1 — the pace marker.
    public let pace: Double
    /// One per budgeted category, in category order.
    public let lines: [BudgetLine]
    /// Spending in categories that have no budget.
    public let unbudgeted: Double

    public init(month: SharedFinanceMonth, asOf now: Date = .now) {
        self.init(
            period: month.period ?? YearMonth(containing: now),
            budgets: month.sortedBudgets.map { (category: $0.category, limit: $0.limit) },
            transactions: month.transactionsInMonth,
            asOf: now
        )
    }

    /// Only transactions dated inside `period` count, whatever's passed in.
    public init(
        period: YearMonth,
        budgets: [(category: String, limit: Double)],
        transactions: [SharedFinanceTransaction],
        asOf now: Date = .now
    ) {
        let spending = SpendingSummary.totalsByKey(transactions.filter { period.contains($0.date) })
        var budgetedKeys = Set<String>()
        var lines: [BudgetLine] = []
        for budget in budgets {
            let key = SpendingSummary.key(budget.category)
            guard !budgetedKeys.contains(key) else { continue }
            budgetedKeys.insert(key)
            lines.append(BudgetLine(category: budget.category, limit: budget.limit, spent: spending[key] ?? 0))
        }
        self.lines = lines
        self.unbudgeted = spending.filter { !budgetedKeys.contains($0.key) }.values.reduce(0, +)
        self.pace = period.fractionElapsed(asOf: now)
    }

    public var totalLimit: Double { lines.reduce(0) { $0 + $1.limit } }
    public var totalSpent: Double { lines.reduce(0) { $0 + $1.spent } }

    /// "Left this month" — negative once the whole budget is blown.
    public var left: Double { totalLimit - totalSpent }

    public func state(of line: BudgetLine) -> BudgetState { line.state(pace: pace) }

    /// The whole budget's state, the same rule as a single line.
    public var overallState: BudgetState {
        BudgetLine(category: "", limit: totalLimit, spent: totalSpent).state(pace: pace)
    }
}
