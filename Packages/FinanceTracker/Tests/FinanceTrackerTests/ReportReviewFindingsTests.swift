import Core
import CoreData
import Foundation
import Testing
@testable import FinanceTracker

// The defects a review of the report found, one test each: an open month's
// untyped zeros read as real, recurring charges guessed from a category
// alone, notes that reversed their fact, card use with no-limit cards,
// no-budget lines with another person's charges, and last month's limit.

// MARK: - A month still being filled in

@Test @MainActor func anOpenMonthsUntypedBalancesAreNotReadAsReal() throws {
    let fixture = ReportDataFixture.standard()
    let october = try #require(MonthRollover.startMonth(after: fixture.september))
    october.setBalance(3_300, for: fixture.checking)
    let data = try #require(ReportDataFixture.report(.month(ReportDataFixture.october), fixture.household))
    #expect(data.header.isPartial)

    let kinds = Set(data.findings.map(\.kind))
    #expect(!kinds.contains(.debtPaidDown), "The loan's untyped zero isn't the loan paid off")
    #expect(!kinds.contains(.assetFell), "Retirement at an untyped zero didn't fall")
    #expect(!kinds.contains(.staleBalances))
    #expect(kinds.contains(.openMonthUnfinished))
    let netWorth = try #require(data.findings.first { $0.kind == .netWorthMove })
    #expect(netWorth.plainText.contains("so far"), "\(netWorth.plainText)")
    #expect(!netWorth.plainText.contains("fell"))
    let loans = try #require(data.moved.first { $0.source == .loans })
    #expect(loans.name == "Car loan not filled in yet")
    let loanRow = try #require(data.accountGroups.first { $0.category == .loan }?.rows.first)
    #expect(!loanRow.isFilledIn)
    let checking = try #require(data.accountGroups.flatMap(\.rows).first { $0.name == "First Bank - Checking" })
    #expect(checking.isFilledIn)
}

@Test @MainActor func aYearOfOnlyAnOpenJanuaryHasNoFalseFall() throws {
    let household = ReportDataFixture.household()
    let savings = SharedFinanceAccount(institution: "Bank", name: "Savings", category: .cash, household: household)
    let loan = SharedFinanceAccount(institution: "Lender", name: "Loan", category: .loan, household: household)
    let december = ReportDataFixture.month(YearMonth(year: 2025, month: 12), in: household)
    _ = SharedFinanceBalance(account: savings, month: december, amount: 10_000, edited: true)
    _ = SharedFinanceBalance(account: loan, month: december, amount: 5_000, edited: true)
    _ = try #require(MonthRollover.startMonth(after: december))

    let data = try #require(ReportDataFixture.report(.year(2026), household))
    let kinds = Set(data.findings.map(\.kind))
    #expect(!kinds.contains(.yearNetWorth))
    #expect(!kinds.contains(.yearWorstMonth))
    #expect(!kinds.contains(.yearDebtPaidDown))
    #expect(kinds.contains(.openMonthUnfinished))
    #expect(data.year?.worstMonth == nil)
}

// MARK: - Recurring charges

@MainActor
private func recurringHousehold() -> (SharedFinanceHousehold, SharedFinanceAccount) {
    let household = ReportDataFixture.household()
    let card = SharedFinanceAccount(institution: "Big Bank", name: "Card", category: .card, household: household)
    return (household, card)
}

@Test @MainActor func theFirstMonthOfChargesHasNoNewSubscriptions() throws {
    let (household, card) = recurringHousehold()
    _ = ReportDataFixture.month(ReportDataFixture.september, in: household)
    ReportDataFixture.charge(household, ReportDataFixture.september, 9.99, "Music App", "Subscriptions", on: card)
    ReportDataFixture.charge(household, ReportDataFixture.september, 40, "Grocer", "Food", on: card)
    let data = try #require(ReportDataFixture.report(.month(ReportDataFixture.september), household))
    #expect(data.spending.recurring.isEmpty, "August had nothing logged at all, so nothing is new since it")
    #expect(!data.findings.contains { $0.kind == .newRecurring })
}

@Test @MainActor func aYearlySubscriptionIsNotAMonthlyOne() throws {
    let (household, card) = recurringHousehold()
    let periods = [YearMonth(year: 2026, month: 7), ReportDataFixture.august, ReportDataFixture.september]
    for period in periods {
        _ = ReportDataFixture.month(period, in: household)
        ReportDataFixture.charge(household, period, day: 3, 59.99, "Gym", "Health", on: card)
    }
    ReportDataFixture.charge(household, YearMonth(year: 2025, month: 9), 139, "Cloud Plan", "Subscriptions", on: card)
    ReportDataFixture.charge(household, ReportDataFixture.september, 139, "Cloud Plan", "Subscriptions", on: card)
    // Charged three months ago and now, but not last month: not monthly.
    ReportDataFixture.charge(household, YearMonth(year: 2026, month: 6), 30, "Quarterly Box", "Subscriptions", on: card)
    ReportDataFixture.charge(household, ReportDataFixture.september, 30, "Quarterly Box", "Subscriptions", on: card)

    let data = try #require(ReportDataFixture.report(.month(ReportDataFixture.september), household))
    #expect(data.spending.recurring.map(\.merchant) == ["Gym"])
    #expect(!data.findings.contains { $0.kind == .newRecurring })
}

