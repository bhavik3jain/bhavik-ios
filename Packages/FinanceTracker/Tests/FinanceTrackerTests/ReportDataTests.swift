import Core
import CoreData
import Foundation
import ObjectiveC
import Testing
@testable import FinanceTracker

/// Ties a fixture context's lifetime to its container — see Fuel's tests.
private nonisolated(unsafe) var reportContainerKey: UInt8 = 0

/// Households for the report tests: a fresh in-memory container each, since
/// Swift Testing runs tests in parallel.
@MainActor
enum ReportDataFixture {
    static let august = YearMonth(year: 2026, month: 8)
    static let september = YearMonth(year: 2026, month: 9)
    static let october = YearMonth(year: 2026, month: 10)
    /// Every report here is built "on" this day.
    static let now = FinanceCalendar.date(2026, 10, 3).addingTimeInterval(12 * 3_600)

    static func emptyHousehold() -> SharedFinanceHousehold {
        let container = CloudSharedStore.makeContainer(
            name: "FinanceReportTests-\(UUID().uuidString)",
            model: FinanceModel.make(),
            containerID: "iCloud.com.bhavikjain.trackers.tests",
            inMemory: true
        )
        let context = container.viewContext
        objc_setAssociatedObject(context, &reportContainerKey, container, .OBJC_ASSOCIATION_RETAIN)
        return FinanceHouseholdResolver.forWriting(in: context, container: container)
    }

    static func household() -> SharedFinanceHousehold {
        let household = emptyHousehold()
        for (name, kind) in [("Bhavik", OwnerKind.person), ("Saloni", .person), ("Joint", .joint)] {
            _ = SharedFinanceOwner(name: name, kind: kind, household: household)
        }
        return household
    }

    static func owner(_ name: String, in household: SharedFinanceHousehold) -> SharedFinanceOwner? {
        household.sortedOwners.first { $0.name == name }
    }

    static func day(_ period: YearMonth, _ day: Int) -> Date {
        FinanceCalendar.date(period.year, period.month, day).addingTimeInterval(12 * 3_600)
    }

    @discardableResult
    static func charge(
        _ household: SharedFinanceHousehold,
        _ period: YearMonth,
        day: Int = 10,
        _ cost: Double,
        _ merchant: String,
        _ category: String,
        on account: SharedFinanceAccount?
    ) -> SharedFinanceTransaction {
        let transaction = SharedFinanceTransaction(date: Self.day(period, day), cost: cost, merchant: merchant, household: household, card: account)
        transaction.category = category
        return transaction
    }

    static func month(_ period: YearMonth, in household: SharedFinanceHousehold, gold: Double = 0, silver: Double = 0, closed: Bool = true) -> SharedFinanceMonth {
        let month = SharedFinanceMonth(period: period, household: household)
        month.goldPricePerOz = gold
        month.silverPricePerOz = silver
        if closed { month.close(asOf: period.end) }
        return month
    }

    /// The accounts and metals of `standard()`, by name.
    struct Standard {
        let household: SharedFinanceHousehold
        let checking: SharedFinanceAccount
        let roth: SharedFinanceAccount
        let hsa: SharedFinanceAccount
        let car: SharedFinanceAccount
        let loan: SharedFinanceAccount
        let travelCard: SharedFinanceAccount
        let cashBack: SharedFinanceAccount
        let august: SharedFinanceMonth
        let september: SharedFinanceMonth
    }

