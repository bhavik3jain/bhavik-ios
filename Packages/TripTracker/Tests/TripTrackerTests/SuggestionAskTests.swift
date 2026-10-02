import Core
import CoreData
import Foundation
import Synchronization
import Testing
@testable import TripTracker

/// Rome with two placed stops on Day 1 (morning and afternoon), one on Day 2,
/// and things that must never reach the prompt: an unplaced stop, a hotel and
/// a stop's private detail.
@MainActor
private func makePlannedRome(in context: NSManagedObjectContext) -> SharedTrip {
    let trip = makeRome(in: context)
    func place(_ item: SharedItineraryItem, _ latitude: Double, _ longitude: Double) {
        item.latitude = latitude
        item.longitude = longitude
    }
    let vatican = addItem("Vatican Museums", to: trip, in: context, day: 0, at: (9, 0))
    place(vatican, 41.9065, 12.4536)
    vatican.detail = "SECRET-DETAIL"
    place(addItem("Colosseum", to: trip, in: context, day: 0, at: (14, 30), sortOrder: 1), 41.8902, 12.4922)
    addItem("Somewhere unplaced", to: trip, in: context, day: 0, sortOrder: 2)
    place(addItem("Hotel Artemide", to: trip, in: context, day: 0, sortOrder: 3, kind: .lodging), 41.9005, 12.4950)
    place(addItem("Appian Way bike ride", to: trip, in: context, day: 1, at: (10, 0), kind: .activity), 41.8580, 12.5160)
    return trip
}

@MainActor
@Test func theModelSeesEachDaysPlacedStopsNumberedAndNothingPrivate() throws {
    let context = try makeContext()
    let trip = makePlannedRome(in: context)

    let ask = try #require(SuggestionAsk(text: "  coffee this afternoon  ", trip: trip, openDay: 0))

    #expect(ask.text == "coffee this afternoon")
    #expect(ask.stops.map(\.title) == ["Vatican Museums", "Colosseum", "Appian Way bike ride"])
    #expect(ask.stops.map(\.number) == [1, 2, 3], "Numbered across the trip")
    #expect(ask.prompt.contains("1. Vatican Museums (Sight, 09:00); 2. Colosseum (Sight, 14:30)"))
    #expect(ask.prompt.contains("3. Appian Way bike ride (Activity, 10:00)"))
    #expect(ask.prompt.contains("Day 3, \(IdeaDays.dayLabel(2, dates: trip.dates)): no stops with a place yet"))
    #expect(ask.prompt.contains("The traveller is looking at Day 1."))
    #expect(ask.prompt.hasSuffix("Request: coffee this afternoon"))
    for leak in ["SECRET-DETAIL", "Somewhere unplaced", "Hotel Artemide"] {
        #expect(!ask.prompt.contains(leak))
    }
    #expect(SuggestionAsk(text: "   ", trip: trip, openDay: 0) == nil, "Nothing to ask")
}

@MainActor
@Test func pointedStopsCentreTheSearchCloselyOnTheirDay() throws {
    let context = try makeContext()
    let trip = makePlannedRome(in: context)
    let ask = try #require(SuggestionAsk(text: "coffee this afternoon", trip: trip, openDay: 0))

    let resolved = try #require(ask.resolve(AskReading(day: 0, stops: [2], searches: ["coffee"]), trip: trip))

    #expect(resolved.request.dayIndex == 0)
    #expect(resolved.request.center == GeoCoordinate(latitude: 41.8902, longitude: 12.4922))
    #expect(resolved.request.radiusMetres == SuggestionAsk.stopRadiusMetres)
    #expect(resolved.request.queriesByGroup == [.asked: ["coffee"]])
    #expect(resolved.request.groups == [.asked], "One list, in place of the usual two")
    #expect(resolved.request.context.contains("The traveller asked: \"coffee this afternoon\"."))
    #expect(resolved.request.context.contains("Looking near: Colosseum."))
    #expect(resolved.summary.hasPrefix("Searched for “coffee” near Colosseum on Day 1"))
}

@MainActor
@Test func stopsAloneSayWhichDayButANamedDayWins() throws {
    let context = try makeContext()
    let trip = makePlannedRome(in: context)
    let ask = try #require(SuggestionAsk(text: "sights near the bike ride", trip: trip, openDay: 0))

    let byStop = try #require(ask.resolve(AskReading(day: 0, stops: [3], searches: ["landmark"]), trip: trip))
    #expect(byStop.request.dayIndex == 1, "The bike ride is on Day 2")
    #expect(byStop.request.center == GeoCoordinate(latitude: 41.8580, longitude: 12.5160))

    // Day 1 named, Day 2's stop pointed at: the day stands, the stop goes,
    // and the search spreads around Day 1's stops.
    let named = try #require(ask.resolve(AskReading(day: 1, stops: [3], searches: ["landmark"]), trip: trip))
    #expect(named.request.dayIndex == 0)
    #expect(named.request.radiusMetres == SuggestionRequest.dayRadiusMetres)
    #expect(named.request.center == NearbyIdeas.centroid(ofDay: 0, in: trip))
    #expect(!named.request.context.contains("Looking near"))
}

