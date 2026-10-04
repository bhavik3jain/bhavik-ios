import Core
import Foundation

/// A plain look over one month's report for what changed, what's off and
/// what's worth doing next month: overs, movers, debt paid down, balances
/// that weren't looked up, new recurring charges, values that won't follow
/// the market.
///
/// No model and no store — it reads only `FinanceReportData`, so it's the
/// same on iOS 18 as on a Mac with Apple Intelligence, and every fix is a
/// screen Swift can open. The on-device model only ranks and rewords these
/// (`ReportBrief`, `ReportReview`), the way Trips' `PlanCheck` feeds its
/// review: left to judge a plan itself, the model there answered six real
/// problems with "No change needed".
public struct MonthCheck {
    // MARK: Thresholds

    /// A category is a spike once it's this far over its 3-month average…
    public static let spikeFraction = 0.2
    /// …and at least this many dollars over it.
    public static let spikeMinimum = 50.0
    /// A category with no spend in the months before is worth a note from here.
    public static let newCategoryMinimum = 100.0
    /// Combined card use worth watching.
    public static let highCardUse = 0.3
    /// An asset falling by this share of net worth is worth a note.
    public static let fallShareOfNetWorth = 0.005
    /// Most stale balances named in one sentence.
    public static let namedStaleBalances = 4
    /// Under-budget streak findings, the biggest budgets first.
    public static let underBudgetStreaks = 3
    /// The net worth's move always heads the brief.
    public static let headlineWeight = 1_000_000.0

    public let findings: [ReportFinding]

    public var isEmpty: Bool { findings.isEmpty }

    public init(_ data: FinanceReportData) {
        var found: [ReportFinding] = []
        found += Self.netWorth(data)
        found += Self.movers(data)
        found += Self.debt(data)
        found += Self.budgets(data)
        found += Self.spikes(data)
        found += Self.staleBalances(data)
        found += Self.metals(data)
        found += Self.unbudgeted(data)
        found += Self.recurring(data)
        found += Self.cardUse(data)
        found += Self.unfinished(data)
        findings = found
    }

    // MARK: - Net worth and movers

    static func netWorth(_ data: FinanceReportData) -> [ReportFinding] {
        guard let delta = data.hero.delta, let name = data.hero.comparisonName else { return [] }
        let amount = FinanceFormat.money(abs(delta))
        let total = data.hero.netWorthText
        if delta.rounded() == 0 {
            return [ReportFinding(
                id: "netWorthMove", kind: .netWorthMove, tone: .info,
                title: "Net worth held at \(total)",
                plainText: "Net worth held at \(total), the same as \(name).",
                figures: [total], names: [name], weight: headlineWeight
            )]
        }
        // A month still being filled in has every balance not typed yet at
        // zero, so "Net worth fell $14,380" there was mostly missing figures.
        // Said as where it stands so far; `unfinished` says why.
        if data.header.isPartial {
            let side = delta > 0 ? "above" : "below"
            return [ReportFinding(
                id: "netWorthMove", kind: .netWorthMove, tone: .info,
                title: "Net worth \(total) so far",
                plainText: "Net worth reads \(total) so far, \(amount) \(side) \(name), with \(data.period.monthName) not filled in yet.",
                figures: [total, amount], names: [name, data.period.monthName], weight: headlineWeight
            )]
        }
        let verb = delta > 0 ? "rose" : "fell"
        var figures = [amount, total]
        var text = "Net worth \(verb) \(amount) since \(name), to \(total)"
        if let percent = data.hero.deltaPercentText {
            text += " (\(percent))"
            figures.append(percent)
        }
        return [ReportFinding(
            id: "netWorthMove", kind: .netWorthMove, tone: .info,
            title: "Net worth \(verb) \(amount)",
            plainText: text + ".",
            figures: figures, names: [name], weight: headlineWeight
        )]
    }

