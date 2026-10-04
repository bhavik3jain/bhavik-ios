import Core
import CoreData
import Foundation
import Testing
@testable import FinanceTracker

// Where the review's one-tap fixes lead — the logic behind the buttons, kept
// out of the (untested) views.

@Test @MainActor func aBudgetFixEditsTheOpenMonthsBudget() throws {
    let household = ReportDataFixture.household()
    _ = ReportDataFixture.month(ReportDataFixture.september, in: household)
    let october = ReportDataFixture.month(ReportDataFixture.october, in: household, closed: false)
    let route = ReportFixRoute.resolve(
        .adjustBudget(category: "Food"),
        in: household,
        period: ReportDataFixture.september,
        spendingPeriods: [ReportDataFixture.september]
    )
    // September's over-run is fixed in October's budget: "Try in October".
    #expect(route == .budget(october, category: "Food"))
}

@Test @MainActor func aBudgetFixWithNoOpenMonthEditsTheReportsMonth() throws {
    let household = ReportDataFixture.household()
    _ = ReportDataFixture.month(ReportDataFixture.august, in: household)
    let september = ReportDataFixture.month(ReportDataFixture.september, in: household)
    let route = ReportFixRoute.resolve(
        .adjustBudget(category: "Food"),
        in: household,
        period: ReportDataFixture.september,
        spendingPeriods: [ReportDataFixture.september]
    )
    #expect(route == .budget(september, category: "Food"))
}

@Test @MainActor func aMonthFixOpensThatMonthAndNothingWhenItsGone() throws {
    let household = ReportDataFixture.household()
    let october = ReportDataFixture.month(ReportDataFixture.october, in: household, closed: false)
    #expect(ReportFixRoute.resolve(.updateBalances(ReportDataFixture.october), in: household, period: ReportDataFixture.september, spendingPeriods: []) == .month(october))
    #expect(ReportFixRoute.resolve(.openMonth(ReportDataFixture.october), in: household, period: ReportDataFixture.september, spendingPeriods: []) == .month(october))
    // A month deleted since the report was built: the button does nothing
    // rather than open an editor on nothing.
    #expect(ReportFixRoute.resolve(.updateBalances(ReportDataFixture.august), in: household, period: ReportDataFixture.september, spendingPeriods: []) == nil)
    #expect(ReportFixRoute.resolve(.openHoldings, in: household, period: ReportDataFixture.september, spendingPeriods: []) == .holdings)
}

@Test @MainActor func categoryChargesAreTheReportsMonthsComparedLikeBudgets() throws {
    let household = ReportDataFixture.household()
    let card = SharedFinanceAccount(institution: "Big Bank", name: "Card", category: .card, household: household)
    let dinner = ReportDataFixture.charge(household, ReportDataFixture.september, day: 12, 80, "Bistro", "food ", on: card)
    let lunch = ReportDataFixture.charge(household, ReportDataFixture.september, day: 20, 20, "Cafe", "Food", on: card)
    ReportDataFixture.charge(household, ReportDataFixture.august, 50, "Bistro", "Food", on: card)
    ReportDataFixture.charge(household, ReportDataFixture.september, 30, "Grocer", "Groceries", on: card)
    let untyped = ReportDataFixture.charge(household, ReportDataFixture.september, 5, "Kiosk", "", on: card)

    let route = ReportFixRoute.resolve(
        .showCharges(category: "Food", merchant: nil),
        in: household,
        period: ReportDataFixture.september,
        spendingPeriods: [ReportDataFixture.september]
    )
    guard case .charges(let query) = route else {
        Issue.record("Expected charges, got \(String(describing: route))")
        return
    }
    let all = Array(household.transactions ?? [])
    #expect(query.title == "Food")
    // Newest first; "food " is Food; August and Groceries left out.
    #expect(query.transactions(in: all) == [lunch, dinner])

    let other = ReportChargesQuery(category: SpendingSummary.uncategorised, merchant: nil, periods: [ReportDataFixture.september])
    #expect(other.transactions(in: all) == [untyped])
}

@Test @MainActor func merchantChargesLookBackHalfAYear() throws {
    let household = ReportDataFixture.household()
    let card = SharedFinanceAccount(institution: "Big Bank", name: "Card", category: .card, household: household)
    let september = ReportDataFixture.charge(household, ReportDataFixture.september, 9.99, "Music App ", "Subscriptions", on: card)
    let april = ReportDataFixture.charge(household, YearMonth(year: 2026, month: 4), 9.99, "music app", "Subscriptions", on: card)
    ReportDataFixture.charge(household, YearMonth(year: 2026, month: 3), 9.99, "Music App", "Subscriptions", on: card)
    ReportDataFixture.charge(household, ReportDataFixture.september, 12, "Video App", "Subscriptions", on: card)

    let route = ReportFixRoute.resolve(
        .showCharges(category: nil, merchant: "Music App"),
        in: household,
        period: ReportDataFixture.september,
        spendingPeriods: [ReportDataFixture.september]
    )
    guard case .charges(let query) = route else {
        Issue.record("Expected charges, got \(String(describing: route))")
        return
    }
    #expect(query.periods.count == FinanceReportBuilder.recurringLookbackMonths)
    #expect(query.periods.min() == YearMonth(year: 2026, month: 4))
    #expect(query.periods.max() == ReportDataFixture.september)
    #expect(query.transactions(in: Array(household.transactions ?? [])) == [september, april])
}

@Test @MainActor func aReportOpensOnTheDefaultOwnerOnlyWhileTheyreInTheHousehold() throws {
    let household = ReportDataFixture.household()
    let owners = household.sortedOwners
    #expect(OwnerFilter.reportDefaultOwnerName(preferred: "Saloni", owners: owners) == "Saloni")
    #expect(OwnerFilter.reportDefaultOwnerName(preferred: "Someone Else", owners: owners) == nil)
    #expect(OwnerFilter.reportDefaultOwnerName(preferred: nil, owners: owners) == nil)
    let saloni = try #require(ReportDataFixture.owner("Saloni", in: household))
    #expect(OwnerFilter.owner(saloni).reportOwnerName == "Saloni")
    #expect(OwnerFilter.all.reportOwnerName == nil)
}
