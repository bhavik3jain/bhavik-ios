import Core
import CoreData
import Foundation
import Testing
@testable import FinanceTracker

// MARK: - A hand-made month

/// Four findings shaped like the seeded September's, and the brief built
/// from them, so a test can write exact notes against exact facts.
private enum Sample {
    static let netWorth = ReportFinding(
        id: "netWorthMove", kind: .netWorthMove, tone: .info,
        title: "Net worth rose $5,565",
        plainText: "Net worth rose $5,565 since August, to $387,675 (1.5%).",
        figures: ["$5,565", "$387,675", "1.5%"], names: ["August"], weight: MonthCheck.headlineWeight
    )
    static let loan = ReportFinding(
        id: "debtPaidDown:loan", kind: .debtPaidDown, tone: .wentWell,
        title: "Car loan down $420",
        plainText: "Car loan is down $420, to $14,380.",
        figures: ["$420", "$14,380"], names: ["Car loan"], weight: 420
    )
    static let food = ReportFinding(
        id: "overBudget:food", kind: .overBudget, tone: .watch,
        title: "Food $84 over",
        plainText: "Food: $684 of a $600 budget, $84 over.",
        figures: ["$684", "$600", "$84"], names: ["Food"],
        fix: .adjustBudget(category: "Food"), weight: 168
    )
    static let stale = ReportFinding(
        id: "staleBalances", kind: .staleBalances, tone: .tryNext,
        severity: .distorts, isWorthFixing: true,
        title: "1 balance matches August to the dollar",
        plainText: "Benefits Co - HSA ($4,750) matches August to the dollar. Look it up when you fill in October.",
        figures: ["$4,750"], names: ["Benefits Co - HSA", "August"],
        fix: .updateBalances(YearMonth(year: 2026, month: 10)), weight: 2_047
    )
    static let groceries = ReportFinding(
        id: "underBudgetStreak:groceries", kind: .underBudgetStreak, tone: .wentWell,
        title: "Groceries under budget again",
        plainText: "Groceries came in at $612 of $700, under budget for the second month running.",
        figures: ["$612", "$700"], names: ["Groceries"], weight: 138
    )

    static let findings = [netWorth, loan, food, stale, groceries]
    static let scope = ReportScope.month(YearMonth(year: 2026, month: 9))

    static var brief: ReportBrief {
        let facts = ReportBrief.rank(findings, limit: ReportBrief.factLimit).enumerated().map { offset, finding in
            ReportBrief.Fact(
                number: offset + 1, findingID: finding.id, kind: finding.kind,
                group: ReportReview.Group(finding: finding), text: finding.plainText,
                figures: finding.figures, names: finding.names
            )
        }
        return handBrief(facts: facts, figures: ["Spent $3,100 in 42 transactions."])
    }

    static func number(of finding: ReportFinding) -> Int {
        brief.fact(findingID: finding.id)!.number
    }

    static func note(_ finding: ReportFinding, _ message: String) -> ReportReviewDraft.Note {
        ReportReviewDraft.Note(fact: number(of: finding), message: message)
    }

    static func review(headline: String? = nil, _ notes: [ReportReviewDraft.Note], complete: Bool = true) -> ReportReview {
        ReportReview(findings: findings, scope: scope, brief: brief, draft: ReportReviewDraft(headline: headline, notes: notes, isComplete: complete))
    }
}

private func isFaithful(_ message: String, about finding: ReportFinding) throws -> Bool {
    let brief = Sample.brief
    let fact = try #require(brief.fact(findingID: finding.id))
    return ReportReview.isFaithful(message, to: fact, in: brief)
}

// MARK: - isFaithful

@Test func aNoteThatKeepsEveryFigureAndNameIsKept() throws {
    #expect(try isFaithful("Food came to $684 against a $600 budget — $84 over.", about: Sample.food))
    #expect(try isFaithful("The car loan dropped $420 and now stands at $14,380.", about: Sample.loan), "Names match whatever the case")
    #expect(try isFaithful("Benefits Co - HSA still reads $4,750, the same as August; look it up before finishing October.", about: Sample.stale), "The header's months are anyone's")
}

@Test func aNoteThatLosesAFigureOrNameIsDropped() throws {
    #expect(try !isFaithful("Food ran $84 over its budget.", about: Sample.food), "Lost $684 and $600")
    #expect(try !isFaithful("Dining came to $684 of a $600 budget, $84 over.", about: Sample.food), "Lost the category's name")
}