    static func movers(_ data: FinanceReportData) -> [ReportFinding] {
        guard let name = data.hero.comparisonName else { return [] }
        var found: [ReportFinding] = []
        let assetMoves = data.moved.filter { if case .asset = $0.source { true } else { false } }
        let risers = assetMoves.filter { $0.impact.rounded() >= 1 }.prefix(2)
        if !risers.isEmpty {
            let parts = risers.map { "\($0.name) rose \(FinanceFormat.money($0.impact))" }
            found.append(ReportFinding(
                id: "topMovers", kind: .topMovers, tone: .wentWell,
                title: "\(risers[risers.startIndex].name) led the way",
                plainText: FinanceReportBuilder.list(parts) + " since \(name).",
                figures: risers.map { FinanceFormat.money($0.impact) },
                names: risers.map(\.name) + [name],
                weight: risers.reduce(0) { $0 + $1.impact }
            ))
        }
        let floor = max(100, abs(data.hero.netWorth) * fallShareOfNetWorth)
        // Not a kind with a balance still to type in this month: its "fall"
        // is the zero the month started at, not money gone.
        let unfilled = Set(data.accountGroups
            .filter { $0.rows.contains { !$0.isFilledIn } }
            .map { FinanceReportBuilder.metric(for: $0.category) })
        let falls = assetMoves.filter { line in
            guard -line.impact >= floor else { return false }
            if case .asset(let metric) = line.source, unfilled.contains(metric) { return false }
            return true
        }
        if let fall = falls.min(by: { $0.impact < $1.impact }) {
            let amount = FinanceFormat.money(-fall.impact)
            found.append(ReportFinding(
                id: "assetFell:\(fall.id)", kind: .assetFell, tone: .watch,
                title: "\(fall.name) fell \(amount)",
                plainText: "\(fall.name) fell \(amount) since \(name).",
                figures: [amount], names: [fall.name, name],
                weight: -fall.impact
            ))
        }
        return found
    }

    static func debt(_ data: FinanceReportData) -> [ReportFinding] {
        let loans = data.accountGroups.first { $0.category == .loan }?.rows ?? []
        return loans.compactMap { row -> ReportFinding? in
            // A loan not typed in yet this month is at the zero the month
            // started with: read as real, it went under Went well as "Car
            // loan is paid off, down $14,380".
            guard row.isFilledIn, let previous = row.previous, previous - row.value >= 1 else { return nil }
            let paid = FinanceFormat.money(previous - row.value)
            let left = row.valueText
            let text = row.value.rounded() == 0
                ? "\(row.name) is paid off, down \(paid)."
                : "\(row.name) is down \(paid), to \(left)."
            return ReportFinding(
                id: "debtPaidDown:\(row.id)", kind: .debtPaidDown, tone: .wentWell,
                title: "\(row.name) down \(paid)",
                plainText: text,
                figures: row.value.rounded() == 0 ? [paid] : [paid, left],
                names: [row.name],
                weight: previous - row.value
            )
        }
    }

    // MARK: - Budgets and spending

