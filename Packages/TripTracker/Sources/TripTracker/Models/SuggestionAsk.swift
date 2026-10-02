import Core
import Foundation

/// What the model made of a typed request — "coffee shops on this day", "more
/// sights near where I'll be this afternoon" — as numbers from
/// `SuggestionAsk`'s lists and a few search words. Nothing here is trusted:
/// `SuggestionAsk.resolve` checks every number and cleans every word.
public struct AskReading: Sendable, Equatable {
    /// 1-based, a day the person named; 0 when they named none.
    public var day: Int
    /// 1-based, `SuggestionAsk.Stop.number`: what to search around. Empty for
    /// the whole day.
    public var stops: [Int]
    /// What to search Apple Maps for.
    public var searches: [String]

    public init(day: Int, stops: [Int], searches: [String]) {
        self.day = day
        self.stops = stops
        self.searches = searches
    }
}

/// A request typed into Suggest Places, with the trip laid out as numbered
/// lists for the model to point into. The model only reads the request —
/// which day, which stops, what kind of place — and answers in numbers
/// (`AskReading`); Swift then builds an ordinary `SuggestionRequest`, so the
/// searches, the filtering and the picking are the same as any other run, and
/// the model can never search the whole world or name a place itself.
///
/// Only offered while the model can run and "Apple Intelligence in Trips" is
/// on: with no model there's nothing to read the words, and Apple Maps given a
/// whole sentence finds nothing.
public struct SuggestionAsk: Sendable, Equatable {
    /// A stop the search can centre on: on a day, with a place.
    public struct Stop: Sendable, Equatable {
        /// 1-based, across the whole trip, as the model sees it.
        public let number: Int
        public let dayIndex: Int
        public let title: String
        public let coordinate: GeoCoordinate
    }

    /// Longer is clipped: a request is a line, not a letter, and the prompt
    /// has to fit beside the trip.
    public static let maximumLength = 200
    /// Stops listed for the model — a few weeks of full days, well inside its
    /// context.
    public static let maximumStops = 40
    /// Around particular stops: "near where I'll be" is a short walk, closer
    /// than a whole day's spread.
    public static let stopRadiusMetres = 1_500.0
    /// Each search word: Apple Maps finds nothing for long phrases.
    static let maximumWordsPerSearch = 2

    public let text: String
    /// The day Suggest Places is looking at; nil for the whole trip.
    public let openDay: Int?
    public let stops: [Stop]
    /// What the model reads: the trip's days and their numbered stops, the
    /// day open on screen, and the request. Titles, kinds and times only —
    /// never notes, addresses, bookings or flights.
    public let prompt: String

    /// Nil when there's nothing to ask: an empty request.
    public init?(text: String, trip: SharedTrip, openDay: Int?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let dayCount = trip.dates.dayCount
        self.text = String(trimmed.prefix(Self.maximumLength))
        self.openDay = openDay.flatMap { (0..<dayCount).contains($0) ? $0 : nil }

        var stops: [Stop] = []
        var dayLines: [String] = []
        for dayIndex in 0..<dayCount {
            let plan = DayPlan(trip: trip, dayIndex: dayIndex)
            var listed: [String] = []
            for entry in plan.entries {
                guard stops.count < Self.maximumStops,
                      case .item(let item) = entry, PlanCheck.isStop(item),
                      let coordinate = item.coordinate else { continue }
                let stop = Stop(number: stops.count + 1, dayIndex: dayIndex, title: item.title, coordinate: coordinate)
                stops.append(stop)
                var about = item.kind.displayName
                if let start = plan.start(of: entry) {
                    let minute = plan.dates.minuteOfDay(start)
                    about += String(format: ", %02d:%02d", minute / 60, minute % 60)
                }
                listed.append("\(stop.number). \(TripBrief.clip(item.title)) (\(about))")
            }
            let label = "Day \(dayIndex + 1), \(IdeaDays.dayLabel(dayIndex, dates: trip.dates))"
            dayLines.append(listed.isEmpty ? "\(label): no stops with a place yet" : "\(label): \(listed.joined(separator: "; "))")
        }
        self.stops = stops

        let destination = trip.destination.isEmpty ? trip.title : trip.destination
        var prompt = ["Destination: \(TripBrief.clip(destination)).", "Days and their numbered stops:"]
        prompt += dayLines
        prompt.append(self.openDay.map { "The traveller is looking at Day \($0 + 1)." } ?? "The traveller is looking at the whole trip.")
        prompt.append("Request: \(self.text)")
        self.prompt = prompt.joined(separator: "\n")
    }