@MainActor
@Test func madeUpNumbersLeaveTheOpenDay() throws {
    let context = try makeContext()
    let trip = makePlannedRome(in: context)

    let onDay = try #require(SuggestionAsk(text: "bakeries", trip: trip, openDay: 1))
    let resolved = try #require(onDay.resolve(AskReading(day: 99, stops: [-3, 400], searches: ["bakery"]), trip: trip))
    #expect(resolved.request.dayIndex == 1)
    #expect(resolved.request.center == GeoCoordinate(latitude: 41.8580, longitude: 12.5160))

    let whole = try #require(SuggestionAsk(text: "bakeries", trip: trip, openDay: nil))
    let wide = try #require(whole.resolve(AskReading(day: 0, stops: [], searches: ["bakery"]), trip: trip))
    #expect(wide.request.dayIndex == nil)
    #expect(wide.request.radiusMetres == SuggestionRequest.tripRadiusMetres)
    #expect(wide.summary == "Searched for “bakery” around Rome, Italy.")
}

@Test func searchesAreCutToPlainShortWords() {
    #expect(SuggestionAsk.searches(from: ["Coffee Shops near Colosseum", "coffee shops", "Café!", "", "bakery", "bar"])
        == ["coffee shops", "café", "bakery"])
    #expect(SuggestionAsk.searches(from: ["???", "  ", "12:00"]).isEmpty)
}

@MainActor
@Test func aReadingWithNoUsableSearchIsNoRequest() throws {
    let context = try makeContext()
    let trip = makePlannedRome(in: context)
    let ask = try #require(SuggestionAsk(text: "something nice", trip: trip, openDay: 0))

    #expect(ask.resolve(AskReading(day: 0, stops: [1], searches: ["???"]), trip: trip) == nil)
}

@MainActor
@Test func aRequestRunSearchesOnlyWhatWasAskedAndFillsOneList() async throws {
    let context = try makeContext()
    let trip = makePlannedRome(in: context)
    let ask = try #require(SuggestionAsk(text: "find me some coffee", trip: trip, openDay: 0))
    let advisor = StubTripAdvisor()

    let reading = try await advisor.readAsk(ask)
    #expect(reading == AskReading(day: 0, stops: [], searches: ["coffee"]))
    let resolved = try #require(ask.resolve(reading, trip: trip))

    let searched = Mutex<[String]>([])
    let searcher = StubPlaceSearcher(onSearch: { query in searched.withLock { $0.append(query) } })
    let outcome = await PlaceSuggester.suggest(for: resolved.request, searcher: searcher, advisor: advisor)

    #expect(searched.withLock(\.self) == ["coffee"])
    #expect(outcome.sections.map(\.group) == [.asked])
    #expect(outcome.usedModel)
    #expect(!outcome.suggestions.isEmpty)
}

@MainActor
@Test func aFailingOrMissingModelThrowsInsteadOfReading() async throws {
    let context = try makeContext()
    let ask = try #require(SuggestionAsk(text: "coffee", trip: makePlannedRome(in: context), openDay: 0))

    await #expect(throws: TripAdvisorError.unavailable(.notReady)) {
        try await StubTripAdvisor(failure: .unavailable(.notReady)).readAsk(ask)
    }
    await #expect(throws: TripAdvisorError.unavailable(.turnedOff)) {
        try await UnavailableTripAdvisor(availability: .turnedOff).readAsk(ask)
    }
}

@MainActor
@Test func aRequestTheModelCantReadIsNoRunAtAll() async throws {
    let context = try makeContext()
    let trip = makePlannedRome(in: context)
    let searched = Mutex<[String]>([])
    let searcher = StubPlaceSearcher(onSearch: { query in searched.withLock { $0.append(query) } })

    let asked = await PlaceSuggester.suggest(
        asking: "coffee", trip: trip, openDay: 0, weather: [], searcher: searcher, advisor: StubTripAdvisor()
    )
    #expect(asked?.outcome.sections.map(\.group) == [.asked])
    #expect(asked?.summary.hasPrefix("Searched for “coffee”") == true)

    searched.withLock { $0.removeAll() }
    let failed = await PlaceSuggester.suggest(
        asking: "coffee", trip: trip, openDay: 0, weather: [], searcher: searcher,
        advisor: StubTripAdvisor(failure: .unavailable(.notReady))
    )
    #expect(failed == nil)
    let empty = await PlaceSuggester.suggest(asking: "  ", trip: trip, openDay: 0, weather: [], searcher: searcher, advisor: StubTripAdvisor())
    #expect(empty == nil)
    #expect(searched.withLock(\.self).isEmpty, "Nothing searched for a request that never became one")
}