    /// August and September, both finished, with:
    /// - Bhavik's checking up $200, Saloni's Roth up $1,000, the loan down
    ///   $420, the car unchanged (valued by hand) and Bhavik's HSA matching
    ///   August to the dollar;
    /// - a typed-value ring, a coin with no cost, a bar with one, gold up
    ///   $120 an ounce;
    /// - September's Food over its $300 budget, Clothes kept with "No
    ///   budget", Car spent on with none, a new $9.99 Music App charge, and
    ///   Streaming Co charged in July, August and September.
    static func standard() -> Standard {
        let household = household()
        let bhavik = owner("Bhavik", in: household)
        let saloni = owner("Saloni", in: household)
        let joint = owner("Joint", in: household)
        let checking = SharedFinanceAccount(institution: "First Bank", name: "Checking", category: .cash, household: household, owner: bhavik)
        let roth = SharedFinanceAccount(institution: "Plan Provider", name: "Roth IRA", category: .retirement, household: household, owner: saloni)
        let hsa = SharedFinanceAccount(institution: "Benefits Co", name: "HSA", category: .health, household: household, owner: bhavik)
        let car = SharedFinanceAccount(institution: "", name: "Family car", category: .fixed, household: household, owner: joint)
        let loan = SharedFinanceAccount(institution: "Auto Lender", name: "Car loan", category: .loan, household: household, owner: joint)
        let travelCard = SharedFinanceAccount(institution: "Big Bank", name: "Travel Rewards", category: .card, household: household, owner: bhavik)
        travelCard.limit = 10_000
        travelCard.annualFee = 95
        let cashBack = SharedFinanceAccount(institution: "Big Bank", name: "Cash Back", category: .card, household: household, owner: saloni)
        cashBack.limit = 5_000

        let bar = SharedFinanceMetalItem(name: "Gold - Bar 100 g", metal: .gold, grams: 100, household: household, owner: joint)
        bar.location = "Locker"
        bar.pricePaidPerOz = 2_300
        let ring = SharedFinanceMetalItem(name: "Gold - Ring", metal: .gold, grams: 6, household: household, owner: saloni)
        ring.location = "Home"
        ring.hasManualValue = true
        ring.manualValue = 3_500
        let coin = SharedFinanceMetalItem(name: "Gold - Coin 1 oz", metal: .gold, grams: 31.1035, household: household, owner: bhavik)
        coin.location = "Locker"

        let july = month(YearMonth(year: 2026, month: 7), in: household, gold: 4_200, silver: 47)
        let august = month(Self.august, in: household, gold: 4_300, silver: 48)
        let september = month(Self.september, in: household, gold: 4_420, silver: 50.5)
        for (account, values) in [
            (checking, [2_900.0, 3_000, 3_200]),
            (roth, [49_000, 50_000, 51_000]),
            (hsa, [4_500, 4_600.20, 4_600.40]),
            (car, [20_000, 20_000, 20_000]),
            (loan, [15_420, 15_000, 14_580]),
        ] {
            for (month, value) in zip([july, august, september], values) {
                _ = SharedFinanceBalance(account: account, month: month, amount: value, edited: true)
            }
        }
        for month in [july, august, september] {
            month.setBudget(300, for: "Food")
            month.setBudget(nil, for: "Clothes")
            month.setBudget(40, for: "Subscriptions")
            month.setBudget(2_000, for: "Home")
        }

        for period in [YearMonth(year: 2026, month: 7), Self.august, Self.september] {
            charge(household, period, day: 5, 15.99, "Streaming Co", "Subscriptions", on: cashBack)
            charge(household, period, day: 1, 1_800, "Landlord", "Home", on: checking)
        }
        charge(household, Self.august, 250, "Noodle House", "Food", on: travelCard)
        charge(household, Self.september, day: 12, 350, "Noodle House", "Food", on: travelCard)
        charge(household, Self.september, day: 13, 80, "Clothes Shop", "Clothes", on: cashBack)
        charge(household, Self.september, day: 14, 40, "Gas Station", "Car", on: travelCard)
        charge(household, Self.september, day: 15, 9.99, "Music App", "Subscriptions", on: cashBack)
        try? household.managedObjectContext?.save()
        return Standard(
            household: household, checking: checking, roth: roth, hsa: hsa, car: car, loan: loan,
            travelCard: travelCard, cashBack: cashBack, august: august, september: september
        )
    }

