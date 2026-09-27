import CoreData
import Foundation

/// How much of a month has been typed in — "20 of 32 updated".
public struct MonthProgress: Equatable, Sendable {
    public var updated: Int
    public var total: Int

    public init(updated: Int, total: Int) {
        self.updated = updated
        self.total = total
    }

    public var isComplete: Bool { updated >= total }

    public var fraction: Double { total == 0 ? 1 : Double(updated) / Double(total) }

    public var label: String { "\(updated) of \(total) updated" }
}

/// Starting a new month the way the Numbers sheet did it: duplicate last
/// month, then go down the column changing what moved.
public enum MonthRollover {
    /// Makes the month after `previous`, copying every open non-card
    /// account's balance (marked not yet edited), both metal prices and every
    /// budget. Returns the existing month instead if it's already there — a
    /// second tap, or the partner got there first. Two devices doing this
    /// offline still make one each; `FinanceFold` folds them once they meet.
    @discardableResult
    public static func startMonth(after previous: SharedFinanceMonth) -> SharedFinanceMonth? {
        guard let household = previous.household, let period = previous.period else { return nil }
        let nextPeriod = period.next
        if let existing = household.month(for: nextPeriod) { return existing }

        let month = SharedFinanceMonth(period: nextPeriod, household: household)
        month.goldPricePerOz = previous.goldPricePerOz
        month.silverPricePerOz = previous.silverPricePerOz
        for account in household.sortedAccounts where !account.isArchived && account.category.hasMonthlyBalance {
            let amount = previous.balance(for: account)?.amount ?? 0
            _ = SharedFinanceBalance(account: account, month: month, amount: amount, edited: false)
        }
        for budget in previous.sortedBudgets {
            _ = SharedFinanceBudget(category: budget.category, limit: budget.limit, month: month)
        }
        return month
    }

    /// The very first month: the one `now` is in, with a zero balance for
    /// every open account and nothing else.
    @discardableResult
    public static func startFirstMonth(in household: SharedFinanceHousehold, asOf now: Date = .now) -> SharedFinanceMonth {
        let period = YearMonth(containing: now)
        if let existing = household.month(for: period) { return existing }
        let month = SharedFinanceMonth(period: period, household: household)
        for account in household.sortedAccounts where !account.isArchived && account.category.hasMonthlyBalance {
            _ = SharedFinanceBalance(account: account, month: month, amount: 0, edited: false)
        }
        return month
    }

    /// What the + on the Months tab does: the month after the latest, or the
    /// current month when there are none yet.
    @discardableResult
    public static func startNextMonth(in household: SharedFinanceHousehold, asOf now: Date = .now) -> SharedFinanceMonth {
        if let latest = household.latestMonth, let next = startMonth(after: latest) {
            return next
        }
        return startFirstMonth(in: household, asOf: now)
    }

    /// Edited balances plus prices that moved, out of every balance plus the
    /// two prices. A price counts as updated once it differs from last
    /// month's — or, in a first month, once it's been set at all.
    public static func progress(of month: SharedFinanceMonth) -> MonthProgress {
        let balances = (month.balances ?? []).filter { $0.account?.category.hasMonthlyBalance ?? false }
        let previous = month.previousMonth
        var updated = balances.filter(\.edited).count
        if month.goldPricePerOz > 0, month.goldPricePerOz != previous?.goldPricePerOz { updated += 1 }
        if month.silverPricePerOz > 0, month.silverPricePerOz != previous?.silverPricePerOz { updated += 1 }
        return MonthProgress(updated: updated, total: balances.count + 2)
    }
}
