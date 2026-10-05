import Core
import CoreData
import Foundation
import Testing
@testable import FinanceTracker

// MARK: - Fixtures

private let september = ReportScope.month(YearMonth(year: 2026, month: 9))
private let august = ReportScope.month(YearMonth(year: 2026, month: 8))
private let october = YearMonth(year: 2026, month: 10)

private func scratchCache() -> ReportReviewCache {
    ReportReviewCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ReportReviewRenewalTests-\(UUID().uuidString)", isDirectory: true))
}

/// A one-fact brief for `scope` and `owner`, and a review of it the model
/// wrote — enough for the cache to keep.
private func writtenReview(_ scope: ReportScope, owner: String = "Everyone") -> (review: ReportReview, brief: ReportBrief) {
    let food = ReportFinding(
        id: "overBudget:food", kind: .overBudget, tone: .watch, title: "Food $84 over",
        plainText: "Food: $684 of a $600 budget, $84 over.", figures: ["$684", "$600", "$84"], names: ["Food"], weight: 168
    )
    let brief = ReportBrief(
        scope: scope,
        ownerLabel: owner,
        header: "Household finances: \(scope.title), \(owner)'s figures.",
        figures: [],
        facts: [ReportBrief.Fact(number: 1, findingID: food.id, kind: food.kind, group: ReportReview.Group(finding: food), text: food.plainText, figures: food.figures, names: food.names)],
        nextName: "October"
    )
    let draft = ReportReviewDraft(notes: [.init(fact: 1, message: "Food came to $684 against a $600 budget, so $84 over.")], isComplete: true)
    let review = ReportReview(findings: [food], scope: scope, brief: brief, draft: draft)
    return (review, brief)
}

@MainActor
private func seededHousehold() throws -> SharedFinanceHousehold {
    let household = ReportDataFixture.emptyHousehold()
    let context = try #require(household.managedObjectContext)
    FinanceDebugSeed.run(context: context, container: nil, asOf: ReportDataFixture.now)
    return try #require(try context.fetch(SharedFinanceHousehold.fetchRequest()).first { !$0.isEmpty })
}

@MainActor
private func makeRecipe(_ scope: ReportScope, _ household: SharedFinanceHousehold, asOf now: Date = ReportDataFixture.now) -> ReportRecipe {
    ReportRecipe(scope: scope, household: household, filter: .all, deviceName: "this iPhone", builtAt: now)
}

private func basis(_ fingerprint: String, _ scope: ReportScope = september, owner: String = "Everyone", live: MetalPrices? = nil) -> ReportReviewBasis {
    ReportReviewBasis(scope: scope, ownerLabel: owner, fingerprint: fingerprint, livePrices: live)
}

// MARK: - Keep or write again

@Test func withNoReviewOnScreenOneIsMade() {
    #expect(ReportReviewRenewal.decide(current: nil, next: basis("a")) { _ in nil } == .replace)
}

@Test func theSameFactsKeepTheReview() {
    var asked = false
    let renewal = ReportReviewRenewal.decide(current: basis("a"), next: basis("a")) { _ in
        asked = true
        return nil
    }
    #expect(renewal == .keep)
    #expect(!asked, "Nothing to rebuild when the facts match")
}

@Test func anotherMonthOrPersonIsAnotherReview() {
    #expect(ReportReviewRenewal.decide(current: basis("a"), next: basis("a", august)) { _ in "a" } == .replace)
    #expect(ReportReviewRenewal.decide(current: basis("a"), next: basis("a", owner: "Saloni")) { _ in "a" } == .replace)
}

@Test func newFiguresAtSavedPricesAreWrittenAgain() {
    var asked = false
    let renewal = ReportReviewRenewal.decide(current: basis("a"), next: basis("b")) { _ in
        asked = true
        return "a"
    }
    #expect(renewal == .replace)
    #expect(!asked, "Saved prices never tick")
}

// The open month is valued at live gold and silver; each fetch moved the net
// worth, the brief's fingerprint with it, and the model wrote the review again.
@Test func aLivePriceTickAloneCarriesTheReviewOver() {
    let morning = MetalPrices(gold: 4_420, silver: 50.5)
    let noon = MetalPrices(gold: 4_431.2, silver: 50.75)
    var askedAt: MetalPrices?
    let renewal = ReportReviewRenewal.decide(current: basis("a", live: morning), next: basis("b", live: noon)) { prices in
        askedAt = prices
        return "a"
    }
    #expect(renewal == .carryOver)
    #expect(askedAt == morning, "Rebuilt at the prices the review was written at")
}

