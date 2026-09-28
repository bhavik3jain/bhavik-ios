import Core
import CoreData
import Foundation
import Synchronization
import Testing
@testable import TripTracker

private let rome = GeoCoordinate(latitude: 41.9, longitude: 12.48)

private func place(_ name: String, _ latitude: Double, _ longitude: Double, category: String? = "Museum") -> FoundPlace {
    FoundPlace(name: name, category: category, latitude: latitude, longitude: longitude, address: "\(name) street")
}

// MARK: - Candidates

@Test func theSamePlaceUnderTwoSpellingsIsOneCandidate() {
    let candidates = SuggestionCandidates(
        found: [
            place("Caffè Greco", 41.9056, 12.4811, category: "Cafe"),
            place("caffe greco", 41.9100, 12.4700, category: "Cafe"),
            place("The Pantheon", 41.8986, 12.4769),
            place("Pantheon", 41.8990, 12.4700),
        ],
        taken: [],
        center: rome
    )

    #expect(candidates.candidates.map(\.place.name).sorted() == ["Caffè Greco", "The Pantheon"])
}

@Test func placesWithin150MetresAreOnePlace() {
    let candidates = SuggestionCandidates(
        found: [
            place("Musei Vaticani", 41.9065, 12.4536),
            // ~90 m away, another name for the same door.
            place("Vatican Museums entrance", 41.9070, 12.4545),
            // ~1 km away: a different place.
            place("Castel Sant'Angelo", 41.9031, 12.4663),
        ],
        taken: [],
        center: rome
    )

    #expect(candidates.candidates.map(\.place.name).sorted() == ["Castel Sant'Angelo", "Musei Vaticani"])
}

@Test func whatsAlreadyOnTheTripIsNeverACandidate() {
    let candidates = SuggestionCandidates(
        found: [
            // Planned as "Borghese Gallery" — a different name, the same building.
            place("Galleria Borghese", 41.9142, 12.4923),
            // Saved as an idea with no place, matched by name.
            place("Giolitti", 41.9009, 12.4766, category: "Cafe"),
            place("Capitoline Museums", 41.8933, 12.4829),
        ],
        taken: [
            TakenPlace(title: "Borghese Gallery", coordinate: GeoCoordinate(latitude: 41.9143, longitude: 12.4925)),
            TakenPlace(title: "Gelato at Giolitti", coordinate: nil),
        ],
        center: rome
    )

    #expect(candidates.candidates.map(\.place.name) == ["Capitoline Museums"])
}

@Test func aShortNameInsideALongOneIsNotAMatch() {
    #expect(!SuggestionCandidates.isSame(place("Bar del Fico", 41.9, 12.47), title: "Bar", coordinate: nil))
    #expect(SuggestionCandidates.isSame(place("Pantheon, Rome", 41.9, 12.47), title: "Pantheon", coordinate: nil))
    // Whole words only: "Museum 1" isn't "Museum 19", nor "Roma" "Romanoff".
    #expect(!SuggestionCandidates.isSame(place("Museum 19", 41.9, 12.47), title: "Museum 1", coordinate: nil))
    #expect(!SuggestionCandidates.isSame(place("Romanoff Bistro", 41.9, 12.47), title: "Roman", coordinate: nil))
    #expect(SuggestionCandidates.normalized("The Café  de Paris!") == "cafe de paris")
}

@Test func candidatesAreNumberedNearestFirstAndCapped() {
    let found = (0..<20).map { index in place("Museum \(index)", rome.latitude + Double(20 - index) * 0.002, rome.longitude) }

    let candidates = SuggestionCandidates(found: found, taken: [], center: rome, limit: 5)

    #expect(candidates.count == 5)
    #expect(candidates.candidates.map(\.number) == [1, 2, 3, 4, 5])
    #expect(candidates.candidates.map(\.place.name) == ["Museum 19", "Museum 18", "Museum 17", "Museum 16", "Museum 15"])
    #expect(candidates.candidates.map { $0.metres ?? 0 } == candidates.candidates.map { $0.metres ?? 0 }.sorted())
}

@Test func placesPastTheRadiusAreDropped() {
    let candidates = SuggestionCandidates(
        found: [place("Near", 41.901, 12.48), place("Boston museum", 42.36, -71.06)],
        taken: [],
        center: rome,
        radiusMetres: 3_000
    )
    #expect(candidates.candidates.map(\.place.name) == ["Near"])
}

@Test func picksOutOfRangeOrRepeatedAreDropped() {
    let candidates = SuggestionCandidates(
        found: [place("A", 41.901, 12.48), place("B", 41.905, 12.48), place("C", 41.91, 12.48)],
        taken: [],
        center: rome
    )

    let suggestions = candidates.resolve([
        PlacePick(number: 0, why: "Zero isn't a number on the list"),
        PlacePick(number: 2, why: "  A fine gallery.  "),
        PlacePick(number: 99, why: "Nor is 99"),
        PlacePick(number: 2, why: "Twice"),
        PlacePick(number: 1, why: "Close by."),
    ])

    #expect(suggestions.map(\.place.name) == ["B", "A"])
    #expect(suggestions.map(\.why) == ["A fine gallery.", "Close by."])
    #expect(suggestions.allSatisfy { $0.isModelPick })
    #expect(candidates.nearest(2).map(\.place.name) == ["A", "B"])
    #expect(candidates.nearest(2).allSatisfy { !$0.isModelPick })
}

