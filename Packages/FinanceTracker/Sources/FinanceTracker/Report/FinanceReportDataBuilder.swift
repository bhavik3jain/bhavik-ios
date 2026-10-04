import Core
import CoreData
import Foundation

public extension FinanceReportData {
    /// The scope a report opens on: `FinanceHome.reportedMonth` of the
    /// household's latest month — the month the Summary headlines. nil with
    /// no months yet.
    @MainActor
    static func defaultScope(for household: SharedFinanceHousehold, live: MetalPrices?) -> ReportScope? {
        guard let latest = FinanceReportBuilder.months(of: household).last else { return nil }
        return FinanceHome.reportedMonth(for: latest, live: live).period.map(ReportScope.month)
    }

    /// Every year the household has a month in, newest first — the Months
    /// tab's "Year in Review" rows.
    static func reportYears(in months: [SharedFinanceMonth]) -> [Int] {
        Set(months.compactMap { $0.period?.year }).sorted(by: >)
    }

    /// Builds the report for `scope` from the household's own objects. nil
    /// when the scope has no month in the household.
    ///
    /// - Parameters:
    ///   - filter: whose money — `.all` is "Everyone". Balances, metals and
    ///     spending follow it the way `MonthSummary` does (a charge on
    ///     Bhavik's card is Bhavik's); budgets stay household-wide.
    ///   - live: `MetalPriceFeed`'s prices; they value only the latest month,
    ///     and only while it's open.
    ///   - deviceName: "Bhavik's iPhone", for the header. Finance never looks it up.
    @MainActor
    static func build(
        scope: ReportScope,
        household: SharedFinanceHousehold,
        filter: OwnerFilter = .all,
        live: MetalPrices?,
        deviceName: String,
        asOf now: Date = .now
    ) -> FinanceReportData? {
        let builder = FinanceReportBuilder(household: household, filter: filter, live: live, now: now)
        guard var data = builder.build(scope: scope, deviceName: deviceName) else { return nil }
        data.findings = scope.isYear ? YearCheck(data).findings : MonthCheck(data).findings
        return data
    }
}

/// The arithmetic behind `FinanceReportData.build`, one report at a time.
@MainActor
struct FinanceReportBuilder {
    let household: SharedFinanceHousehold
    let filter: OwnerFilter
    let live: MetalPrices?
    let now: Date
    /// One per period (`FinanceFold.distinctMonths`), oldest first.
    let months: [SharedFinanceMonth]
    let accounts: [SharedFinanceAccount]
    let cards: [SharedFinanceAccount]
    let metals: [SharedFinanceMetalItem]
    /// Every transaction of the household.
    let allTransactions: [SharedFinanceTransaction]
    let history: FinanceHistory

    /// How far back a charge is looked for to call it recurring.
    nonisolated static let recurringLookbackMonths = 6
    /// A recurring charge's amount may drift this much month to month.
    nonisolated static let recurringTolerance = 0.10
    /// The spending average is over at most this many earlier months…
    nonisolated static let averageMonths = 3
    /// …found within this many months before.
    nonisolated static let averageLookbackMonths = 6

    init(household: SharedFinanceHousehold, filter: OwnerFilter, live: MetalPrices?, now: Date) {
        self.household = household
        self.filter = filter
        self.live = live
        self.now = now
        months = Self.months(of: household)
        accounts = Array(household.accounts ?? []).filter { !$0.isDeleted }.sorted(by: SharedFinanceAccount.displayOrder)
        cards = accounts.filter { $0.category == .card }
        metals = Array(household.metalItems ?? []).filter { !$0.isDeleted }.sorted(by: SharedFinanceMetalItem.displayOrder)
        allTransactions = Array(household.transactions ?? []).filter { !$0.isDeleted }
        history = FinanceHistory(months: months, filter: filter, live: live)
    }

    static func months(of household: SharedFinanceHousehold) -> [SharedFinanceMonth] {
        FinanceFold.distinctMonths((household.months ?? []).filter { !$0.isDeleted && $0.period != nil })
    }

    // MARK: - Report

    func build(scope: ReportScope, deviceName: String) -> FinanceReportData? {
        switch scope {
        case .month(let period):
            guard let month = months.first(where: { $0.period == period }) else { return nil }
            let previous = history.point(before: period)?.month
            return report(scope: scope, month: month, compared: previous, spendingPeriods: [period], deviceName: deviceName)
        case .year(let year):
            let inYear = months.filter { $0.period?.year == year }
            guard let first = inYear.first, let last = inYear.last, let firstPeriod = first.period else { return nil }
            // The year's last month, unless it's the latest and still half
            // typed in — the same rule as the Summary's headline.
            let reported = FinanceHome.reportedMonth(for: last, live: live)
            let end = reported.period?.year == year && months.last == last ? reported : last
            guard let endPeriod = end.period else { return nil }
            let start = history.point(before: firstPeriod)?.month ?? (first == end ? nil : first)
            let periods = inYear.compactMap(\.period).filter { $0 <= endPeriod }
            return report(scope: scope, month: end, compared: start, spendingPeriods: periods, deviceName: deviceName)
        }
    }

    private func report(
        scope: ReportScope,
        month: SharedFinanceMonth,
        compared: SharedFinanceMonth?,
        spendingPeriods: [YearMonth],
        deviceName: String
    ) -> FinanceReportData? {
        guard let period = month.period else { return nil }
        let summary = summary(of: month)
        let previousSummary = compared.map(summary(of:))
        let comparisonPeriod = compared?.period
        let comparisonName = comparisonPeriod.map { name(of: $0, relativeTo: period) }

        let accountGroups = accountGroups(in: month, compared: compared, comparisonName: comparisonName)
        let spending = spending(scope: scope, period: period, periods: spendingPeriods, month: month)
        let cards = cardsSection(periods: spendingPeriods, isYear: scope.isYear)
        let mix = mixLines(summary, previous: previousSummary)
        let moved = movedLines(summary, previous: previousSummary, month: month, compared: compared)

        return FinanceReportData(
            scope: scope,
            period: period,
            comparisonPeriod: comparisonPeriod,
            header: header(scope: scope, month: month, period: period, deviceName: deviceName),
            hero: hero(summary, previous: previousSummary, comparisonName: comparisonName),
            kpis: kpis(summary, mix: mix, spending: spending, cards: cards, month: month),
            mix: mix,
            mixLede: mixLede(mix),
            moved: moved,
            movedLede: movedLede(moved, summary: summary, previous: previousSummary, month: month, compared: compared, comparisonName: comparisonName),
            trend: trend(scope: scope, through: period, from: comparisonPeriod),
            accountGroups: accountGroups,
            metals: metalsSection(month: month),
            spending: spending,
            cards: cards,
            year: scope.isYear ? yearSection(year: scope.year, end: month, compared: compared, periods: spendingPeriods, spending: spending) : nil,
            findings: []
        )
    }

    /// Open and not yet filled in: its unedited balances are zeros nobody
    /// typed, not figures.
    func isPartial(_ month: SharedFinanceMonth) -> Bool {
        !month.isClosed && !MonthRollover.progress(of: month, live: live).isComplete
    }

