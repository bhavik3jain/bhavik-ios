import Core
import CoreData
import Foundation
import ObjectiveC
import Testing
@testable import FinanceTracker

/// Ties a returned context's lifetime to its container — see Fuel's tests.
private nonisolated(unsafe) var associatedContainerKey: UInt8 = 0

/// A fresh, uniquely-named in-memory container per test: Swift Testing runs
/// tests in parallel, and two containers under one name share a store URL.
@MainActor
private func makeContainer() -> NSPersistentCloudKitContainer {
    CloudSharedStore.makeContainer(
        name: "FinanceTests-\(UUID().uuidString)",
        model: FinanceModel.make(),
        containerID: "iCloud.com.bhavikjain.trackers.tests",
        inMemory: true
    )
}

@MainActor
private func makeHousehold() -> SharedFinanceHousehold {
    let container = makeContainer()
    let context = container.viewContext
    objc_setAssociatedObject(context, &associatedContainerKey, container, .OBJC_ASSOCIATION_RETAIN)
    return FinanceHouseholdResolver.forWriting(in: context, container: container)
}

@MainActor
private func owner(_ name: String, in household: SharedFinanceHousehold) throws -> SharedFinanceOwner {
    try #require(household.sortedOwners.first { $0.name == name })
}

private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
    FinanceCalendar.date(year, month, day).addingTimeInterval(TimeInterval(hour) * 3_600)
}

private let september = YearMonth(year: 2026, month: 9)

private func approximately(_ lhs: Double, _ rhs: Double, within tolerance: Double = 0.0001) -> Bool {
    abs(lhs - rhs) <= tolerance
}

// MARK: - YearMonth and input

@Test func yearMonthsReadWriteAndRollOver() throws {
    let month = try #require(YearMonth("2026-09"))
    #expect(month.rawValue == "2026-09")
    #expect(YearMonth(year: 2026, month: 12).next.rawValue == "2027-01")
    #expect(YearMonth(year: 2026, month: 1).previous.rawValue == "2025-12")
    #expect(YearMonth("2026-13") == nil)
    #expect(YearMonth("September") == nil)
    #expect(YearMonth("2026-09")! < YearMonth("2026-10")!)
    #expect(month.contains(day(2026, 9, 30, hour: 23)))
    #expect(!month.contains(FinanceCalendar.date(2026, 10, 1)), "The end is exclusive")
    #expect(FinanceCalendar.dayString(day(2026, 9, 3)) == "2026-09-03")
    #expect(FinanceCalendar.date(fromDayString: "2026-09-03") == FinanceCalendar.date(2026, 9, 3))
}

@Test func moneyTypedByHandReads() {
    #expect(FinanceInput.parse("1234.56") == 1234.56)
    #expect(FinanceInput.parse("$1,234.56") == 1234.56)
    #expect(FinanceInput.parse("-20") == -20)
    #expect(FinanceInput.parse("(20)") == -20)
    #expect(FinanceInput.parse("") == nil)
    #expect(FinanceInput.parse("abc") == nil)
    #expect(FinanceInput.parse(FinanceFormat.editable(4500.5)) == 4500.5, "What the field shows reads back")
    let german = Locale(identifier: "de_DE")
    #expect(FinanceInput.parse("12,5", locale: german) == 12.5, "A comma decimal isn't read as 125")
    #expect(FinanceInput.parse("1.234,56", locale: german) == 1234.56)
    #expect(FinanceFormat.editable(0) == "")
}

// MARK: - Metals

/// One regular (avoirdupois) ounce: what the Numbers sheet's "ozm" converts with.
private let ounce = 28.349523125

@Test func metalsAreValuedPerRegularOunceLikeTheSheet() {
    #expect(MetalValuation.gramsPerOunce == 28.349523125)
    #expect(approximately(MetalValuation.ounces(grams: ounce), 1))
    #expect(approximately(MetalValuation.grams(ounces: 2), 56.69904625))

    let prices = MetalPrices(gold: 4_500, silver: 52)
    #expect(approximately(MetalValuation.value(grams: 2 * ounce, metal: .gold, manualValue: nil, prices: prices), 9_000, within: 0.01))
    #expect(approximately(MetalValuation.value(grams: ounce, metal: .silver, manualValue: nil, prices: prices), 52, within: 0.01))
    #expect(MetalValuation.value(grams: 6, metal: .gold, manualValue: 3_500, prices: prices) == 3_500, "A hand-set value wins")
}