    static func budgets(_ data: FinanceReportData) -> [ReportFinding] {
        let spending = data.spending
        guard !spending.budgets.isEmpty else { return [] }
        let month = data.period.monthName
        var found: [ReportFinding] = []
        let over = spending.overBudget

        for row in over {
            let spent = FinanceFormat.money(row.spent)
            let limit = FinanceFormat.money(row.limit)
            let by = FinanceFormat.money(row.over)
            found.append(ReportFinding(
                id: "overBudget:\(row.id)", kind: .overBudget, tone: .watch,
                title: "\(row.category) \(by) over",
                plainText: "\(row.category): \(spent) of a \(limit) budget, \(by) over.",
                figures: [spent, limit, by], names: [row.category],
                fix: .adjustBudget(category: row.category),
                weight: row.over * 2
            ))
            if row.overStreak >= 2 {
                let streak = ordinalCount(row.overStreak)
                var text = "\(row.category) has been over budget \(streak) months running"
                var figures = [spent]
                var names = [row.category]
                if let previousSpent = row.previousSpent {
                    let before = FinanceFormat.money(previousSpent)
                    let previousMonth = data.period.previous.monthName
                    // Each month against its own limit: "against $600" for
                    // both misstated last month once its limit differed — and
                    // the review's own "Adjust Food Budget" changes the open
                    // month's limit, so the very next report hit it.
                    if let previousLimit = row.previousLimit, previousLimit.rounded() != row.limit.rounded() {
                        let limitBefore = FinanceFormat.money(previousLimit)
                        text += ": \(spent) of \(limit) in \(month) and \(before) of \(limitBefore) in \(previousMonth)."
                        figures += [limit, before, limitBefore]
                    } else {
                        text += ": \(spent) in \(month) and \(before) in \(previousMonth), against \(limit)."
                        figures += [before, limit]
                    }
                    names += [month, previousMonth]
                } else {
                    text += ", at \(spent) against \(limit) this month."
                    figures.append(limit)
                }
                found.append(ReportFinding(
                    id: "overBudgetRepeat:\(row.id)", kind: .overBudgetRepeat, tone: .tryNext,
                    severity: .note, isWorthFixing: true,
                    title: "\(row.category) over budget \(streak) months running",
                    plainText: text,
                    detail: "Either the budget or the charges need a look.",
                    figures: figures, names: names,
                    fix: .adjustBudget(category: row.category),
                    weight: row.over * Double(row.overStreak)
                ))
            }
        }

        if over.isEmpty {
            let spent = spending.budgets.reduce(0) { $0 + $1.spent }
            let limit = spending.budgets.reduce(0) { $0 + $1.limit }
            let count = counted(spending.budgets.count, "budget")
            found.append(ReportFinding(
                id: "budgetsSummary", kind: .budgetsSummary, tone: .wentWell,
                title: "Every budget came in under",
                plainText: "All \(count) came in under: \(FinanceFormat.money(spent)) spent of \(FinanceFormat.money(limit)).",
                figures: [count, FinanceFormat.money(spent), FinanceFormat.money(limit)],
                weight: max(limit - spent, 0) + 500
            ))
        } else {
            let total = FinanceFormat.money(spending.overBudgetTotal)
            let names = over.map(\.category)
            // counted(), so one budget reads "1 of 1 category", not "1 of 1
            // categories".
            let ofCount = "\(over.count) of \(counted(spending.budgets.count, "category", plural: "categories"))"
            found.append(ReportFinding(
                id: "budgetsSummary", kind: .budgetsSummary, tone: .info,
                title: "\(total) over budget",
                plainText: "Spending ran \(total) over budget in \(ofCount): \(FinanceReportBuilder.list(names)).",
                figures: [total, ofCount], names: names,
                weight: spending.overBudgetTotal + 500
            ))
        }

        let streaks = spending.budgets
            .filter { $0.underStreak >= 2 && $0.limit > 0 }
            .sorted { $0.limit > $1.limit }
            .prefix(underBudgetStreaks)
        for row in streaks {
            let spent = FinanceFormat.money(row.spent)
            let limit = FinanceFormat.money(row.limit)
            let ordinal = ordinalWord(row.underStreak)
            found.append(ReportFinding(
                id: "underBudgetStreak:\(row.id)", kind: .underBudgetStreak, tone: .wentWell,
                title: "\(row.category) under budget again",
                plainText: "\(row.category) came in at \(spent) of \(limit), under budget for the \(ordinal) month running.",
                figures: [spent, limit], names: [row.category],
                weight: row.limit - row.spent + 50
            ))
        }
        return found
    }