    func summary(of month: SharedFinanceMonth) -> MonthSummary {
        MonthSummary(month: month, cards: cards, metals: metals, filter: filter, live: live)
    }

    /// "August" within the same year, "December 2025" across one.
    func name(of compared: YearMonth, relativeTo period: YearMonth) -> String {
        compared.year == period.year ? compared.monthName : compared.title
    }

    // MARK: - Header

    private func header(scope: ReportScope, month: SharedFinanceMonth, period: YearMonth, deviceName: String) -> FinanceReportData.Header {
        let ownerLabel: String = switch filter {
        case .all: "Everyone"
        case .owner(let owner): owner.name
        }
        let builtAtText = now.formatted(.dateTime.day().month(.wide).year())
        let device = deviceName.trimmingCharacters(in: .whitespaces)
        let progress = MonthRollover.progress(of: month, live: live)
        let pricesAreLive = MetalPriceFeed.usesLivePrices(month, live: live)
        let isPartial = !month.isClosed && !progress.isComplete

        // The latest month, when it's open and unfinished and it's this one
        // or the one right after — the month a report defaulted past.
        var openMonth: FinanceReportData.OpenMonth?
        if let latest = months.last, let latestPeriod = latest.period, !latest.isClosed {
            let latestProgress = MonthRollover.progress(of: latest, live: live)
            let relevant = scope.isYear ? latestPeriod.year == scope.year : (latestPeriod == period || latestPeriod == period.next)
            if !latestProgress.isComplete, relevant {
                openMonth = FinanceReportData.OpenMonth(period: latestPeriod, progress: latestProgress)
            }
        }

        let monthState = stateSentence(month: month, period: period, progress: progress, pricesAreLive: pricesAreLive)
        let coverage: String
        switch scope {
        case .month:
            if let openMonth, openMonth.period > period {
                let lead = "\(openMonth.period.monthName) is \(openMonth.progressText), so this report covers \(period.monthName)"
                coverage = month.isClosed ? "\(lead), which \(monthState)" : "\(lead). \(period.monthName) \(monthState)"
            } else {
                coverage = "\(period.monthName) \(monthState)"
            }
        case .year(let year):
            let firstName = months.first { $0.period?.year == year }?.period?.monthName ?? period.monthName
            var text = "Covers \(firstName) to \(period.monthName) \(year)"
            if let openMonth, openMonth.period > period {
                text += ", leaving out \(openMonth.period.monthName), which is \(openMonth.progressText)"
            }
            coverage = text + ". \(period.monthName) \(monthState)"
        }

        return FinanceReportData.Header(
            title: scope.title,
            ownerLabel: ownerLabel,
            kicker: "Multitrack · Finance · \(scope.isYear ? "Year in review" : "Net worth summary") · \(ownerLabel)",
            builtAt: now,
            builtAtText: builtAtText,
            deviceName: device,
            builtNote: "Built on \(device.isEmpty ? "this device" : device) on \(builtAtText) from the household's own figures.",
            coverageNote: coverage.trimmingCharacters(in: .whitespaces),
            isPartial: isPartial,
            pricesAreLive: pricesAreLive,
            closedAt: month.closedAt,
            openMonth: openMonth
        )
    }

    /// What follows the month's name: "was finished on October 2 and keeps
    /// the metal prices saved that day."
    private func stateSentence(month: SharedFinanceMonth, period: YearMonth, progress: MonthProgress, pricesAreLive: Bool) -> String {
        if let closedAt = month.closedAt {
            return "was finished on \(closedAt.formatted(.dateTime.day().month(.wide))) and keeps the metal prices saved that day."
        }
        if !progress.isComplete {
            return "isn't finished: \(progress.updated) of \(progress.total) filled in, so figures are partial"
                + (pricesAreLive ? " and gold and silver are at today's prices." : ".")
        }
        return "is filled in but not finished yet" + (pricesAreLive ? "; gold and silver are at today's prices." : ".")
    }

    // MARK: - Hero and KPIs

    private func hero(_ summary: MonthSummary, previous: MonthSummary?, comparisonName: String?) -> FinanceReportData.Hero {
        let delta = previous.map { summary.netWorth - $0.netWorth }
        let fraction: Double? = {
            guard let delta, let previous, previous.netWorth > 0 else { return nil }
            return delta / previous.netWorth
        }()
        let deltaText = delta.map(FinanceFormat.signedMoney)
        let percentText = fraction.map(FinanceFormat.percent)
        let deltaLine: String
        if let deltaText, let comparisonName {
            deltaLine = percentText.map { "\(deltaText) · \($0) on \(comparisonName)" } ?? "\(deltaText) on \(comparisonName)"
        } else {
            deltaLine = "First month"
        }
        return FinanceReportData.Hero(
            netWorth: summary.netWorth,
            netWorthText: FinanceFormat.money(summary.netWorth),
            delta: delta,
            deltaText: deltaText,
            deltaFraction: fraction,
            deltaPercentText: percentText,
            comparisonName: comparisonName,
            deltaLine: deltaLine,
            assets: summary.totalAssets,
            assetsText: FinanceFormat.money(summary.totalAssets),
            owed: summary.owed,
            owedText: FinanceFormat.money(summary.owed),
            assetsLine: "\(FinanceFormat.money(summary.totalAssets)) assets − \(FinanceFormat.money(summary.owed)) owed"
        )
    }

    private func kpis(
        _ summary: MonthSummary,
        mix: [FinanceReportData.MixLine],
        spending: FinanceReportData.SpendingSection,
        cards: FinanceReportData.CardsSection,
        month: SharedFinanceMonth
    ) -> [FinanceReportData.KPI] {
        let kinds = mix.count { $0.value > 0 }
        let loanAccounts = (month.balances ?? []).count {
            guard let account = $0.account else { return false }
            return account.category == .loan && filter.includes(account.owner) && $0.amount != 0
        }
        // Months of spending at the usual month: the 3-month average, or a
        // year's average month, or failing both this month's.
        let monthlySpend = spending.average ?? (spending.periods.count > 1 ? spending.total / Double(spending.periods.count) : spending.total)
        let cashDetail = monthlySpend > 0
            ? "\((summary.cash / monthlySpend).formatted(.number.precision(.fractionLength(1)))) months of spending"
            : "No spending to compare"
        let retirementShare = summary.totalAssets > 0 ? summary.retirement / summary.totalAssets : 0
        // A year's card use is its average month's, as `cardsSection` works it out.
        let periodCount = max(spending.periods.count, 1)
        let cardUseDetail = periodCount > 1
            ? "\(FinanceFormat.money(cards.limitedSpend / Double(periodCount))) a month of \(cards.totalLimitText)"
            : "\(cards.limitedSpendText) of \(cards.totalLimitText)"
        return [
            FinanceReportData.KPI(
                id: "assets", label: "Total assets", value: summary.totalAssets,
                valueText: FinanceFormat.money(summary.totalAssets),
                detail: counted(kinds, "category", plural: "categories")
            ),
            FinanceReportData.KPI(
                id: "owed", label: "Owed", value: summary.owed,
                valueText: FinanceFormat.money(summary.owed),
                detail: "Cards \(FinanceFormat.money(summary.cardSpend)) · \(loanAccounts == 1 ? "loan" : "loans") \(FinanceFormat.money(summary.loans))"
            ),
            FinanceReportData.KPI(
                id: "cash", label: "Liquid cash", value: summary.cash,
                valueText: FinanceFormat.money(summary.cash), detail: cashDetail
            ),
            FinanceReportData.KPI(
                id: "retirement", label: "Retirement", value: summary.retirement,
                valueText: FinanceFormat.money(summary.retirement),
                detail: "\(FinanceFormat.percent(retirementShare)) of assets"
            ),
            FinanceReportData.KPI(
                id: "cardUse", label: "Card use", value: cards.use ?? 0,
                valueText: cards.useText ?? "—",
                detail: cards.totalLimit > 0 ? cardUseDetail : "No card limits set"
            ),
        ]
    }