@Test func aNoteWithANumberOfItsOwnIsDropped() throws {
    #expect(try !isFaithful("Food: $684 of a $600 budget, $84 over — about $1,008 a year.", about: Sample.food), "The model's own arithmetic")
    #expect(try !isFaithful("Food: $684 of a $600 budget, $84 over, and the loan is down $420.", about: Sample.food), "A true number, from another fact")
}

@Test func aNoteNamingAnotherFactIsDropped() throws {
    #expect(try !isFaithful("Food: $684 of a $600 budget, $84 over, while Groceries stayed under.", about: Sample.food))
}

@Test func aNoteThatWavesTheFactAwayOrAdvisesIsDropped() throws {
    #expect(try !isFaithful("Food: $684 of a $600 budget, $84 over — nothing to worry about.", about: Sample.food))
    #expect(try !isFaithful("The car loan is down $420 to $14,380, so consider buying more stocks.", about: Sample.loan))
    #expect(try !isFaithful("The car loan is down $420 to $14,380; rebalance toward bonds.", about: Sample.loan))
}

@Test func aMerchantsNameIsNotAdvice() {
    let brief = handBrief(facts: [briefFact(1, "newRecurring:best buy", .watch, "Best Buy, $9.99, is a new recurring charge since August.", figures: ["$9.99"], names: ["Best Buy", "August"])])
    #expect(!ReportReview.soundsLikeAdvice("Best Buy, $9.99, is new since August.", brief: brief))
    #expect(ReportReview.soundsLikeAdvice("You could sell some gold.", brief: brief))
}

@Test @MainActor func everySeededFactIsFaithfulToItself() throws {
    for scope in [nil, ReportScope.year(2026)] {
        let data = try seededBriefReport(scope)
        let brief = ReportBrief(data: data)
        #expect(!brief.facts.isEmpty)
        for fact in brief.facts {
            #expect(ReportReview.isFaithful(fact.text, to: fact, in: brief), "\(fact.findingID): \(fact.text)")
            #expect(ReportReview.isFaithful("Stub: \(fact.text)", to: fact, in: brief))
        }
    }
}

// MARK: - Building the review

@Test func withNoDraftTheReviewIsThePlainCheck() {
    let review = ReportReview.plain(findings: Sample.findings, scope: Sample.scope)
    #expect(!review.isWrittenByModel)
    #expect(review.headline == "Net worth rose $5,565 since August, to $387,675 (1.5%).")
    #expect(review.wentWell.map(\.findingID) == ["debtPaidDown:loan", "underBudgetStreak:groceries"], "By weight")
    #expect(review.watch.map(\.text) == [Sample.food.plainText])
    #expect(review.tryNext.map(\.findingID) == ["staleBalances"])
    #expect(review.tryNext.first?.fix == .updateBalances(YearMonth(year: 2026, month: 10)), "Swift's fix rides along")
    #expect(!review.allItems.contains { $0.findingID == "netWorthMove" }, "The headline's fact isn't also a line")
    #expect(review.counts == FinanceReportData.ToneCounts(wentWell: 2, watch: 1, tryNext: 1))
    #expect(review.tryNextTitle == "Try in October")
    #expect(review.title(for: .watch) == "To watch")
}

@Test func faithfulNotesComeFirstInTheModelsOrderAndTheRestFallBack() {
    let review = Sample.review(headline: "A steady September: net worth up $5,565 to $387,675.", [
        Sample.note(Sample.groceries, "Groceries stayed under at $612 of $700 for a second month."),
        Sample.note(Sample.loan, "Car loan fell $420 — $14,380 to go."),
        Sample.note(Sample.food, "Food went over its budget."),
    ])
    #expect(review.isHeadlineWrittenByModel)
    #expect(review.headline == "A steady September: net worth up $5,565 to $387,675.")
    #expect(review.wentWell.map(\.findingID) == ["underBudgetStreak:groceries", "debtPaidDown:loan"], "The model's ranking")
    #expect(review.wentWell.allSatisfy { $0.isWrittenByModel })
    let food = review.watch.first
    #expect(food?.isWrittenByModel == false, "Lost its figures, so the check's words")
    #expect(food?.text == Sample.food.plainText)
    #expect(review.tryNext.first?.isWrittenByModel == false, "Not written about: the check's words")
    #expect(review.isWrittenByModel)
}

