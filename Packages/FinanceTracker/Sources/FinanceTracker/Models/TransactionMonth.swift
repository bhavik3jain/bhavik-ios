import Foundation

/// Which month a transaction counts toward when nobody picks one.
///
/// A card statement doesn't end when the calendar month does: on Nov 1 the
/// user's October was still running to a statement closing Nov 7 or 8. Going by
/// date split its charges at Oct 31, so the app's October disagreed with the
/// sheet, whose card balances run from close to close (`SheetPeriod`).
public enum TransactionMonthRule {
    /// The month before `date`'s, while that's still open. Otherwise `date`'s
    /// own, or the first month after it that isn't closed, as the sheet does
    /// for a charge typed in late.
    ///
    /// Only the month just before counts as still running. "The oldest open
    /// month" would pour every new charge into a month someone forgot to close
    /// a year ago.
    public static func automatic(for date: Date, closedByPeriod: [YearMonth: Bool]) -> YearMonth {
        let dated = YearMonth(containing: date)
        if closedByPeriod[dated.previous] == false { return dated.previous }
        var period = dated
        while closedByPeriod[period] == true { period = period.next }
        return period
    }

    /// The months the editor offers, oldest first: either side of the date,
    /// the automatic one and whatever's chosen already.
    public static func choices(for date: Date, automatic: YearMonth, selected: YearMonth?) -> [YearMonth] {
        let dated = YearMonth(containing: date)
        var periods: Set<YearMonth> = [dated.previous, dated, dated.next, automatic]
        if let selected { periods.insert(selected) }
        return periods.sorted()
    }

    /// What the editor saves as `assignedMonth`. A transaction from before
    /// there was a choice stays unassigned until someone makes one, so it keeps
    /// following its date on screen and its entry time on the sheet.
    public static func stored(selected: YearMonth?, automatic: YearMonth, isUnassignedExisting: Bool) -> String? {
        if let selected { return selected.rawValue }
        return isUnassignedExisting ? nil : automatic.rawValue
    }

    /// The line under the editor's row, when the month isn't the date's own.
    public static func explanation(counted: YearMonth, date: Date, isAutomatic: Bool) -> String? {
        let dated = YearMonth(containing: date)
        guard counted != dated else { return nil }
        guard isAutomatic else { return "Dated in \(dated.monthName), counted in \(counted.monthName)." }
        return counted < dated
            ? "\(counted.monthName) is still open, so this counts toward it."
            : "\(dated.monthName) is closed, so this counts toward \(counted.monthName)."
    }
}
