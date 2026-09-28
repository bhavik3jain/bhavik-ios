import CoreData
import Foundation
import Testing
@testable import TripTracker

private let beforeTrip = day(6, 1)

/// Three findings: an overlap on Day 1, a free run from Day 2, a busy Day 3.
@MainActor
private func reviewedTrip(in context: NSManagedObjectContext) -> (PlanCheck, TripBrief) {
    let trip = makeRome(in: context)
    addItem("Colosseum", to: trip, in: context, day: 0, at: (9, 0), minutes: 180)
    addItem("Borghese Gallery", to: trip, in: context, day: 0, at: (11, 30), minutes: 120)
    for index in 0..<7 {
        addItem("Stop \(index)", to: trip, in: context, day: 2)
    }
    for index in 3..<9 {
        addItem("Walk \(index)", to: trip, in: context, day: index)
    }
    let check = PlanCheck(trip: trip, asOf: beforeTrip)
    return (check, TripBrief(trip: trip, check: check))
}

private func collect(_ stream: AsyncThrowingStream<TripReviewDraft, any Error>) async throws -> [TripReviewDraft] {
    var drafts: [TripReviewDraft] = []
    for try await draft in stream { drafts.append(draft) }
    return drafts
}

@MainActor
@Test func withNoModelTheReviewIsThePlainCheck() throws {
    let context = try makeContext()
    let (check, brief) = reviewedTrip(in: context)

    let review = PlanReview(check: check, brief: brief, draft: nil)

    #expect(review.verdict == nil)
    #expect(review.entries.map(\.id) == check.findings.map(\.id))
    #expect(review.entries.map(\.message) == check.findings.map(\.message))
    #expect(review.entries.allSatisfy { !$0.isWrittenByModel })
}

@MainActor
@Test func theModelsNotesComeFirstInItsOrderAndTheRestFollow() throws {
    let context = try makeContext()
    let (check, brief) = reviewedTrip(in: context)
    #expect(check.findings.map(\.kind) == [.overlap, .emptyDay, .overloaded])

    let draft = TripReviewDraft(
        verdict: "  Day 3 is the problem.  ",
        notes: [
            .init(fact: 3, message: "Day 3 has 7 stops; move one."),
            .init(fact: 3, message: "A repeat of the same fact."),
            .init(fact: 9, message: "A fact that doesn't exist."),
            .init(fact: 1, message: "   "),
        ],
        isComplete: true
    )
    let review = PlanReview(check: check, brief: brief, draft: draft)

    #expect(review.verdict == "Day 3 is the problem.")
    #expect(review.entries.map(\.finding.kind) == [.overloaded, .overlap, .emptyDay])
    #expect(review.entries.map(\.isWrittenByModel) == [true, false, false])
    #expect(review.entries.first?.message == "Day 3 has 7 stops; move one.")
    #expect(review.entries[1].message == check.findings[0].message, "An empty note falls back to the check's words")
    #expect(review.entries.first?.finding.fixes.isEmpty == false, "Fixes are Swift's, whoever wrote the words")
}

@MainActor
@Test func aNoteThatWavesAProblemAwayIsReplacedByTheChecksWords() throws {
    let context = try makeContext()
    let (check, brief) = reviewedTrip(in: context)

    let draft = TripReviewDraft(verdict: "Great plan!", notes: [
        .init(fact: 1, message: "Colosseum and Borghese Gallery — no change needed."),
        .init(fact: 2, message: "Plan unchanged, stays intact."),
    ])
    let review = PlanReview(check: check, brief: brief, draft: draft)

    #expect(review.entries.allSatisfy { !$0.isWrittenByModel })
    #expect(review.entries.map(\.message) == check.findings.map(\.message))
}