@Test func aNoteUnderAnotherFactsNumberIsDropped() {
    let review = Sample.review([
        ReportReviewDraft.Note(fact: Sample.number(of: Sample.loan), message: Sample.food.plainText),
        ReportReviewDraft.Note(fact: 99, message: "A fact that doesn't exist."),
        ReportReviewDraft.Note(fact: Sample.number(of: Sample.netWorth), message: Sample.netWorth.plainText),
    ])
    #expect(!review.allItems.contains { $0.isWrittenByModel })
    #expect(review.wentWell.first { $0.findingID == "debtPaidDown:loan" }?.text == Sample.loan.plainText)
}

@Test func theFirstNoteForAFactWins() {
    let review = Sample.review([
        Sample.note(Sample.food, "Food: $684 against $600, so $84 over."),
        Sample.note(Sample.food, "Food came to $684 of $600 — $84 over budget."),
    ])
    #expect(review.watch.count == 1)
    #expect(review.watch.first?.text == "Food: $684 against $600, so $84 over.")
}

@Test func aModelGroupNeverMovesAFinding() {
    let note = ReportReviewDraft.Note(fact: Sample.number(of: Sample.food), group: .wentWell, message: "Food: $684 of $600, $84 over.")
    let review = Sample.review([note])
    #expect(review.watch.first?.isWrittenByModel == true)
    #expect(review.wentWell.allSatisfy { $0.findingID != "overBudget:food" })
}

@Test func aHeadlineWithANumberNotInTheFactsIsReplaced() {
    let invented = Sample.review(headline: "Net worth rose $6,000 this month.", [])
    #expect(!invented.isHeadlineWrittenByModel)
    #expect(invented.headline == ReportReview.plainHeadline(findings: Sample.findings, scope: Sample.scope))
    let advice = Sample.review(headline: "Net worth rose $5,565; time to buy gold.", [])
    #expect(!advice.isHeadlineWrittenByModel)
    #expect(!invented.isWrittenByModel)
}

@Test func whileStreamingOnlyFinishedNotesShowAndNothingIsFilledIn() {
    let draft = ReportReviewDraft(headline: "A steady September: net worth up $5,5", notes: [
        Sample.note(Sample.loan, "Car loan fell $420 — $14,380 to go."),
        Sample.note(Sample.food, "Food: $684 of a $6"),
    ], isComplete: false)
    let review = ReportReview(findings: Sample.findings, scope: Sample.scope, brief: Sample.brief, draft: draft, fillingIn: false)
    #expect(review.isHeadlineWrittenByModel, "A number cut off mid-stream isn't a wrong one")
    #expect(review.allItems.map(\.findingID) == ["debtPaidDown:loan"], "The last note may be unfinished; nothing plain yet")
}

@Test func theNoBudgetKindsAndTypedValuesLandInAGroup() {
    let typed = ReportFinding(
        id: "typedMetalValue", kind: .typedMetalValue, tone: .info, severity: .fragile, isWorthFixing: true,
        title: "Ring holds a typed value", plainText: "Ring holds a typed value of $1,200.", figures: ["$1,200"], names: ["Ring"],
        fix: .openHoldings, weight: 240
    )
    #expect(ReportReview.Group(finding: typed) == .tryNext)
    #expect(ReportReview.Group(finding: Sample.netWorth) == nil)
    let summaryUnder = ReportFinding(id: "budgetsSummary", kind: .budgetsSummary, tone: .wentWell, title: "", plainText: "All 4 budgets came in under.")
    #expect(ReportReview.Group(finding: summaryUnder) == .wentWell, "Every budget under is good news, not the headline")
}

@Test @MainActor func thePlainSeededReviewListsTheHeaviestFindingsOncePerGroup() throws {
    let data = try seededBriefReport()
    let review = ReportReview.plain(data: data)
    let listed = review.allItems.map(\.findingID)
    #expect(Set(listed).count == listed.count)
    for group in ReportReview.Group.allCases {
        let expected = data.findings
            .filter { ReportReview.Group(finding: $0) == group }
            .sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.id < $1.id }
            .prefix(ReportReview.perGroupLimit)
            .map(\.id)
        #expect(review.items(in: group).map(\.findingID) == Array(expected))
    }
    #expect(review.headline.hasPrefix("Net worth"))
    #expect(review.headline.contains("over budget"), "The budgets' total joins the headline when something went over")
}

// MARK: - Ask