@Test func aTroyOunceCoinIsWorthAboutTenPercentOverItsQuote() {
    // Deliberate: prices are per troy ounce, weights in regular ounces, as in
    // the sheet. A 1 oz t coin at $4,500 values at ~$4,937, not $4,500.
    let prices = MetalPrices(gold: 4_500, silver: 52)
    let coin = MetalValuation.value(grams: MetalValuation.gramsPerTroyOunce, metal: .gold, manualValue: nil, prices: prices)
    #expect(approximately(coin, 4_500 * 31.1035 / 28.349523125, within: 0.01))
    #expect(approximately(coin / 4_500, 1.0971, within: 0.0001))
}

@Test func aMetalsCostPrefersItsPurchaseValue() {
    #expect(MetalValuation.cost(grams: ounce, pricePaidPerOz: 1_600, purchaseValue: 1_700) == 1_700)
    #expect(approximately(MetalValuation.cost(grams: ounce, pricePaidPerOz: 1_600, purchaseValue: 0) ?? 0, 1_600, within: 0.01))
    #expect(MetalValuation.cost(grams: ounce, pricePaidPerOz: 0, purchaseValue: 0) == nil)
}

@MainActor
@Test func holdingsCountGainOnlyWhereTheCostIsKnown() {
    let household = makeHousehold()
    let bar = SharedFinanceMetalItem(name: "Bar", metal: .gold, grams: ounce, household: household)
    bar.purchaseValue = 4_000
    let chain = SharedFinanceMetalItem(name: "Chain", metal: .gold, grams: ounce, household: household)
    let ring = SharedFinanceMetalItem(name: "Ring", metal: .gold, grams: 5, household: household)
    ring.hasManualValue = true
    ring.manualValue = 3_000

    let prices = MetalPrices(gold: 4_500, silver: 50)
    let holdings = MetalHoldings([bar, chain, ring], prices: prices)

    #expect(approximately(holdings.value, 4_500 + 4_500 + 3_000, within: 0.01))
    #expect(holdings.paid == 4_000)
    #expect(approximately(holdings.gain, 500, within: 0.01), "Only the bar has a cost")
    #expect(chain.gain(at: prices) == nil)
    #expect(ring.value(at: prices) == 3_000)
}

// MARK: - Cards

@MainActor
@Test func aCardsBalanceIsItsShareOfThatMonthsTransactions() {
    let household = makeHousehold()
    let card = SharedFinanceAccount(institution: "Chase", name: "Sapphire", category: .card, household: household)
    let other = SharedFinanceAccount(institution: "Amex", name: "Gold", category: .card, household: household)

    _ = SharedFinanceTransaction(date: day(2026, 9, 1, hour: 0), cost: 100, merchant: "A", household: household, card: card)
    let split = SharedFinanceTransaction(date: day(2026, 9, 15), cost: 80, merchant: "B", household: household, card: card)
    split.actualCost = 40
    _ = SharedFinanceTransaction(date: day(2026, 9, 20), cost: -10.5, merchant: "Refund", household: household, card: card)
    _ = SharedFinanceTransaction(date: day(2026, 10, 1, hour: 0), cost: 999, merchant: "Next month", household: household, card: card)
    _ = SharedFinanceTransaction(date: day(2026, 9, 2), cost: 7, merchant: "Other card", household: household, card: other)

    #expect(card.spend(in: september) == 129.5)
    #expect(other.spend(in: september) == 7)
    #expect(card.transactionCount == 4)
}

@MainActor
@Test func displayNamesJoinInstitutionAndName() {
    let household = makeHousehold()
    let account = SharedFinanceAccount(institution: "Capital One", name: "Checkings", category: .cash, household: household)
    let bare = SharedFinanceAccount(institution: "", name: "Family car", category: .fixed, household: household)
    #expect(account.displayName == "Capital One - Checkings")
    #expect(bare.displayName == "Family car")
    let split = FinanceMonthExchange.splitDisplayName("Chase - Sapphire Preferred")
    #expect(split.institution == "Chase")
    #expect(split.name == "Sapphire Preferred")
    let unsplit = FinanceMonthExchange.splitDisplayName("Store card")
    #expect(unsplit.institution == "")
    #expect(unsplit.name == "Store card")
}

@MainActor
@Test func anUnknownCategoryFallsBackToCash() {
    let account = SharedFinanceAccount(institution: "", name: "x", category: .loan, household: makeHousehold())
    account.categoryRaw = "crypto"
    #expect(account.category == .cash)
    #expect(AccountCategory.card.isLiability)
    #expect(AccountCategory.fixed.isAsset)
}

