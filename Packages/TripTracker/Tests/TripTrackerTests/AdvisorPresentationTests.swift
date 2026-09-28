import Core
import CoreData
import Foundation
import Testing
@testable import TripTracker

// MARK: - What shows, by availability

@Test func turnedOffShowsNothingOfTheModel() {
    let advisor = StubTripAdvisor(availability: .available)
    let availability = advisor.availability(isEnabled: false)

    #expect(availability == .turnedOff)
    #expect(!availability.offersAssistant, "No Suggest Places, no verdict")
    #expect(ReviewHeadline(availability: availability, phase: .waiting, verdict: nil) == .none)
    #expect(ReviewHeadline(availability: availability, phase: .finished, verdict: "Looks good.") == .none,
            "A verdict left over from before the switch never shows")
}

@Test func onlyAModelThatRunsOrSoonCouldOffersTheAssistant() {
    #expect(TripAdvisorAvailability.available.offersAssistant)
    #expect(TripAdvisorAvailability.notEnabled.offersAssistant)
    #expect(TripAdvisorAvailability.notReady.offersAssistant)
    #expect(!TripAdvisorAvailability.deviceNotEligible.offersAssistant)
    #expect(!TripAdvisorAvailability.unsupportedOS.offersAssistant)
    #expect(!TripAdvisorAvailability.unsupportedLanguage.offersAssistant)
    #expect(!TripAdvisorAvailability.turnedOff.offersAssistant)
}

@Test func settingsHidesTheSwitchOnlyWhereTheModelCanNeverRun() {
    #expect(!TripAdvisorAvailability.deviceNotEligible.showsSetting)
    #expect(!TripAdvisorAvailability.unsupportedOS.showsSetting)
    for availability in [TripAdvisorAvailability.available, .notEnabled, .notReady, .unsupportedLanguage, .turnedOff] {
        #expect(availability.showsSetting, "\(availability)")
    }
}

// MARK: - The review's headline

@Test func theHeadlineWaitsThenStreamsThenSettles() {
    #expect(ReviewHeadline(availability: .available, phase: .waiting, verdict: nil) == .writing)
    #expect(ReviewHeadline(availability: .available, phase: .streaming, verdict: "  ") == .writing)
    #expect(ReviewHeadline(availability: .available, phase: .streaming, verdict: "Day 1 is") == .verdict("Day 1 is", isFinal: false))
    #expect(ReviewHeadline(availability: .available, phase: .finished, verdict: " Day 1 is packed. ") == .verdict("Day 1 is packed.", isFinal: true))
    #expect(ReviewHeadline(availability: .available, phase: .finished, verdict: nil) == .none)
}

@Test func aFailedReviewShowsNoHeadlineAtAll() {
    // The plan check below it is complete on its own; never an alert, never
    // a half-written verdict.
    #expect(ReviewHeadline(availability: .available, phase: .failed, verdict: "Day 1 is") == .none)
}

@Test func aModelThatCantRunYetGetsItsQuietFootnote() {
    #expect(ReviewHeadline(availability: .notEnabled, phase: .waiting, verdict: nil)
        == .footnote("Turn on Apple Intelligence in Settings to get a written review."))
    #expect(ReviewHeadline(availability: .notReady, phase: .waiting, verdict: nil) == .footnote("Getting ready…"))
    #expect(ReviewHeadline(availability: .deviceNotEligible, phase: .waiting, verdict: nil) == .none, "No nag")
    #expect(ReviewHeadline(availability: .unsupportedOS, phase: .waiting, verdict: nil) == .none, "No nag")
}

// MARK: - Suggestions

@Test func theSuggestionsNoteSaysWhoChose() {
    #expect(SuggestionsNote.footer(usedModel: true, availability: .available).contains("Apple Intelligence"))
    #expect(SuggestionsNote.footer(usedModel: true, availability: .available).contains("check opening hours"))
    #expect(SuggestionsNote.footer(usedModel: false, availability: .available) == "The nearest places from Apple Maps.")
    #expect(SuggestionsNote.footer(usedModel: false, availability: .notEnabled).contains("Turn on Apple Intelligence"))
    #expect(SuggestionsNote.footer(usedModel: false, availability: .turnedOff) == "The nearest places from Apple Maps.",
            "Turned off by the person: no mention of the model")
    #expect(SuggestionsNote.progress(availability: .turnedOff) == "Finding places…")
}