    // MARK: - Mix and moves

    nonisolated static let assetMetrics: [FinanceMetric] = [.cash, .investments, .retirement, .health, .fixed, .metals]

    nonisolated static func assetName(_ metric: FinanceMetric) -> String {
        switch metric {
        case .cash: "Cash"
        case .investments: "Investments"
        case .retirement: "Retirement"
        case .health: "Health (FSA/HSA)"
        case .fixed: "Cars & property"
        case .metals: "Gold & silver"
        case .netWorth: "Net worth"
        case .cardSpend: "Card spend"
        }
    }

    /// The design's series colours, one per kind for good.
    nonisolated static func colorIndex(_ metric: FinanceMetric) -> Int {
        switch metric {
        case .fixed: 1
        case .cash: 2
        case .metals: 3
        case .investments: 4
        case .retirement: 5
        case .health: 6
        case .netWorth, .cardSpend: 1
        }
    }

    private func mixLines(_ summary: MonthSummary, previous: MonthSummary?) -> [FinanceReportData.MixLine] {
        let total = summary.totalAssets
        return Self.assetMetrics.compactMap { metric -> FinanceReportData.MixLine? in
            let value = summary.value(for: metric)
            let before = previous.map { $0.value(for: metric) }
            guard value != 0 || (before ?? 0) != 0 else { return nil }
            let share = total > 0 ? max(value, 0) / total : 0
            let delta = before.map { value - $0 }
            return FinanceReportData.MixLine(
                metric: metric,
                name: Self.assetName(metric),
                value: value,
                valueText: FinanceFormat.money(value),
                share: share,
                shareText: FinanceFormat.percent(share),
                previous: before,
                delta: delta,
                deltaText: delta.map(FinanceFormat.change),
                colorIndex: Self.colorIndex(metric)
            )
        }
        .sorted { lhs, rhs in
            lhs.value != rhs.value
                ? lhs.value > rhs.value
                : (Self.assetMetrics.firstIndex(of: lhs.metric) ?? 0) < (Self.assetMetrics.firstIndex(of: rhs.metric) ?? 0)
        }
    }

    private func mixLede(_ mix: [FinanceReportData.MixLine]) -> String {
        let held = mix.filter { $0.value > 0 }
        guard let top = held.first else { return "Nothing owned yet." }
        var text = "\(counted(held.count, "kind")) of asset. \(top.name) is \(top.shareText) of everything owned"
        if held.count > 1 {
            let second = held[1]
            text += "; with \(second.name) it's \(FinanceFormat.percent(top.share + second.share))"
        }
        return text + "."
    }

    /// Each line's effect on net worth. Net worth is assets less card spend
    /// less loans, so the asset changes, minus the loan change and minus the
    /// card-spend change, add up to its change exactly — kept unrounded so
    /// they still do.
    private func movedLines(
        _ summary: MonthSummary,
        previous: MonthSummary?,
        month: SharedFinanceMonth,
        compared: SharedFinanceMonth?
    ) -> [FinanceReportData.MovedLine] {
        guard let previous else { return [] }
        var lines: [FinanceReportData.MovedLine] = []
        for metric in Self.assetMetrics {
            let impact = summary.value(for: metric) - previous.value(for: metric)
            guard impact != 0 else { continue }
            lines.append(.init(id: metric.rawValue, source: .asset(metric), name: Self.assetName(metric), impact: impact, impactText: FinanceFormat.change(impact)))
        }
        let loanImpact = previous.loans - summary.loans
        if loanImpact != 0 {
            let loans = Set((Array(month.balances ?? []) + Array(compared?.balances ?? [])).compactMap { balance -> SharedFinanceAccount? in
                guard let account = balance.account, account.category == .loan, filter.includes(account.owner), balance.amount != 0 else { return nil }
                return account
            })
            let subject = loans.count == 1 ? loans.first!.name.trimmingCharacters(in: .whitespaces) : "Loans"
            // A loan not typed in yet this month sits at the zero the month
            // started with, and its whole balance read as "Car loan paid
            // down" — on a month that's still half filled in.
            let unfilled = !month.isClosed && (month.balances ?? []).contains { balance in
                guard let account = balance.account, account.category == .loan, filter.includes(account.owner) else { return false }
                return !balance.edited
            }
            let name = loanImpact > 0
                ? (unfilled ? "\(subject.isEmpty ? "Loans" : subject) not filled in yet" : "\(subject.isEmpty ? "Loans" : subject) paid down")
                : "More owed on \(loans.count == 1 && !subject.isEmpty ? subject : "loans")"
            lines.append(.init(id: "loans", source: .loans, name: name, impact: loanImpact, impactText: FinanceFormat.change(loanImpact)))
        }
        let cardImpact = previous.cardSpend - summary.cardSpend
        if cardImpact != 0 {
            lines.append(.init(id: "cards", source: .cards, name: "Card spend", impact: cardImpact, impactText: FinanceFormat.change(cardImpact)))
        }
        return lines.sorted { $0.impact > $1.impact }
    }

    private func movedLede(
        _ moved: [FinanceReportData.MovedLine],
        summary: MonthSummary,
        previous: MonthSummary?,
        month: SharedFinanceMonth,
        compared: SharedFinanceMonth?,
        comparisonName: String?
    ) -> String {
        guard let previous, let comparisonName else { return "Nothing to compare with yet." }
        let delta = summary.netWorth - previous.netWorth
        var sentences: [String] = []
        if delta.rounded() == 0 {
            sentences.append("Net worth is where it was in \(comparisonName).")
        } else {
            sentences.append("Net worth \(delta > 0 ? "rose" : "fell") \(FinanceFormat.money(abs(delta))) since \(comparisonName).")
        }
        let leaders = moved.filter { $0.impact.rounded() != 0 && ($0.impact > 0) == (delta > 0) }.prefix(2).map(\.name)
        if !leaders.isEmpty {
            sentences.append("\(leaders.joined(separator: " and ")) did most of it.")
        }
        if let compared {
            let now = MetalPriceFeed.effectivePrices(for: month, live: live)
            let then = MetalPriceFeed.effectivePrices(for: compared, live: live)
            if now.gold > 0, then.gold > 0, now.gold.rounded() != then.gold.rounded() {
                sentences.append("Gold went from \(FinanceFormat.money(then.gold)) to \(FinanceFormat.money(now.gold)) an ounce.")
            }
        }
        if delta > 0, let drag = moved.last(where: { $0.impact.rounded() < 0 }) {
            sentences.append("\(drag.name) was the biggest drag, at \(drag.impactText).")
        }
        return sentences.joined(separator: " ")
    }