    static func report(
        _ scope: ReportScope,
        _ household: SharedFinanceHousehold,
        filter: OwnerFilter = .all,
        live: MetalPrices? = nil
    ) -> FinanceReportData? {
        FinanceReportData.build(scope: scope, household: household, filter: filter, live: live, deviceName: "Test iPhone", asOf: now)
    }
}

private func approximately(_ lhs: Double, _ rhs: Double, within tolerance: Double = 0.001) -> Bool {
    abs(lhs - rhs) <= tolerance
}

// MARK: - Scope

@Test func reportScopesReadWriteAndStep() throws {
    let month = ReportScope.month(YearMonth(year: 2026, month: 9))
    #expect(month.rawValue == "2026-09")
    #expect(ReportScope(rawValue: "2026-09") == month)
    #expect(ReportScope(rawValue: "2026") == .year(2026))
    #expect(ReportScope(rawValue: "September") == nil)
    #expect(month.previous == .month(YearMonth(year: 2026, month: 8)))
    #expect(ReportScope.year(2026).next == .year(2027))
    #expect(ReportScope.month(YearMonth(year: 2026, month: 12)).next == .month(YearMonth(year: 2027, month: 1)))
    #expect(ReportScope.year(2026).title == "2026 in review")
    let encoded = try JSONEncoder().encode([month, .year(2025)])
    #expect(String(decoding: encoded, as: UTF8.self) == #"["2026-09","2025"]"#, "Codable as its raw value")
    #expect(try JSONDecoder().decode([ReportScope].self, from: encoded) == [month, .year(2025)])
}

// MARK: - Figures agree with the rest of the app

@Test @MainActor func reportFiguresMatchTheSummaryAndAddUp() throws {
    let fixture = ReportDataFixture.standard()
    let data = try #require(ReportDataFixture.report(.month(ReportDataFixture.september), fixture.household))
    let summary = MonthSummary(month: fixture.september)
    let previous = MonthSummary(month: fixture.august)

    #expect(approximately(data.hero.netWorth, summary.netWorth), "The headline is the Summary's own figure")
    #expect(approximately(data.hero.assets, summary.totalAssets))
    #expect(approximately(data.hero.owed, summary.owed))
    let delta = try #require(data.hero.delta)
    #expect(approximately(delta, summary.netWorth - previous.netWorth))
    #expect(data.hero.comparisonName == "August")

    let moved = data.moved.reduce(0) { $0 + $1.impact }
    #expect(approximately(moved, delta), "What moved adds up to the net worth's change")
    #expect(data.moved.contains { $0.source == .loans && $0.name == "Car loan paid down" && approximately($0.impact, 420) })
    #expect(data.moved.contains { $0.source == .cards })
    #expect(!data.moved.contains { $0.source == .asset(.fixed) }, "An unchanged car moves nothing")

    #expect(approximately(data.mix.reduce(0) { $0 + $1.value }, summary.totalAssets), "The mix adds up to total assets")
    #expect(approximately(data.mix.reduce(0) { $0 + $1.share }, 1))
    #expect(data.mix.first?.metric == .retirement, "Largest first")
    let mixDelta = data.mix.reduce(0) { $0 + ($1.delta ?? 0) }
    #expect(approximately(mixDelta, summary.totalAssets - previous.totalAssets))

    let accounts = data.accountGroups.flatMap(\.rows).filter { $0.category.isAsset }.reduce(0) { $0 + $1.value }
    #expect(approximately(accounts + data.metals.total, summary.totalAssets), "Accounts plus metals are the assets")
    #expect(data.accountGroups.last?.category == .loan, "Loans come last")
    #expect(approximately(data.metals.total, summary.metals))
    #expect(data.metals.prices == MetalPrices(gold: 4_420, silver: 50.5), "A finished month keeps its saved prices")
    #expect(!data.metals.pricesAreLive)

    #expect(approximately(data.cards.totalSpend, summary.cardSpend), "Card spend is the balance sheet's")
    #expect(data.cards.totalLimit == 15_000)
    #expect(approximately(data.spending.total, FinanceHome.spend(in: fixture.september)), "Spending is the home row's")
    #expect(approximately(data.spending.fromCash, 1_800), "Rent from checking isn't owed")
    #expect(data.spending.topMerchants.first?.name == "Landlord")
    #expect(data.trend.points.map(\.period.month) == [7, 8, 9])
    #expect(data.kpis.map(\.id) == ["assets", "owed", "cash", "retirement", "cardUse"])
    #expect(data.header.ownerLabel == "Everyone")
    #expect(data.header.coverageNote.contains("September was finished"))
    #expect(data.sections.map(\.id).contains("fixing"))
}