@Test func anAnswerMayOnlyQuoteTheBriefsNumbers() {
    let brief = Sample.brief
    let good = AskReply(question: "Why did Food go over?", answer: "Food came to $684 against its $600 budget, $84 over.", brief: brief, isComplete: true)
    #expect(good.isWrittenByModel)
    #expect(good.text == "Food came to $684 against its $600 budget, $84 over.")

    let figures = AskReply(question: "How much did we spend?", answer: "You spent $3,100 across 42 transactions.", brief: brief, isComplete: true)
    #expect(figures.isWrittenByModel, "The figures block is the brief too")

    let invented = AskReply(question: "Why did Food go over?", answer: "Food went over because of $250 in restaurants.", brief: brief, isComplete: true)
    #expect(!invented.isWrittenByModel)
    #expect(invented.text.hasPrefix(AskReply.fallbackLead))
    #expect(invented.text.contains(Sample.food.plainText), "The fact nearest the question follows")
    #expect(invented.facts.first?.findingID == "overBudget:food")
}

@Test func anAnswerMayEchoTheQuestionsNumbersButNeverAdvise() {
    let brief = Sample.brief
    let echoed = AskReply(question: "Did Food stay under $650?", answer: "No: Food came to $684, above $650.", brief: brief, isComplete: true)
    #expect(echoed.isWrittenByModel)
    let advice = AskReply(question: "What should we do?", answer: "Sell some gold and invest in index funds.", brief: brief, isComplete: true)
    #expect(!advice.isWrittenByModel)
    let empty = AskReply(question: "Anything?", answer: "  ", brief: brief, isComplete: true)
    #expect(!empty.isWrittenByModel)
}

@Test func aFallbackWithNothingMatchingQuotesTheHeadline() {
    let reply = AskReply.fallback(question: "Zebras?", brief: Sample.brief)
    #expect(reply.facts.first?.findingID == "netWorthMove")
    #expect(reply.facts.count == 2)
}

@Test @MainActor func suggestedQuestionsComeFromWhatTheCheckFound() throws {
    let questions = AskReply.suggestedQuestions(for: try seededBriefReport())
    #expect(questions.count == 4)
    #expect(questions.contains("Why did Food go over?"))
    #expect(questions.contains("What's recurring?"))
    #expect(questions.contains("How does this compare with August?"))
    let year = AskReply.suggestedQuestions(for: try seededBriefReport(.year(2026)))
    #expect(year.contains("Where did the money go in 2026?"))
}

// MARK: - Availability

@Test func theSummaryCardFollowsAvailability() {
    #expect(FinanceAdvisorAvailability.available.reviewCardStyle == .assistant)
    #expect(FinanceAdvisorAvailability.turnedOff.reviewCardStyle == .hidden)
    for plain in [FinanceAdvisorAvailability.notEnabled, .notReady, .deviceNotEligible, .unsupportedOS, .unsupportedLanguage] {
        #expect(plain.reviewCardStyle == .plainCheck)
    }
    #expect(!FinanceAdvisorAvailability.unsupportedOS.showsSetting)
    #expect(!FinanceAdvisorAvailability.deviceNotEligible.showsSetting)
    #expect(FinanceAdvisorAvailability.turnedOff.showsSetting, "Off by choice keeps the switch, so it can come back on")
    #expect(StubFinanceAdvisor().availability(isEnabled: false) == .turnedOff)
    #expect(StubFinanceAdvisor().availability(isEnabled: true) == .available)
    #expect(UnavailableFinanceAdvisor().availability(isEnabled: true) == .unsupportedOS)
}

// MARK: - The stub

private func finalDraft(_ advisor: any FinanceAdvising, _ brief: ReportBrief) async throws -> ReportReviewDraft? {
    var last: ReportReviewDraft?
    for try await draft in advisor.review(brief) { last = draft }
    return last
}

@Test @MainActor func theStubIsDeterministicAndFaithful() async throws {
    let data = try seededBriefReport()
    let brief = ReportBrief(data: data)
    let first = try await finalDraft(StubFinanceAdvisor(), brief)
    let second = try await finalDraft(StubFinanceAdvisor(), brief)
    #expect(first == second)
    #expect(first?.isComplete == true)
    let review = ReportReview(findings: data.findings, scope: data.scope, brief: brief, draft: first)
    #expect(review.isHeadlineWrittenByModel)
    let inBrief = Set(brief.facts.filter { !$0.isHeadline }.map(\.findingID))
    #expect(review.allItems.filter { inBrief.contains($0.findingID) }.allSatisfy { $0.isWrittenByModel })
    #expect(review.allItems.filter { !inBrief.contains($0.findingID) }.allSatisfy { !$0.isWrittenByModel }, "Past the cap, the check's words")

    var answer = ""
    for try await text in StubFinanceAdvisor().answer(question: "Why did Food go over?", brief: brief) { answer = text }
    #expect(AskReply(question: "Why did Food go over?", answer: answer, brief: brief, isComplete: true).isWrittenByModel)
}