    // MARK: - Trend

    /// A year's line starts from the month it's compared with (last
    /// December), so its change is the headline's.
    private func trend(scope: ReportScope, through period: YearMonth, from start: YearMonth?) -> FinanceReportData.Trend {
        let values: [FinanceHistory.Value] = switch scope {
        case .month: history.series(.netWorth, through: period, last: 12)
        case .year(let year): history.series(.netWorth, through: period).filter { $0.period.year == year || $0.period == start }
        }
        let points = values.map {
            FinanceReportData.TrendPoint(period: $0.period, label: $0.period.shortName, value: $0.value, valueText: FinanceFormat.money($0.value))
        }
        var dips: [YearMonth] = []
        for (before, after) in zip(points, points.dropFirst()) where after.value.rounded() < before.value.rounded() {
            dips.append(after.period)
        }
        guard let first = points.first, let last = points.last, points.count > 1 else {
            return FinanceReportData.Trend(points: points, change: nil, changeText: nil, perMonth: nil, dips: [], lede: "Only one month so far.")
        }
        let change = last.value - first.value
        let span = (last.period.year - first.period.year) * 12 + (last.period.month - first.period.month)
        let perMonth = span > 0 ? change / Double(span) : nil
        var lede = "\(change >= 0 ? "Up" : "Down") \(FinanceFormat.money(abs(change))) since \(first.period.title)"
        if let perMonth {
            lede += ", about \(FinanceFormat.money(abs(perMonth))) a month"
        }
        lede += "."
        switch dips.count {
        case 0: lede += " No month fell on the one before."
        case 1: lede += " The only dip was \(dips[0].monthName)."
        case 2: lede += " The only dips were \(dips[0].monthName) and \(dips[1].monthName)."
        default: lede += " It fell in \(counted(dips.count, "month"))."
        }
        return FinanceReportData.Trend(
            points: points, change: change, changeText: FinanceFormat.signedMoney(change),
            perMonth: perMonth, dips: dips, lede: lede
        )
    }

    // MARK: - Accounts

    static func ownerChip(_ owner: SharedFinanceOwner?) -> FinanceReportData.OwnerChip? {
        guard let owner else { return nil }
        return FinanceReportData.OwnerChip(
            name: owner.name, colorName: owner.color.rawValue,
            colorHex: owner.color.hexLight, colorHexDark: owner.color.hexDark
        )
    }

    static func identifier(_ object: NSManagedObject) -> String {
        object.objectID.uriRepresentation().absoluteString
    }

    private func accountGroups(in month: SharedFinanceMonth, compared: SharedFinanceMonth?, comparisonName: String?) -> [FinanceReportData.AccountGroupSection] {
        let groups = AccountCategory.monthlyCases.compactMap { category -> FinanceReportData.AccountGroupSection? in
            let rows = (month.balances ?? []).compactMap { balance -> FinanceReportData.AccountRow? in
                guard let account = balance.account, account.category == category, filter.includes(account.owner) else { return nil }
                let previous = compared.flatMap { account.balance(in: $0)?.amount }
                // An archived account at zero is history, not a holding —
                // `BalanceTileDetail`'s rule.
                if account.isArchived, balance.amount == 0, (previous ?? 0) == 0 { return nil }
                let unchanged = previous.map { $0.rounded() == balance.amount.rounded() } ?? false
                return FinanceReportData.AccountRow(
                    id: Self.identifier(account),
                    name: account.displayName,
                    ownerName: account.owner?.name,
                    owner: Self.ownerChip(account.owner),
                    category: category,
                    value: balance.amount,
                    valueText: FinanceFormat.money(balance.amount),
                    previous: previous,
                    isUnchanged: unchanged && balance.amount.rounded() != 0,
                    isFilledIn: balance.edited || month.isClosed
                )
            }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            guard !rows.isEmpty else { return nil }
            let total = rows.reduce(0) { $0 + $1.value }
            let previousTotal: Double? = compared == nil ? nil : rows.reduce(0) { $0 + ($1.previous ?? 0) }
            let change = previousTotal.map { total - $0 }
            var owners: [FinanceReportData.OwnerChip] = []
            for chip in rows.compactMap(\.owner) where !owners.contains(chip) { owners.append(chip) }
            var lede = "\(counted(rows.count, "account"))."
            if owners.count > 1 {
                let parts = owners.map { chip in
                    "\(chip.name) \(FinanceFormat.money(rows.filter { $0.owner == chip }.reduce(0) { $0 + $1.value }))"
                }
                lede += " " + parts.joined(separator: ", ") + "."
            }
            if let change, let comparisonName {
                lede += change.rounded() == 0
                    ? " Unchanged from \(comparisonName)."
                    : " \(change > 0 ? "Up" : "Down") \(FinanceFormat.money(abs(change))) on \(comparisonName)."
            }
            return FinanceReportData.AccountGroupSection(
                category: category,
                title: category == .loan ? "Loans" : Self.assetName(Self.metric(for: category)),
                total: total,
                totalText: FinanceFormat.money(total),
                previousTotal: previousTotal,
                change: change,
                lede: lede,
                rows: rows,
                owners: owners
            )
        }
        let assets = groups.filter { $0.category != .loan }.sorted { $0.total > $1.total }
        return assets + groups.filter { $0.category == .loan }
    }

    nonisolated static func metric(for category: AccountCategory) -> FinanceMetric {
        switch category {
        case .cash: .cash
        case .investments: .investments
        case .retirement: .retirement
        case .health: .health
        case .fixed: .fixed
        case .card, .loan: .cardSpend
        }
    }

    // MARK: - Metals

    private func metalRow(_ item: SharedFinanceMetalItem, prices: MetalPrices) -> FinanceReportData.MetalRow {
        let value: Double = item.value(at: prices)
        let cost: Double? = item.cost
        let location: String = item.location.trimmingCharacters(in: .whitespaces)
        var gain: Double?
        var gainFraction: Double?
        var costText: String?
        if let cost {
            gain = value - cost
            gainFraction = cost > 0 ? value / cost - 1 : nil
            costText = FinanceFormat.money(cost)
        }
        let weightOrTyped: String = item.hasManualValue ? "typed value" : FinanceFormat.grams(item.grams)
        let detail: String = location.isEmpty ? weightOrTyped : "\(weightOrTyped) · \(location)"
        let name: String = item.name.isEmpty ? item.metal.displayName : item.name
        let id: String = Self.identifier(item)
        let owner: FinanceReportData.OwnerChip? = Self.ownerChip(item.owner)
        return FinanceReportData.MetalRow(
            id: id,
            name: name,
            metal: item.metal,
            grams: item.grams,
            gramsText: FinanceFormat.grams(item.grams),
            location: location,
            ownerName: item.owner?.name,
            owner: owner,
            value: value,
            valueText: FinanceFormat.money(value),
            isTyped: item.hasManualValue,
            cost: cost,
            costText: costText,
            gain: gain,
            gainFraction: gainFraction,
            detail: detail
        )
    }