@Test @MainActor func liveMetalPricesValueOnlyTheOpenLatestMonth() throws {
    let fixture = ReportDataFixture.standard()
    let october = ReportDataFixture.month(ReportDataFixture.october, in: fixture.household, gold: 4_420, silver: 50.5, closed: false)
    for account in [fixture.checking, fixture.roth, fixture.hsa, fixture.car, fixture.loan] {
        _ = SharedFinanceBalance(account: account, month: october, amount: 0, edited: false)
    }
    let live = MetalPrices(gold: 5_000, silver: 60)
    let september = try #require(ReportDataFixture.report(.month(ReportDataFixture.september), fixture.household, live: live))
    #expect(september.metals.prices == MetalPrices(gold: 4_420, silver: 50.5), "A finished month ignores live prices")
    let open = try #require(ReportDataFixture.report(.month(ReportDataFixture.october), fixture.household, live: live))
    #expect(open.metals.pricesAreLive)
    #expect(open.metals.prices == live)
    #expect(open.header.isPartial)
    #expect(open.findings.contains { $0.kind == .openMonthUnfinished && $0.severity == .distorts })
    #expect(open.worthFixing.first?.severity == .distorts, "What distorts the headline comes first")

    // The default report is September's while October is half typed in —
    // `FinanceHome.reportedMonth`'s rule.
    #expect(FinanceReportData.defaultScope(for: fixture.household, live: live) == .month(ReportDataFixture.september))
    #expect(september.header.openMonth?.period == ReportDataFixture.october)
    #expect(september.header.coverageNote.hasPrefix("October is"))
    #expect(september.findings.contains { $0.kind == .reportedMonthFallback && $0.fix == .updateBalances(ReportDataFixture.october) })
}

// MARK: - Budgets

@Test @MainActor func noBudgetIsAnUnbudgetedLineNeverAMinusOneBudget() throws {
    let fixture = ReportDataFixture.standard()
    let data = try #require(ReportDataFixture.report(.month(ReportDataFixture.september), fixture.household))
    let spending = data.spending
    #expect(!spending.budgets.contains { $0.category == "Clothes" }, "A category at noLimit is never a budget line")
    #expect(spending.budgets.allSatisfy { $0.limit >= 0 })
    let clothes = try #require(spending.unbudgeted.first { $0.category == "Clothes" })
    #expect(clothes.isKeptWithNoBudget)
    #expect(clothes.spent == 80)
    let car = try #require(spending.unbudgeted.first { $0.category == "Car" })
    #expect(!car.isKeptWithNoBudget, "Spent on and never given a budget")
    #expect(spending.unbudgetedTotal == 120)

    let food = try #require(spending.budgets.first { $0.category == "Food" })
    #expect(food.isOver && food.over == 50)
    #expect(food.label == "$350 of $300 · $50 over")
    #expect(food.overStreak == 1, "August's $250 was under")
    #expect(food.previousSpent == 250)
    #expect(spending.overBudgetTotal == 50, "Subscriptions, $25.98 of $40, is within")
    #expect(!data.findings.contains { $0.figures.contains("-$1") || $0.plainText.contains("$-1") })
    let unbudgeted = try #require(data.findings.first { $0.kind == .unbudgetedSpend })
    #expect(unbudgeted.figures == ["$120"])
    #expect(unbudgeted.names == ["Clothes", "Car"])
}

// MARK: - Stale balances