// MARK: - The model and its cache

private func scratchCache() -> ReportReviewCache {
    ReportReviewCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ReportReviewTests-\(UUID().uuidString)", isDirectory: true))
}

@Test @MainActor func aWrittenReviewIsCachedAndShownAgainWithoutTheModel() async throws {
    let data = try seededBriefReport()
    let cache = scratchCache()
    defer { try? FileManager.default.removeItem(at: cache.directory) }

    let model = ReportReviewModel(data: data, cache: cache)
    #expect(model.state == .idle)
    #expect(model.review == model.plainReview)
    await model.start(advisor: StubFinanceAdvisor(), enabled: true)
    guard case .ready(let written) = model.state else {
        Issue.record("Expected a ready review, got \(model.state)")
        return
    }
    #expect(written.isWrittenByModel)
    #expect(model.isReady)
    #expect(model.counts == model.plainReview.counts)

    // A second sheet on the same figures: from the cache, with a model that
    // would fail if it were asked.
    let again = ReportReviewModel(data: data, cache: cache)
    await again.start(advisor: StubFinanceAdvisor(failure: .unavailable(.notReady)), enabled: true)
    #expect(again.state == .ready(written))

    // "Write Again" skips the cache: with the model failing, the plain check.
    await again.writeAgain(advisor: StubFinanceAdvisor(failure: .unavailable(.notReady)), enabled: true)
    #expect(again.state == .plain(again.plainReview))
}

// The Summary's `.task` restarted mid-review (its inputs changed): SwiftUI
// cancelled the first start and made a second before the first stream wound
// down, the second saw `.writing` and returned, and the cancelled run left the
// model idle for good — on screen, the plain check forever.
@Test @MainActor func aStartCancelledMidReviewIsPickedUpByTheNextStart() async throws {
    let data = try seededBriefReport()
    let cache = scratchCache()
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let model = ReportReviewModel(data: data, cache: cache)
    let slow = StubFinanceAdvisor(delay: .milliseconds(20))

    let first = Task { await model.start(advisor: slow, enabled: true) }
    while !model.isWriting { await Task.yield() }
    first.cancel()
    await model.start(advisor: slow, enabled: true)
    await first.value

    guard case .ready(let review) = model.state else {
        Issue.record("Expected a ready review, got \(model.state)")
        return
    }
    #expect(review.isWrittenByModel)
}

@Test @MainActor func aCachedReviewIsAMissOnceAFigureChanges() throws {
    let cache = scratchCache()
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let review = Sample.review([Sample.note(Sample.food, "Food: $684 against $600, so $84 over.")])
    cache.save(review, for: Sample.brief)
    #expect(cache.review(for: Sample.brief, findings: Sample.findings) == review)

    let changedFood = ReportFinding(
        id: "overBudget:food", kind: .overBudget, tone: .watch, title: "Food $90 over",
        plainText: "Food: $690 of a $600 budget, $90 over.", figures: ["$690", "$600", "$90"], names: ["Food"],
        fix: .adjustBudget(category: "Food"), weight: 180
    )
    let findings = [Sample.netWorth, Sample.loan, changedFood, Sample.stale, Sample.groceries]
    let changedBrief = ReportBrief(
        scope: Sample.scope, ownerLabel: "Everyone", header: Sample.brief.header, figures: [],
        facts: ReportBrief.rank(findings, limit: 14).enumerated().map { offset, finding in
            ReportBrief.Fact(number: offset + 1, findingID: finding.id, kind: finding.kind, group: ReportReview.Group(finding: finding), text: finding.plainText, figures: finding.figures, names: finding.names)
        },
        nextName: "October"
    )
    #expect(cache.review(for: changedBrief, findings: findings) == nil)
    #expect(cache.entry(for: changedBrief) == nil)

    // A plain review is never saved.
    cache.remove(for: Sample.brief)
    cache.save(ReportReview.plain(findings: Sample.findings, scope: Sample.scope), for: Sample.brief)
    #expect(cache.entry(for: Sample.brief) == nil)
}

