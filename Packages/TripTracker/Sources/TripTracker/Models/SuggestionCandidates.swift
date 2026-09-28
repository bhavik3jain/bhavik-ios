import Core
import Foundation

/// Something already on the trip — planned or saved as an idea — that a
/// suggestion mustn't repeat.
public struct TakenPlace: Sendable, Equatable {
    public let title: String
    public let coordinate: GeoCoordinate?

    public init(title: String, coordinate: GeoCoordinate?) {
        self.title = title
        self.coordinate = coordinate
    }

    public init(item: SharedItineraryItem) {
        self.init(title: item.title, coordinate: item.coordinate)
    }

    /// Every item on the trip, ideas included.
    public static func all(in trip: SharedTrip) -> [TakenPlace] {
        (trip.items ?? []).map(TakenPlace.init(item:))
    }
}

/// A place worth adding, ready for "Add to Ideas".
public struct PlaceSuggestion: Sendable, Equatable, Identifiable {
    public let place: FoundPlace
    /// The model's one line, or "" when it was never asked or failed.
    public let why: String
    /// From the search centre, when there was one.
    public let metres: Double?

    public init(place: FoundPlace, why: String, metres: Double?) {
        self.place = place
        self.why = why
        self.metres = metres
    }

    public var id: String { place.id }
    public var isModelPick: Bool { !why.isEmpty }
}

/// The numbered list the model chooses from. Everything on it is a real place
/// a search returned, near enough, and not already on the trip — the model
/// only picks numbers, so it can't add anything that isn't. The spike's
/// model, given a search tool instead, re-suggested Borghese Gallery, already
/// on Day 1, and when searches came back empty looped ~70 tool calls until it
/// ran out of context.
public struct SuggestionCandidates: Sendable, Equatable {
    public struct Candidate: Sendable, Equatable, Identifiable {
        /// 1-based, as the model sees it.
        public let number: Int
        public let place: FoundPlace
        public let metres: Double?
        public var id: String { place.id }
    }

    /// Two results this close are one place under two names ("Galleria
    /// Borghese" and "Borghese Gallery"), and a result this close to
    /// something on the trip is that thing.
    public static let duplicateMetres = 150.0
    /// Enough to choose from, few enough to keep the prompt small.
    public static let defaultLimit = 12

    public let candidates: [Candidate]

    public var isEmpty: Bool { candidates.isEmpty }
    public var count: Int { candidates.count }

    public init(candidates: [Candidate]) {
        self.candidates = candidates
    }

    /// - Parameters:
    ///   - found: every search's results, in the order they came.
    ///   - taken: what's already on the trip, planned or idea.
    ///   - center: where the searches were centred; nearer comes first.
    ///   - radiusMetres: results farther than this from `center` are dropped.
    public init(
        found: [FoundPlace],
        taken: [TakenPlace],
        center: GeoCoordinate?,
        radiusMetres: Double? = nil,
        limit: Int = defaultLimit
    ) {
        func metres(_ place: FoundPlace) -> Double? { center.map { place.coordinate.distance(to: $0) } }
        var kept: [FoundPlace] = []
        for place in found {
            if let radiusMetres, let distance = metres(place), distance > radiusMetres { continue }
            let isTaken = taken.contains { Self.isSame(place, title: $0.title, coordinate: $0.coordinate) }
            let isRepeat = kept.contains { Self.isSame(place, title: $0.name, coordinate: $0.coordinate) }
            if isTaken || isRepeat { continue }
            kept.append(place)
        }
        let ordered = kept.enumerated().sorted { lhs, rhs in
            let left = metres(lhs.element) ?? .infinity, right = metres(rhs.element) ?? .infinity
            return left != right ? left < right : lhs.offset < rhs.offset
        }
        candidates = ordered.prefix(max(0, limit)).enumerated().map { index, pair in
            Candidate(number: index + 1, place: pair.element, metres: metres(pair.element))
        }
    }

    public func candidate(numbered number: Int) -> Candidate? {
        candidates.indices.contains(number - 1) ? candidates[number - 1] : nil
    }

    /// The model's picks as suggestions: numbers that aren't on the list, and
    /// a number picked twice, are dropped.
    public func resolve(_ picks: [PlacePick]) -> [PlaceSuggestion] {
        var seen = Set<Int>()
        return picks.compactMap { pick in
            guard let candidate = candidate(numbered: pick.number), seen.insert(pick.number).inserted else { return nil }
            let why = pick.why.trimmingCharacters(in: .whitespacesAndNewlines)
            return PlaceSuggestion(place: candidate.place, why: TripBrief.clip(why, to: 160), metres: candidate.metres)
        }
    }