@Test func theModelSeesNumberNameCategoryAndDistance() {
    let candidates = SuggestionCandidates(
        found: [place("Capitoline Museums", 41.9033, 12.48), place("Parco del Colle Oppio", 41.91, 12.48, category: "Park")],
        taken: [],
        center: rome
    )

    let lines = candidates.promptList.components(separatedBy: "\n")
    #expect(lines.count == 2)
    #expect(lines[0].hasPrefix("1. Capitoline Museums — Museum, "))
    #expect(!lines[0].contains("indoor"), "The word led every reason the model wrote")
    #expect(lines[0].hasSuffix(" m away"))
    #expect(lines[1].hasPrefix("2. Parco del Colle Oppio — Park, outdoor, "))
}

// MARK: - Places

@Test func mapKitCategoriesReadAsWordsAndKinds() {
    #expect(FoundPlace.categoryName(fromRawValue: "MKPOICategoryNationalPark") == "National Park")
    #expect(FoundPlace.categoryName(fromRawValue: "MKPOICategoryMuseum") == "Museum")
    #expect(FoundPlace.categoryName(fromRawValue: "MKPOICategoryATM") == "ATM")
    #expect(FoundPlace.kind(forCategory: "Museum") == .sight)
    #expect(FoundPlace.kind(forCategory: "Food Market") == .food)
    #expect(FoundPlace.kind(forCategory: "National Park") == .activity)
    #expect(FoundPlace.kind(forCategory: "Gas Station") == .other)
    #expect(FoundPlace.kind(forCategory: nil) == .other)
    #expect(FoundPlace.isIndoor(category: "Cafe") == true)
    #expect(FoundPlace.isIndoor(category: "Beach") == false)
    #expect(FoundPlace.isIndoor(category: "Gas Station") == nil)
}

// MARK: - What to search for

@Test func eachListSearchesForWhatTheDayLacksAndTheWeather() {
    #expect(SuggestionRequest.queries(for: .food, kinds: [], isWet: false) == ["restaurant", "cafe", "bakery"])
    #expect(SuggestionRequest.queries(for: .food, kinds: [.food], isWet: true) == ["restaurant", "cafe", "bakery"])
    #expect(SuggestionRequest.queries(for: .sights, kinds: [], isWet: true) == ["museum", "gallery", "landmark"], "Indoors when it rains")
    #expect(SuggestionRequest.queries(for: .sights, kinds: [.sight, .sight], isWet: false) == ["park", "viewpoint", "museum"])
    #expect(SuggestionRequest.queries(for: .sights, kinds: [.food], isWet: false) == ["landmark", "park", "viewpoint"])
    #expect(SuggestionRequest.queries(for: .sights, kinds: [.sight, .activity], isWet: false) == ["viewpoint", "museum", "landmark"])
    #expect(SuggestionRequest.queries(for: .sights, kinds: [], isWet: false, isWholeTrip: true) == ["landmark", "museum", "park"])
    for group in SuggestionGroup.allCases {
        for query in SuggestionRequest.queries(for: group, kinds: [], isWet: true) {
            #expect(query.split(separator: " ").count <= 2, "Long queries return nothing from MapKit")
        }
    }
}

@MainActor
@Test func aDaysRequestCentresOnItsStopsAndSaysWhatsPlanned() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let picnic = addItem("Villa Borghese picnic", to: trip, in: context, day: 1, kind: .activity)
    picnic.latitude = 41.9128
    picnic.longitude = 12.4852
    picnic.detail = "SECRET-DETAIL"
    let rain = DayWeather(date: day(6, 7), highCelsius: 19, lowCelsius: 14, symbolName: "cloud.rain.fill", summary: "Rain")

    let request = try #require(SuggestionRequest(trip: trip, day: 1, weather: [nil, rain], locale: Locale(identifier: "en_GB")))

    #expect(request.dayIndex == 1)
    #expect(request.center == GeoCoordinate(latitude: 41.9128, longitude: 12.4852))
    #expect(request.radiusMetres == SuggestionRequest.dayRadiusMetres)
    #expect(request.queriesByGroup[.sights] == ["museum", "gallery", "landmark"], "Rain: indoors")
    #expect(request.queriesByGroup[.food] == ["restaurant", "cafe", "bakery"])
    #expect(request.context.contains("Destination: Rome, Italy."))
    #expect(request.context.contains("Forecast: Rain, 19°."))
    #expect(request.context.contains("Already planned that day: Villa Borghese picnic (Activity)."))
    #expect(!request.context.contains("SECRET-DETAIL"))
    #expect(request.taken.map(\.title) == ["Villa Borghese picnic"])
}