// MARK: - Month summary

/// One month with one account per category, a card each, metals and a loan.
@MainActor
private func makeSeptember() throws -> (household: SharedFinanceHousehold, month: SharedFinanceMonth) {
    let household = makeHousehold()
    let bhavik = try owner("Bhavik", in: household)
    let saloni = try owner("Saloni", in: household)
    let joint = try owner("Joint", in: household)

    let month = SharedFinanceMonth(period: september, household: household)
    month.goldPricePerOz = 4_000
    month.silverPricePerOz = 50

    let entries: [(AccountCategory, SharedFinanceOwner?, Double)] = [
        (.cash, joint, 3_000),
        (.cash, bhavik, 1_000),
        (.investments, saloni, 20_000),
        (.retirement, bhavik, 50_000),
        (.fixed, joint, 15_000),
        (.loan, joint, 10_000),
        (.cash, nil, 500),
    ]
    for (index, (category, owner, amount)) in entries.enumerated() {
        let account = SharedFinanceAccount(institution: "Bank", name: "Account \(index)", category: category, household: household, owner: owner)
        month.setBalance(amount, for: account)
    }

    let bhavikCard = SharedFinanceAccount(institution: "Chase", name: "Sapphire", category: .card, household: household, owner: bhavik)
    let jointCard = SharedFinanceAccount(institution: "Store", name: "Card", category: .card, household: household, owner: joint)
    _ = SharedFinanceTransaction(date: day(2026, 9, 3), cost: 300, merchant: "A", household: household, card: bhavikCard)
    _ = SharedFinanceTransaction(date: day(2026, 9, 4), cost: 200, merchant: "B", household: household, card: jointCard)

    _ = SharedFinanceMetalItem(name: "Bar", metal: .gold, grams: ounce, household: household, owner: joint)
    let ring = SharedFinanceMetalItem(name: "Ring", metal: .gold, grams: 5, household: household, owner: saloni)
    ring.hasManualValue = true
    ring.manualValue = 2_000
    return (household, month)
}

@MainActor
@Test func aMonthAddsUpToANetWorth() throws {
    let (_, month) = try makeSeptember()
    let summary = MonthSummary(month: month)

    #expect(summary.cash == 4_500)
    #expect(summary.investments == 20_000)
    #expect(summary.retirement == 50_000)
    #expect(summary.fixed == 15_000)
    #expect(approximately(summary.metals, 6_000, within: 0.01))
    #expect(summary.cardSpend == 500)
    #expect(summary.loans == 10_000)
    #expect(approximately(summary.totalAssets, 95_500, within: 0.01))
    #expect(summary.totalLiabilities == 10_500)
    #expect(approximately(summary.netWorth, 85_000, within: 0.01))
    #expect(summary.owed == 10_500)
}

@MainActor
@Test func theOwnerFilterSplitsAccountsMetalsAndCards() throws {
    let (household, month) = try makeSeptember()
    let bhavik = MonthSummary(month: month, filter: .owner(try owner("Bhavik", in: household)))
    let joint = MonthSummary(month: month, filter: .owner(try owner("Joint", in: household)))
    let saloni = MonthSummary(month: month, filter: .owner(try owner("Saloni", in: household)))

    #expect(bhavik.cash == 1_000, "The unowned cash belongs to no one's filter")
    #expect(bhavik.retirement == 50_000)
    #expect(bhavik.cardSpend == 300, "A charge on Bhavik's card is Bhavik's")
    #expect(bhavik.metals == 0)

    #expect(joint.cash == 3_000, "Joint is an owner like anyone else")
    #expect(joint.cardSpend == 200)
    #expect(joint.loans == 10_000)
    #expect(approximately(joint.metals, 4_000, within: 0.01))

    #expect(saloni.investments == 20_000)
    #expect(saloni.metals == 2_000)
    #expect(saloni.cardSpend == 0)
}

@MainActor
@Test func historyChartsEachMonthAndItsChange() throws {
    let (household, september) = try makeSeptember()
    let october = try #require(MonthRollover.startMonth(after: september))
    let cash = try #require(household.sortedAccounts.first { $0.category == .cash && $0.owner?.name == "Joint" })
    october.setBalance(4_000, for: cash)

    let history = FinanceHistory(months: [october, september])

    #expect(history.points.map(\.period.rawValue) == ["2026-09", "2026-10"], "Oldest first whatever order they came in")
    #expect(history.series(.cash).map(\.value) == [4_500, 5_500])
    #expect(history.delta(.cash, at: YearMonth(year: 2026, month: 10)) == 1_000)
    #expect(history.delta(.cash, at: YearMonth(year: 2026, month: 9)) == nil, "The first month has nothing to compare with")
    // October has no card transactions yet, so its liabilities drop by September's 500.
    #expect(history.delta(.cardSpend, at: YearMonth(year: 2026, month: 10)) == -500)
    #expect(history.series(.netWorth, last: 1).count == 1)
}