    private func metalsSection(month: SharedFinanceMonth) -> FinanceReportData.MetalsSection {
        let prices = MetalPriceFeed.effectivePrices(for: month, live: live)
        let pricesAreLive = MetalPriceFeed.usesLivePrices(month, live: live)
        let items = metals.filter { filter.includes($0.owner) }
        let rows: [FinanceReportData.MetalRow] = items
            .map { metalRow($0, prices: prices) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let total = rows.reduce(0) { $0 + $1.value }
        let grams = rows.reduce(0) { $0 + $1.grams }

        func metalTotal(_ metal: MetalKind) -> FinanceReportData.MetalTotal {
            let members = rows.filter { $0.metal == metal }
            let value = members.reduce(0) { $0 + $1.value }
            let grams = members.reduce(0) { $0 + $1.grams }
            return FinanceReportData.MetalTotal(
                metal: metal, value: value, valueText: FinanceFormat.money(value),
                grams: grams, gramsText: FinanceFormat.grams(grams.rounded()), count: members.count,
                detail: "\(FinanceFormat.grams(grams.rounded())) · \(counted(members.count, "item"))"
            )
        }

        var byLocation: [String: Double] = [:]
        for row in rows { byLocation[row.location.isEmpty ? "No location" : row.location, default: 0] += row.value }
        let locations = byLocation
            .map { name, value -> FinanceReportData.LocationTotal in
                let share = total > 0 ? value / total : 0
                return FinanceReportData.LocationTotal(
                    name: name, value: value, valueText: FinanceFormat.money(value), share: share,
                    detail: "\(FinanceFormat.percent(share)) of holdings"
                )
            }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.name < $1.name }

        let costed = rows.filter { $0.cost != nil }
        let paid = costed.reduce(0) { $0 + ($1.cost ?? 0) }
        let gain = costed.reduce(0) { $0 + ($1.gain ?? 0) }
        let goldText = FinanceFormat.cents(prices.gold)
        let silverText = FinanceFormat.cents(prices.silver)

        var lede = ""
        if !rows.isEmpty {
            lede = "\(counted(rows.count, "item")), \(FinanceFormat.grams(grams.rounded()))."
            let priceList = "gold \(goldText) and silver \(silverText) an ounce."
            if pricesAreLive {
                lede += " Valued at today's prices: \(priceList)"
            } else if month.isClosed {
                lede += " Valued at the prices saved when \(month.monthName) was finished: \(priceList)"
            } else {
                lede += " Valued at \(month.monthName)'s prices: \(priceList)"
            }
            let typed = rows.filter(\.isTyped)
            if typed.isEmpty {
                lede += " Every item follows the price."
            } else {
                let following = rows.count - typed.count
                let names = typed.map(\.name).joined(separator: ", ")
                lede += following > 0
                    ? " \(counted(following, "item")) \(following == 1 ? "follows" : "follow") the price; \(names) \(typed.count == 1 ? "holds a typed value" : "hold typed values")."
                    : " Every item holds a typed value."
            }
        }

        return FinanceReportData.MetalsSection(
            total: total, totalText: FinanceFormat.money(total), totalGrams: grams,
            gold: metalTotal(.gold), silver: metalTotal(.silver),
            locations: locations, items: rows, prices: prices,
            goldPriceText: goldText, silverPriceText: silverText, pricesAreLive: pricesAreLive,
            paid: paid, gainOnCosted: gain, lede: lede
        )
    }

    // MARK: - Spending

    /// The household's transactions in `period` that the filter counts — by
    /// the card or account they were paid with, as `MonthSummary` counts a
    /// card's spend by its owner.
    func filteredTransactions(in period: YearMonth) -> [SharedFinanceTransaction] {
        allTransactions.filter { period.contains($0.date) && filter.includes($0.card?.owner) }
    }

    private func spending(scope: ReportScope, period: YearMonth, periods: [YearMonth], month: SharedFinanceMonth) -> FinanceReportData.SpendingSection {
        let transactions = periods.flatMap { filteredTransactions(in: $0) }
        let total = SpendingSummary.total(transactions)
        let onCards = SpendingSummary.total(transactions.filter { $0.card?.category == .card })
        let fromCash = total - onCards

        // The average month over the three before, among those with any
        // transactions at all: a month nobody logged spending in isn't a
        // month of no spending.
        let averagePeriods: [YearMonth] = scope.isYear ? [] : (1...Self.averageLookbackMonths)
            .map { YearMonth(year: period.year, month: period.month - $0) }
            .filter { candidate in allTransactions.contains { candidate.contains($0.date) } }
            .prefix(Self.averageMonths)
            .reversed()
        let averageTransactions = averagePeriods.map { filteredTransactions(in: $0) }
        let average: Double? = averagePeriods.isEmpty ? nil : averageTransactions.map(SpendingSummary.total).reduce(0, +) / Double(averagePeriods.count)

        let categories = SpendingSummary.breakdown(transactions).map { category -> FinanceReportData.CategorySpend in
            let categoryAverage: Double? = averagePeriods.isEmpty ? nil : averageTransactions
                .map { SpendingSummary.total(SpendingSummary.transactions($0, inCategory: category.name)) }
                .reduce(0, +) / Double(averagePeriods.count)
            let change = categoryAverage.map { category.total - $0 }
            let fraction: Double? = categoryAverage.flatMap { $0 > 0 ? (category.total - $0) / $0 : nil }
            let changeText: String? = {
                guard let categoryAverage else { return nil }
                if categoryAverage == 0 { return "none in \(Self.list(averagePeriods.map(\.monthName), conjunction: "or"))" }
                return fraction.map(FinanceFormat.signedPercent)
            }()
            return FinanceReportData.CategorySpend(
                name: category.name, total: category.total, totalText: FinanceFormat.money(category.total),
                count: category.count, share: category.share,
                average: categoryAverage, averageText: categoryAverage.map(FinanceFormat.money),
                change: change, changeFraction: fraction, changeText: changeText
            )
        }
        let changed: [FinanceReportData.CategorySpend] = categories.filter { abs($0.change ?? 0) >= 1 }
        let biggestChanges = changed.sorted { abs($0.change ?? 0) > abs($1.change ?? 0) }.prefix(4)

        let (budgets, unbudgeted) = scope.isYear
            ? ([], yearUnbudgeted(periods: periods, end: month))
            : budgetRows(month: month, period: period)
        let overBudget: Double
        let overCount: Int
        if scope.isYear {
            let statuses = periods.compactMap { budgetStatus(for: $0) }
            overBudget = statuses.flatMap(\.lines).filter(\.isOver).reduce(0) { $0 + $1.spent - $1.limit }
            overCount = Set(statuses.flatMap(\.lines).filter(\.isOver).map { SpendingSummary.key($0.category) }).count
        } else {
            overBudget = budgets.reduce(0) { $0 + $1.over }
            overCount = budgets.count(where: \.isOver)
        }
        let unbudgetedTotal = unbudgeted.reduce(0) { $0 + $1.spent }

        let byAccount = accountSpend(transactions)
        let merchants = topMerchants(transactions)
        let recurring = recurringCharges(at: periods.last ?? period)
        let recurringMonthly = recurring.reduce(0) { $0 + $1.amount }

        var lede: String
        let cashAccounts = byAccount.filter { !$0.isCard && $0.total != 0 }
        if fromCash.rounded() != 0 {
            let source = cashAccounts.count == 1 ? cashAccounts[0].name : "cash accounts"
            lede = "\(FinanceFormat.money(onCards)) on cards and \(FinanceFormat.money(fromCash)) paid from \(source), across \(counted(transactions.count, "transaction")). Only the card share is owed."
        } else {
            lede = "\(FinanceFormat.money(total)) across \(counted(transactions.count, "transaction")), all of it on cards."
        }
        if !scope.isYear {
            if overCount > 0 {
                lede += " \(FinanceFormat.money(overBudget)) over budget in \(overCount) of \(counted(budgets.count, "category", plural: "categories"))."
            } else if !budgets.isEmpty {
                lede += " Within budget in all \(counted(budgets.count, "category", plural: "categories"))."
            }
        } else if overCount > 0 {
            lede += " Over budget in \(counted(overCount, "category", plural: "categories")) at some point in the year."
        }

        return FinanceReportData.SpendingSection(
            periods: periods,
            total: total, totalText: FinanceFormat.money(total),
            onCards: onCards, onCardsText: FinanceFormat.money(onCards),
            fromCash: fromCash, fromCashText: FinanceFormat.money(fromCash),
            transactionCount: transactions.count,
            average: average, averageText: average.map(FinanceFormat.money),
            averageMonths: Array(averagePeriods),
            changeVsAverage: average.flatMap { $0 > 0 ? (total - $0) / $0 : nil },
            categories: categories,
            biggestChanges: Array(biggestChanges),
            budgets: budgets,
            unbudgeted: unbudgeted,
            unbudgetedTotal: unbudgetedTotal, unbudgetedTotalText: FinanceFormat.money(unbudgetedTotal),
            overBudgetTotal: overBudget, overBudgetCount: overCount,
            budgetsAreHouseholdWide: { if case .owner = filter { true } else { false } }(),
            byAccount: byAccount,
            topMerchants: merchants,
            recurring: recurring,
            recurringMonthly: recurringMonthly, recurringMonthlyText: FinanceFormat.cents(recurringMonthly),
            lede: lede
        )
    }