@MainActor
@Test func aDayWithNoPlacedStopsSearchesAroundTheDestination() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)

    let request = try #require(SuggestionRequest(trip: trip, day: 3))
    #expect(request.center == GeoCoordinate(latitude: 41.9, longitude: 12.5))
    #expect(request.radiusMetres == SuggestionRequest.tripRadiusMetres)
    #expect(request.context.contains("Nothing is planned that day yet."))

    let whole = try #require(SuggestionRequest(trip: trip, day: nil))
    #expect(whole.dayIndex == nil)
    #expect(whole.queriesByGroup[.sights] == ["landmark", "museum", "park"])

    trip.latitude = nil
    trip.longitude = nil
    #expect(SuggestionRequest(trip: trip, day: 3) == nil, "Nowhere to search around")
}

// MARK: - A whole run

private let request = SuggestionRequest(
    dayIndex: 1,
    center: rome,
    radiusMetres: SuggestionRequest.dayRadiusMetres,
    queries: [.food: ["restaurant", "cafe", "bakery", "bar"], .sights: ["museum", "park", "landmark", "viewpoint"]],
    context: "Destination: Rome, Italy.",
    taken: [TakenPlace(title: "Museum 1", coordinate: nil)]
)

@Test func aRunFillsAFoodListAndAPlacesListEachPickedFromWhatsLeft() async {
    let searched = Mutex<[String]>([])
    let searcher = StubPlaceSearcher(onSearch: { query in searched.withLock { $0.append(query) } })

    let outcome = await PlaceSuggester.suggest(for: request, searcher: searcher, advisor: StubTripAdvisor())

    #expect(searched.withLock { $0.sorted() } == ["bakery", "cafe", "landmark", "museum", "park", "restaurant"], "Three a list, never the fourth")
    #expect(outcome.sections.map(\.group) == [.food, .sights])
    #expect(outcome.usedModel)
    for section in outcome.sections {
        #expect(section.suggestions.count == PlaceSuggester.suggestionCount)
        #expect(section.suggestions.allSatisfy { $0.why.hasPrefix("Stub pick") })
    }
    let food = outcome.sections[0].suggestions, sights = outcome.sections[1].suggestions
    #expect(food.allSatisfy { $0.place.kind == .food }, "No museum among the food")
    #expect(!sights.contains { $0.place.kind == .food }, "No restaurant among the sights")
    #expect(!outcome.suggestions.contains { $0.place.name == "Museum 1" }, "Already on the trip")
    #expect(Set(outcome.suggestions.map(\.id)).count == outcome.suggestions.count, "A place is on one list only")
}

@Test func withNoModelTheNearestCandidatesStandIn() async {
    let outcome = await PlaceSuggester.suggest(for: request, searcher: StubPlaceSearcher(), advisor: nil)

    #expect(!outcome.usedModel)
    #expect(outcome.sections.map(\.suggestions.count) == [PlaceSuggester.suggestionCount, PlaceSuggester.suggestionCount])
    #expect(outcome.suggestions.allSatisfy { $0.why.isEmpty })
    for section in outcome.sections {
        let metres = section.suggestions.map { $0.metres ?? 0 }
        #expect(metres == metres.sorted(), "Nearest first")
    }
}

@Test func aFailingOrUnavailableModelFallsBackToTheNearest() async {
    let failing = await PlaceSuggester.suggest(
        for: request,
        searcher: StubPlaceSearcher(),
        advisor: StubTripAdvisor(failure: .unavailable(.notReady))
    )
    #expect(!failing.usedModel)
    #expect(failing.suggestions.count == 2 * PlaceSuggester.suggestionCount)

    let notReady = await PlaceSuggester.suggest(
        for: request,
        searcher: StubPlaceSearcher(),
        advisor: StubTripAdvisor(availability: .notReady)
    )
    #expect(!notReady.usedModel, "A model that isn't ready is never asked")
}

private struct WildGuesser: TripAdvising {
    let availability = TripAdvisorAvailability.available
    func prewarm() {}
    func review(_ brief: TripBrief) -> AsyncThrowingStream<TripReviewDraft, any Error> { AsyncThrowingStream { $0.finish() } }
    func pickPlaces(candidates: SuggestionCandidates, context: String) async throws -> [PlacePick] {
        [PlacePick(number: 40, why: "Made up"), PlacePick(number: -1, why: "Also made up")]
    }
}

@Test func picksThatArentOnTheListFallBackToTheNearest() async {
    let outcome = await PlaceSuggester.suggest(for: request, searcher: StubPlaceSearcher(), advisor: WildGuesser())

    #expect(!outcome.usedModel)
    #expect(outcome.suggestions.count == 2 * PlaceSuggester.suggestionCount)
    #expect(!outcome.suggestions.contains { $0.why == "Made up" })
}

@Test func nothingFoundIsNoSuggestions() async {
    let outcome = await PlaceSuggester.suggest(for: request, searcher: StubPlaceSearcher(results: [:]), advisor: StubTripAdvisor())

    #expect(outcome.suggestions.isEmpty)
    #expect(outcome.candidateCount == 0)
}
