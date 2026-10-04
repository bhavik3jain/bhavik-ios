import Core
import CoreData
import Foundation
import Testing
@testable import FinanceTracker

/// A household with a card, `July`…`September` finished, and the given
/// spend in one category each month against one budget.
@MainActor
private func spendingHousehold(
    category: String,
    limit: Double?,
    spend: [Double]
) -> (SharedFinanceHousehold, SharedFinanceAccount) {
    let household = ReportDataFixture.household()
    let card = SharedFinanceAccount(institution: "Big Bank", name: "Card", category: .card, household: household)
    let periods = [YearMonth(year: 2026, month: 7), ReportDataFixture.august, ReportDataFixture.september]
    for (period, amount) in zip(periods, spend) {
        let month = ReportDataFixture.month(period, in: household)
        if let limit { month.setBudget(limit, for: category) }
        if amount != 0 {
            ReportDataFixture.charge(household, period, amount, "Shop", category, on: card)
        }
    }
    return (household, card)
}

@MainActor
private func septemberFindings(_ household: SharedFinanceHousehold) throws -> [ReportFinding] {
    try #require(ReportDataFixture.report(.month(ReportDataFixture.september), household)).findings
}

// MARK: - Faithfulness of the plain wording

/// `ReportReview.isFaithful` keeps a model note only if every figure and
/// name of its finding survives, falling back to `plainText`. A finding
/// whose own sentence lacks one would fail its own check.
@Test @MainActor func everyFindingQuotesItsOwnFiguresAndNames() throws {
    let seeded = ReportDataFixture.emptyHousehold()
    let context = try #require(seeded.managedObjectContext)
    FinanceDebugSeed.run(context: context, container: nil, asOf: ReportDataFixture.now)
    let fixture = ReportDataFixture.standard()
    let reports = [
        ReportDataFixture.report(.month(ReportDataFixture.september), seeded),
        ReportDataFixture.report(.year(2026), seeded),
        ReportDataFixture.report(.month(ReportDataFixture.october), seeded),
        ReportDataFixture.report(.month(ReportDataFixture.september), fixture.household),
    ].compactMap(\.self)
    #expect(reports.count == 4)
    for report in reports {
        #expect(!report.findings.isEmpty)
        #expect(Set(report.findings.map(\.id)).count == report.findings.count, "Ids are unique in \(report.scope)")
        for finding in report.findings {
            for figure in finding.figures {
                #expect(finding.plainText.contains(figure), "\(finding.id): \"\(figure)\" missing from \"\(finding.plainText)\"")
            }
            for name in finding.names {
                #expect(finding.plainText.contains(name), "\(finding.id): \"\(name)\" missing from \"\(finding.plainText)\"")
            }
        }
    }
}

// MARK: - Budgets

@Test @MainActor func overBudgetTwoMonthsRunningIsWorthFixing() throws {
    let (household, _) = spendingHousehold(category: "Subscriptions", limit: 80, spend: [70, 91, 96])
    let findings = try septemberFindings(household)
    let over = try #require(findings.first { $0.kind == .overBudget })
    #expect(over.plainText == "Subscriptions: $96 of a $80 budget, $16 over.")
    #expect(over.tone == .watch)
    #expect(over.fix == .adjustBudget(category: "Subscriptions"))
    let repeatOver = try #require(findings.first { $0.kind == .overBudgetRepeat })
    #expect(repeatOver.plainText == "Subscriptions has been over budget two months running: $96 in September and $91 in August, against $80.")
    #expect(repeatOver.isWorthFixing && repeatOver.severity == .note)
    let summary = try #require(findings.first { $0.kind == .budgetsSummary })
    #expect(summary.plainText == "Spending ran $16 over budget in 1 of 1 category: Subscriptions.")
}

@Test @MainActor func aBudgetUnderTwoMonthsRunningWentWell() throws {
    let (household, _) = spendingHousehold(category: "Groceries", limit: 700, spend: [800, 640, 612])
    let findings = try septemberFindings(household)
    let streak = try #require(findings.first { $0.kind == .underBudgetStreak })
    #expect(streak.plainText == "Groceries came in at $612 of $700, under budget for the second month running.")
    #expect(streak.tone == .wentWell)
    let summary = try #require(findings.first { $0.kind == .budgetsSummary })
    #expect(summary.tone == .wentWell)
    #expect(summary.plainText == "All 1 budget came in under: $612 spent of $700.")
    #expect(!findings.contains { $0.kind == .overBudget })
}

// MARK: - Spikes

@Test @MainActor func aCategoryWellAboveItsAverageIsASpike() throws {
    let (household, _) = spendingHousehold(category: "Food", limit: nil, spend: [200, 200, 300])
    let spike = try #require(try septemberFindings(household).first { $0.kind == .categorySpike })
    #expect(spike.plainText == "Food came to $300, 50% above its 3-month average of $200.")
    #expect(spike.fix == .showCharges(category: "Food", merchant: nil))
}

@Test @MainActor func aSmallRiseIsNoSpike() throws {
    // 15% over the average: under the 20% threshold.
    let (household, _) = spendingHousehold(category: "Food", limit: nil, spend: [200, 200, 230])
    #expect(try !septemberFindings(household).contains { $0.kind == .categorySpike })
}