@MainActor
@Test func theOverviewsChangeMatchesTheWholeHistorys() throws {
    let (household, september) = try makeSeptember()
    let october = try #require(MonthRollover.startMonth(after: september))
    let cash = try #require(household.sortedAccounts.first { $0.category == .cash && $0.owner?.name == "Joint" })
    october.setBalance(4_000, for: cash)
    let november = try #require(MonthRollover.startMonth(after: october))
    november.setBalance(2_500, for: cash)

    let change = try #require(FinanceHome.netWorthChange(for: november, live: nil))
    let full = FinanceHistory(months: Array(household.months ?? []))
    #expect(change.previous == YearMonth(year: 2026, month: 10), "Against the month before, not the first")
    #expect(change.delta == full.delta(.netWorth, at: YearMonth(year: 2026, month: 11)))
    #expect(approximately(change.delta, -1_500, within: 0.01))
    #expect(FinanceHome.netWorthChange(for: september, live: nil) == nil, "The first month has nothing to compare with")
}

@Test func assetMixIsLargestFirstAndAddsUpToTheWhole() {
    var summary = MonthSummary()
    summary.cash = 10
    summary.investments = 60
    summary.retirement = 30
    summary.metals = 0
    summary.fixed = -5
    summary.cardSpend = 999
    let mix = AssetMix(summary)
    #expect(mix.shares.map(\.metric) == [.investments, .retirement, .cash], "Nothing empty or negative, and no liabilities")
    #expect(abs(mix.shares.reduce(0) { $0 + $1.fraction } - 1) < 0.0001)
    #expect(mix.legend() == "Investments 60% · Retirement 30% · Cash 10%")
    #expect(mix.legend(limit: 1) == "Investments 60%")

    var tie = MonthSummary()
    tie.retirement = 5
    tie.cash = 5
    #expect(AssetMix(tie).shares.map(\.metric) == [.cash, .retirement], "A tie keeps the metrics' own order")
    #expect(AssetMix(MonthSummary()).shares.isEmpty)
}

// MARK: - Rollover

@MainActor
@Test func startingAMonthCopiesLastMonth() throws {
    let (household, september) = try makeSeptember()
    let archived = SharedFinanceAccount(institution: "Old", name: "Closed", category: .cash, household: household)
    september.setBalance(99, for: archived)
    archived.isArchived = true
    _ = SharedFinanceBudget(category: "Food", limit: 600, month: september)

    let october = try #require(MonthRollover.startMonth(after: september))

    #expect(october.yearMonth == "2026-10")
    #expect(october.goldPricePerOz == 4_000)
    #expect(october.silverPricePerOz == 50)
    let balances = october.balances ?? []
    #expect(balances.count == 7, "Every open non-card account, and not the archived one")
    #expect(balances.allSatisfy { !$0.edited }, "Copied figures aren't updated yet")
    #expect(balances.allSatisfy { $0.account?.category != .card })
    #expect(!balances.contains { $0.account == archived })
    #expect(MonthSummary(month: october).cash == 4_500)
    #expect(october.sortedBudgets.map(\.category) == ["Food"])
    #expect(october.sortedBudgets.first?.limit == 600)

    #expect(MonthRollover.startMonth(after: september) == october, "A second tap finds the month already there")
    #expect(household.months?.count == 2)
}

@MainActor
@Test func progressCountsEditedBalancesAndMovedPrices() throws {
    let (_, september) = try makeSeptember()
    let october = try #require(MonthRollover.startMonth(after: september))
    #expect(MonthRollover.progress(of: october) == MonthProgress(updated: 0, total: 9))
    #expect(MonthRollover.progress(of: october).label == "0 of 9 updated")

    let account = try #require(october.sortedBalances.first?.account)
    october.setBalance(1, for: account)
    october.goldPricePerOz = 4_100
    #expect(MonthRollover.progress(of: october) == MonthProgress(updated: 2, total: 9))

    // September has no month before it: set prices count as updated.
    #expect(MonthRollover.progress(of: september).updated == 7 + 2)
}