@Test @MainActor func balancesMatchingLastMonthToTheDollarAreFlagged() throws {
    let fixture = ReportDataFixture.standard()
    let data = try #require(ReportDataFixture.report(.month(ReportDataFixture.september), fixture.household))
    let rows = data.accountGroups.flatMap(\.rows)
    let hsa = try #require(rows.first { $0.name == "Benefits Co - HSA" })
    #expect(hsa.isUnchanged, "$4,600.20 then $4,600.40 is the same to the dollar")
    #expect(rows.first { $0.name == "Family car" }?.isUnchanged == true)
    #expect(rows.first { $0.name == "First Bank - Checking" }?.isUnchanged == false)

    let stale = try #require(data.findings.first { $0.kind == .staleBalances })
    #expect(stale.names.contains("Benefits Co - HSA"))
    #expect(!stale.names.contains("Family car"), "A hand-valued car keeping its figure isn't stale")
    #expect(stale.severity == .distorts && stale.isWorthFixing)
    #expect(stale.title == "1 balance matches August to the dollar")
    #expect(stale.fix == .updateBalances(ReportDataFixture.september))
}

@Test @MainActor func aZeroBalanceIsNeverStale() throws {
    let household = ReportDataFixture.household()
    let account = SharedFinanceAccount(institution: "Bank", name: "Old savings", category: .cash, household: household)
    for period in [ReportDataFixture.august, ReportDataFixture.september] {
        let month = ReportDataFixture.month(period, in: household)
        _ = SharedFinanceBalance(account: account, month: month, amount: 0, edited: true)
    }
    let data = try #require(ReportDataFixture.report(.month(ReportDataFixture.september), household))
    #expect(!data.findings.contains { $0.kind == .staleBalances })
}

// MARK: - Recurring

@Test @MainActor func recurringChargesAreSubscriptionsOrThreeMonthsRunning() throws {
    let household = ReportDataFixture.household()
    let card = SharedFinanceAccount(institution: "Big Bank", name: "Card", category: .card, household: household)
    let checking = SharedFinanceAccount(institution: "Bank", name: "Checking", category: .cash, household: household)
    let periods = [YearMonth(year: 2026, month: 7), ReportDataFixture.august, ReportDataFixture.september]
    for period in periods {
        _ = ReportDataFixture.month(period, in: household)
        ReportDataFixture.charge(household, period, day: 3, 59.99, "Gym", "Health", on: card)
        ReportDataFixture.charge(household, period, day: 1, 1_800, "Landlord", "Home", on: checking)
    }
    // Two months only, not filed as a subscription: not yet a pattern.
    ReportDataFixture.charge(household, ReportDataFixture.august, 30, "Cinema", "Entertainment", on: card)
    ReportDataFixture.charge(household, ReportDataFixture.september, 30, "Cinema", "Entertainment", on: card)
    // Filed as a subscription, first seen this month: new.
    ReportDataFixture.charge(household, ReportDataFixture.september, 9.99, "Music App", "Subscriptions", on: card)
    // Twice in one month is shopping, not a subscription.
    ReportDataFixture.charge(household, ReportDataFixture.august, day: 4, 12, "Coffee", "Subscriptions", on: card)
    ReportDataFixture.charge(household, ReportDataFixture.september, day: 4, 12, "Coffee", "Subscriptions", on: card)
    ReportDataFixture.charge(household, ReportDataFixture.september, day: 18, 12, "Coffee", "Subscriptions", on: card)

    let data = try #require(ReportDataFixture.report(.month(ReportDataFixture.september), household))
    let recurring = data.spending.recurring
    #expect(Set(recurring.map(\.merchant)) == ["Gym", "Music App"], "Rent from checking and the cinema aren't recurring charges")
    #expect(recurring.first { $0.merchant == "Gym" }?.isNew == false)
    #expect(recurring.first { $0.merchant == "Gym" }?.monthsSeen == 3)
    #expect(recurring.first { $0.merchant == "Music App" }?.isNew == true)
    #expect(approximately(data.spending.recurringMonthly, 69.98))

    let new = try #require(data.findings.first { $0.kind == .newRecurring })
    #expect(new.plainText == "Music App, $9.99, is a new recurring charge since August.")
    #expect(new.fix == .showCharges(category: nil, merchant: "Music App"))
    let total = try #require(data.findings.first { $0.kind == .recurringTotal })
    #expect(total.plainText == "2 recurring charges come to $70 a month, $840 a year.")
}

