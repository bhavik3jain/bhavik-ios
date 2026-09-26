import Core
import CoreData
import Foundation

/// Where the Nearby tab measures from: the person's own position, or the
/// middle of one day's planned stops — "what could I fit in around Day 4?"
/// works before the trip, and for someone who won't share their location.
public enum NearbyOrigin: Hashable, Sendable {
    case me
    case day(Int)
}

/// A trip's ideas ranked by how far they are from somewhere, in buckets a
/// person decides with: close enough to wander over, worth a detour, or a
/// proper outing.
///
/// Distance is worked out here, in Swift, every time — it depends on where the
/// reader is standing, so it can never be a stored value or a query.
public struct NearbyIdeas {
    public enum Bucket: Int, CaseIterable, Identifiable, Sendable {
        case shortWalk
        case worthTheTrip
        case farther

        public var id: Int { rawValue }

        public var title: String {
            switch self {
            case .shortWalk: "A short walk"
            case .worthTheTrip: "Worth the trip"
            case .farther: "Farther"
            }
        }

        /// Up to a quarter of an hour on foot, at `WalkingEstimate`'s pace, is
        /// "a short walk". Written out rather than multiplied, so the edge is
        /// exactly 1,250 m and not a floating-point hair either side of it.
        public static let shortWalkMetres = 1_250.0
        /// Beyond this it's a taxi, a train or a day out, not a detour.
        public static let worthTheTripMetres = 5_000.0

        public static func of(metres: Double) -> Bucket {
            if metres <= shortWalkMetres { return .shortWalk }
            return metres <= worthTheTripMetres ? .worthTheTrip : .farther
        }
    }

    public struct Suggestion: Identifiable {
        public let item: SharedItineraryItem
        public let estimate: WalkingEstimate
        public var id: NSManagedObjectID { item.objectID }
    }

    public struct Group: Identifiable {
        public let bucket: Bucket
        /// Nearest first.
        public let suggestions: [Suggestion]
        public var id: Bucket { bucket }
    }

    /// Only buckets with something in them, nearest bucket first.
    public let groups: [Group]
    /// Ideas with no coordinate, which can't be ranked — the screen asks for an
    /// address for these.
    public let unplaced: [SharedItineraryItem]

    public var suggestions: [Suggestion] { groups.flatMap(\.suggestions) }