    /// The month's `BudgetStatus`, household-wide — the Budget screen's own.
    /// `filtered` counts only the filter's charges instead: for the no-budget
    /// lines, which sit beside that person's own spending on the page.
    func budgetStatus(for period: YearMonth, filtered: Bool = false) -> BudgetStatus? {
        guard let month = months.first(where: { $0.period == period }) else { return nil }
        return BudgetStatus(
            period: period,
            budgets: month.sortedBudgets.map { (category: $0.category, limit: $0.limit) },
            transactions: filtered ? filteredTransactions(in: period) : allTransactions,
            asOf: now
        )
    }

    private func budgetRows(month: SharedFinanceMonth, period: YearMonth) -> ([FinanceReportData.BudgetRow], [FinanceReportData.UnbudgetedRow]) {
        guard let status = budgetStatus(for: period) else { return ([], []) }
        // Earlier months' statuses, newest first, while they run on without a gap.
        var earlier: [BudgetStatus] = []
        var cursor = period
        for previous in months.reversed() {
            guard let previousPeriod = previous.period, previousPeriod < period else { continue }
            guard previousPeriod == cursor.previous, let previousStatus = budgetStatus(for: previousPeriod) else { break }
            earlier.append(previousStatus)
            cursor = previousPeriod
        }
        let rows = status.lines.map { line -> FinanceReportData.BudgetRow in
            let key = SpendingSummary.key(line.category)
            let history = earlier.map { $0.lines.first { SpendingSummary.key($0.category) == key } }
            var overStreak = line.isOver ? 1 : 0
            if line.isOver {
                for earlierLine in history {
                    guard let earlierLine, earlierLine.isOver else { break }
                    overStreak += 1
                }
            }
            var underStreak = !line.isOver && line.spent > 0 ? 1 : 0
            if underStreak > 0 {
                for earlierLine in history {
                    guard let earlierLine, !earlierLine.isOver, earlierLine.spent > 0 else { break }
                    underStreak += 1
                }
            }
            let previousLine = history.first ?? nil
            let over = max(line.spent - line.limit, 0)
            return FinanceReportData.BudgetRow(
                category: line.category,
                limit: line.limit,
                spent: line.spent,
                isOver: line.isOver,
                over: over,
                label: "\(FinanceFormat.money(line.spent)) of \(FinanceFormat.money(line.limit))" + (line.isOver ? " · \(FinanceFormat.money(over)) over" : ""),
                previousSpent: previousLine?.spent,
                previousLimit: previousLine?.limit,
                overStreak: overStreak,
                underStreak: underStreak
            )
        }
        // Whose charges, like the rest of the page's spending: only the
        // budget lines are household-wide. Built off the household's status,
        // Saloni's report said "$X went on N categories with no budget" with
        // Bhavik's charges in it.
        let ownStatus = budgetStatus(for: period, filtered: true) ?? status
        let unbudgeted = ownStatus.unbudgetedLines
            .filter { $0.spent != 0 }
            .map { line in
                FinanceReportData.UnbudgetedRow(
                    category: line.category,
                    spent: line.spent,
                    spentText: FinanceFormat.money(line.spent),
                    isUncategorised: line.isUncategorised,
                    isKeptWithNoBudget: !line.isUncategorised && month.budget(for: line.category).map { !$0.hasLimit } == true
                )
            }
        return (rows, unbudgeted)
    }

    /// A year's unbudgeted spending, category by category across its months.
    private func yearUnbudgeted(periods: [YearMonth], end: SharedFinanceMonth) -> [FinanceReportData.UnbudgetedRow] {
        var totals: [String: (name: String, spent: Double, uncategorised: Bool)] = [:]
        // The filter's own charges, as in `budgetRows`.
        for status in periods.compactMap({ budgetStatus(for: $0, filtered: true) }) {
            for line in status.unbudgetedLines where line.spent != 0 {
                let key = line.id
                totals[key, default: (line.category, 0, line.isUncategorised)].spent += line.spent
            }
        }
        return totals.values
            .map { entry in
                FinanceReportData.UnbudgetedRow(
                    category: entry.name, spent: entry.spent, spentText: FinanceFormat.money(entry.spent),
                    isUncategorised: entry.uncategorised,
                    isKeptWithNoBudget: !entry.uncategorised && end.budget(for: entry.name).map { !$0.hasLimit } == true
                )
            }
            .sorted { $0.spent != $1.spent ? $0.spent > $1.spent : $0.category.localizedStandardCompare($1.category) == .orderedAscending }
    }