@MainActor
@Test func theFirstMonthStartsFromNothing() {
    let household = makeHousehold()
    _ = SharedFinanceAccount(institution: "Bank", name: "Checking", category: .cash, household: household)
    _ = SharedFinanceAccount(institution: "Bank", name: "Card", category: .card, household: household)

    let first = MonthRollover.startNextMonth(in: household, asOf: day(2026, 9, 10))
    #expect(first.yearMonth == "2026-09")
    #expect(first.balances?.count == 1, "Cards never get a typed balance")

    let second = MonthRollover.startNextMonth(in: household, asOf: day(2026, 9, 10))
    #expect(second.yearMonth == "2026-10")
}

// MARK: - Budgets

@MainActor
@Test func budgetsCompareSpendingWithThePaceOfTheMonth() throws {
    let household = makeHousehold()
    let card = SharedFinanceAccount(institution: "Chase", name: "Card", category: .card, household: household)
    let month = SharedFinanceMonth(period: september, household: household)
    _ = SharedFinanceBudget(category: "Food", limit: 600, month: month)
    _ = SharedFinanceBudget(category: "Travel", limit: 400, month: month)
    _ = SharedFinanceBudget(category: "Home", limit: 100, month: month)

    func spend(_ cost: Double, on category: String, _ dayOfMonth: Int) {
        let transaction = SharedFinanceTransaction(date: day(2026, 9, dayOfMonth), cost: cost, merchant: "M", household: household, card: card)
        transaction.category = category
    }
    spend(100, on: "food", 2)       // Matched case-insensitively.
    spend(300, on: "Travel", 3)
    spend(150, on: "Home", 4)
    spend(50, on: "Clothes", 5)     // No budget.
    let late = SharedFinanceTransaction(date: day(2026, 10, 2), cost: 500, merchant: "Next month", household: household, card: card)
    late.category = "Food"

    // Halfway through September (30 days).
    let status = BudgetStatus(month: month, asOf: FinanceCalendar.date(2026, 9, 16))
    #expect(approximately(status.pace, 0.5))

    let lines = Dictionary(uniqueKeysWithValues: status.lines.map { ($0.category, $0) })
    let food = try #require(lines["Food"])
    let travel = try #require(lines["Travel"])
    let home = try #require(lines["Home"])
    #expect(food.spent == 100)
    #expect(status.state(of: food) == .onTrack)
    #expect(travel.spent == 300)
    #expect(status.state(of: travel) == .aheadOfPace, "75% gone halfway through the month")
    #expect(status.state(of: home) == .over)
    #expect(home.remaining == -50)
    #expect(status.unbudgeted == 50)
    #expect(status.totalLimit == 1_100)
    #expect(status.totalSpent == 550)
    #expect(status.left == 550)

    #expect(BudgetStatus(month: month, asOf: FinanceCalendar.date(2026, 8, 20)).pace == 0)
    #expect(BudgetStatus(month: month, asOf: FinanceCalendar.date(2026, 11, 1)).pace == 1)
}

@Test func anEmptyBudgetIsOnlyOverOnceSomethingIsSpent() {
    #expect(BudgetLine(category: "x", limit: 0, spent: 0).state(pace: 0.5) == .onTrack)
    #expect(BudgetLine(category: "x", limit: 0, spent: 5).state(pace: 0.5) == .over)
    #expect(BudgetLine(category: "x", limit: 100, spent: 100).state(pace: 1) == .onTrack, "Exactly on budget at month end")
}

// MARK: - Spending

@MainActor
@Test func spendingGroupsByCategoryAndDay() {
    let household = makeHousehold()
    let card = SharedFinanceAccount(institution: "Chase", name: "Card", category: .card, household: household)
    // The newest "Food" is typed with a capital, so that's the name shown.
    let rows: [(Int, Double, String)] = [(4, 10, "Food"), (3, 20, "food"), (5, 50, "Travel"), (5, 5, "")]
    for (dayOfMonth, cost, category) in rows {
        let transaction = SharedFinanceTransaction(date: day(2026, 9, dayOfMonth), cost: cost, merchant: "M", household: household, card: card)
        transaction.category = category
    }
    let transactions = SpendingSummary.transactions(Array(household.transactions ?? []), in: september)

    #expect(SpendingSummary.byCategory(transactions) == [
        SpendingTotal(name: "Travel", total: 50),
        SpendingTotal(name: "Food", total: 30),
        SpendingTotal(name: SpendingSummary.uncategorised, total: 5),
    ])
    let days = SpendingSummary.byDay(transactions)
    #expect(days.count == 3)
    #expect(days.first?.total == 55, "Newest day first")
    #expect(SpendingSummary.knownCategories(transactions).prefix(2) == ["Food", "Travel"], "Most used first")
}