// MARK: - Year

@Test @MainActor func yearInReviewRunsFromTheMonthBeforeToTheYearsEnd() throws {
    let household = ReportDataFixture.household()
    let savings = SharedFinanceAccount(institution: "Bank", name: "Savings", category: .cash, household: household)
    let card = SharedFinanceAccount(institution: "Big Bank", name: "Card", category: .card, household: household)
    let values: [(YearMonth, Double)] = [
        (YearMonth(year: 2025, month: 12), 10_000),
        (YearMonth(year: 2026, month: 1), 11_000),
        (YearMonth(year: 2026, month: 2), 10_500),
        (YearMonth(year: 2026, month: 3), 12_000),
    ]
    for (period, value) in values {
        let month = ReportDataFixture.month(period, in: household)
        _ = SharedFinanceBalance(account: savings, month: month, amount: value, edited: true)
        month.setBudget(100, for: "Food")
    }
    ReportDataFixture.charge(household, YearMonth(year: 2025, month: 12), 50, "Diner", "Food", on: card)
    ReportDataFixture.charge(household, YearMonth(year: 2026, month: 1), 150, "Diner", "Food", on: card)
    ReportDataFixture.charge(household, YearMonth(year: 2026, month: 2), 120, "Diner", "Food", on: card)
    ReportDataFixture.charge(household, YearMonth(year: 2026, month: 3), 80, "Diner", "Food", on: card)

    let data = try #require(ReportDataFixture.report(.year(2026), household))
    let year = try #require(data.year)
    #expect(data.period == YearMonth(year: 2026, month: 3))
    #expect(year.startPeriod == YearMonth(year: 2025, month: 12), "The year starts from where the last one ended")
    #expect(year.months.map(\.period.month) == [1, 2, 3])
    #expect(data.trend.points.map(\.period.month) == [12, 1, 2, 3], "The year's months, from the December it's compared with")
    #expect(data.trend.change == year.change, "The line's change is the headline's")
    #expect(year.change == 1_970, "$11,920 in March against $9,950 in December, each less its card spend")
    #expect(year.bestMonth?.period.month == 3)
    #expect(year.worstMonth?.period.month == 2)
    #expect(year.spendTotal == 350)
    #expect(data.spending.budgets.isEmpty, "A year has no single month's budgets")
    let food = try #require(year.budgets.first)
    #expect(food.monthsOver == 2 && food.monthsBudgeted == 3)
    #expect(year.categories.first?.monthly == [150, 120, 80])
    #expect(year.previousYearMonthlyAverage == 50)

    let kinds = Set(data.findings.map(\.kind))
    #expect(kinds.isSuperset(of: [.yearNetWorth, .yearBestMonth, .yearWorstMonth, .yearOverBudget, .yearSpendingTotal]))
    #expect(!kinds.contains(.overBudget), "No month-only findings in a year")
    #expect(data.header.title == "2026 in review")
}

@Test @MainActor func aYearEndingInAHalfTypedMonthReportsTheOneBefore() throws {
    let fixture = ReportDataFixture.standard()
    let october = ReportDataFixture.month(ReportDataFixture.october, in: fixture.household, closed: false)
    _ = SharedFinanceBalance(account: fixture.checking, month: october, amount: 0, edited: false)
    let data = try #require(ReportDataFixture.report(.year(2026), fixture.household))
    #expect(data.period == ReportDataFixture.september)
    #expect(data.year?.months.last?.period == ReportDataFixture.september)
    #expect(data.header.coverageNote.contains("leaving out October"))
}

