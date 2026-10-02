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

    /// "3. Capitoline Museums — Museum, 650 m away". No "indoor"/"outdoor":
    /// a wet day's searches already look indoors, and with the word on every
    /// line the small model began every reason with it — ten picks, ten
    /// "Indoor dining…", one of them for an open-air archaeological park.
    public var promptList: String {
        candidates.map { candidate in
            var about = [candidate.place.category ?? "Place"]
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

/// The two lists "Suggest Places" shows: somewhere to eat and drink, and
/// somewhere to go. One list of three mixed the two and ran out fast — a
/// restaurant crowded out the only sight, and the traveller asked for "more
/// options, broken up by food and places to check out".
///
/// Plus `asked`: the one list a typed request gets (`SuggestionAsk`) in their
/// place. "Bookshops" belongs on neither of the other two, and a café found
/// for "coffee" shouldn't sit under a heading the person never asked for.
public enum SuggestionGroup: String, Sendable, Identifiable {
    case food
    case sights
    case asked

    /// The lists an ordinary run fills, in the order they're shown.
    public static let standard: [SuggestionGroup] = [.food, .sights]
    /// Every list in the order a run fills and shows them: what a place is
    /// found for first goes on the earlier list only.
    static let order: [SuggestionGroup] = [.asked, .food, .sights]

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .food: "Food & Drink"
        case .sights: "Places to Check Out"
        case .asked: "For Your Request"
        }
    }

    public var symbolName: String {
        switch self {
        case .food: "fork.knife"
        case .sights: "binoculars"
        case .asked: "sparkle.magnifyingglass"
        }
    }

    /// Added to the model's context: which list it's picking for.
    var modelContext: String {
        switch self {
        case .food: "Pick places to eat or drink."
        case .sights: "Pick sights and things to do, not places to eat."
        case .asked: "Pick the places that best match what the traveller asked for."
        }
    }

    /// Whether a found place belongs on this list. A search word brings back
    /// its neighbours too — "landmark" found a trattoria on the piazza — so
    /// a place goes where its own category says, and one Apple Maps gives
    /// no category stays with the search that found it.
    func admits(_ place: FoundPlace) -> Bool {
        switch self {
        case .food: place.kind != .sight && place.kind != .activity
        case .sights: place.kind != .food
        case .asked: true
        }
    }
}

/// What a "Suggest Places" run searches for, where, and what the model is told
/// about the day — all chosen in Swift from the plan, before anything is sent
/// anywhere.
public struct SuggestionRequest: Sendable, Equatable {
    /// The spike's model looped on searches; here Swift runs at most this many
    /// per list per suggestion run, never per keystroke — MapKit throttles
    /// (`MKError.loadingThrottled`), and six a run is well inside it.
    public static let maximumSearchesPerGroup = 3
    public static var maximumSearches: Int { maximumSearchesPerGroup * SuggestionGroup.standard.count }
    /// Around one day's stops: a walk or a short ride from what's planned.
    public static let dayRadiusMetres = 2_500.0
    /// Around the destination when there's no day to centre on.
    public static let tripRadiusMetres = 6_000.0

    /// The day it's for; nil for the trip as a whole.
    public let dayIndex: Int?
    public let center: GeoCoordinate
    public let radiusMetres: Double
    /// One or two plain words each, at most `maximumSearchesPerGroup` a list.
    public let queriesByGroup: [SuggestionGroup: [String]]
    /// The lists this run fills, in `SuggestionGroup.order`.
    public var groups: [SuggestionGroup] { SuggestionGroup.order.filter { !(queriesByGroup[$0] ?? []).isEmpty } }
    /// Every search, food first.
    public var queries: [String] { groups.flatMap { queriesByGroup[$0] ?? [] } }
    /// What the model is told: destination, day, forecast, what's planned.
    public let context: String
    public let taken: [TakenPlace]

    public init(
        dayIndex: Int?,
        center: GeoCoordinate,
        radiusMetres: Double,
        queries: [SuggestionGroup: [String]],
        context: String,
        taken: [TakenPlace]
    ) {
        self.dayIndex = dayIndex
        self.center = center
        self.radiusMetres = radiusMetres
        self.queriesByGroup = queries.mapValues { Array($0.prefix(Self.maximumSearchesPerGroup)) }
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
            queries: Dictionary(uniqueKeysWithValues: SuggestionGroup.standard.map { group in
                (group, Self.queries(for: group, kinds: stops.map(\.kind), isWet: isWet, isWholeTrip: dayIndex == nil))
            }),
            context: context.joined(separator: " "),
            taken: TakenPlace.all(in: trip)
        )
    }

    /// What to search for on each list, from what the day lacks and the
    /// weather: indoors on a wet day, a sight on a day of errands, somewhere
    /// green on a day with nothing outside. Plain words only — long phrases
    /// return nothing from Apple Maps.
    public static func queries(for group: SuggestionGroup, kinds: [ItemKind], isWet: Bool, isWholeTrip: Bool = false) -> [String] {
        var queries: [String]
        switch group {
        case .asked:
            // Only ever what the person asked for — `SuggestionAsk` sets them.
            return []
        case .food:
            queries = isWet ? ["restaurant", "cafe", "bakery"] : ["restaurant", "cafe", "bakery", "bar"]
        case .sights:
            if isWholeTrip {
                queries = ["landmark", "museum", "park"]
            } else if isWet {
                queries = ["museum", "gallery", "landmark"]
            } else {
                queries = []
                if !kinds.contains(.sight) { queries.append("landmark") }
                if !kinds.contains(.activity) { queries.append("park") }
                queries += ["viewpoint", "museum", "landmark", "gallery"]
            }
        }
        var seen = Set<String>()
        return Array(queries.filter { seen.insert($0).inserted }.prefix(maximumSearchesPerGroup))
    }
}