// MARK: - Home

@MainActor
@Test func homeDetailShowsTheLatestNetWorth() throws {
    #expect(FinanceHome.homeDetail(for: [], container: nil) == "No months yet")

    let (_, september) = try makeSeptember()
    let october = try #require(MonthRollover.startMonth(after: september))
    let expected = MonthSummary(month: october).netWorth
    #expect(FinanceHome.homeDetail(for: [october, september], container: nil) == "Net worth \(FinanceFormat.money(expected))")
    #expect(FinanceTrackerModule.homeDetail(months: [september], container: nil) == "Net worth \(FinanceFormat.money(MonthSummary(month: september).netWorth))")
}

@MainActor
@Test func sidebarDetailNamesTheLatestMonth() throws {
    #expect(FinanceTrackerModule.sidebarDetail(months: [], container: nil) == nil)

    let (_, september) = try makeSeptember()
    let october = try #require(MonthRollover.startMonth(after: september))
    #expect(FinanceTrackerModule.sidebarDetail(months: [september], container: nil) == september.period?.shortName)
    #expect(FinanceTrackerModule.sidebarDetail(months: [october, september], container: nil) == october.period?.shortName)
}

// MARK: - Households

@MainActor
@Test func aNewHouseholdStartsWithTheDefaultOwners() throws {
    let container = makeContainer()
    let context = container.viewContext
    let first = FinanceHouseholdResolver.forWriting(in: context, container: container)
    try context.save()

    #expect(first.sortedOwners.map(\.name) == ["Bhavik", "Saloni", "Joint"])
    #expect(first.sortedOwners.last?.kind == .joint)
    #expect(FinanceHouseholdResolver.forWriting(in: context, container: container) == first)
    #expect(first.objectID.persistentStore == container.privatePersistentStore, "A new household is this device's own")
    #expect(FinanceHouseholdResolver.forDisplay(among: [first], container: container) == first)
    #expect(FinanceHouseholdResolver.forDisplay(among: [], container: container) == nil)
}

@MainActor
@Test func aHouseholdSharedWithThisDeviceWinsAndKeepsNewThingsInItsStore() throws {
    let container = makeContainer()
    let context = container.viewContext
    let mine = FinanceHouseholdResolver.forWriting(in: context, container: container)
    let sharedStore = try #require(container.persistentStoreCoordinator.persistentStores.first {
        $0 != container.privatePersistentStore
    })
    let partners = SharedFinanceHousehold(context: context, name: "Partner's")
    context.assign(partners, to: sharedStore)
    try context.save()

    let chosen = FinanceHouseholdResolver.forWriting(in: context, container: container)
    #expect(chosen == partners, "New things go where the partner can see them")
    #expect(FinanceHouseholdResolver.forDisplay(among: [mine, partners], container: container) == partners)
    #expect(FinanceHouseholdResolver.own(in: context, container: container) == mine)

    let account = SharedFinanceAccount(institution: "Bank", name: "Checking", category: .cash, household: chosen)
    let month = MonthRollover.startFirstMonth(in: chosen, asOf: day(2026, 9, 1))
    let budget = SharedFinanceBudget(category: "Food", limit: 100, month: month)
    let transaction = SharedFinanceTransaction(date: day(2026, 9, 2), cost: 1, merchant: "M", household: chosen)
    try context.save()

    let balance = try #require(month.balances?.first)
    #expect(account.objectID.persistentStore == sharedStore)
    #expect(month.objectID.persistentStore == sharedStore)
    #expect(balance.objectID.persistentStore == sharedStore, "Balances follow their month, not the default store")
    #expect(budget.objectID.persistentStore == sharedStore)
    #expect(transaction.objectID.persistentStore == sharedStore)
}

@MainActor
@Test func deletingAPersonKeepsWhatTheyHeld() throws {
    let household = makeHousehold()
    let context = try #require(household.managedObjectContext)
    let saloni = try owner("Saloni", in: household)
    _ = SharedFinanceAccount(institution: "Bank", name: "Savings", category: .cash, household: household, owner: saloni)
    _ = SharedFinanceMetalItem(name: "Ring", metal: .gold, grams: 5, household: household, owner: saloni)
    try context.save()

    context.delete(saloni)
    try context.save()

    #expect(try context.fetch(SharedFinanceAccount.fetchRequest()).first?.owner == nil)
    #expect(try context.fetch(SharedFinanceMetalItem.fetchRequest()).first?.owner == nil)
}