@Test @MainActor func aReviewCachedByOneAdvisorIsAMissForAnother() throws {
    let cache = scratchCache()
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let review = Sample.review([Sample.note(Sample.food, "Food: $684 against $600, so $84 over.")])
    cache.save(review, for: Sample.brief, writer: "StubFinanceAdvisor")
    #expect(cache.review(for: Sample.brief, findings: Sample.findings, writer: "StubFinanceAdvisor") == review)
    #expect(cache.review(for: Sample.brief, findings: Sample.findings, writer: "FoundationModelsFinanceAdvisor") == nil)
}

@Test func eachGroupShowsAtMostThreeNotes() {
    let many = (1...6).map { index in
        ReportFinding(
            id: "staleBalances:\(index)", kind: .staleBalances, tone: .tryNext, title: "Account \(index)",
            plainText: "Account \(index) matches last month.", figures: [], names: ["Account \(index)"],
            fix: nil, weight: Double(100 - index)
        )
    }
    let review = ReportReview.plain(findings: many, scope: Sample.scope)
    #expect(review.tryNext.count == ReportReview.perGroupLimit)
    #expect(review.tryNext.map(\.findingID) == ["staleBalances:1", "staleBalances:2", "staleBalances:3"])
}

@Test @MainActor func offOrUnavailableIsThePlainCheckAndNothingIsAsked() async throws {
    let data = try seededBriefReport()
    let cache = scratchCache()
    defer { try? FileManager.default.removeItem(at: cache.directory) }

    let off = ReportReviewModel(data: data, cache: cache)
    await off.start(advisor: StubFinanceAdvisor(), enabled: false)
    #expect(off.state == .plain(off.plainReview))
    #expect(off.availability == .turnedOff)

    let notReady = ReportReviewModel(data: data, cache: cache)
    await notReady.start(advisor: StubFinanceAdvisor(availability: .notReady), enabled: true)
    #expect(notReady.state == .plain(notReady.plainReview))
    #expect(notReady.availability.footnote == "Getting ready…")

    let failing = ReportReviewModel(data: data, cache: cache)
    await failing.start(advisor: StubFinanceAdvisor(failure: .unavailable(.notReady)), enabled: true)
    #expect(failing.state == .plain(failing.plainReview))
    #expect(cache.entry(for: failing.brief) == nil)
}

@Test @MainActor func askingStreamsACheckedAnswer() async throws {
    let data = try seededBriefReport()
    let model = ReportReviewModel(data: data, cache: scratchCache())
    #expect(model.suggestedQuestions.contains("Why did Food go over?"))

    await model.ask("Why did Food go over?", advisor: StubFinanceAdvisor(), enabled: true)
    #expect(model.answer?.isWrittenByModel == true)
    #expect(model.answer?.isComplete == true)
    #expect(model.isAnswering == false)

    await model.ask("Why did Food go over?", advisor: StubFinanceAdvisor(failure: .unavailable(.notReady)), enabled: true)
    #expect(model.answer?.isWrittenByModel == false)
    #expect(model.answer?.text.hasPrefix(AskReply.fallbackLead) == true)

    await model.ask("Why did Food go over?", advisor: StubFinanceAdvisor(), enabled: false)
    #expect(model.answer?.isWrittenByModel == false, "Off means nothing is sent")

    model.clearAnswer()
    #expect(model.answer == nil)
}

// MARK: - The probe

@Test @MainActor func theProbeRunsEndToEndWithTheStub() async throws {
    let container = CloudSharedStore.makeContainer(
        name: "FinanceProbeTests-\(UUID().uuidString)",
        model: FinanceModel.make(),
        containerID: "iCloud.com.bhavikjain.trackers.tests",
        inMemory: true
    )
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FinanceProbeTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let report = await FinanceAdvisorProbe.run(
        context: container.viewContext, container: container, advisor: StubFinanceAdvisor(),
        htmlDirectory: directory, asOf: ReportDataFixture.now
    )
    #expect(report.contains("######## September 2026 · Everyone"))
    #expect(report.contains("######## 2026 in review"))
    #expect(report.contains("== ReportBrief: 14 facts"))
    #expect(report.contains("headline [model]: Stub:"))
    #expect(report.contains("Q: Should we sell the gold?"))
    #expect(report.contains("HTML report"))
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(Set(files) == ["September 2026 Report.html", "2026 in review Report.html"])
}