@Test func aTickAlongsideAnEditIsWrittenAgain() {
    let morning = MetalPrices(gold: 4_420, silver: 50.5)
    let noon = MetalPrices(gold: 4_431.2, silver: 50.75)
    #expect(ReportReviewRenewal.decide(current: basis("a", live: morning), next: basis("b", live: noon)) { _ in "c" } == .replace)
    #expect(ReportReviewRenewal.decide(current: basis("a", live: morning), next: basis("b", live: noon)) { _ in nil } == .replace)
}

// Until the first fetch lands the open month is at its own saved prices, so
// every launch moved the figures a second after the review was on screen.
@Test func theFirstFetchCarriesTheReviewOverToo() {
    let noon = MetalPrices(gold: 4_431.2, silver: 50.75)
    var askedAt: MetalPrices?? = .none
    let renewal = ReportReviewRenewal.decide(current: basis("a"), next: basis("b", live: noon)) { prices in
        askedAt = .some(prices)
        return "a"
    }
    #expect(renewal == .carryOver)
    #expect(askedAt == .some(nil), "Rebuilt at the month's own saved prices")
    #expect(ReportReviewRenewal.decide(current: basis("a"), next: basis("b", live: noon)) { _ in "c" } == .replace, "An edit made before the fetch")
}

@Test func closingTheMonthIsNewFigures() {
    // Closing saves the live prices into the month, and a closed month is
    // never valued at live ones: rebuilt at them, it still tells other facts.
    let noon = MetalPrices(gold: 4_431.2, silver: 50.75)
    var askedAt: MetalPrices?
    let renewal = ReportReviewRenewal.decide(current: basis("a", live: noon), next: basis("b")) { prices in
        askedAt = prices
        return "b"
    }
    #expect(renewal == .replace)
    #expect(askedAt == noon)
}

@Test func samePricesOtherFactsIsAnEdit() {
    let same = MetalPrices(gold: 4_420, silver: 50.5)
    var asked = false
    let renewal = ReportReviewRenewal.decide(current: basis("a", live: same), next: basis("b", live: same)) { _ in
        asked = true
        return "a"
    }
    #expect(renewal == .replace)
    #expect(!asked, "Nothing to rebuild when the prices didn't move")
}

@Test func notesAreRenumberedOntoTheNewBriefByFinding() {
    let food = briefFact(1, "overBudget:food", .watch, "Food: $684 of a $600 budget, $84 over.", figures: ["$684", "$600", "$84"], names: ["Food"])
    let loan = briefFact(2, "debtPaidDown:loan", .wentWell, "Car loan is down $420, to $14,380.", figures: ["$420", "$14,380"], names: ["Car loan"], kind: .debtPaidDown)
    let gone = briefFact(3, "staleBalances", .tryNext, "HSA matches August.", names: ["HSA"], kind: .staleBalances)
    let written = handBrief(facts: [food, loan, gone])
    let movedLoan = briefFact(1, "debtPaidDown:loan", .wentWell, loan.text, figures: loan.figures, names: loan.names, kind: .debtPaidDown)
    let movedFood = briefFact(2, "overBudget:food", .watch, "Food: $690 of a $600 budget, $90 over.", figures: ["$690", "$600", "$90"], names: ["Food"])
    let current = handBrief(facts: [movedLoan, movedFood])
    let draft = ReportReviewDraft(headline: "A month.", notes: [
        .init(fact: 1, message: "Food: $684 against $600, $84 over."),
        .init(fact: 2, message: "The car loan fell $420 to $14,380."),
        .init(fact: 3, message: "HSA still matches August.")
    ], isComplete: true)

    let carried = draft.carried(from: written, to: current)
    #expect(carried.headline == "A month.")
    #expect(carried.notes.map(\.fact) == [2, 1], "Food is fact 2 now, the loan fact 1, and the stale balance is gone")
    #expect(draft.carried(from: written, to: written) == draft)

    // The loan's note still holds; the food note's figures moved, so the
    // check's own words stand in for it.
    let findings = [
        ReportFinding(id: movedLoan.findingID, kind: .debtPaidDown, tone: .wentWell, title: "Loan", plainText: movedLoan.text, figures: movedLoan.figures, names: movedLoan.names, weight: 420),
        ReportFinding(id: movedFood.findingID, kind: .overBudget, tone: .watch, title: "Food", plainText: movedFood.text, figures: movedFood.figures, names: movedFood.names, weight: 180)
    ]
    let review = ReportReview(findings: findings, scope: september, brief: current, draft: carried)
    #expect(review.allItems.first { $0.findingID == movedLoan.findingID }?.isWrittenByModel == true)
    let foodItem = review.allItems.first { $0.findingID == movedFood.findingID }
    #expect(foodItem?.isWrittenByModel == false)
    #expect(foodItem?.text == movedFood.text)
}