    /// With no model, or when it failed: the nearest few, with no "why".
    public func nearest(_ count: Int) -> [PlaceSuggestion] {
        candidates.prefix(max(0, count)).map { PlaceSuggestion(place: $0.place, why: "", metres: $0.metres) }
    }

    /// "3. Capitoline Museums — Museum, indoor, 650 m away".
    public var promptList: String {
        candidates.map { candidate in
            var about = [candidate.place.category ?? "Place"]
            if let indoor = candidate.place.isIndoor { about.append(indoor ? "indoor" : "outdoor") }
            if let metres = candidate.metres { about.append("\(Int((metres / 50).rounded()) * 50) m away") }
            return "\(candidate.number). \(TripBrief.clip(candidate.place.name)) — \(about.joined(separator: ", "))"
        }
        .joined(separator: "\n")
    }

    // MARK: - Sameness

    /// Case, accents and punctuation don't count; "The" in front doesn't either.
    static func normalized(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let words = folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return (words.first == "the" ? Array(words.dropFirst()) : words).joined(separator: " ")
    }

    /// The same name — or one name's words inside the other's, when the
    /// shorter is long enough to mean something ("Pantheon" in "Pantheon,
    /// Rome", but not "Bar" in every bar) — or within `duplicateMetres`.
    /// Whole words: as plain substrings "Museum 1" swallowed "Museum 10"
    /// through "Museum 19".
    static func isSame(_ place: FoundPlace, title: String, coordinate: GeoCoordinate?) -> Bool {
        let a = normalized(place.name), b = normalized(title)
        if !a.isEmpty, a == b { return true }
        let shorter = a.count <= b.count ? a : b, longer = a.count <= b.count ? b : a
        if shorter.count >= 5, " \(longer) ".contains(" \(shorter) ") { return true }
        if let coordinate, place.coordinate.distance(to: coordinate) < duplicateMetres { return true }
        return false
    }
}

/// What a "Suggest Places" run searches for, where, and what the model is told
/// about the day — all chosen in Swift from the plan, before anything is sent
/// anywhere.
public struct SuggestionRequest: Sendable, Equatable {
    /// The spike's model looped on searches; here Swift runs at most this many
    /// per suggestion run, never per keystroke — MapKit throttles
    /// (`MKError.loadingThrottled`).
    public static let maximumSearches = 3
    /// Around one day's stops: a walk or a short ride from what's planned.
    public static let dayRadiusMetres = 2_500.0
    /// Around the destination when there's no day to centre on.
    public static let tripRadiusMetres = 6_000.0

    /// The day it's for; nil for the trip as a whole.
    public let dayIndex: Int?
    public let center: GeoCoordinate
    public let radiusMetres: Double
    /// One or two plain words each, at most `maximumSearches`.
    public let queries: [String]
    /// What the model is told: destination, day, forecast, what's planned.
    public let context: String
    public let taken: [TakenPlace]

    public init(
        dayIndex: Int?,
        center: GeoCoordinate,
        radiusMetres: Double,
        queries: [String],
        context: String,
        taken: [TakenPlace]
    ) {
        self.dayIndex = dayIndex
        self.center = center
        self.radiusMetres = radiusMetres
        self.queries = Array(queries.prefix(Self.maximumSearches))
        self.context = context
        self.taken = taken
    }