/// What the real model wrote on a Mac for the probe's trip: each loses a
/// figure, names no stop, or brings in a stop from another finding.
@MainActor
@Test func aNoteThatLosesTheFiguresOrThePlacesIsReplacedByTheChecksWords() throws {
    let context = try makeContext()
    let (check, brief) = reviewedTrip(in: context)
    let overlap = check.findings[0].message
    #expect(overlap == "Day 1: Colosseum runs 30 min into Borghese Gallery.")

    let unfaithful = [
        "Colosseum and Borghese Gallery on Day 1.",
        "Your two morning visits run into each other by 30 min.",
        "Colosseum runs 30 min into Stop 4.",
        // Every name and figure kept, and backwards.
        "Colosseum ends 30 min before Borghese Gallery starts on Day 1.",
    ]
    for note in unfaithful {
        let review = PlanReview(check: check, brief: brief, draft: TripReviewDraft(notes: [.init(fact: 1, message: note)]))
        #expect(review.entries.first?.message == overlap, "\(note) should have fallen back")
        #expect(review.entries.allSatisfy { !$0.isWrittenByModel })
    }

    let faithful = "Colosseum overruns Borghese Gallery by 30 min; start the gallery later."
    let review = PlanReview(check: check, brief: brief, draft: TripReviewDraft(notes: [.init(fact: 1, message: faithful)]))
    #expect(review.entries.first?.message == faithful)
    #expect(review.entries.first?.isWrittenByModel == true)
}

@Test func figuresAreReadWithoutTheDayNumber() {
    let text = "Day 1: Vatican Museums to Colosseum is 2.3 mi, about 44 min on foot, with 30 min between them."
    #expect(PlanReview.figures(in: text, ignoringDays: true) == ["2.3", "44", "30"])
    #expect(PlanReview.figures(in: text) == ["1", "2.3", "44", "30"])
    #expect(PlanReview.figures(in: "Days 2–7 have nothing planned.", ignoringDays: true).isEmpty)
    #expect(PlanReview.figures(in: "Day 1 has 6 stops, about 9 hr 45 min planned.", ignoringDays: true) == ["6", "9", "45"])
}

@MainActor
@Test func theStubStreamsAVerdictThenANotePerFact() async throws {
    let context = try makeContext()
    let (check, brief) = reviewedTrip(in: context)

    let drafts = try await collect(StubTripAdvisor().review(brief))
    let last = try #require(drafts.last)

    #expect(drafts.first?.verdict == "Stub review: 3 things to look at.")
    #expect(drafts.first?.notes.isEmpty == true)
    #expect(drafts.dropLast().allSatisfy { !$0.isComplete })
    #expect(last.isComplete)
    #expect(last.notes.map(\.fact) == [3, 2, 1])

    let review = PlanReview(check: check, brief: brief, draft: last)
    #expect(review.entries.allSatisfy { $0.isWrittenByModel })
    #expect(review.entries.map(\.finding.kind) == [.overloaded, .emptyDay, .overlap])
}

@MainActor
@Test func aFailingAdvisorEndsTheStreamWithItsError() async throws {
    let context = try makeContext()
    let (_, brief) = reviewedTrip(in: context)

    await #expect(throws: TripAdvisorError.unavailable(.notReady)) {
        _ = try await collect(StubTripAdvisor(failure: .unavailable(.notReady)).review(brief))
    }
    await #expect(throws: TripAdvisorError.unavailable(.unsupportedOS)) {
        _ = try await collect(UnavailableTripAdvisor().review(brief))
    }
    await #expect(throws: TripAdvisorError.unavailable(.deviceNotEligible)) {
        _ = try await UnavailableTripAdvisor(availability: .deviceNotEligible).pickPlaces(candidates: SuggestionCandidates(candidates: []), context: "")
    }
}

@Test func turningItOffWinsOverWhatTheModelSays() {
    #expect(StubTripAdvisor().availability(isEnabled: true) == .available)
    #expect(StubTripAdvisor().availability(isEnabled: false) == .turnedOff)
    #expect(UnavailableTripAdvisor(availability: .notEnabled).availability(isEnabled: false) == .turnedOff)
}

@Test func onlyASwitchableOrWaitingModelGetsAFootnote() {
    #expect(TripAdvisorAvailability.notEnabled.footnote == "Turn on Apple Intelligence in Settings to get a written review.")
    #expect(TripAdvisorAvailability.notReady.footnote == "Getting ready…")
    for quiet: TripAdvisorAvailability in [.available, .deviceNotEligible, .unsupportedOS, .unsupportedLanguage, .turnedOff] {
        #expect(quiet.footnote == nil)
    }
    #expect(TripAdvisorAvailability.available.isAvailable)
    #expect(!TripAdvisorAvailability.turnedOff.isAvailable)
}