// MARK: - The cache

@Test func writingAMonthAgainForgetsItForEveryPersonAndNothingElse() throws {
    let cache = scratchCache()
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let everyone = writtenReview(september)
    let saloni = writtenReview(september, owner: "Saloni")
    let lastMonth = writtenReview(august)
    let year = writtenReview(.year(2026))
    for (review, brief) in [everyone, saloni, lastMonth, year] {
        cache.save(review, for: brief)
        #expect(cache.entry(for: brief) != nil)
    }

    cache.removeAll(for: september)
    #expect(cache.entry(for: everyone.brief) == nil)
    #expect(cache.entry(for: saloni.brief) == nil)
    #expect(cache.entry(for: lastMonth.brief) != nil)
    #expect(cache.entry(for: year.brief) != nil, "2026's file starts like September's")

    cache.removeAll(for: .year(2026))
    #expect(cache.entry(for: year.brief) == nil)
    #expect(cache.entry(for: lastMonth.brief) != nil, "September's year isn't its months")

    // Nothing there yet is nothing to do.
    scratchCache().removeAll(for: september)
}

@Test func aCacheFileIsReadBackToItsScope() {
    #expect(ReportReviewCache.scope(ofFileNamed: "2026-09-0123456789ab.json") == september)
    #expect(ReportReviewCache.scope(ofFileNamed: "2026-0123456789ab.json") == .year(2026))
    #expect(ReportReviewCache.scope(ofFileNamed: "2026-09-0123456789ab.json.tmp") == nil)
    #expect(ReportReviewCache.scope(ofFileNamed: "2026-09-notahash.json") == nil)
    #expect(ReportReviewCache.scope(ofFileNamed: ".DS_Store") == nil)
    let cache = scratchCache()
    #expect(cache.fileURL(scope: september, owner: "Saloni").lastPathComponent.hasPrefix("2026-09-"))
    #expect(ReportReviewCache.scope(ofFileNamed: cache.fileURL(scope: september, owner: "Saloni").lastPathComponent) == september)
    #expect(ReportReviewCache.scope(ofFileNamed: cache.fileURL(scope: .year(2026), owner: "Everyone").lastPathComponent) == .year(2026))
}

@Test func aRunNeverFilesItsReviewOverOneSavedSinceItStarted() throws {
    let cache = scratchCache()
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let (review, brief) = writtenReview(september)
    let nine = Date(timeIntervalSince1970: 1_790_000_000)
    cache.save(review, for: brief, asOf: nine)

    // Started before nine, finished after: about figures since replaced.
    cache.save(review, for: brief, startedAt: nine.addingTimeInterval(-60), asOf: nine.addingTimeInterval(60))
    #expect(cache.entry(for: brief)?.savedAt == nine)

    cache.save(review, for: brief, startedAt: nine.addingTimeInterval(30), asOf: nine.addingTimeInterval(90))
    #expect(cache.entry(for: brief)?.savedAt == nine.addingTimeInterval(90))
}

