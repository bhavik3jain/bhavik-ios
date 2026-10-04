import Core
import CoreData
import Foundation
import Testing
@testable import FinanceTracker

/// The seeded household's report: September, with October open — every
/// check fires on it (see `theDebugSeedSetsOffEveryCheck`).
@MainActor
func seededBriefReport(_ scope: ReportScope? = nil) throws -> FinanceReportData {
    let household = ReportDataFixture.emptyHousehold()
    let context = try #require(household.managedObjectContext)
    FinanceDebugSeed.run(context: context, container: nil, asOf: ReportDataFixture.now)
    let seeded = try #require(try context.fetch(SharedFinanceHousehold.fetchRequest()).first { !$0.isEmpty })
    let resolved = try #require(scope ?? FinanceReportData.defaultScope(for: seeded, live: nil))
    return try #require(ReportDataFixture.report(resolved, seeded))
}

/// A brief made by hand, for tests that need exact facts.
func handBrief(facts: [ReportBrief.Fact], figures: [String] = [], owner: String = "Everyone") -> ReportBrief {
    ReportBrief(
        scope: .month(YearMonth(year: 2026, month: 9)),
        ownerLabel: owner,
        header: "Household finances: September 2026, everyone's figures, compared with August.",
        figures: figures,
        facts: facts,
        nextName: "October"
    )
}

func briefFact(_ number: Int, _ id: String, _ group: ReportReview.Group?, _ text: String, figures: [String] = [], names: [String] = [], kind: ReportFinding.Kind = .overBudget) -> ReportBrief.Fact {
    ReportBrief.Fact(number: number, findingID: id, kind: kind, group: group, text: text, figures: figures, names: names)
}

// MARK: - Numbering and ranking

@Test @MainActor func factsAreNumberedFromOneWithTheHeadlineFirstAndCapped() throws {
    let data = try seededBriefReport()
    #expect(data.findings.count > ReportBrief.factLimit, "The seed finds more than the brief can hold, so the cap is exercised")
    let brief = ReportBrief(data: data)
    #expect(brief.facts.count == ReportBrief.factLimit)
    #expect(brief.facts.map(\.number) == Array(1...ReportBrief.factLimit))
    #expect(brief.facts.first?.findingID == "netWorthMove", "The net worth's move always heads the brief")
    let firstListed = try #require(brief.facts.firstIndex { !$0.isHeadline })
    #expect(brief.facts[firstListed...].allSatisfy { !$0.isHeadline }, "Headline facts come before every listed one")
    #expect(Set(brief.facts.map(\.findingID)).count == brief.facts.count, "No finding twice")
    for item in brief.facts {
        let finding = try #require(data.findings.first { $0.id == item.findingID })
        #expect(item.text == finding.plainText)
        #expect(item.figures == finding.figures)
        #expect(item.group == ReportReview.Group(finding: finding))
    }
}

@Test @MainActor func aTightCapStillKeepsEveryGroup() throws {
    let data = try seededBriefReport()
    let brief = ReportBrief(data: data, factLimit: 8)
    #expect(brief.facts.count == 8)
    for group in ReportReview.Group.allCases {
        #expect(brief.facts.contains { $0.group == group }, "\(group) kept under a cap of 8")
    }
    let kept = Set(brief.facts.map(\.findingID))
    let leftOut = data.findings.filter { !kept.contains($0.id) }
    #expect(!leftOut.isEmpty)
}

@Test @MainActor func theHeaderNamesTheMonthWhoseAndTheComparison() throws {
    let data = try seededBriefReport()
    let brief = ReportBrief(data: data)
    #expect(brief.header.contains("September 2026"))
    #expect(brief.header.contains("everyone's figures"))
    #expect(brief.header.contains("compared with August"))
    #expect(brief.nextName == "October")
    #expect(ReportBrief(data: try seededBriefReport(.year(2026))).nextName == "2027")
}

// MARK: - The prompt

@Test @MainActor func thePromptLosesFiguresBeforeFactsAndFactsFromTheEnd() throws {
    let data = try seededBriefReport()
    let brief = ReportBrief(data: data)
    #expect(!brief.figures.isEmpty)

    let everything = brief.prompt(maxTokens: 100_000, includeFigures: true)
    #expect(everything.contains("Figures:"))
    #expect(everything.contains("\(brief.facts.count). ["))

    let review = brief.prompt(maxTokens: 100_000)
    #expect(!review.contains("Figures:"), "The review is never shown the figures")
    #expect(review == brief.fullPrompt)

    // Just under the whole thing: some figures go, every fact stays.
    let tight = brief.prompt(maxTokens: ReportBrief.estimatedTokens(everything) - 20, includeFigures: true)
    #expect(tight.contains("\(brief.facts.count). ["))
    #expect(tight.count < everything.count)

    // Far too small: one fact, never none.
    let tiny = brief.prompt(maxTokens: 10, includeFigures: true)
    #expect(!tiny.contains("Figures:"))
    #expect(tiny.contains("1. [headline]"))
    #expect(!tiny.contains("2. ["))
}