@Test @MainActor func aCategoryWithNoneBeforeIsNew() throws {
    let (household, card) = spendingHousehold(category: "Food", limit: nil, spend: [200, 200, 200])
    ReportDataFixture.charge(household, ReportDataFixture.september, 310, "Airline", "Travel", on: card)
    let spike = try #require(try septemberFindings(household).first { $0.kind == .categorySpike })
    #expect(spike.plainText == "Travel came to $310, with none in July or August.")
}

@Test @MainActor func anOverBudgetCategoryIsNotAlsoASpike() throws {
    let (household, _) = spendingHousehold(category: "Food", limit: 250, spend: [200, 200, 300])
    let findings = try septemberFindings(household)
    #expect(findings.contains { $0.kind == .overBudget })
    #expect(!findings.contains { $0.kind == .categorySpike }, "One finding per category, not two")
}

// MARK: - Stale balances

@Test @MainActor func staleBalancesNameWhoseWhenTwoAccountsShareAName() throws {
    let household = ReportDataFixture.household()
    let bhavik = ReportDataFixture.owner("Bhavik", in: household)
    let saloni = ReportDataFixture.owner("Saloni", in: household)
    let his = SharedFinanceAccount(institution: "Online Brokerage", name: "Taxable", category: .investments, household: household, owner: bhavik)
    let hers = SharedFinanceAccount(institution: "Online Brokerage", name: "Taxable", category: .investments, household: household, owner: saloni)
    let august = ReportDataFixture.month(ReportDataFixture.august, in: household)
    let september = ReportDataFixture.month(ReportDataFixture.september, in: household)
    let october = ReportDataFixture.month(ReportDataFixture.october, in: household, closed: false)
    _ = SharedFinanceBalance(account: his, month: august, amount: 61_500, edited: true)
    _ = SharedFinanceBalance(account: his, month: september, amount: 62_700, edited: true)
    _ = SharedFinanceBalance(account: hers, month: august, amount: 38_900, edited: true)
    _ = SharedFinanceBalance(account: hers, month: september, amount: 38_900, edited: true)
    _ = SharedFinanceBalance(account: his, month: october, amount: 0, edited: false)
    _ = SharedFinanceBalance(account: hers, month: october, amount: 0, edited: false)

    let stale = try #require(try septemberFindings(household).first { $0.kind == .staleBalances })
    #expect(stale.plainText == "Online Brokerage - Taxable, Saloni's ($38,900) matches August to the dollar. Look them up when you fill in October.")
    #expect(stale.fix == .updateBalances(ReportDataFixture.october), "Fixed in the month being filled in")
    #expect(stale.detail.hasSuffix("If it moved, net worth is off by that much."))
}

// MARK: - Debt, ordering, words

@Test @MainActor func aLoanPaidDownWentWell() throws {
    let household = ReportDataFixture.household()
    let loan = SharedFinanceAccount(institution: "Auto Lender", name: "Car loan", category: .loan, household: household)
    for (period, amount) in [(ReportDataFixture.august, 14_800.0), (ReportDataFixture.september, 14_380)] {
        let month = ReportDataFixture.month(period, in: household)
        _ = SharedFinanceBalance(account: loan, month: month, amount: amount, edited: true)
    }
    let findings = try septemberFindings(household)
    let debt = try #require(findings.first { $0.kind == .debtPaidDown })
    #expect(debt.plainText == "Auto Lender - Car loan is down $420, to $14,380.")
    let netWorth = try #require(findings.first { $0.kind == .netWorthMove })
    #expect(netWorth.plainText == "Net worth rose $420 since August, to \(FinanceFormat.money(-14_380)).", "No percent of a negative net worth")
    #expect(netWorth.tone == .info)
}

@Test @MainActor func worthFixingPutsWhatDistortsTheHeadlineFirst() throws {
    let fixture = ReportDataFixture.standard()
    let data = try #require(ReportDataFixture.report(.month(ReportDataFixture.september), fixture.household))
    let severities = data.worthFixing.map(\.severity)
    #expect(severities == severities.sorted(), "Distorts, then fragile, then notes")
    #expect(data.worthFixing.first?.kind == .staleBalances)
    #expect(data.worthFixing.contains { $0.kind == .typedMetalValue && $0.severity == .fragile })
    #expect(data.worthFixing.allSatisfy { $0.isWorthFixing })
    let counts = data.toneCounts
    #expect(counts.total == data.findings.count { $0.tone != .info })
    #expect(!counts.label.isEmpty)
}

@Test func streaksReadAsWords() {
    #expect(MonthCheck.ordinalCount(2) == "two")
    #expect(MonthCheck.ordinalCount(14) == "14")
    #expect(MonthCheck.ordinalWord(2) == "second")
    #expect(MonthCheck.ordinalWord(12) == "twelfth")
    #expect(MonthCheck.ordinalWord(13) == "13th")
    #expect(MonthCheck.ordinalWord(22) == "22nd")
    #expect(FinanceFormat.percent(0.015) == "1.5%")
    #expect(FinanceFormat.percent(0.5) == "50%")
    #expect(FinanceFormat.signedPercent(-0.08) == "−8%")
    #expect(FinanceFormat.change(0.2) == "no change")
}