    static func spikes(_ data: FinanceReportData) -> [ReportFinding] {
        let overKeys = Set(data.spending.overBudget.map(\.id))
        let months = data.spending.averageMonths.map(\.monthName)
        return data.spending.categories.compactMap { category -> ReportFinding? in
            guard let average = category.average, !overKeys.contains(category.id),
                  category.name != SpendingSummary.uncategorised
            else { return nil }
            let total = category.totalText
            if average == 0 {
                guard category.total >= newCategoryMinimum, !months.isEmpty else { return nil }
                let none = FinanceReportBuilder.list(months, conjunction: "or")
                return ReportFinding(
                    id: "categorySpike:\(category.id)", kind: .categorySpike, tone: .watch,
                    title: "\(category.name) \(total), new this month",
                    plainText: "\(category.name) came to \(total), with none in \(none).",
                    figures: [total], names: [category.name] + months,
                    fix: .showCharges(category: category.name, merchant: nil),
                    weight: category.total
                )
            }
            guard let change = category.change, let fraction = category.changeFraction,
                  change >= spikeMinimum, fraction >= spikeFraction,
                  let averageText = category.averageText
            else { return nil }
            let percent = FinanceFormat.percent(fraction)
            return ReportFinding(
                id: "categorySpike:\(category.id)", kind: .categorySpike, tone: .watch,
                title: "\(category.name) up \(percent)",
                plainText: "\(category.name) came to \(total), \(percent) above its 3-month average of \(averageText).",
                figures: [total, percent, averageText], names: [category.name],
                fix: .showCharges(category: category.name, merchant: nil),
                weight: change
            )
        }
    }

    // MARK: - Stale balances

    /// Accounts whose balance matches the month before to the dollar.
    ///
    /// Cars and property are left out: they're valued by hand, and a house
    /// that keeps its figure month to month is right, not stale. Cards have
    /// no typed balance at all.
    static func staleRows(_ data: FinanceReportData) -> [FinanceReportData.AccountRow] {
        data.accountGroups
            .filter { $0.category != .fixed }
            .flatMap(\.rows)
            .filter { $0.isUnchanged && $0.isFilledIn }
            .sorted { $0.value > $1.value }
    }

    static func staleBalances(_ data: FinanceReportData) -> [ReportFinding] {
        let rows = staleRows(data)
        guard !rows.isEmpty, let name = data.hero.comparisonName else { return [] }
        // Two accounts with one name ("Online Brokerage - Taxable", his and
        // hers) are told apart by whose they are.
        let allNames = data.accountGroups.flatMap(\.rows).map(\.name)
        func label(_ row: FinanceReportData.AccountRow) -> String {
            guard allNames.count(where: { $0 == row.name }) > 1, let owner = row.ownerName else { return row.name }
            return "\(row.name), \(owner)'s"
        }
        let named = rows.prefix(namedStaleBalances)
        var parts = named.map { "\(label($0)) (\($0.valueText))" }
        if rows.count > named.count {
            parts.append(counted(rows.count - named.count, "more"))
        }
        let list = FinanceReportBuilder.list(parts)
        let target: YearMonth
        let advice: String
        if let open = data.header.openMonth, open.period > data.period {
            target = open.period
            advice = "Look them up when you fill in \(open.period.monthName)."
        } else {
            target = data.period
            advice = "Look them up before finishing \(data.period.monthName)."
        }
        let count = counted(rows.count, "balance")
        let verb = rows.count == 1 ? "matches" : "match"
        let sum = rows.reduce(0) { $0 + $1.value }
        return [ReportFinding(
            id: "staleBalances", kind: .staleBalances, tone: .tryNext,
            severity: .distorts, isWorthFixing: true,
            title: "\(count) \(verb) \(name) to the dollar",
            plainText: "\(list) \(verb) \(name) to the dollar. \(advice)",
            detail: "\(list). A balance carried over unchanged usually means it wasn't looked up. If \(rows.count == 1 ? "it" : "any of them") moved, net worth is off by that much.",
            figures: named.map(\.valueText),
            names: named.map(\.name) + [name],
            fix: .updateBalances(target),
            weight: 2_000 + sum * 0.01
        )]
    }

    // MARK: - Metals