@Test func factsCarryTheirGroupLabel() {
    let brief = handBrief(facts: [
        briefFact(1, "netWorthMove", nil, "Net worth rose $5,565 since August, to $387,675 (1.5%).", kind: .netWorthMove),
        briefFact(2, "debt", .wentWell, "Car loan is down $420, to $14,380."),
        briefFact(3, "food", .watch, "Food: $684 of a $600 budget, $84 over."),
        briefFact(4, "stale", .tryNext, "HSA ($4,750) matches August to the dollar."),
    ])
    let prompt = brief.fullPrompt
    #expect(prompt.contains("1. [headline] Net worth rose"))
    #expect(prompt.contains("2. [went well] Car loan"))
    #expect(prompt.contains("3. [to watch] Food"))
    #expect(prompt.contains("4. [to try in October] HSA"))
}

@Test func theBudgetFallsBackWhenTheContextSizeIsImplausible() {
    #expect(ReportBrief.promptBudget(contextSize: 4_096) == 4_096 - ReportBrief.reservedOutputTokens - ReportBrief.estimatedOverheadTokens)
    #expect(ReportBrief.promptBudget(contextSize: 0) == ReportBrief.promptBudget(contextSize: 4_096), "The iOS 27 simulator reports 0")
    #expect(ReportBrief.promptBudget(contextSize: 8_192, overhead: 600) == 8_192 - 1_000 - 600)
    #expect(ReportBrief.promptBudget(contextSize: 2_048, overhead: 2_000) == 64, "Never below 64")
}

// MARK: - Fingerprint and cache key

@Test func theFingerprintChangesWhenAFigureDoes() {
    let facts = [briefFact(1, "food", .watch, "Food: $684 of a $600 budget, $84 over.", figures: ["$684", "$600", "$84"], names: ["Food"])]
    let same = handBrief(facts: facts)
    #expect(same.fingerprint == handBrief(facts: facts).fingerprint)
    #expect(ReportReviewCache.key(for: same) == ReportReviewCache.key(for: handBrief(facts: facts)))

    let changed = handBrief(facts: [briefFact(1, "food", .watch, "Food: $690 of a $600 budget, $90 over.", figures: ["$690", "$600", "$90"], names: ["Food"])])
    #expect(changed.fingerprint != same.fingerprint)
    #expect(ReportReviewCache.key(for: changed) != ReportReviewCache.key(for: same))

    let someoneElse = handBrief(facts: facts, owner: "Saloni")
    #expect(someoneElse.fingerprint != same.fingerprint, "Whose report is part of it")
    #expect(ReportReviewCache.key(for: someoneElse).contains("Saloni"))
}

@Test @MainActor func aSeededBriefIsTheSameEveryTime() throws {
    // Two stores, so finding ids that carry an object URI differ; what the
    // model reads, and so the cache's fingerprint, must not.
    let first = ReportBrief(data: try seededBriefReport())
    let second = ReportBrief(data: try seededBriefReport())
    #expect(first.fullPrompt == second.fullPrompt)
    #expect(first.figures == second.figures)
    #expect(first.facts.map(\.text) == second.facts.map(\.text))
    #expect(first.fingerprint == second.fingerprint)
}

@Test @MainActor func aCachedReviewSurvivesFindingIDsChanging() async throws {
    // The same figures in another store: ids built from object URIs differ,
    // as a temporary id does from the permanent one after the first save.
    let cache = ReportReviewCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ReportBriefTests-\(UUID().uuidString)", isDirectory: true))
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let firstData = try seededBriefReport()
    let first = ReportReviewModel(data: firstData, cache: cache)
    await first.start(advisor: StubFinanceAdvisor(), enabled: true)
    #expect(first.isReady)

    let secondData = try seededBriefReport()
    #expect(Set(firstData.findings.map(\.id)) != Set(secondData.findings.map(\.id)), "The fixture should exercise an id change")
    let second = ReportReviewModel(data: secondData, cache: cache)
    await second.start(advisor: StubFinanceAdvisor(failure: .unavailable(.notReady)), enabled: true)
    #expect(second.isReady)
    #expect(second.review.allItems.map(\.text) == first.review.allItems.map(\.text))
}

// MARK: - Numbers

@Test func numbersAreReadWithoutGroupingSignsOrSymbols() {
    #expect(ReportNumbers.numbers(in: "Net worth rose $5,565 (1.5%), −$310 on cards; $9.99.") == ["5565", "1.5", "310", "9.99"])
    #expect(ReportNumbers.numbers(in: "Food: $684, of a $600 budget") == ["684", "600"], "A comma before a space ends the number")
    #expect(ReportNumbers.numbers(in: "a 3-month average") == ["3"])
    #expect(ReportNumbers.numbers(in: "no numbers here").isEmpty)
    // Streaming: an answer that stops mid-number isn't read as a wrong one.
    #expect(ReportNumbers.numbers(in: "Net worth rose $5,5", ignoringTrailing: true).isEmpty)
    #expect(ReportNumbers.numbers(in: "Net worth rose $5,", ignoringTrailing: true).isEmpty)
    #expect(ReportNumbers.numbers(in: "up $84 to $6", ignoringTrailing: true) == ["84"])
}