@MainActor
@Test func deletingACardTakesItsTransactions() throws {
    let household = makeHousehold()
    let context = try #require(household.managedObjectContext)
    let card = SharedFinanceAccount(institution: "Chase", name: "Card", category: .card, household: household)
    _ = SharedFinanceTransaction(date: day(2026, 9, 2), cost: 1, merchant: "M", household: household, card: card)
    try context.save()

    context.delete(card)
    try context.save()

    #expect(try context.count(for: SharedFinanceTransaction.fetchRequest()) == 0)
}

// MARK: - JSON

@MainActor
@Test func aMonthRoundTripsThroughJSON() throws {
    let (household, month) = try makeSeptember()
    _ = SharedFinanceBudget(category: "Food", limit: 600, month: month)
    let card = try #require(household.sortedAccounts.first { $0.category == .card })
    card.limit = 41_900
    card.annualFee = 95
    let split = SharedFinanceTransaction(date: day(2026, 9, 9), cost: 50, merchant: "Dinner", household: household, card: card)
    split.actualCost = 25
    split.category = "Food"
    split.expense = "Birthday"
    split.breakDown = "Half is Sam's"
    try #require(household.managedObjectContext).processPendingChanges()

    let exported = FinanceMonthDocument(month: month)
    let data = try FinanceMonthExchange.encode(exported)
    let decoded = try FinanceMonthExchange.decode(data)
    #expect(decoded == exported)

    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains("\"manualValue\" : null"), "Automatic metals write an explicit null for the scripts")
    #expect(json.contains("\"card\" : \"Chase - Sapphire\""))
    #expect(json.contains("\"date\" : \"2026-09-09\""))

    let fresh = makeHousehold()
    let summary = try FinanceMonthExchange.apply(decoded, to: fresh)
    try #require(fresh.managedObjectContext).processPendingChanges()
    #expect(summary.accountsAdded == 7)
    #expect(summary.cardsAdded == 2)
    #expect(summary.metalsAdded == 2)
    #expect(summary.transactionsAdded == 3)
    #expect(summary.budgetsAdded == 1)
    #expect(summary.ownersAdded == 0, "Bhavik, Saloni and Joint were already there")

    let imported = try #require(fresh.month(for: september))
    #expect(FinanceMonthDocument(month: imported) == exported)
    #expect(approximately(MonthSummary(month: imported).netWorth, MonthSummary(month: month).netWorth, within: 0.01))
}

@MainActor
@Test func importingTheSameMonthTwiceAddsNothing() throws {
    let document = FinanceMonthDocument(
        month: "2026-09",
        metalPrices: .init(gold: 4_500, silver: 52),
        owners: ["Bhavik", "Saloni", "Joint", "Kid"],
        accounts: [.init(category: "cash", institution: "Capital One", name: "Checkings", owner: "Joint", balance: 3_000)],
        cards: [.init(institution: "Chase", name: "Sapphire Preferred", owner: "Bhavik", limit: 41_900, annualFee: 95)],
        metals: [.init(name: "Gold - Bar 1", metal: "gold", grams: 28.35, pricePaidPerOz: 1_600, purchaseValue: 1_600, manualValue: nil, location: "Locker", owner: "Joint")],
        transactions: [
            .init(date: "2026-09-03", cost: 4.35, actualCost: 4.35, merchant: "Park Duluth", category: "Travel", expense: "Parking", breakDown: "N/A", card: "Chase - Sapphire Preferred"),
            .init(date: "2026-09-04", cost: 20, actualCost: 20, merchant: "Deli", category: "Food", expense: "Lunch", breakDown: "", card: "Amex - Blue"),
        ],
        budgets: [.init(category: "Food", limit: 600)]
    )
    let household = makeHousehold()
    let context = try #require(household.managedObjectContext)

    let first = try FinanceMonthExchange.apply(document, to: household)
    try context.save()
    #expect(first.ownersAdded == 1)
    #expect(first.transactionsAdded == 2)
    #expect(first.cardsAdded == 2, "Amex - Blue appears only on a transaction, and is made a card")
    let amex = try #require(household.sortedAccounts.first { $0.name == "Blue" })
    #expect(amex.institution == "Amex")
    #expect(amex.category == .card)

    let second = try FinanceMonthExchange.apply(document, to: household)
    try context.save()
    #expect(second.transactionsAdded == 0)
    #expect(second.transactionsSkipped == 2)
    #expect(second.accountsAdded == 0)
    #expect(second.cardsAdded == 0)
    #expect(second.metalsAdded == 0)
    #expect(second.budgetsAdded == 0)
    #expect(second.ownersAdded == 0)
    #expect(try context.count(for: SharedFinanceTransaction.fetchRequest()) == 2)
    #expect(try context.count(for: SharedFinanceAccount.fetchRequest()) == 3)
    #expect(try context.count(for: SharedFinanceMonth.fetchRequest()) == 1)
    #expect(try context.count(for: SharedFinanceBalance.fetchRequest()) == 1)
    #expect(household.month(for: september)?.balances?.first?.edited == true, "An imported figure is a real one")
}