    static func metals(_ data: FinanceReportData) -> [ReportFinding] {
        var found: [ReportFinding] = []
        let metals = data.metals
        let typed = metals.typedItems
        if !typed.isEmpty {
            let value = typed.reduce(0) { $0 + $1.value }
            let valueText = FinanceFormat.money(value)
            let share = metals.total > 0 ? value / metals.total : 0
            let shareText = FinanceFormat.percent(share)
            let others = metals.items.count - typed.count
            let names = typed.map(\.name)
            let subject = FinanceReportBuilder.list(names)
            let title = typed.count == 1 ? "\(subject) holds a typed value" : "\(counted(typed.count, "item")) hold typed values"
            let othersText = others == 0 ? "" : " The other \(counted(others, "item")) \(others == 1 ? "is" : "are") weight × the month's price;"
                + " \(typed.count == 1 ? "this one stays" : "these stay") put when gold moves."
            found.append(ReportFinding(
                id: "typedMetalValue", kind: .typedMetalValue, tone: .info,
                severity: .fragile, isWorthFixing: true,
                title: title,
                plainText: "\(subject) \(typed.count == 1 ? "holds a typed value" : "hold typed values") of \(valueText), \(shareText) of gold and silver, so \(typed.count == 1 ? "it doesn't" : "they don't") move with the price.",
                detail: "\(valueText), \(shareText) of gold and silver.\(othersText)",
                figures: [valueText, shareText], names: names,
                fix: .openHoldings,
                weight: value * 0.2
            ))
        }
        // A typed item is already flagged above; its cost hardly matters to
        // a value that doesn't follow the price.
        let noCost = metals.items.filter { $0.cost == nil && !$0.isTyped }
        if !noCost.isEmpty {
            let names = noCost.map(\.name)
            let subject = FinanceReportBuilder.list(names)
            let costed = metals.costedItems.count
            let coverage = "\(costed) of the \(counted(metals.items.count, "item"))"
            found.append(ReportFinding(
                id: "metalWithoutCost", kind: .metalWithoutCost, tone: .tryNext,
                severity: .note, isWorthFixing: true,
                title: noCost.count == 1 ? "\(subject) has no cost basis" : "\(counted(noCost.count, "item")) have no cost basis",
                plainText: "\(subject) \(noCost.count == 1 ? "has" : "have") no cost recorded, so paid vs now covers \(coverage).",
                detail: "So the paid-vs-now comparison covers \(coverage), not the whole line.",
                figures: [coverage], names: names,
                fix: .openHoldings,
                weight: noCost.reduce(0) { $0 + $1.value } * 0.05
            ))
        }
        return found
    }

    // MARK: - Unbudgeted, recurring, cards

    static func unbudgeted(_ data: FinanceReportData) -> [ReportFinding] {
        var found: [ReportFinding] = []
        let rows = data.spending.unbudgeted.filter { !$0.isUncategorised && $0.spent > 0 }
        if !rows.isEmpty {
            let total = FinanceFormat.money(rows.reduce(0) { $0 + $1.spent })
            let categories = counted(rows.count, "category", plural: "categories")
            let names = Array(rows.prefix(5).map(\.category))
            var list = names
            if rows.count > names.count { list.append(counted(rows.count - names.count, "more")) }
            let listText = FinanceReportBuilder.list(list)
            found.append(ReportFinding(
                id: "unbudgetedSpend", kind: .unbudgetedSpend, tone: .tryNext,
                severity: .note, isWorthFixing: true,
                title: "\(total) spent in \(categories) with no budget",
                plainText: "\(total) went on \(categories) with no budget: \(listText).",
                detail: "\(listText). Kept with “No budget” on purpose, or not set up yet?",
                figures: [total], names: names,
                fix: .adjustBudget(category: rows[0].category),
                weight: rows.reduce(0) { $0 + $1.spent } * 0.5
            ))
        }
        if let other = data.spending.unbudgeted.first(where: { $0.isUncategorised && $0.spent > 0 }) {
            found.append(ReportFinding(
                id: "uncategorisedSpend", kind: .uncategorisedSpend, tone: .tryNext,
                severity: .note, isWorthFixing: true,
                title: "\(other.spentText) has no category",
                plainText: "\(other.spentText) of spending has no category, so no budget can cover it.",
                detail: "Filed under \(SpendingSummary.uncategorised), which no budget matches.",
                figures: [other.spentText],
                fix: .showCharges(category: SpendingSummary.uncategorised, merchant: nil),
                weight: other.spent * 0.5
            ))
        }
        return found
    }

