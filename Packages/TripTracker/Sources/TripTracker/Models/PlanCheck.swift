import Core
import CoreData
import Foundation

/// A plain look over a trip's plan for what goes wrong on the day: two things
/// at once, a walk longer than the gap left for it, a day nobody could get
/// through, rain on the picnic, a free day, a saved idea around the corner.
///
/// No model and no network — every finding is worked out here, in Swift, so
/// it's the same on iOS 18 as on a Mac with Apple Intelligence, and every fix
/// is something Swift can do. The on-device model only ranks and rewords
/// these (see `TripBrief` and `PlanReview`): in the research spike, left to
/// its own fixes, it told a traveller to "combine Vatican Museums and Borghese
/// Gallery into one stop" — 3 km apart — and answered six real problems with
/// "No change needed".
///
/// Ideas (any negative `dayIndex`) are never stops: they're on no day.
public struct PlanCheck {
    public enum Kind: String, Sendable, CaseIterable {
        case overlap
        case tightTransfer
        case overloaded
        case busyFlightDay
        case weatherClash
        case emptyDay
        case ideaNearby

        /// "Overlap", as a finding's small heading.
        public var title: String {
            switch self {
            case .overlap: "Overlap"
            case .tightTransfer: "Tight walk"
            case .overloaded: "Busy day"
            case .busyFlightDay: "Busy travel day"
            case .weatherClash: "Weather"
            case .emptyDay: "Free day"
            case .ideaNearby: "Idea nearby"
            }
        }

        /// Whether the finding is about particular stops, so a note on it
        /// should name one; a busy or free day is about the day.
        public var isAboutPlaces: Bool {
            switch self {
            case .overlap, .tightTransfer, .weatherClash, .ideaNearby: true
            case .overloaded, .busyFlightDay, .emptyDay: false
            }
        }

        public var symbolName: String {
            switch self {
            case .overlap: "clock.badge.exclamationmark"
            case .tightTransfer: "figure.walk.motion"
            case .overloaded: "calendar.badge.exclamationmark"
            case .busyFlightDay: "airplane"
            case .weatherClash: "cloud.rain"
            case .emptyDay: "calendar"
            case .ideaNearby: "lightbulb"
            }
        }
    }

    /// One tap that changes the plan, through the same `move(toDay:)` the
    /// timeline's "Move to…" and the Ideas menus use — so a fix lands where a
    /// hand-made move would, at the end of its new day. The caller saves.
    public struct Fix: Identifiable {
        public let item: SharedItineraryItem
        /// A day, or `SharedItineraryItem.unassignedDayIndex` for "send to Ideas".
        public let targetDay: Int
        /// "Move Borghese Gallery to Day 3", "Send Picnic to Ideas",
        /// "Add Pantheon to Day 1".
        public let title: String

        public var id: String { "\(item.objectID.uriRepresentation().absoluteString)->\(targetDay)" }
        public var sendsToIdeas: Bool { targetDay < 0 }

        public func apply() {
            item.move(toDay: targetDay)
        }
    }

    public struct Finding: Identifiable {
        public let kind: Kind
        public let dayIndex: Int
        /// The itinerary items it's about. Flights are named in the message
        /// but never moved.
        public let items: [SharedItineraryItem]
        /// The plain-English text shown when there is no model, or the model
        /// fails, or it says nothing useful about this one.
        public let message: String
        public let fixes: [Fix]
        public let id: String
    }

    // MARK: Thresholds

    /// More stops than this is more than a day holds.
    public static let overloadedStops = 6
    /// More than nine hours of set lengths is a day with no room to eat.
    public static let overloadedMinutes = 9 * 60
    /// On a day with a flight, more stops than this is a squeeze.
    public static let flightDayStops = 2
    /// Back-to-back stops a few minutes' walk apart is how every day is
    /// planned; only a walk this much longer than the gap is worth a note.
    public static let walkToleranceMinutes = 5
    /// Ideas at most this far from a day's stop are "a short walk" — the same
    /// edge Nearby uses.
    public static let ideaNearbyMetres = NearbyIdeas.Bucket.shortWalkMetres
    /// Per day, so one well-placed day doesn't turn into a list of every idea.
    public static let ideasPerFinding = 3

    public let findings: [Finding]
    /// Where findings start: today while the trip runs. A day already gone
    /// can't be fixed, and a finished trip gets no findings at all.
    public let firstOpenDay: Int

    public var isEmpty: Bool { findings.isEmpty }