@Test func aReviewKeepsThePricesItWasWrittenAt() throws {
    let cache = scratchCache()
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let (review, brief) = writtenReview(september)
    let noon = MetalPrices(gold: 4_431.2, silver: 50.75)
    cache.save(review, for: brief, writer: "Stub", livePrices: noon)
    #expect(cache.entry(for: brief, writer: "Stub")?.livePrices == noon)
    #expect(cache.latestEntry(scope: september, owner: "Everyone", writer: "Stub")?.fingerprint == brief.fingerprint)
    #expect(cache.latestEntry(scope: september, owner: "Everyone", writer: "Other") == nil, "Another writer's isn't this one's")
    #expect(cache.latestEntry(scope: september, owner: "Saloni", writer: "Stub") == nil)

    // A review kept before the prices were reads back as one at saved prices.
    let url = cache.fileURL(scope: september, owner: "Everyone")
    guard var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
        Issue.record("The entry isn't a JSON object")
        return
    }
    #expect(json.keys.contains("livePrices"))
    json.removeValue(forKey: "livePrices")
    try JSONSerialization.data(withJSONObject: json).write(to: url)
    let old = try #require(cache.entry(for: brief, writer: "Stub"))
    #expect(old.livePrices == nil)
    #expect(old.notes.count == 1)
}

// MARK: - "Written today at 9:14"

private let london: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    return calendar
}()

private func londonDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    london.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

@Test func theReviewSaysWhenItWasWritten() {
    let now = londonDate(2026, 10, 4, 15, 30)
    let british = Locale(identifier: "en_GB")
    func text(_ date: Date, asOf now: Date = now) -> String {
        ReviewWrittenNote.text(writtenAt: date, asOf: now, calendar: london, locale: british)
    }
    // The time is the system's to spell ("9:14" or "09:14"); which words go
    // round it is what's tested.
    func time(_ date: Date) -> String {
        ReviewWrittenNote.timeText(date, calendar: london, locale: british)
    }
    #expect(time(londonDate(2026, 10, 3, 18, 2)) == "18:02", "24-hour, as en_GB has it")
    let nine = londonDate(2026, 10, 4, 9, 14)
    #expect(text(nine) == "Written today at \(time(nine))")
    let justAfterMidnight = londonDate(2026, 10, 4, 0, 5)
    #expect(text(justAfterMidnight) == "Written today at \(time(justAfterMidnight))")
    #expect(text(londonDate(2026, 10, 3, 18, 2)) == "Written yesterday at 18:02")
    #expect(text(londonDate(2026, 10, 3, 23, 59), asOf: justAfterMidnight) == "Written yesterday at 23:59", "By the calendar, not 24 hours")
    let thursday = londonDate(2026, 10, 2, 9, 14)
    #expect(text(thursday) == "Written on 2 October at \(time(thursday))")
    #expect(text(londonDate(2025, 12, 31, 23, 59)) == "Written on 31 December 2025 at 23:59", "With the year once it's another")
    let tomorrow = londonDate(2026, 10, 5, 8, 0)
    #expect(text(tomorrow) == "Written today at \(time(tomorrow))", "A clock set back since isn't a date to come")
}

@Test @MainActor func theMenuLineFollowsTheModel() async throws {
    let cache = scratchCache()
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let model = ReportReviewModel(data: try seededBriefReport(), cache: cache)
    #expect(ReviewWrittenNote.status(of: model) == nil, "Not started")
    await model.start(advisor: StubFinanceAdvisor(), enabled: true)
    let writtenAt = try #require(model.writtenAt)
    #expect(ReviewWrittenNote.status(of: model, asOf: writtenAt) == ReviewWrittenNote.text(writtenAt: writtenAt, asOf: writtenAt))
    await model.start(advisor: StubFinanceAdvisor(), enabled: false)
    #expect(ReviewWrittenNote.status(of: model) == nil, "The plain check is worked out each time")
    #expect(model.writtenAt == nil)
}

// MARK: - The model through new figures

@Test @MainActor func aKeptModelTakesTheNewReportAndKeepsItsReview() async throws {
    let household = try seededHousehold()
    let cache = scratchCache()
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let first = try #require(makeRecipe(september, household).build(live: nil))
    let model = ReportReviewModel(data: first, cache: cache)
    await model.start(advisor: StubFinanceAdvisor(), enabled: true)
    guard case .ready(let written) = model.state else {
        Issue.record("Expected a ready review, got \(model.state)")
        return
    }
    let writtenAt = model.writtenAt

    // Built again a minute later: a different report, the same facts. The
    // Summary kept the model and the figures it had, so Ask went on
    // answering from them.
    let later = try #require(makeRecipe(september, household, asOf: ReportDataFixture.now.addingTimeInterval(60)).build(live: nil))
    #expect(ReportReviewRenewal.decide(current: model.basis, next: ReportReviewBasis(data: later, brief: ReportBrief(data: later))) { _ in nil } == .keep)
    model.update(later)
    #expect(model.data == later)
    #expect(model.state == .ready(written))
    #expect(model.writtenAt == writtenAt)
    #expect(!model.isCarriedOver)
}