@MainActor
@Test func importRejectsWhatItCantRead() {
    let household = makeHousehold()
    #expect(throws: FinanceImportError.unsupportedVersion(2)) {
        try FinanceMonthExchange.apply(FinanceMonthDocument(version: 2, month: "2026-09"), to: household)
    }
    #expect(throws: FinanceImportError.badMonth("September")) {
        try FinanceMonthExchange.apply(FinanceMonthDocument(month: "September"), to: household)
    }
    #expect(throws: FinanceImportError.unreadableFile) {
        try FinanceMonthExchange.decode(Data("not json".utf8))
    }
}

@Test func aTrimmedFileStillDecodes() throws {
    let json = #"{ "version": 1, "month": "2026-09", "metals": [ { "name": "Coin", "metal": "silver", "grams": 31.1035 } ], "transactions": [ { "date": "2026-09-01", "cost": 12.5, "merchant": "Shop" } ] }"#
    let document = try FinanceMonthExchange.decode(Data(json.utf8))
    #expect(document.accounts.isEmpty)
    #expect(document.metals.first?.manualValue == nil)
    #expect(document.metals.first?.grams == 31.1035, "Grams arrive as written: no ounce is involved on the way in")
    #expect(document.transactions.first?.actualCost == 12.5, "A missing actual cost is the whole cost")
    #expect(FinanceMonthDocument.fileName(for: "2026-09") == "Finance 2026-09.json")
}

@MainActor
@Test func aDoubleSpacedCardImportsOnce() throws {
    // The real sheet has "Bank of America -  Cash Rewards", two spaces.
    let document = FinanceMonthDocument(
        month: "2026-09",
        cards: [.init(institution: "Bank of America", name: " Cash Rewards", owner: "Bhavik", limit: 7_000, annualFee: 0)],
        transactions: [
            .init(date: "2026-09-05", cost: 18, actualCost: 18, merchant: "Cafe", category: "Food", expense: "", breakDown: "", card: "Bank of America -  Cash Rewards"),
        ]
    )
    let household = makeHousehold()
    let context = try #require(household.managedObjectContext)
    _ = try FinanceMonthExchange.apply(document, to: household)
    try context.save()
    let second = try FinanceMonthExchange.apply(document, to: household)
    try context.save()
    #expect(second.transactionsAdded == 0)
    #expect(second.cardsAdded == 0)
    #expect(try context.count(for: SharedFinanceTransaction.fetchRequest()) == 1)
    #expect(try context.count(for: SharedFinanceAccount.fetchRequest()) == 1)
}

@MainActor
@Test func aFileWithoutPricesOrOwnersKeepsWhatsThere() throws {
    let full = FinanceMonthDocument(
        month: "2026-09",
        metalPrices: .init(gold: 4_500, silver: 52),
        owners: ["Saloni"],
        metals: [.init(name: "Gold - Bar 1", metal: "gold", grams: 100, pricePaidPerOz: 0, purchaseValue: 0, manualValue: nil, location: "Locker", owner: "Saloni")]
    )
    let trimmed = FinanceMonthDocument(
        month: "2026-09",
        metals: [.init(name: "Gold - Bar 1", metal: "gold", grams: 100, pricePaidPerOz: 0, purchaseValue: 0, manualValue: nil, location: "Locker", owner: "")]
    )
    let household = makeHousehold()
    let context = try #require(household.managedObjectContext)
    _ = try FinanceMonthExchange.apply(full, to: household)
    _ = try FinanceMonthExchange.apply(trimmed, to: household)
    try context.save()
    let month = try #require(household.month(for: september))
    #expect(month.goldPricePerOz == 4_500)
    #expect(month.silverPricePerOz == 52)
    #expect(household.sortedMetals.first?.owner?.name == "Saloni")
}