    /// The search to run, and a line saying what was searched.
    public struct Resolved: Sendable, Equatable {
        public let request: SuggestionRequest
        /// "Searched for “coffee”, “cafe” near Colosseum, Roman Forum on Day 2 · Sat 10 Oct."
        public let summary: String
    }

    /// The reading checked against the trip: a day that isn't on it, or a stop
    /// that isn't on the list, is ignored, and the open day stands. Nil when
    /// there's nowhere to search around or no search word survives cleaning —
    /// the caller shows the ordinary suggestions instead.
    @MainActor
    public func resolve(_ reading: AskReading, trip: SharedTrip, weather: [DayWeather?] = [], locale: Locale = .current) -> Resolved? {
        let searches = Self.searches(from: reading.searches)
        guard !searches.isEmpty else { return nil }

        let dayCount = trip.dates.dayCount
        let namedDay = (1...max(dayCount, 1)).contains(reading.day) && dayCount > 0 ? reading.day - 1 : nil
        var seen = Set<Int>()
        let pointed = reading.stops.compactMap { number -> Stop? in
            guard stops.indices.contains(number - 1), seen.insert(number).inserted else { return nil }
            return stops[number - 1]
        }
        // A named day wins; otherwise the stops say which day; otherwise the
        // one on screen. Stops on any other day are dropped — "near the
        // Colosseum on Day 3" can't centre on Day 1's visit.
        let day = namedDay ?? pointed.first?.dayIndex ?? openDay
        let near = pointed.filter { $0.dayIndex == day }

        guard let base = SuggestionRequest(trip: trip, day: day, weather: weather, locale: locale) else { return nil }
        let center = GeoCoordinate.centroid(of: near.map(\.coordinate)) ?? base.center
        var context = base.context
        context += " The traveller asked: \"\(TripBrief.clip(text, to: 160))\"."
        if !near.isEmpty {
            context += " Looking near: \(near.map { TripBrief.clip($0.title) }.joined(separator: "; "))."
        }
        let request = SuggestionRequest(
            dayIndex: base.dayIndex,
            center: center,
            radiusMetres: near.isEmpty ? base.radiusMetres : Self.stopRadiusMetres,
            queries: [.asked: searches],
            context: context,
            taken: base.taken
        )

        var summary = "Searched for \(searches.map { "“\($0)”" }.joined(separator: ", "))"
        if !near.isEmpty {
            summary += " near \(near.map(\.title).joined(separator: ", "))"
        }
        if let day = base.dayIndex {
            summary += " on Day \(day + 1) · \(IdeaDays.dayLabel(day, dates: trip.dates))"
        } else {
            let place = trip.destination.isEmpty ? trip.title : trip.destination
            summary += place.isEmpty ? " around the trip" : " around \(place)"
        }
        return Resolved(request: request, summary: summary + ".")
    }

    /// Plain words Apple Maps can use: lowercased, letters only, two words at
    /// most each, no repeats, `SuggestionRequest.maximumSearchesPerGroup` in
    /// all.
    static func searches(from raw: [String]) -> [String] {
        var seen = Set<String>()
        var kept: [String] = []
        for search in raw {
            let letters = search.lowercased().map { $0.isLetter || $0 == "'" || $0 == "-" ? $0 : " " }
            let words = String(letters).split(separator: " ").prefix(maximumWordsPerSearch)
            let cleaned = words.joined(separator: " ")
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { continue }
            kept.append(cleaned)
            if kept.count == SuggestionRequest.maximumSearchesPerGroup { break }
        }
        return kept
    }
}

public extension PlaceSuggester {
    /// A typed request's run, and the line saying what it searched.
    struct AskedOutcome: Sendable, Equatable {
        public let outcome: Outcome
        public let summary: String
    }

    /// The model reads `text`, Swift checks the reading, then an ordinary run.
    /// Nil whenever that can't happen — an empty request, the model failing
    /// or refusing, nothing usable in its answer, nowhere to search — and the
    /// caller shows the usual lists with `SuggestionsNote.unreadableAsk`.
    /// Call only while `advisor` is available and the setting is on.
    @MainActor
    static func suggest(
        asking text: String,
        trip: SharedTrip,
        openDay: Int?,
        weather: [DayWeather?],
        searcher: any PlaceSearching,
        advisor: any TripAdvising
    ) async -> AskedOutcome? {
        guard let ask = SuggestionAsk(text: text, trip: trip, openDay: openDay),
              let reading = try? await advisor.readAsk(ask),
              let resolved = ask.resolve(reading, trip: trip, weather: weather) else { return nil }
        let outcome = await suggest(for: resolved.request, searcher: searcher, advisor: advisor)
        return AskedOutcome(outcome: outcome, summary: resolved.summary)
    }
}