@Test @MainActor func aReportHandedOverMidReviewWaitsForTheReviewToFinish() async throws {
    let household = try seededHousehold()
    let cache = scratchCache()
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let first = try #require(makeRecipe(september, household).build(live: nil))
    let later = try #require(makeRecipe(september, household, asOf: ReportDataFixture.now.addingTimeInterval(60)).build(live: nil))
    let model = ReportReviewModel(data: first, cache: cache)

    let run = Task { await model.start(advisor: StubFinanceAdvisor(delay: .milliseconds(5)), enabled: true) }
    while !model.isWriting { await Task.yield() }
    model.update(later)
    #expect(model.data == first, "Held back while the model writes about it")
    #expect(model.basis.fingerprint == ReportBrief(data: later).fingerprint, "…but decided on as the latest")
    await run.value

    #expect(model.isReady)
    #expect(model.data == later)
    #expect(cache.entry(for: ReportBrief(data: first), writer: StubFinanceAdvisor().cacheIdentity) != nil, "Kept against what it was asked about")
}

// The seeded October is open and the latest month, so it's valued at the
// live prices: a fetch moves its net worth and the facts quoting it.
@Test @MainActor func aPriceTickCarriesTheReviewOverWithoutWritingItAgain() async throws {
    let household = try seededHousehold()
    let cache = scratchCache()
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let scope = ReportScope.month(october)
    let morning = MetalPrices(gold: 4_420, silver: 50.5)
    let noon = MetalPrices(gold: 4_517.35, silver: 52.25)
    let recipe = makeRecipe(scope, household)
    let first = try #require(recipe.build(live: morning))
    let second = try #require(recipe.build(live: noon))
    #expect(first.header.pricesAreLive)
    let firstBrief = ReportBrief(data: first), secondBrief = ReportBrief(data: second)
    #expect(firstBrief.fingerprint != secondBrief.fingerprint, "The tick moved a figure the model is shown")

    let model = ReportReviewModel(data: first, cache: cache)
    await model.start(advisor: StubFinanceAdvisor(), enabled: true)
    #expect(model.isReady)
    let writtenAt = model.writtenAt

    let renewal = ReportReviewRenewal.decide(current: model.basis, next: ReportReviewBasis(data: second, brief: secondBrief)) { recipe.brief(at: $0)?.fingerprint }
    #expect(renewal == .carryOver)
    model.update(second)
    #expect(model.data == second)
    #expect(model.writtenAt == writtenAt, "Not written again")
    if model.isReady {
        #expect(model.isCarriedOver)
        // Every word still the model's holds for the new figures.
        for item in model.review.allItems where item.isWrittenByModel {
            let fact = try #require(secondBrief.fact(findingID: item.findingID))
            #expect(ReportReview.isFaithful(item.text, to: fact, in: secondBrief), "\(item.text)")
        }
    } else {
        #expect(model.state == .plain(model.plainReview), "Nothing of the model's held")
    }

    // A balance typed alongside the tick is new figures: written again.
    let cash = try #require(household.months?.first { $0.period == october }?.balances?.first { $0.amount > 0 })
    cash.amount += 1_000
    let edited = try #require(recipe.build(live: noon))
    #expect(ReportReviewRenewal.decide(current: model.basis, next: ReportReviewBasis(data: edited, brief: ReportBrief(data: edited))) { recipe.brief(at: $0)?.fingerprint } == .replace)
}