@Test @MainActor func theRecurringTotalOpensItsCharges() throws {
    let fixture = ReportDataFixture.standard()
    let data = try #require(ReportDataFixture.report(.month(ReportDataFixture.september), fixture.household))
    let total = try #require(data.findings.first { $0.kind == .recurringTotal })
    let merchants = data.spending.recurring.map(\.merchant)
    #expect(Set(merchants) == ["Streaming Co", "Music App"])
    #expect(total.fix == .showRecurring(merchants: merchants))
    #expect(total.fix?.title == "Review Recurring Charges")

    let route = try #require(ReportFixRoute.resolve(
        .showRecurring(merchants: merchants), in: fixture.household,
        period: ReportDataFixture.september, spendingPeriods: [ReportDataFixture.september]
    ))
    guard case .charges(let query) = route else {
        Issue.record("Expected charges, got \(route)")
        return
    }
    let charges = query.transactions(in: Array(fixture.household.transactions ?? []))
    #expect(Set(charges.map(\.merchant)) == ["Streaming Co", "Music App"])
    #expect(charges.count == 2, "September's only")
    #expect(query.title == "Recurring Charges")
}

// MARK: - Faithfulness keeps the direction

@Test @MainActor func aNoteThatReversesItsFactIsDropped() throws {
    let fixture = ReportDataFixture.standard()
    let data = try #require(ReportDataFixture.report(.month(ReportDataFixture.september), fixture.household))
    let brief = ReportBrief(data: data)
    let food = try #require(brief.facts.first { $0.findingID.hasPrefix("overBudget:") })
    #expect(food.text == "Food: $350 of a $300 budget, $50 over.")
    #expect(ReportReview.isFaithful("Food ran $50 over its $300 budget, at $350.", to: food, in: brief))
    #expect(!ReportReview.isFaithful("Food came in $50 under its $300 budget, at $350.", to: food, in: brief))

    let netWorth = try #require(brief.facts.first { $0.kind == .netWorthMove })
    #expect(netWorth.text.contains("rose"))
    #expect(ReportReview.isFaithfulHeadline(netWorth.text, brief: brief, partial: false))
    let reversed = netWorth.text.replacingOccurrences(of: "rose", with: "fell")
    #expect(!ReportReview.isFaithfulHeadline(reversed, brief: brief, partial: false))
}

@Test func namesAndFiguresMatchWholeWords() {
    #expect(!ReportReview.containsWhole("card spend went up", "car"))
    #expect(ReportReview.containsWhole("the car loan is down", "car"))
    #expect(!ReportReview.containsWhole("spent $840 in all", "$84"))
    #expect(ReportReview.containsWhole("spent $84.", "$84"))
    #expect(ReportReview.keepsDirection("Net worth climbed", of: "Net worth rose $5."))
    #expect(!ReportReview.keepsDirection("Net worth dropped", of: "Net worth rose $5."))
    #expect(ReportReview.keepsDirection("Anything at all", of: "Balances match August to the dollar."))
}

// MARK: - Cards, owners and limits

@Test @MainActor func cardUseLeavesOutCardsWithNoLimit() throws {
    let fixture = ReportDataFixture.standard()
    let store = SharedFinanceAccount(institution: "Store", name: "Store Card", category: .card, household: fixture.household)
    ReportDataFixture.charge(fixture.household, ReportDataFixture.september, 4_000, "Furniture", "Home", on: store)
    let data = try #require(ReportDataFixture.report(.month(ReportDataFixture.september), fixture.household))
    let limited = data.cards.cards.filter { $0.limit > 0 }.reduce(0) { $0 + $1.spend }
    #expect(abs(data.cards.limitedSpend - limited) < 0.001)
    #expect(data.cards.totalSpend > data.cards.limitedSpend + 3_999)
    let use = try #require(data.cards.use)
    #expect(abs(use - limited / 15_000) < 0.0001, "The no-limit card's $4,000 isn't counted against the others' limits")
    #expect(!data.findings.contains { $0.kind == .highCardUse })
}

@Test @MainActor func oneOwnersNoBudgetLinesAreTheirOwnCharges() throws {
    let fixture = ReportDataFixture.standard()
    let bhavik = try #require(ReportDataFixture.owner("Bhavik", in: fixture.household))
    let saloni = try #require(ReportDataFixture.owner("Saloni", in: fixture.household))
    let september = ReportScope.month(ReportDataFixture.september)
    let hers = try #require(ReportDataFixture.report(september, fixture.household, filter: .owner(saloni)))
    let his = try #require(ReportDataFixture.report(september, fixture.household, filter: .owner(bhavik)))
    #expect(hers.spending.unbudgeted.map(\.category) == ["Clothes"], "Clothes went on her card")
    #expect(his.spending.unbudgeted.map(\.category) == ["Car"], "The gas went on his")
    #expect(his.spending.budgetsAreHouseholdWide)
}

@Test @MainActor func overBudgetTwoMonthsRunningNamesEachMonthsLimit() throws {
    let household = ReportDataFixture.household()
    let card = SharedFinanceAccount(institution: "Big Bank", name: "Card", category: .card, household: household)
    let periods = [YearMonth(year: 2026, month: 7), ReportDataFixture.august, ReportDataFixture.september]
    for (period, (limit, spend)) in zip(periods, [(80.0, 70.0), (60, 91), (80, 96)]) {
        let month = ReportDataFixture.month(period, in: household)
        month.setBudget(limit, for: "Subscriptions")
        ReportDataFixture.charge(household, period, spend, "Shop", "Subscriptions", on: card)
    }
    let data = try #require(ReportDataFixture.report(.month(ReportDataFixture.september), household))
    let repeatOver = try #require(data.findings.first { $0.kind == .overBudgetRepeat })
    #expect(repeatOver.plainText == "Subscriptions has been over budget two months running: $96 of $80 in September and $91 of $60 in August.")
    for figure in repeatOver.figures { #expect(repeatOver.plainText.contains(figure)) }
}