    static func recurring(_ data: FinanceReportData) -> [ReportFinding] {
        var found: [ReportFinding] = []
        let spending = data.spending
        let previousMonth = data.period.previous.monthName
        for charge in spending.newRecurring {
            found.append(ReportFinding(
                id: "newRecurring:\(charge.id)", kind: .newRecurring, tone: .watch,
                title: "\(charge.merchant) is new",
                plainText: "\(charge.merchant), \(charge.amountText), is a new recurring charge since \(previousMonth).",
                figures: [charge.amountText], names: [charge.merchant, previousMonth],
                fix: .showCharges(category: nil, merchant: charge.merchant),
                weight: charge.amount * 12
            ))
        }
        if spending.recurring.count >= 2 {
            let monthly = FinanceFormat.money(spending.recurringMonthly)
            let yearly = FinanceFormat.money(spending.recurringMonthly * 12)
            let count = counted(spending.recurring.count, "recurring charge")
            found.append(ReportFinding(
                id: "recurringTotal", kind: .recurringTotal, tone: .tryNext,
                title: "\(count), \(monthly) a month",
                plainText: "\(count) come to \(monthly) a month, \(yearly) a year.",
                figures: [count, monthly, yearly],
                fix: .showRecurring(merchants: spending.recurring.map(\.merchant)),
                weight: spending.recurringMonthly * 12 * 0.2
            ))
        }
        return found
    }

    static func cardUse(_ data: FinanceReportData) -> [ReportFinding] {
        guard let use = data.cards.use, use >= highCardUse, let useText = data.cards.useText else { return [] }
        let subject = data.cards.limitedSpend.rounded() == data.cards.totalSpend.rounded() ? "on cards" : "on cards with a limit"
        return [ReportFinding(
            id: "highCardUse", kind: .highCardUse, tone: .watch,
            title: "Cards at \(useText) of their limit",
            plainText: "\(data.cards.limitedSpendText) \(subject) is \(useText) of their combined \(data.cards.totalLimitText) limit.",
            figures: [data.cards.limitedSpendText, useText, data.cards.totalLimitText],
            weight: data.cards.limitedSpend * 0.1
        )]
    }

    // MARK: - Unfinished months

    static func unfinished(_ data: FinanceReportData) -> [ReportFinding] {
        guard let open = data.header.openMonth else { return [] }
        let progress = "\(open.progress.updated) of \(open.progress.total)"
        if open.period == data.period {
            return [ReportFinding(
                id: "openMonthUnfinished", kind: .openMonthUnfinished, tone: .tryNext,
                severity: .distorts, isWorthFixing: true,
                title: "\(open.period.monthName) isn't finished",
                plainText: "\(open.period.monthName) has \(progress) balances and prices filled in, so these figures are partial.",
                detail: "Balances not filled in yet count as zero, so net worth reads low until they are.",
                figures: [progress], names: [open.period.monthName],
                fix: .updateBalances(open.period),
                weight: 5_000
            )]
        }
        return [ReportFinding(
            id: "reportedMonthFallback", kind: .reportedMonthFallback, tone: .tryNext,
            title: "\(open.period.monthName) is \(open.progressText)",
            plainText: "\(open.period.monthName) is \(progress) filled in, so this report covers \(data.period.monthName).",
            figures: [progress], names: [open.period.monthName, data.period.monthName],
            fix: .updateBalances(open.period),
            weight: 300
        )]
    }

    // MARK: - Words

    /// "two", "three"… for small streaks; digits after ten.
    static func ordinalCount(_ value: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return value < words.count ? words[value] : String(value)
    }

    /// "second", "third"…; "13th" past twelve.
    static func ordinalWord(_ value: Int) -> String {
        let words = ["zeroth", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth"]
        if value < words.count { return words[value] }
        let suffix = (11...13).contains(value % 100) ? "th" : (["th", "st", "nd", "rd"] + Array(repeating: "th", count: 6))[value % 10]
        return "\(value)\(suffix)"
    }
}