    public init(ideas: [SharedItineraryItem], from origin: GeoCoordinate) {
        let candidates = ideas.filter(\.isUnassigned)
        let ranked = candidates
            .compactMap { item -> Suggestion? in
                guard let point = item.coordinate else { return nil }
                return Suggestion(item: item, estimate: WalkingEstimate(metres: origin.distance(to: point)))
            }
            .sorted { lhs, rhs in
                if lhs.estimate.metres != rhs.estimate.metres { return lhs.estimate.metres < rhs.estimate.metres }
                return lhs.item.title.localizedStandardCompare(rhs.item.title) == .orderedAscending
            }
        groups = Bucket.allCases.compactMap { bucket in
            let matching = ranked.filter { Bucket.of(metres: $0.estimate.metres) == bucket }
            return matching.isEmpty ? nil : Group(bucket: bucket, suggestions: matching)
        }
        unplaced = candidates
            .filter { !$0.hasCoordinate }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public init(trip: SharedTrip, from origin: GeoCoordinate) {
        self.init(ideas: trip.ideas, from: origin)
    }

    // MARK: - Origins

    /// Within this of the trip's destination or any of its places counts as
    /// being at the trip. Generous on purpose — an airport or a day trip out
    /// of the city is still "there" — and far below the distance to anywhere
    /// the person would be planning from at home.
    public static let atTripMetres = 50_000.0

    /// The middle of `day`'s planned stops that have a place, or nil when none
    /// do. Ideas never count: they aren't on the day.
    public static func centroid(ofDay day: Int, in trip: SharedTrip) -> GeoCoordinate? {
        guard day >= 0 else { return nil }
        let points = (trip.items ?? [])
            .filter { !$0.isUnassigned && $0.dayIndex == day }
            .compactMap(\.coordinate)
        return GeoCoordinate.centroid(of: points)
    }

    /// The days Nearby can measure from: every day with at least one placed stop.
    public static func daysWithStops(in trip: SharedTrip) -> [Int] {
        (0..<trip.dates.dayCount).filter { centroid(ofDay: $0, in: trip) != nil }
    }

    /// Whether `location` is at the trip rather than, say, at home planning it.
    public static func isAtTrip(_ location: GeoCoordinate, trip: SharedTrip) -> Bool {
        var anchors = (trip.items ?? []).compactMap(\.coordinate)
        if let latitude = trip.latitude, let longitude = trip.longitude {
            anchors.append(GeoCoordinate(latitude: latitude, longitude: longitude))
        }
        return anchors.contains { location.distance(to: $0) <= atTripMetres }
    }

    /// What Nearby opens on. "Near me" when the person is at the trip; failing
    /// that, today's stops while the trip runs, then the next day with stops
    /// (the first, before it starts), then any day with stops; and "Near me"
    /// again as a last resort when no day has a place but a fix exists, since
    /// ranked from far away is still ranked. Nil when there is nothing at all
    /// to measure from.
    public static func suggestedOrigin(
        for trip: SharedTrip,
        location: GeoCoordinate?,
        asOf now: Date = .now
    ) -> NearbyOrigin? {
        if let location, isAtTrip(location, trip: trip) { return .me }
        let days = daysWithStops(in: trip)
        let today = max(0, trip.dates.offset(of: now))
        if let day = days.first(where: { $0 >= today }) ?? days.last {
            return .day(day)
        }
        return location == nil ? nil : .me
    }

    /// The point `origin` stands for, or nil when it can't be worked out — no
    /// fix yet, or a day whose stops have since lost their places.
    public static func point(
        for origin: NearbyOrigin,
        in trip: SharedTrip,
        location: GeoCoordinate?
    ) -> GeoCoordinate? {
        switch origin {
        case .me: location
        case .day(let day): centroid(ofDay: day, in: trip)
        }
    }

    /// The day "Add" puts an idea on: the chosen day, or today when measuring
    /// from the person while the trip runs. Nil — so the row offers a menu of
    /// days instead — when measuring from the person outside the trip's dates.
    public static func targetDay(for origin: NearbyOrigin, dates: TripDates, asOf now: Date = .now) -> Int? {
        switch origin {
        case .me: dates.dayIndex(of: now)
        case .day(let day): day
        }
    }
}

/// How far an idea is, and how long it is on foot. The same 5 km/h pace and
/// 10 km cut-off as Explore's map card, which Trips can't import.
public struct WalkingEstimate: Equatable, Sendable {
    /// A steady city pace, about 5 km/h.
    public static let metresPerMinute = 5_000.0 / 60
    /// Beyond this nobody is walking, and "about 150 min walk" is noise rather
    /// than information — the row shows the distance alone.
    public static let longestWalkMetres = 10_000.0
    /// Past this, Directions opens Maps in its default mode rather than walking.
    public static let walkingDirectionsLimitMetres = 3_000.0

    public let metres: Double

    public init(metres: Double) {
        self.metres = metres
    }

    /// Whole minutes on foot, never fewer than one.
    public var walkingMinutes: Int {
        max(1, Int((metres / Self.metresPerMinute).rounded()))
    }

    public var isWalkable: Bool { metres <= Self.longestWalkMetres }

    public var prefersWalkingDirections: Bool { metres <= Self.walkingDirectionsLimitMetres }

    /// "8 min walk", "1 hr 5 min walk", or nil past the longest walk.
    public var walkingText: String? {
        guard isWalkable else { return nil }
        let minutes = walkingMinutes
        guard minutes >= 60 else { return "\(minutes) min walk" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) hr walk" : "\(hours) hr \(rest) min walk"
    }

    /// "650 m" or "1.2 km" where people use kilometres, "0.4 mi" or "300 ft"
    /// where they use miles — Foundation's road-distance units for the locale.
    public func distanceText(locale: Locale = .current) -> String {
        Measurement(value: metres, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road).locale(locale))
    }

    /// "650 m · 8 min walk", or just the distance when it's no walk.
    public func summary(locale: Locale = .current) -> String {
        [distanceText(locale: locale), walkingText].compactMap(\.self).joined(separator: " · ")
    }
}