    public func findings(onDay day: Int) -> [Finding] {
        findings.filter { $0.dayIndex == day }
    }

    /// For a badge on the day strip.
    public func count(onDay day: Int) -> Int {
        findings.count { $0.dayIndex == day }
    }

    public func finding(id: String) -> Finding? {
        findings.first { $0.id == id }
    }

    /// - Parameter weather: one slot per trip day, as `TripForecast.byDay`
    ///   returns it; missing or nil slots are days with no forecast.
    public init(trip: SharedTrip, weather: [DayWeather?] = [], asOf now: Date = .now, locale: Locale = .current) {
        let days = Days(trip: trip, weather: weather, asOf: now)
        firstOpenDay = days.firstOpen
        var found: [Finding] = []
        for day in days.open {
            found += Self.overlaps(on: day, in: days)
            found += Self.transfers(on: day, in: days, locale: locale)
            found += Self.load(on: day, in: days)
            found += Self.weather(on: day, in: days)
            found += Self.emptiness(on: day, in: days)
        }
        found += Self.nearbyIdeas(in: days)
        let order = Dictionary(uniqueKeysWithValues: Kind.allCases.enumerated().map { ($1, $0) })
        findings = found.enumerated().sorted { lhs, rhs in
            if lhs.element.dayIndex != rhs.element.dayIndex { return lhs.element.dayIndex < rhs.element.dayIndex }
            let left = order[lhs.element.kind] ?? 0, right = order[rhs.element.kind] ?? 0
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map(\.element)
    }
}

// MARK: - The trip, read once

extension PlanCheck {
    /// Everything the checks read, worked out once per check.
    struct Days {
        let trip: SharedTrip
        let dates: TripDates
        let plans: [DayPlan]
        let weather: [DayWeather?]
        let firstOpen: Int
        let ideas: [SharedItineraryItem]

        init(trip: SharedTrip, weather: [DayWeather?], asOf now: Date) {
            self.trip = trip
            dates = trip.dates
            let items = Array(trip.items ?? [])
            let flights = Array(trip.flights ?? [])
            plans = (0..<dates.dayCount).map { DayPlan(dayIndex: $0, items: items, flights: flights, dates: trip.dates) }
            self.weather = (0..<dates.dayCount).map { weather.indices.contains($0) ? weather[$0] : nil }
            firstOpen = max(0, dates.offset(of: now))
            ideas = trip.ideas.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }

        var open: Range<Int> { min(firstOpen, plans.count)..<plans.count }

        func items(on day: Int) -> [SharedItineraryItem] {
            plans[day].entries.compactMap { if case .item(let item) = $0 { item } else { nil } }
        }

        func flights(on day: Int) -> [SharedFlight] {
            plans[day].entries.compactMap { if case .flight(let flight) = $0 { flight } else { nil } }
        }

        /// What counts toward a day's load: a hotel check-in or "get the
        /// train" is on the day but isn't somewhere you spend it.
        func stops(on day: Int) -> [SharedItineraryItem] {
            items(on: day).filter(PlanCheck.isStop)
        }

        func plannedMinutes(on day: Int) -> Int {
            stops(on: day).reduce(0) { $0 + max(0, $1.durationMinutes) }
        }

        func isOverloaded(_ day: Int) -> Bool {
            stops(on: day).count > PlanCheck.overloadedStops || plannedMinutes(on: day) > PlanCheck.overloadedMinutes
        }

        func isWet(_ day: Int) -> Bool {
            weather[day].map(PlanCheck.isWet) ?? false
        }

        func isKnownDry(_ day: Int) -> Bool {
            weather[day].map { !PlanCheck.isWet($0) } ?? false
        }

        /// The day `item` fits best, other than `source`: open, not past, not
        /// full, nothing already booked at its time, fewest stops first and
        /// then the nearest day. `requireDry` keeps to days with a dry
        /// forecast.
        func bestDay(for item: SharedItineraryItem, from source: Int, requireDry: Bool = false) -> Int? {
            let window = timeWindow(of: item)
            return open
                .filter { $0 != source }
                .filter { !requireDry || isKnownDry($0) }
                .filter { stops(on: $0).count < PlanCheck.overloadedStops }
                .filter { day in
                    guard let window else { return true }
                    return !plans[day].timed.contains { entry in
                        guard let start = minute(ofStart: entry, on: day), let end = minute(ofEnd: entry, on: day) else { return false }
                        return start < window.upperBound && window.lowerBound < max(end, start + 1)
                    }
                }
                .min { lhs, rhs in
                    let left = (stops(on: lhs).count, abs(lhs - source), lhs)
                    let right = (stops(on: rhs).count, abs(rhs - source), rhs)
                    return left < right
                }
        }