// Live prices aren't kept between launches: the open month reopened at its
// saved prices, then at a new fetch's, and neither matched the review kept
// at the last one — it was written again every time Finance opened.
@Test @MainActor func aReviewKeptAtOtherPricesIsShownOnTheNextLaunch() async throws {
    let household = try seededHousehold()
    let cache = scratchCache()
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let recipe = makeRecipe(.month(october), household)
    let morning = MetalPrices(gold: 4_420, silver: 50.5)
    let noon = MetalPrices(gold: 4_517.35, silver: 52.25)
    let yesterday = ReportReviewModel(data: try #require(recipe.build(live: morning)), cache: cache)
    await yesterday.start(advisor: StubFinanceAdvisor(), enabled: true)
    let writtenAt = try #require(yesterday.writtenAt)
    #expect(cache.latestEntry(scope: .month(october), owner: "Everyone", writer: StubFinanceAdvisor().cacheIdentity)?.livePrices == morning)

    // A model that fails if it's asked: anything shown came from the cache.
    let failing = StubFinanceAdvisor(failure: .unavailable(.notReady))
    for prices in [nil, noon] {
        let data = try #require(recipe.build(live: prices))
        #expect(cache.entry(for: ReportBrief(data: data), writer: failing.cacheIdentity) == nil, "Not these very facts")
        let today = ReportReviewModel(data: data, cache: cache)
        today.update(data, repricing: recipe.repricing)
        await today.start(advisor: failing, enabled: true)
        #expect(today.isReady, "At \(String(describing: prices))")
        #expect(today.writtenAt == writtenAt)
        #expect(today.isCarriedOver)
    }

    // Without a way to rebuild the report, a miss is a miss.
    let unpriced = ReportReviewModel(data: try #require(recipe.build(live: noon)), cache: cache)
    await unpriced.start(advisor: failing, enabled: true)
    #expect(!unpriced.isReady)

    // Other figures at other prices are written again.
    let cash = try #require(household.months?.first { $0.period == october }?.balances?.first { $0.amount > 0 })
    cash.amount += 1_000
    let edited = ReportReviewModel(data: try #require(recipe.build(live: noon)), cache: cache)
    edited.update(try #require(recipe.build(live: noon)), repricing: recipe.repricing)
    await edited.start(advisor: failing, enabled: true)
    #expect(!edited.isReady)
}

@Test @MainActor func switchingTheModelOffOrOnIsSeenByTheNextStart() async throws {
    let cache = scratchCache()
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let model = ReportReviewModel(data: try seededBriefReport(), cache: cache)
    await model.start(advisor: StubFinanceAdvisor(), enabled: true)
    #expect(model.isReady)
    await model.start(advisor: StubFinanceAdvisor(), enabled: false)
    #expect(model.state == .plain(model.plainReview))
    // Back on: from the cache, with a model that would fail if asked.
    await model.start(advisor: StubFinanceAdvisor(failure: .unavailable(.notReady)), enabled: true)
    #expect(model.isReady)
}

// MARK: - Edits reach the review

@MainActor
private func snapshot(of household: SharedFinanceHousehold) -> FinanceSnapshot {
    FinanceSnapshot(
        household: household,
        owners: household.sortedOwners,
        accounts: household.sortedAccounts,
        months: household.sortedMonths,
        metals: household.sortedMetals,
        transactions: (household.transactions ?? []).sorted { $0.date > $1.date },
        canEdit: true,
        revision: 0,
        live: nil
    )
}

/// The edits a person makes to a month after its review was written: a
/// balance, a charge, a budget.
@MainActor
private func monthEdits(_ period: YearMonth, in household: SharedFinanceHousehold) throws -> [(String, () -> Void)] {
    let month = try #require(household.month(for: period))
    let largest = month.sortedBalances.max { $0.amount < $1.amount }
    let balance = try #require(largest)
    let budgeted = month.sortedBudgets.first { $0.hasLimit }
    let budget = try #require(budgeted)
    let paid = (household.transactions ?? []).first { YearMonth(containing: $0.date) == period && $0.actualCost > 0 }
    let charge = try #require(paid)
    return [
        ("balance", { balance.amount += 10_000 }),
        ("charge", { charge.actualCost += 2_500 }),
        ("budget", { budget.limit = max(1, budget.limit / 4).rounded() }),
    ]
}

// Every edit to the month a review is of has to reach it: the keeper only
// rebuilds when `ReportInputs` moves, and only a new fingerprint has the
// review written again. Both for the Summary's month and an older, closed
// one opened from Months.
@Test @MainActor func editingAMonthHasItsReviewWrittenAgain() throws {
    for period in [YearMonth(year: 2026, month: 9), YearMonth(year: 2026, month: 5)] {
        let scope = ReportScope.month(period)
        for index in 0..<3 {
            // A fresh household for each edit, so each is tested on its own.
            let household = try seededHousehold()
            #expect(household.month(for: period)?.isClosed == true)
            let (name, edit) = try monthEdits(period, in: household)[index]
            let recipe = makeRecipe(scope, household)
            let before = try #require(recipe.build(live: nil))
            let inputs = ReportInputs(scope: scope, filter: .all, snapshot: snapshot(of: household), availability: .available)
            let session = ReportSession()
            session.show(before, recipe: recipe)
            let model = try #require(session.model)

            edit()
            let after = try #require(recipe.build(live: nil))
            #expect(ReportInputs(scope: scope, filter: .all, snapshot: snapshot(of: household), availability: .available) != inputs, "\(period.title) \(name): the Summary never rebuilt")
            #expect(
                ReportReviewRenewal.decide(current: model.basis, next: ReportReviewBasis(data: after, brief: ReportBrief(data: after))) { recipe.brief(at: $0)?.fingerprint } == .replace,
                "\(period.title) \(name): the old review stayed"
            )
            session.show(after, recipe: recipe)
            #expect(session.model !== model, "\(period.title) \(name)")
            #expect(session.model?.data == after)
        }
    }
}

// MARK: - One model per review

@Test @MainActor func screensShowingTheSameReviewShareOneModel() throws {
    let household = try seededHousehold()
    let cache = scratchCache()
    let data = try #require(makeRecipe(september, household).build(live: nil))
    let first = ReportReviewModel.shared(for: data, cache: cache)
    #expect(ReportReviewModel.shared(for: data, cache: cache) === first)
    #expect(ReportReviewModel.shared(for: data, cache: scratchCache()) !== first, "Another cache is another review")
    let owner = try #require(household.sortedOwners.first { $0.name == "Saloni" })
    let saloni = try #require(FinanceReportData.build(
        scope: september, household: household, filter: .owner(owner),
        live: nil, deviceName: "", asOf: ReportDataFixture.now
    ))
    let theirs = ReportReviewModel.shared(for: saloni, cache: cache)
    #expect(theirs !== first)
    #expect(Set(ReportReviewModel.live(for: september, cache: cache).map(ObjectIdentifier.init)) == [ObjectIdentifier(first), ObjectIdentifier(theirs)])
    #expect(ReportReviewModel.live(for: august, cache: cache).isEmpty)
}

@Test @MainActor func aSessionTakesUpTheReviewAlreadyOnScreen() throws {
    let household = try seededHousehold()
    let recipe = makeRecipe(september, household)
    let data = try #require(recipe.build(live: nil))
    let summary = ReportSession()
    summary.show(data, recipe: recipe)
    let report = ReportSession()
    report.show(data, recipe: recipe)
    #expect(report.model === summary.model)
}

@Test @MainActor func writingAMonthAgainRewritesEveryReviewOfItOnScreen() async throws {
    let household = try seededHousehold()
    let cache = scratchCache()
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let data = try #require(makeRecipe(september, household).build(live: nil))
    let model = ReportReviewModel.shared(for: data, cache: cache)
    await model.start(advisor: StubFinanceAdvisor(), enabled: true)
    let firstWritten = try #require(model.writtenAt)
    let saloni = writtenReview(september, owner: "Saloni")
    let lastMonth = writtenReview(august)
    cache.save(saloni.review, for: saloni.brief)
    cache.save(lastMonth.review, for: lastMonth.brief)

    let rewrite = ReportReviewModel.writeReviewsAgain(of: september, advisor: StubFinanceAdvisor(), enabled: true, cache: cache)
    // Gone before anything opens, so the report opened next can't read it back.
    #expect(cache.entry(for: saloni.brief) == nil)
    #expect(cache.entry(for: model.brief, writer: StubFinanceAdvisor().cacheIdentity) == nil)
    #expect(cache.entry(for: lastMonth.brief) != nil)
    await rewrite.value

    #expect(model.isReady)
    #expect(try #require(model.writtenAt) >= firstWritten)
    #expect(cache.entry(for: model.brief, writer: StubFinanceAdvisor().cacheIdentity) != nil, "Written again and kept")
}
