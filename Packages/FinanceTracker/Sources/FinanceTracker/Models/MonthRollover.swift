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

/// Starting a new month: the Numbers sheet's layout carried over, every
/// balance at zero to be filled in again.
public enum MonthRollover {
    /// Makes the month after `previous`: a zero balance, not yet edited, for
    /// every open non-card account, plus both metal prices and every budget
    /// copied over. Gold and silver keep their value — that's weight times
    /// price, and the weights don't change month to month.
    ///
    /// Balances used to be copied, the way the Numbers sheet duplicated last
    /// month. A figure nobody got round to checking then went into the month
    /// as if it were this month's, and the totals looked finished when they
    /// weren't. Last month's figure is still one tap away on the entry screen
    /// (`previousAmount(for:in:)`). Returns the existing month instead if it's already there — a
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
            _ = SharedFinanceBalance(account: account, month: month, amount: 0, edited: false)
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

    /// What `account` stood at in the month before `month`, if it had a
    /// balance there — the "Same as September" figure.
    public static func previousAmount(for account: SharedFinanceAccount, in month: SharedFinanceMonth) -> Double? {
        month.previousMonth?.balance(for: account)?.amount
    }

    /// The balances "Same as September for the rest" would fill: not yet
    /// filled in, with a figure last month to take.
    public static func unfilledWithPrevious(in month: SharedFinanceMonth) -> [SharedFinanceBalance] {
        (month.balances ?? []).filter { balance in
            guard !balance.edited, let account = balance.account, account.category.hasMonthlyBalance else { return false }
            return previousAmount(for: account, in: month) != nil
        }
    }

    /// Fills every balance not yet filled in with last month's figure, as if
    /// each had been confirmed unchanged. Returns how many it filled.
    @discardableResult
    public static func carryOverUnfilled(in month: SharedFinanceMonth) -> Int {
        let balances = unfilledWithPrevious(in: month)
        for balance in balances {
            guard let account = balance.account, let amount = previousAmount(for: account, in: month) else { continue }
            month.setBalance(amount, for: account)
        }
        return balances.count
    }

    /// Edited balances plus prices that moved, out of every balance plus the
    /// two prices. A price counts as updated once it differs from last
    /// month's — or, in a first month, once it's been set at all. Live
    /// prices (`MetalPriceFeed`) count as updated: nothing is left to type.
    public static func progress(of month: SharedFinanceMonth, live: MetalPrices? = nil) -> MonthProgress {
        let balances = (month.balances ?? []).filter { $0.account?.category.hasMonthlyBalance ?? false }
        let previous = month.previousMonth
        var updated = balances.filter(\.edited).count
        if MetalPriceFeed.usesLivePrices(month, live: live) {
            updated += 2
        } else {
            if month.goldPricePerOz > 0, month.goldPricePerOz != previous?.goldPricePerOz { updated += 1 }
            if month.silverPricePerOz > 0, month.silverPricePerOz != previous?.silverPricePerOz { updated += 1 }
        }
        return MonthProgress(updated: updated, total: balances.count + 2)
    }
}