    /// For `day`'s stops — "Find more around Day 3", the Mac inspector's
    /// selected day — or the whole trip when `day` is nil or has no placed
    /// stops. Nil when there is nowhere to search around: no placed stop, no
    /// picked destination.
    public init?(trip: SharedTrip, day: Int?, weather: [DayWeather?] = [], locale: Locale = .current) {
        let dayCenter = day.flatMap { NearbyIdeas.centroid(ofDay: $0, in: trip) }
        let tripCenter: GeoCoordinate? = {
            if let latitude = trip.latitude, let longitude = trip.longitude {
                return GeoCoordinate(latitude: latitude, longitude: longitude)
            }
            return GeoCoordinate.centroid(of: trip.plannedPlaces.compactMap(\.coordinate))
        }()
        guard let center = dayCenter ?? tripCenter else { return nil }

        let dayIndex = day.flatMap { (0..<trip.dates.dayCount).contains($0) ? $0 : nil }
        let stops = dayIndex.map { index in
            DayPlan(trip: trip, dayIndex: index).entries.compactMap { entry -> SharedItineraryItem? in
                if case .item(let item) = entry, PlanCheck.isStop(item) { item } else { nil }
            }
        } ?? []
        let forecast = dayIndex.flatMap { weather.indices.contains($0) ? weather[$0] : nil }
        let isWet = forecast.map(PlanCheck.isWet) ?? false

        var context: [String] = []
        let destination = trip.destination.isEmpty ? trip.title : trip.destination
        context.append("Destination: \(TripBrief.clip(destination)).")
        if let dayIndex {
            context.append("Day \(dayIndex + 1), \(IdeaDays.dayLabel(dayIndex, dates: trip.dates)).")
            if let forecast {
                context.append("Forecast: \(forecast.summary), \(WeatherFormat.temperature(forecast.highCelsius, locale: locale)).")
            }
            if stops.isEmpty {
                context.append("Nothing is planned that day yet.")
            } else {
                let planned = stops.prefix(8).map { "\(TripBrief.clip($0.title)) (\($0.kind.displayName))" }
                context.append("Already planned that day: \(planned.joined(separator: "; ")).")
            }
            context.append(dayCenter == nil ? "Looking for places around the destination." : "Looking for places near that day's stops.")
        } else {
            context.append("Looking for places around the destination for any day of the trip.")
        }

        self.init(
            dayIndex: dayIndex,
            center: center,
            radiusMetres: dayCenter == nil ? Self.tripRadiusMetres : Self.dayRadiusMetres,
            queries: Self.queries(kinds: stops.map(\.kind), isWet: isWet, isWholeTrip: dayIndex == nil),
            context: context.joined(separator: " "),
            taken: TakenPlace.all(in: trip)
        )
    }

    /// What to search for, from what the day lacks and the weather: indoors on
    /// a wet day, somewhere to eat on a day with no food, a sight on a day of
    /// errands. Plain words only.
    public static func queries(kinds: [ItemKind], isWet: Bool, isWholeTrip: Bool = false) -> [String] {
        var queries: [String] = []
        if isWholeTrip {
            queries = ["landmark", "museum", "restaurant"]
        } else if isWet {
            queries = ["museum", kinds.contains(.food) ? "gallery" : "restaurant", "cafe"]
        } else {
            if !kinds.contains(.sight) { queries.append("landmark") }
            if !kinds.contains(.food) { queries.append("restaurant") }
            if !kinds.contains(.activity) { queries.append("park") }
            queries += ["viewpoint", "museum", "cafe"]
        }
        var seen = Set<String>()
        return Array(queries.filter { seen.insert($0).inserted }.prefix(maximumSearches))
    }
}

/// One "Suggest Places" run: Swift searches, Swift filters, the model picks by
/// number and says why, Swift checks the numbers. No tool calling, so nothing
/// can loop.
public enum PlaceSuggester {
    public static let suggestionCount = 3

    public struct Outcome: Sendable, Equatable {
        public let suggestions: [PlaceSuggestion]
        /// How many real places the model had to choose from.
        public let candidateCount: Int
        /// False when these are simply the nearest, with no model involved.
        public let usedModel: Bool
    }

    /// - Parameter advisor: nil — the setting is off, or there is no model —
    ///   gives the nearest candidates without asking any model. Any error from
    ///   it does the same.
    public static func suggest(
        for request: SuggestionRequest,
        searcher: any PlaceSearching,
        advisor: (any TripAdvising)?
    ) async -> Outcome {
        let found = await withTaskGroup(of: (Int, [FoundPlace]).self) { group in
            for (index, query) in request.queries.prefix(SuggestionRequest.maximumSearches).enumerated() {
                group.addTask {
                    // A failed search is just no results for that word; the
                    // others still count.
                    let places = (try? await searcher.search(query, near: request.center, radiusMetres: request.radiusMetres)) ?? []
                    return (index, places)
                }
            }
            var results: [(Int, [FoundPlace])] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        let candidates = SuggestionCandidates(
            found: found,
            taken: request.taken,
            center: request.center,
            radiusMetres: request.radiusMetres * 1.5
        )
        guard !candidates.isEmpty else { return Outcome(suggestions: [], candidateCount: 0, usedModel: false) }

        if let advisor, advisor.availability == .available,
           let picks = try? await advisor.pickPlaces(candidates: candidates, context: request.context) {
            let suggestions = Array(candidates.resolve(picks).prefix(suggestionCount))
            if !suggestions.isEmpty {
                return Outcome(suggestions: suggestions, candidateCount: candidates.count, usedModel: true)
            }
        }
        return Outcome(suggestions: candidates.nearest(suggestionCount), candidateCount: candidates.count, usedModel: false)
    }
}