        /// Minutes after midnight an item occupies, at least one minute wide.
        func timeWindow(of item: SharedItineraryItem) -> Range<Int>? {
            guard let start = item.startTime.map(dates.minuteOfDay) else { return nil }
            return start..<(start + max(1, item.durationMinutes))
        }

        func minute(ofStart entry: DayPlan.Entry, on day: Int) -> Int? {
            plans[day].start(of: entry).map { dates.minuteOfDay($0) + dayOffsetMinutes($0, day: day) }
        }

        func minute(ofEnd entry: DayPlan.Entry, on day: Int) -> Int? {
            plans[day].end(of: entry).map { dates.minuteOfDay($0) + dayOffsetMinutes($0, day: day) }
        }

        /// An end past midnight counts on from 24:00 rather than wrapping to 00:10.
        private func dayOffsetMinutes(_ moment: Date, day: Int) -> Int {
            (dates.offset(of: moment) - day) * 24 * 60
        }
    }

    static func isStop(_ item: SharedItineraryItem) -> Bool {
        item.kind != .lodging && item.kind != .transit
    }

    /// Words in a title that put a plan outdoors whatever its kind. An
    /// Activity always counts; a Sight such as a museum doesn't unless it says
    /// so.
    static let outdoorWords: Set<String> = [
        "park", "parks", "garden", "gardens", "beach", "beaches", "hike", "hiking", "picnic", "walk", "walking",
        "bike", "biking", "cycle", "cycling", "boat", "kayak", "viewpoint", "lookout", "zoo", "trail", "terrace",
    ]

    static func isOutdoor(_ item: SharedItineraryItem) -> Bool {
        if item.kind == .activity { return true }
        let words = item.title.lowercased().split { !$0.isLetter }.map(String.init)
        return words.contains(where: outdoorWords.contains)
    }

    /// Rain, storms, snow — by symbol first, which is what WeatherKit is
    /// consistent about, then by the words of its summary.
    static func isWet(_ weather: DayWeather) -> Bool {
        let symbol = weather.symbolName.lowercased()
        if ["rain", "drizzle", "bolt", "snow", "sleet", "hail", "tropicalstorm", "hurricane"].contains(where: symbol.contains) {
            return true
        }
        let summary = weather.summary.lowercased()
        return ["rain", "storm", "thunder", "drizzle", "shower", "snow", "sleet", "hail"].contains(where: summary.contains)
    }

    static func fixMoving(_ item: SharedItineraryItem, to day: Int) -> Fix {
        Fix(item: item, targetDay: day, title: "Move \(item.title) to Day \(day + 1)")
    }

    static func fixSendingToIdeas(_ item: SharedItineraryItem) -> Fix {
        Fix(item: item, targetDay: SharedItineraryItem.unassignedDayIndex, title: "Send \(item.title) to Ideas")
    }

    static func fixAdding(_ idea: SharedItineraryItem, to day: Int) -> Fix {
        Fix(item: idea, targetDay: day, title: "Add \(idea.title) to Day \(day + 1)")
    }

    /// Move it to the best other day when there is one, and always offer Ideas.
    static func moveFixes(for item: SharedItineraryItem, from day: Int, in days: Days, requireDry: Bool = false) -> [Fix] {
        var fixes: [Fix] = []
        if let target = days.bestDay(for: item, from: day, requireDry: requireDry) {
            fixes.append(fixMoving(item, to: target))
        }
        fixes.append(fixSendingToIdeas(item))
        return fixes
    }

    static func id(_ kind: Kind, day: Int, _ objects: [NSManagedObject]) -> String {
        ([kind.rawValue, String(day)] + objects.map { $0.objectID.uriRepresentation().absoluteString }).joined(separator: "|")
    }

