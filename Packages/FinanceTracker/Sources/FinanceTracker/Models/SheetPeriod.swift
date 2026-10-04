import Foundation

/// Which transactions a month's Numbers sheet (and its JSON) holds.
///
/// The user's sheet isn't a calendar month: September's began with charges
/// from Aug 23 and kept growing into October until the next sheet was
/// started, and its card balances are the SUMIFS over whatever it holds. An
/// export by calendar month left 19 of September's 116 charges out (they were
/// dated in August), so every card's Outstanding Balance came out low.
///
/// So a month's sheet holds what was entered after the month before it was
/// closed, up to this month's own close — or up to now while it's open. By
/// when it was entered (`createdAt`), not its date: a charge dated Sep 30 but
/// typed in after September was closed goes on October's sheet, as it would
/// have on the spreadsheet. A month that was never closed ends where the next
/// calendar month starts, if there is one.
///
/// The app's own screens (spending, budgets, reports) still go by calendar
/// month; only the sheet follows this.
public struct SheetPeriod: Equatable, Sendable {
    /// Entered strictly after this; nil from the very first transaction.
    public var after: Date?
    /// Entered at or before this; nil up to now.
    public var through: Date?

    public init(after: Date?, through: Date?) {
        self.after = after
        self.through = through
    }

    /// `period`'s sheet, given when it was closed, the month before it (if
    /// any) and whether a later month exists.
    public init(period: YearMonth, closedAt: Date?, previous: (period: YearMonth, closedAt: Date?)?, hasLaterMonth: Bool) {
        // The month before always has a later one: this.
        after = previous.map { $0.closedAt ?? $0.period.end }
        through = closedAt ?? (hasLaterMonth ? period.end : nil)
    }

    public func contains(entered: Date) -> Bool {
        if let after, entered <= after { return false }
        if let through, entered > through { return false }
        return true
    }
}

public extension SheetPeriod {
    init(month: SharedFinanceMonth) {
        let period = month.period ?? YearMonth(containing: month.createdAt)
        let later = (month.household?.months ?? []).contains {
            !$0.isDeleted && $0.period != nil && $0.yearMonth > month.yearMonth
        }
        let previous = month.previousMonth.flatMap { previous in
            previous.period.map { (period: $0, closedAt: previous.closedAt) }
        }
        self.init(period: period, closedAt: month.closedAt, previous: previous, hasLaterMonth: later)
    }
}
