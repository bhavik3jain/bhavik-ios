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

/// A category on the Budget screen with no limit: kept with "No budget", or
/// spent on and never given one. Shown with what's gone on it, never as
/// over.
public struct UnbudgetedLine: Identifiable, Equatable, Sendable {
    public let category: String
    public let spent: Double
    /// Transactions with no category typed, listed as "Other". There's no
    /// budget to give them: a budget named "Other" matches only a category
    /// typed "Other".
    public let isUncategorised: Bool

    public init(category: String, spent: Double, isUncategorised: Bool = false) {
        self.category = category
        self.spent = spent
        self.isUncategorised = isUncategorised
    }

    public var id: String { isUncategorised ? "" : SpendingSummary.key(category) }
}

/// A month's budgets against its spending, and how far through the month we
/// are — the Budget screen.
public struct BudgetStatus: Equatable, Sendable {
    /// Fraction of the month elapsed, 0 to 1 — the pace marker.
    public let pace: Double
    /// One per category with a limit, in category order.
    public let lines: [BudgetLine]
    /// Every other category: those kept with no budget, and any spent on
    /// that the month has no budget for. Biggest spend first. Every category
    /// in the month shows up on the Budget screen without being added there.
    public let unbudgetedLines: [UnbudgetedLine]

    public init(month: SharedFinanceMonth, asOf now: Date = .now) {
        self.init(
            period: month.period ?? YearMonth(containing: now),
            budgets: month.sortedBudgets.map { (category: $0.category, limit: $0.limit) },
            transactions: month.transactionsInMonth,
            asOf: now
        )
    }

    /// Only transactions dated inside `period` count, whatever's passed in.
    /// A negative limit is a category kept with no budget
    /// (`SharedFinanceBudget.noLimit`).
    public init(
        period: YearMonth,
        budgets: [(category: String, limit: Double)],
        transactions: [SharedFinanceTransaction],
        asOf now: Date = .now
    ) {
        let inPeriod = transactions.filter { period.contains($0.date) }
        let spending = SpendingSummary.totalsByKey(inPeriod)
        var listedKeys = Set<String>()
        var lines: [BudgetLine] = []
        var unbudgeted: [UnbudgetedLine] = []
        for budget in budgets {
            let key = SpendingSummary.key(budget.category)
            guard listedKeys.insert(key).inserted else { continue }
            if budget.limit >= 0 {
                lines.append(BudgetLine(category: budget.category, limit: budget.limit, spent: spending[key] ?? 0))
            } else {
                unbudgeted.append(UnbudgetedLine(category: budget.category, spent: spending[key] ?? 0))
            }
        }
        // Every other category spent on, named as first typed.
        var names: [String: String] = [:]
        for transaction in inPeriod {
            let trimmed = transaction.category.trimmingCharacters(in: .whitespaces)
            let key = SpendingSummary.key(trimmed)
            if names[key] == nil { names[key] = trimmed }
        }
        for (key, name) in names where listedKeys.insert(key).inserted {
            unbudgeted.append(UnbudgetedLine(
                category: key.isEmpty ? SpendingSummary.uncategorised : name,
                spent: spending[key] ?? 0,
                isUncategorised: key.isEmpty
            ))
        }
        self.lines = lines
        self.unbudgetedLines = unbudgeted.sorted {
            $0.spent != $1.spent ? $0.spent > $1.spent : $0.category.localizedStandardCompare($1.category) == .orderedAscending
        }
        self.pace = period.fractionElapsed(asOf: now)
    }

    /// Spending in categories with no limit.
    public var unbudgeted: Double { unbudgetedLines.reduce(0) { $0 + $1.spent } }

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
