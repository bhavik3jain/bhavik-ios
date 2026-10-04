import Core
import Foundation

/// `MonthCheck` for a year in review: how net worth moved over the year,
/// its best and weakest months, the budgets that went over most months, the
/// category that grew most on last year, debt paid down, recurring charges.
/// Plain Swift over `FinanceReportData` (with its `year` section), worded
/// here; the model only ranks and rewords.
///
/// Holdings findings (typed metal values, no cost basis) carry over from
/// `MonthCheck`: they're about what's held at the year's end. Month-only ones
/// — a single month's overs, stale balances, new charges — don't.
public struct YearCheck {
    /// A category over budget in at least this share of the months it had
    /// a budget (and at least twice) is worth a note.
    public static let overBudgetShare = 0.5
    /// A category's monthly average is "up" on last year from here…
    public static let increaseFraction = 0.2
    /// …and at least this many dollars a month.
    public static let increaseMinimum = 50.0

    public let findings: [ReportFinding]

    public var isEmpty: Bool { findings.isEmpty }

    public init(_ data: FinanceReportData) {
        guard let year = data.year else {
            findings = []
            return
        }
        var found: [ReportFinding] = []
        // A year whose only month is the open one, still half typed in
        // (January, with the Summary falling back to December): its balances
        // not filled in yet are zeros, so "net worth fell" and "loans came
        // down" over the year were missing figures. Say it isn't finished
        // instead.
        let isPartial = data.header.isPartial
        if !isPartial {
            found += Self.netWorth(data, year: year)
        }
        found += Self.bestAndWorst(year)
        found += Self.budgets(year)
        found += Self.spending(data, year: year)
        if !isPartial {
            found += Self.debt(year)
        }
        found += Self.recurring(data, year: year)
        found += MonthCheck.metals(data)
        found += MonthCheck.unfinished(data).filter { $0.kind == .reportedMonthFallback || (isPartial && $0.kind == .openMonthUnfinished) }
        findings = found
    }

    static func netWorth(_ data: FinanceReportData, year: FinanceReportData.YearSection) -> [ReportFinding] {
        guard let change = year.change, let start = year.startPeriod else { return [] }
        let amount = FinanceFormat.money(abs(change))
        let end = FinanceFormat.money(year.endNetWorth)
        let since = start.title
        let text = change.rounded() == 0
            ? "Net worth ended \(year.year) at \(end), where it was in \(since)."
            : "Net worth \(change > 0 ? "rose" : "fell") \(amount) since \(since), to \(end)."
        return [ReportFinding(
            id: "yearNetWorth", kind: .yearNetWorth, tone: .info,
            title: "Net worth \(change >= 0 ? "up" : "down") \(amount) over \(year.year)",
            plainText: text,
            figures: change.rounded() == 0 ? [end] : [amount, end],
            names: [since],
            weight: MonthCheck.headlineWeight
        )]
    }

    static func bestAndWorst(_ year: FinanceReportData.YearSection) -> [ReportFinding] {
        var found: [ReportFinding] = []
        if let best = year.bestMonth, let change = best.change, change.rounded() > 0 {
            let amount = FinanceFormat.money(change)
            let name = best.period.monthName
            found.append(ReportFinding(
                id: "yearBestMonth", kind: .yearBestMonth, tone: .wentWell,
                title: "\(name) was the best month",
                plainText: "\(name) was the best month, with net worth up \(amount).",
                figures: [amount], names: [name],
                weight: change
            ))
        }
        if let worst = year.worstMonth, let change = worst.change, change.rounded() < 0 {
            let amount = FinanceFormat.money(-change)
            let name = worst.period.monthName
            found.append(ReportFinding(
                id: "yearWorstMonth", kind: .yearWorstMonth, tone: .watch,
                title: "\(name) was the weakest month",
                plainText: "\(name) was the weakest month, with net worth down \(amount).",
                figures: [amount], names: [name],
                weight: -change
            ))
        }
        return found
    }