/// One "Suggest Places" run: Swift searches, Swift filters, the model picks by
/// number and says why, Swift checks the numbers — once per list. No tool
/// calling, so nothing can loop.
public enum PlaceSuggester {
    /// Per list. Three in all left almost nothing to choose between.
    public static let suggestionCount = 5

    public struct Section: Sendable, Equatable, Identifiable {
        public let group: SuggestionGroup
        public let suggestions: [PlaceSuggestion]
        /// How many real places the model had to choose from for this list.
        public let candidateCount: Int
        /// False when these are simply the nearest, with no model involved.
        public let usedModel: Bool

        public var id: SuggestionGroup { group }
    }

    public struct Outcome: Sendable, Equatable {
        /// Food first, then places to check out; a list with nothing is left out.
        public let sections: [Section]

        public init(sections: [Section]) {
            self.sections = sections.filter { !$0.suggestions.isEmpty }
        }

        public var suggestions: [PlaceSuggestion] { sections.flatMap(\.suggestions) }
        public var candidateCount: Int { sections.reduce(0) { $0 + $1.candidateCount } }
        /// Whether the model picked any of the lists.
        public var usedModel: Bool { sections.contains(where: \.usedModel) }
    }

    /// - Parameter advisor: nil — the setting is off, or there is no model —
    ///   gives the nearest candidates without asking any model. Any error from
    ///   it does the same, list by list.
    public static func suggest(
        for request: SuggestionRequest,
        searcher: any PlaceSearching,
        advisor: (any TripAdvising)?
    ) async -> Outcome {
        // Every search at once, each remembered with its list and order.
        let found = await withTaskGroup(of: (SuggestionGroup, Int, [FoundPlace]).self) { tasks in
            for group in request.groups {
                for (index, query) in (request.queriesByGroup[group] ?? []).enumerated() {
                    tasks.addTask {
                        // A failed search is just no results for that word;
                        // the others still count.
                        let places = (try? await searcher.search(query, near: request.center, radiusMetres: request.radiusMetres)) ?? []
                        return (group, index, places)
                    }
                }
            }
            var results: [(SuggestionGroup, Int, [FoundPlace])] = []
            for await result in tasks { results.append(result) }
            return results
        }

        // Food first, and a place only ever on one list: what the food list
        // took is "taken" for the other.
        var taken = request.taken
        var lists: [(SuggestionGroup, SuggestionCandidates)] = []
        let rank = { (group: SuggestionGroup) in SuggestionGroup.order.firstIndex(of: group) ?? 0 }
        for group in request.groups {
            let places = found
                .sorted { $0.0 == $1.0 ? $0.1 < $1.1 : rank($0.0) < rank($1.0) }
                .flatMap(\.2)
                .filter(group.admits)
            let candidates = SuggestionCandidates(
                found: places,
                taken: taken,
                center: request.center,
                radiusMetres: request.radiusMetres * 1.5
            )
            taken += candidates.candidates.map { TakenPlace(title: $0.place.name, coordinate: $0.place.coordinate) }
            lists.append((group, candidates))
        }

        let asked = advisor.flatMap { $0.availability == .available ? $0 : nil }
        let sections = await withTaskGroup(of: Section.self) { tasks in
            for (group, candidates) in lists where !candidates.isEmpty {
                tasks.addTask {
                    await section(group, candidates: candidates, context: "\(request.context) \(group.modelContext)", advisor: asked)
                }
            }
            var sections: [Section] = []
            for await section in tasks { sections.append(section) }
            return sections
        }
        return Outcome(sections: request.groups.compactMap { group in sections.first { $0.group == group } })
    }

    private static func section(
        _ group: SuggestionGroup,
        candidates: SuggestionCandidates,
        context: String,
        advisor: (any TripAdvising)?
    ) async -> Section {
        if let advisor, let picks = try? await advisor.pickPlaces(candidates: candidates, context: context) {
            let suggestions = Array(candidates.resolve(picks).prefix(suggestionCount))
            if !suggestions.isEmpty {
                return Section(group: group, suggestions: suggestions, candidateCount: candidates.count, usedModel: true)
            }
        }
        return Section(group: group, suggestions: candidates.nearest(suggestionCount), candidateCount: candidates.count, usedModel: false)
    }
}