    /// "3 hr", "1 hr 30 min", "45 min".
    static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}

// MARK: - The checks

extension PlanCheck {
    /// Two timed entries at once — a flight included, since you can't be at
    /// lunch and on the plane. Each entry is measured against whichever
    /// earlier one runs latest, so a long visit that swallows two short ones
    /// reports both.
    static func overlaps(on day: Int, in days: Days) -> [Finding] {
        var findings: [Finding] = []
        var latest: (entry: DayPlan.Entry, end: Int)?
        for entry in days.plans[day].timed {
            guard let start = days.minute(ofStart: entry, on: day), let end = days.minute(ofEnd: entry, on: day) else { continue }
            if let previous = latest, previous.end > start {
                let overlap = previous.end - start
                // The later one moves; a flight never does.
                let movable: SharedItineraryItem? = switch (entry, previous.entry) {
                case (.item(let later), _): later
                case (.flight, .item(let earlier)): earlier
                case (.flight, .flight): nil
                }
                let items = [previous.entry, entry].compactMap { if case .item(let item) = $0 { item } else { nil } }
                let objects: [NSManagedObject] = [previous.entry, entry].map {
                    switch $0 {
                    case .item(let item): item
                    case .flight(let flight): flight
                    }
                }
                findings.append(Finding(
                    kind: .overlap,
                    dayIndex: day,
                    items: items,
                    message: "Day \(day + 1): \(previous.entry.title) runs \(duration(overlap)) into \(entry.title).",
                    fixes: movable.map { moveFixes(for: $0, from: day, in: days) } ?? [],
                    id: id(.overlap, day: day, objects)
                ))
            }
            if end > latest?.end ?? .min { latest = (entry, end) }
        }
        return findings
    }

    /// Consecutive timed stops, both placed, whose walk is longer than the
    /// time between them. Overlaps are left to `overlaps`.
    static func transfers(on day: Int, in days: Days, locale: Locale) -> [Finding] {
        let timed = days.plans[day].timed.compactMap { entry -> SharedItineraryItem? in
            if case .item(let item) = entry { item } else { nil }
        }
        var findings: [Finding] = []
        for (from, to) in zip(timed, timed.dropFirst()) {
            guard let a = from.coordinate, let b = to.coordinate,
                  let end = days.minute(ofEnd: .item(from), on: day),
                  let start = days.minute(ofStart: .item(to), on: day) else { continue }
            let gap = start - end
            guard gap >= 0 else { continue }
            let estimate = WalkingEstimate(metres: a.distance(to: b))
            guard estimate.walkingMinutes > gap + walkToleranceMinutes else { continue }
            let walk = estimate.isWalkable
                ? "\(estimate.distanceText(locale: locale)), about \(duration(estimate.walkingMinutes)) on foot"
                : "\(estimate.distanceText(locale: locale)) apart"
            findings.append(Finding(
                kind: .tightTransfer,
                dayIndex: day,
                items: [from, to],
                message: "Day \(day + 1): \(from.title) to \(to.title) is \(walk), with \(duration(gap)) between them.",
                fixes: moveFixes(for: to, from: day, in: days),
                id: id(.tightTransfer, day: day, [from, to])
            ))
        }
        return findings
    }

    /// Too many stops or too many hours — and, on a flight day, more than a
    /// couple of stops at all. One or the other, never both for the same day.
    static func load(on day: Int, in days: Days) -> [Finding] {
        let stops = days.stops(on: day)
        // The last stop in the day's own order is the one to lift off it.
        guard let last = stops.last else { return [] }
        let minutes = days.plannedMinutes(on: day)
        if days.isOverloaded(day) {
            let hours = minutes > 0 ? ", about \(duration(minutes)) planned" : ""
            return [Finding(
                kind: .overloaded,
                dayIndex: day,
                items: stops,
                message: "Day \(day + 1) has \(stops.count) stops\(hours).",
                fixes: moveFixes(for: last, from: day, in: days),
                id: id(.overloaded, day: day, [])
            )]
        }
        let flights = days.flights(on: day)
        if let flight = flights.first, stops.count > flightDayStops {
            return [Finding(
                kind: .busyFlightDay,
                dayIndex: day,
                items: stops,
                message: "Day \(day + 1) has a flight (\(flight.headline)) and \(stops.count) other stops.",
                fixes: moveFixes(for: last, from: day, in: days),
                id: id(.busyFlightDay, day: day, [flight])
            )]
        }
        return []
    }

    /// Rain on a day with something outdoors: move it to a dry day, or keep it
    /// as an idea.
    static func weather(on day: Int, in days: Days) -> [Finding] {
        guard days.isWet(day), let forecast = days.weather[day] else { return [] }
        let outdoor = days.stops(on: day).filter(isOutdoor)
        guard !outdoor.isEmpty else { return [] }
        let names = list(outdoor.map(\.title))
        let verb = outdoor.count == 1 ? "is" : "are"
        return [Finding(
            kind: .weatherClash,
            dayIndex: day,
            items: outdoor,
            message: "Day \(day + 1): \(forecast.summary) is forecast, and \(names) \(verb) outdoors.",
            fixes: outdoor.prefix(2).flatMap { moveFixes(for: $0, from: day, in: days, requireDry: true) },
            id: id(.weatherClash, day: day, outdoor)
        )]
    }