    static func budgets(_ year: FinanceReportData.YearSection) -> [ReportFinding] {
        year.budgets.compactMap { budget -> ReportFinding? in
            guard budget.monthsOver >= 2,
                  Double(budget.monthsOver) >= Double(budget.monthsBudgeted) * overBudgetShare
            else { return nil }
            let months = "\(budget.monthsOver) of \(budget.monthsBudgeted)"
            let over = FinanceFormat.money(budget.totalOver)
            return ReportFinding(
                id: "yearOverBudget:\(budget.id)", kind: .yearOverBudget, tone: .watch,
                title: "\(budget.category) over in \(months) months",
                plainText: "\(budget.category) went over budget in \(months) months, by \(over) in all.",
                figures: [months, over], names: [budget.category],
                fix: .adjustBudget(category: budget.category),
                weight: budget.totalOver
            )
        }
    }

    static func spending(_ data: FinanceReportData, year: FinanceReportData.YearSection) -> [ReportFinding] {
        var found: [ReportFinding] = []
        let monthCount = counted(year.months.count, "month")
        var text = "Spending came to \(year.spendTotalText) over \(monthCount)"
        var figures = [year.spendTotalText, monthCount]
        if let average = year.spendAverageText {
            text += ", about \(average) a month"
            figures.append(average)
        }
        if let previous = year.previousYearMonthlyAverage, previous > 0, let average = year.spendAverage {
            let fraction = (average - previous) / previous
            let percent = FinanceFormat.percent(fraction)
            text += ", \(percent) \(fraction >= 0 ? "more" : "less") than \(year.year - 1)"
            figures.append(percent)
        }
        found.append(ReportFinding(
            id: "yearSpendingTotal", kind: .yearSpendingTotal, tone: .info,
            title: "\(year.spendTotalText) spent",
            plainText: text + ".",
            figures: figures,
            weight: 800
        ))

        // The category whose month grew most on last year's month.
        let months = Double(max(year.months.count, 1))
        let increases = year.categories.compactMap { category -> (FinanceReportData.YearCategory, Double, Double)? in
            guard let previous = category.previousYearMonthlyAverage, previous > 0,
                  category.name != SpendingSummary.uncategorised
            else { return nil }
            let average = category.total / months
            let change = average - previous
            guard change >= increaseMinimum, change / previous >= increaseFraction else { return nil }
            return (category, average, change)
        }
        if let (category, average, change) = increases.max(by: { $0.2 < $1.2 }),
           let previous = category.previousYearMonthlyAverage {
            let averageText = FinanceFormat.money(average)
            let percent = FinanceFormat.percent(change / previous)
            found.append(ReportFinding(
                id: "yearSpendingIncrease:\(category.id)", kind: .yearSpendingIncrease, tone: .watch,
                title: "\(category.name) up \(percent) on \(year.year - 1)",
                plainText: "\(category.name) averaged \(averageText) a month, \(percent) more than in \(year.year - 1).",
                figures: [averageText, percent], names: [category.name],
                fix: .showCharges(category: category.name, merchant: nil),
                weight: change * 12
            ))
        }
        return found
    }

    static func debt(_ year: FinanceReportData.YearSection) -> [ReportFinding] {
        guard let paid = year.debtPaidDown, paid >= 1 else { return [] }
        let amount = FinanceFormat.money(paid)
        return [ReportFinding(
            id: "yearDebtPaidDown", kind: .yearDebtPaidDown, tone: .wentWell,
            title: "Loans down \(amount)",
            plainText: "Loans came down \(amount) over \(year.year).",
            figures: [amount],
            weight: paid
        )]
    }

    static func recurring(_ data: FinanceReportData, year: FinanceReportData.YearSection) -> [ReportFinding] {
        guard year.recurringMonthly > 0 else { return [] }
        let monthly = FinanceFormat.money(year.recurringMonthly)
        let yearly = FinanceFormat.money(year.recurringMonthly * 12)
        return [ReportFinding(
            id: "yearRecurring", kind: .yearRecurring, tone: .tryNext,
            title: "Recurring charges, \(yearly) a year",
            plainText: "Recurring charges come to \(monthly) a month, \(yearly) a year.",
            figures: [monthly, yearly],
            fix: .showRecurring(merchants: data.spending.recurring.map(\.merchant)),
            weight: year.recurringMonthly * 12 * 0.2
        )]
    }
}