@Test func aSuggestionsDetailIsItsCategoryAndDistance() {
    let place = FoundPlace(name: "Capitoline Museums", category: "Museum", latitude: 41.8933, longitude: 12.4829)
    // Distances in the locale's road units, as Nearby shows them — en_GB
    // gives miles, which a hard-coded "650 m" got wrong.
    let locale = Locale(identifier: "en_GB")
    let distance = WalkingEstimate(metres: 650).distanceText(locale: locale)
    #expect(SuggestionsNote.detail(for: PlaceSuggestion(place: place, why: "", metres: 650), locale: locale) == "Museum · \(distance)")
    let bare = FoundPlace(name: "Somewhere", category: nil, latitude: 41.9, longitude: 12.5)
    #expect(SuggestionsNote.detail(for: PlaceSuggestion(place: bare, why: "", metres: nil)).isEmpty)
}

@MainActor
@Test func suggestionScopesAreTheTripThenEachPlacedDay() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Colosseum", to: trip, in: context, day: 2, placed: true)
    addItem("Unplaced", to: trip, in: context, day: 4)
    addItem("An idea", to: trip, in: context, day: SharedItineraryItem.unassignedDayIndex, placed: true)

    #expect(SuggestionScope.choices(for: trip) == [.trip, .day(2)])
    // A screen opened on Day 5 keeps it, so its picker never shows blank.
    #expect(SuggestionScope.choices(for: trip, keeping: .day(4)) == [.trip, .day(2), .day(4)])
    #expect(SuggestionScope.trip.title(for: trip) == "Around Rome, Italy")
    #expect(SuggestionScope.day(2).title(for: trip).hasPrefix("Near Day 3 · "))
    #expect(SuggestionScope.day(2).dayIndex == 2)
    #expect(SuggestionScope.trip.dayIndex == nil)
}

@MainActor
@Test func aSuggestionAlreadyOnTheTripIsFoundWhereverItIs() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let suggestion = PlaceSuggestion(
        place: FoundPlace(name: "Capitoline Museums", category: "Museum", latitude: 41.8933, longitude: 12.4829),
        why: "",
        metres: nil
    )
    #expect(SharedItineraryItem.existing(suggestion, in: trip) == nil)

    let added = SharedItineraryItem.add(suggestion, to: trip, in: context, day: 3)
    #expect(SharedItineraryItem.existing(suggestion, in: trip) === added)
    #expect(added.dayIndex == 3)
}

// MARK: - The review, a day at a time

@MainActor
@Test func theReviewIsGroupedByDayKeepingTheModelsOrderWithin() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Colosseum", to: trip, in: context, day: 0, at: (9, 0), minutes: 180)
    addItem("Borghese Gallery", to: trip, in: context, day: 0, at: (11, 30), minutes: 120)
    for index in 0..<7 {
        addItem("Stop \(index)", to: trip, in: context, day: 2)
    }
    let check = PlanCheck(trip: trip, asOf: day(6, 1))
    let brief = TripBrief(trip: trip, check: check)
    // The model ranks the last fact first.
    let last = try #require(brief.facts.last)
    let draft = TripReviewDraft(verdict: "Busy.", notes: [.init(fact: last.number, message: "Stub")], isComplete: true)

    let review = PlanReview(check: check, brief: brief, draft: draft)
    let days = review.days

    #expect(days.map(\.dayIndex) == days.map(\.dayIndex).sorted(), "Days in order, whatever the model ranked first")
    #expect(Set(days.flatMap(\.entries).map(\.id)) == Set(check.findings.map(\.id)), "Every finding, once")
    for group in days {
        #expect(group.entries.allSatisfy { $0.finding.dayIndex == group.dayIndex })
        let order = review.entries.filter { $0.finding.dayIndex == group.dayIndex }.map(\.id)
        #expect(group.entries.map(\.id) == order)
    }
}