// MARK: - Owner filter

@Test @MainActor func anOwnerFilterNarrowsBalancesAndSpendingButNotBudgets() throws {
    let fixture = ReportDataFixture.standard()
    let bhavik = try #require(ReportDataFixture.owner("Bhavik", in: fixture.household))
    let data = try #require(ReportDataFixture.report(.month(ReportDataFixture.september), fixture.household, filter: .owner(bhavik)))
    let summary = MonthSummary(month: fixture.september, filter: .owner(bhavik))
    #expect(approximately(data.hero.netWorth, summary.netWorth))
    #expect(data.header.ownerLabel == "Bhavik")
    #expect(data.header.kicker.hasSuffix("· Bhavik"))
    #expect(data.accountGroups.flatMap(\.rows).allSatisfy { $0.ownerName == "Bhavik" })
    #expect(data.metals.items.map(\.name) == ["Gold - Coin 1 oz"])
    #expect(data.cards.cards.map(\.name) == ["Big Bank - Travel Rewards"])
    // Bhavik's card and checking: Food, Car and rent.
    #expect(approximately(data.spending.total, 350 + 40 + 1_800))
    #expect(data.spending.budgetsAreHouseholdWide)
    let subscriptions = try #require(data.spending.budgets.first { $0.category == "Subscriptions" })
    #expect(approximately(subscriptions.spent, 25.98), "Budgets still count Saloni's charges")
}

// MARK: - Seed

@Test @MainActor func theDebugSeedSetsOffEveryCheck() throws {
    let household = ReportDataFixture.emptyHousehold()
    let context = try #require(household.managedObjectContext)
    FinanceDebugSeed.run(context: context, container: nil, asOf: ReportDataFixture.now)
    let seeded = try #require(try context.fetch(SharedFinanceHousehold.fetchRequest()).first { !$0.isEmpty })
    let scope = try #require(FinanceReportData.defaultScope(for: seeded, live: nil))
    #expect(scope == .month(ReportDataFixture.september), "The open October falls back to September")

    let data = try #require(ReportDataFixture.report(scope, seeded))
    let kinds = Set(data.findings.map(\.kind))
    let expected: Set<ReportFinding.Kind> = [
        .netWorthMove, .topMovers, .debtPaidDown, .overBudget, .overBudgetRepeat, .underBudgetStreak,
        .categorySpike, .staleBalances, .typedMetalValue, .metalWithoutCost, .unbudgetedSpend,
        .uncategorisedSpend, .newRecurring, .recurringTotal, .reportedMonthFallback,
    ]
    #expect(kinds.isSuperset(of: expected), "Missing: \(expected.subtracting(kinds))")
    #expect(data.findings.contains { $0.id == "overBudget:food" })
    #expect(data.findings.contains { $0.id == "overBudgetRepeat:subscriptions" })
    #expect(data.findings.contains { $0.kind == .newRecurring && $0.names.first == "Music App" })
    #expect(data.findings.contains { $0.kind == .categorySpike && $0.names.first == "Travel" })
    #expect(data.findings.first { $0.kind == .staleBalances }?.title == "2 balances match August to the dollar")
    #expect(data.trend.points.count == 11, "Eleven finished months before October")
    #expect(!data.trend.dips.isEmpty)
    #expect(data.spending.average != nil)
    #expect(data.spending.recurring.count == 4)
    #expect(data.sections.count == 11, "Every section has something in it")

    let year = try #require(ReportDataFixture.report(.year(2026), seeded))
    #expect(year.year?.months.count == 9)
    #expect(year.findings.contains { $0.kind == .yearOverBudget && $0.names == ["Food"] })
    #expect(year.findings.contains { $0.kind == .yearWorstMonth })

    // Seeding again does nothing.
    FinanceDebugSeed.run(context: context, container: nil, asOf: ReportDataFixture.now)
    #expect(try context.count(for: SharedFinanceMonth.fetchRequest()) == FinanceDebugSeed.monthCount)
}