    static func isEmpty(_ day: Int, in days: Days) -> Bool {
        days.stops(on: day).isEmpty && days.flights(on: day).isEmpty
    }

    /// Days with nothing on them, inside a trip that has plans elsewhere — one
    /// finding per run of free days, so a week planned only on its first day
    /// reads as "Days 2–7 have nothing planned", not six notes saying the
    /// same. A trip with nothing planned at all is one empty state, not a
    /// finding. Reported on a run's first day, which is where its fixes aim.
    static func emptiness(on day: Int, in days: Days) -> [Finding] {
        guard isEmpty(day, in: days), days.plans.contains(where: { !$0.isEmpty }) else { return [] }
        // Only the start of a run reports it.
        if day > days.open.lowerBound, isEmpty(day - 1, in: days) { return [] }
        var last = day
        while last + 1 < days.plans.count, isEmpty(last + 1, in: days) { last += 1 }

        var fixes: [Fix] = []
        // Lift the last stop off the busiest other day, when it has a few.
        let busiest = days.open
            .filter { !(day...last).contains($0) }
            .max { lhs, rhs in
                let left = days.stops(on: lhs).count, right = days.stops(on: rhs).count
                return left != right ? left < right : lhs > rhs
            }
        if let busiest, days.stops(on: busiest).count >= 3, let moving = days.stops(on: busiest).last {
            fixes.append(Fix(item: moving, targetDay: day, title: "Move \(moving.title) from Day \(busiest + 1) to Day \(day + 1)"))
        }
        fixes += days.ideas.prefix(2).map { fixAdding($0, to: day) }
        let message = last == day
            ? "Day \(day + 1) has nothing planned."
            : "Days \(day + 1)–\(last + 1) have nothing planned."
        return [Finding(
            kind: .emptyDay,
            dayIndex: day,
            items: [],
            message: message,
            fixes: fixes,
            id: id(.emptyDay, day: day, [])
        )]
    }

    /// Saved ideas a short walk from a day's stops. Each idea goes on the one
    /// day it's closest to, and never on a day that is already too full.
    static func nearbyIdeas(in days: Days) -> [Finding] {
        let eligible = days.open.filter { day in
            !days.isOverloaded(day) && !(days.flights(on: day).count > 0 && days.stops(on: day).count >= flightDayStops)
        }
        var best: [NSManagedObjectID: (day: Int, match: PlanIdeas.Match)] = [:]
        for day in eligible {
            let stops = days.stops(on: day)
            guard !stops.isEmpty else { continue }
            let ideas = PlanIdeas(ideas: days.ideas, stops: stops)
            for match in ideas.closest + ideas.elsewhere {
                guard let metres = match.estimate?.metres, metres <= ideaNearbyMetres else { continue }
                if let current = best[match.item.objectID], (current.match.estimate?.metres ?? .infinity) <= metres { continue }
                best[match.item.objectID] = (day, match)
            }
        }
        return eligible.compactMap { day -> Finding? in
            let matches = best.values
                .filter { $0.day == day }
                .map(\.match)
                .sorted { lhs, rhs in
                    let left = lhs.estimate?.metres ?? .infinity, right = rhs.estimate?.metres ?? .infinity
                    return left != right ? left < right : lhs.item.title.localizedStandardCompare(rhs.item.title) == .orderedAscending
                }
                .prefix(ideasPerFinding)
            guard !matches.isEmpty else { return nil }
            func minutes(_ match: PlanIdeas.Match) -> Int { match.estimate?.walkingMinutes ?? 0 }
            func stop(_ match: PlanIdeas.Match) -> String { match.nearestStop?.title ?? "the plan" }
            let message: String
            if matches.count == 1, let only = matches.first {
                message = "Day \(day + 1): \(only.item.title), a saved idea, is a \(minutes(only)) min walk from \(stop(only))."
            } else {
                let named = matches.map { "\($0.item.title) (\(minutes($0)) min from \(stop($0)))" }
                message = "Day \(day + 1): \(matches.count) saved ideas are a short walk from the day's stops: \(list(named))."
            }
            let items = matches.map(\.item)
            return Finding(
                kind: .ideaNearby,
                dayIndex: day,
                items: items,
                message: message,
                fixes: items.map { fixAdding($0, to: day) },
                id: id(.ideaNearby, day: day, items)
            )
        }
    }
}