    private func accountSpend(_ transactions: [SharedFinanceTransaction]) -> [FinanceReportData.AccountSpend] {
        let grouped = Dictionary(grouping: transactions) { $0.card.map(Self.identifier) ?? "" }
        return grouped.map { id, members in
            let account = members.first?.card
            let total = SpendingSummary.total(members)
            return FinanceReportData.AccountSpend(
                id: id,
                name: account?.displayName ?? "No account",
                ownerName: account?.owner?.name,
                owner: Self.ownerChip(account?.owner),
                isCard: account?.category == .card,
                total: total,
                totalText: FinanceFormat.money(total),
                count: members.count
            )
        }
        .sorted { $0.total != $1.total ? $0.total > $1.total : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated static let topMerchantCount = 10

    private func topMerchants(_ transactions: [SharedFinanceTransaction]) -> [FinanceReportData.MerchantRow] {
        var rows: [String: (name: String, visits: Int, total: Double)] = [:]
        for transaction in transactions {
            let name = transaction.merchant.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            rows[name.lowercased(), default: (name, 0, 0)].visits += 1
            rows[name.lowercased(), default: (name, 0, 0)].total += transaction.actualCost
        }
        let merchants: [FinanceReportData.MerchantRow] = rows.values.map { entry in
            FinanceReportData.MerchantRow(name: entry.name, visits: entry.visits, total: entry.total, totalText: FinanceFormat.cents(entry.total))
        }
        let sorted = merchants.sorted { lhs, rhs in
            lhs.total != rhs.total ? lhs.total > rhs.total : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return Array(sorted.prefix(Self.topMerchantCount))
    }

    /// Category names that are subscriptions by definition.
    nonisolated static func isSubscriptionLike(_ category: String, expense: String = "") -> Bool {
        let keys = [SpendingSummary.key(category), SpendingSummary.key(expense)]
        return keys.contains { key in
            key.contains("subscription") || ["membership", "memberships", "streaming", "software", "apps"].contains(key)
        }
    }

    /// Card charges that come round every month as of `period`: one charge
    /// this month from a merchant that was charged once in each of the two
    /// months before too, at much the same amount; or one filed as a
    /// subscription that was charged last month too, or is new.
    /// "New" is a subscription charged this month and in none of the five
    /// before — said only when the two months before have card charges at
    /// all, and it wasn't charged about a year ago.
    ///
    /// Cards only: rent paid by Zelle from checking comes round every month
    /// too, but it isn't a charge anyone signed up to and might cancel, and
    /// it swamped the subscriptions the line is for.
    func recurringCharges(at period: YearMonth) -> [FinanceReportData.RecurringCharge] {
        let window = (0..<Self.recurringLookbackMonths).map { YearMonth(year: period.year, month: period.month - $0) }
        var charges: [String: [Int: [SharedFinanceTransaction]]] = [:]
        var monthsWithCharges = Set<Int>()
        for (offset, month) in window.enumerated() {
            for transaction in filteredTransactions(in: month) where transaction.card?.category == .card && transaction.actualCost > 0 {
                monthsWithCharges.insert(offset)
                let key = Self.merchantKey(transaction.merchant)
                guard !key.isEmpty else { continue }
                charges[key, default: [:]][offset, default: []].append(transaction)
            }
        }
        // The household's first month of card charges made every
        // subscription "new since August" — August had nothing logged at all.
        let historyCovers = monthsWithCharges.contains(1) && monthsWithCharges.contains(2)
        // Merchants charged 11 to 13 months ago: a yearly subscription comes
        // back once a year, and outside the six-month window it read as new
        // every year — and as a monthly charge, $139 "a month, $1,668 a year".
        let yearAgo = Set((11...13).flatMap { back in
            filteredTransactions(in: YearMonth(year: period.year, month: period.month - back))
                .filter { $0.card?.category == .card && $0.actualCost > 0 }
                .map { Self.merchantKey($0.merchant) }
        })
        return charges.compactMap { key, byMonth -> FinanceReportData.RecurringCharge? in
            guard let current = byMonth[0], current.count == 1, let charge = current.first else { return nil }
            let amount = charge.actualCost
            func similar(_ other: Double) -> Bool {
                abs(other - amount) <= max(1, amount * Self.recurringTolerance)
            }
            let subscription = Self.isSubscriptionLike(charge.category, expense: charge.expense)
            // Anything not filed as a subscription has to have come round
            // in each of the two months before at much the same amount: one
            // repeat alone made a monthly film night "recurring".
            let repeats = [1, 2].allSatisfy { offset in
                byMonth[offset].map { $0.count == 1 && similar($0[0].actualCost) } ?? false
            }
            let monthsSeen = byMonth.count
            let isNew = monthsSeen == 1
            // A subscription needs last month's charge too, or to be new: a
            // filing alone counted a quarterly or yearly one as monthly.
            let monthlySubscription = subscription && byMonth[1] != nil
            let newSubscription = subscription && isNew && historyCovers && !yearAgo.contains(key)
            guard repeats || monthlySubscription || newSubscription else { return nil }
            return FinanceReportData.RecurringCharge(
                merchant: charge.merchant.trimmingCharacters(in: .whitespaces),
                category: charge.category.trimmingCharacters(in: .whitespaces),
                amount: amount,
                amountText: FinanceFormat.cents(amount),
                monthsSeen: monthsSeen,
                isNew: isNew,
                accountName: charge.card?.displayName
            )
        }
        .sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.merchant.localizedStandardCompare($1.merchant) == .orderedAscending }
    }

    nonisolated static func merchantKey(_ merchant: String) -> String {
        merchant.trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: - Cards

    private func cardsSection(periods: [YearMonth], isYear: Bool) -> FinanceReportData.CardsSection {
        let rows = cards.compactMap { card -> FinanceReportData.CardRow? in
            guard filter.includes(card.owner) else { return nil }
            let spend = periods.reduce(0) { $0 + card.spend(in: $1) }
            let count = (card.transactions ?? []).count { transaction in periods.contains { $0.contains(transaction.date) } }
            guard !card.isArchived || spend != 0 else { return nil }
            let monthly = periods.isEmpty ? spend : spend / Double(periods.count)
            let use: Double? = card.limit > 0 ? monthly / card.limit : nil
            return FinanceReportData.CardRow(
                id: Self.identifier(card),
                name: card.displayName,
                ownerName: card.owner?.name,
                owner: Self.ownerChip(card.owner),
                limit: card.limit,
                limitText: card.limit > 0 ? FinanceFormat.money(card.limit) : "—",
                fee: card.annualFee,
                feeText: card.annualFee > 0 ? FinanceFormat.money(card.annualFee) : "—",
                spend: spend,
                spendText: FinanceFormat.cents(spend),
                use: use,
                useText: use.map(FinanceFormat.percent),
                transactionCount: count
            )
        }
        let totalLimit = rows.reduce(0) { $0 + $1.limit }
        let totalFees = rows.reduce(0) { $0 + $1.fee }
        let totalSpend = rows.reduce(0) { $0 + $1.spend }
        // Use is the spend on cards with a limit over those limits: a card
        // with no limit set added its spend to the top and nothing to the
        // bottom, so a barely used household read "Cards at 40% of their
        // limit".
        let limitedSpend = rows.filter { $0.limit > 0 }.reduce(0) { $0 + $1.spend }
        let monthly = periods.isEmpty ? limitedSpend : limitedSpend / Double(periods.count)
        let use: Double? = totalLimit > 0 ? monthly / totalLimit : nil
        var lede = ""
        if !rows.isEmpty {
            lede = "\(counted(rows.count, "card")), \(FinanceFormat.money(totalLimit)) of combined limit, "
                + (totalFees > 0 ? "\(FinanceFormat.money(totalFees)) a year in fees." : "no annual fees.")
            if let use {
                let charged = isYear ? "charged over the year" : "charged this month"
                let share = isYear ? "of the limit in an average month" : "of the limit"
                lede += limitedSpend.rounded() == totalSpend.rounded()
                    ? " \(FinanceFormat.money(totalSpend)) \(charged): \(FinanceFormat.percent(use)) \(share)."
                    : " \(FinanceFormat.money(totalSpend)) \(charged); the \(FinanceFormat.money(limitedSpend)) on cards with a limit is \(FinanceFormat.percent(use)) \(share)."
            } else {
                lede += " \(FinanceFormat.money(totalSpend)) charged."
            }
        }
        return FinanceReportData.CardsSection(
            cards: rows,
            totalLimit: totalLimit, totalLimitText: FinanceFormat.money(totalLimit),
            totalFees: totalFees, totalFeesText: FinanceFormat.money(totalFees),
            totalSpend: totalSpend, totalSpendText: FinanceFormat.money(totalSpend),
            limitedSpend: limitedSpend, limitedSpendText: FinanceFormat.money(limitedSpend),
            use: use, useText: use.map(FinanceFormat.percent),
            lede: lede
        )
    }

    // MARK: - Year

    private func yearSection(
        year: Int,
        end: SharedFinanceMonth,
        compared: SharedFinanceMonth?,
        periods: [YearMonth],
        spending: FinanceReportData.SpendingSection
    ) -> FinanceReportData.YearSection {
        let rows = periods.compactMap { period -> FinanceReportData.YearMonthRow? in
            guard let point = history.points.first(where: { $0.period == period }) else { return nil }
            let change = history.delta(.netWorth, at: period)
            let spend = SpendingSummary.total(filteredTransactions(in: period))
            return FinanceReportData.YearMonthRow(
                period: period,
                label: period.shortName,
                netWorth: point.summary.netWorth,
                netWorthText: FinanceFormat.money(point.summary.netWorth),
                change: change,
                changeText: change.map(FinanceFormat.change),
                spend: spend,
                spendText: FinanceFormat.money(spend),
                cardSpend: point.summary.cardSpend,
                budgetsOver: budgetStatus(for: period)?.lines.count(where: \.isOver) ?? 0,
                isClosed: point.month.isClosed
            )
        }
        // A month still half typed in has every balance not filled in yet at
        // zero, so its "change" is mostly missing balances: a year ending on
        // an open January called it the weakest month, net worth down by
        // everything not typed in.
        let withChange = rows.filter { row in
            guard row.change != nil else { return false }
            guard let month = months.first(where: { $0.period == row.period }) else { return true }
            return !isPartial(month)
        }
        let best = withChange.max { ($0.change ?? 0) < ($1.change ?? 0) }
        let worst = withChange.count > 1 ? withChange.min { ($0.change ?? 0) < ($1.change ?? 0) } : nil
        let endSummary = summary(of: end)
        let startSummary = compared.map(summary(of:))
        let change = startSummary.map { endSummary.netWorth - $0.netWorth }

        let monthsWithSpend = periods.filter { period in allTransactions.contains { period.contains($0.date) } }
        let spendAverage: Double? = monthsWithSpend.isEmpty ? nil : spending.total / Double(monthsWithSpend.count)

        // Last year, per month with any spending, for "up 12% on 2025".
        let lastYear = (1...12).map { YearMonth(year: year - 1, month: $0) }
        let lastYearMonths = lastYear.filter { period in allTransactions.contains { period.contains($0.date) } }
        let lastYearTransactions = lastYearMonths.flatMap { filteredTransactions(in: $0) }
        let previousYearAverage: Double? = lastYearMonths.isEmpty ? nil : SpendingSummary.total(lastYearTransactions) / Double(lastYearMonths.count)

        let monthTransactions = periods.map { filteredTransactions(in: $0) }
        let categories = spending.categories.map { category -> FinanceReportData.YearCategory in
            let monthly = monthTransactions.map { SpendingSummary.total(SpendingSummary.transactions($0, inCategory: category.name)) }
            let previous: Double? = lastYearMonths.isEmpty ? nil
                : SpendingSummary.total(SpendingSummary.transactions(lastYearTransactions, inCategory: category.name)) / Double(lastYearMonths.count)
            return FinanceReportData.YearCategory(
                name: category.name, total: category.total, totalText: category.totalText,
                monthly: monthly, share: category.share, previousYearMonthlyAverage: previous
            )
        }

        var budgets: [String: (name: String, budgeted: Int, over: Int, limit: Double, spent: Double, overBy: Double)] = [:]
        for status in periods.compactMap({ budgetStatus(for: $0) }) {
            for line in status.lines {
                let key = SpendingSummary.key(line.category)
                var entry = budgets[key] ?? (line.category, 0, 0, 0, 0, 0)
                entry.budgeted += 1
                entry.limit += line.limit
                entry.spent += line.spent
                if line.isOver {
                    entry.over += 1
                    entry.overBy += line.spent - line.limit
                }
                budgets[key] = entry
            }
        }
        let yearBudgets = budgets.values
            .map {
                FinanceReportData.YearBudget(
                    category: $0.name, monthsBudgeted: $0.budgeted, monthsOver: $0.over,
                    totalLimit: $0.limit, totalSpent: $0.spent, totalOver: $0.overBy
                )
            }
            .sorted { $0.monthsOver != $1.monthsOver ? $0.monthsOver > $1.monthsOver : $0.category.localizedStandardCompare($1.category) == .orderedAscending }

        return FinanceReportData.YearSection(
            year: year,
            months: rows,
            startPeriod: compared?.period,
            startNetWorth: startSummary?.netWorth,
            endNetWorth: endSummary.netWorth,
            change: change,
            changeText: change.map(FinanceFormat.signedMoney),
            bestMonth: best,
            worstMonth: worst?.period == best?.period ? nil : worst,
            spendTotal: spending.total,
            spendTotalText: spending.totalText,
            spendAverage: spendAverage,
            spendAverageText: spendAverage.map(FinanceFormat.money),
            categories: categories,
            budgets: yearBudgets,
            debtPaidDown: startSummary.map { $0.loans - endSummary.loans },
            recurringMonthly: spending.recurringMonthly,
            previousYearMonthlyAverage: previousYearAverage
        )
    }

    // MARK: - Words

    /// "July", "July or August", "June, July or August".
    nonisolated static func list(_ items: [String], conjunction: String = "and") -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " \(conjunction) " + items[items.count - 1]
        }
    }
}
