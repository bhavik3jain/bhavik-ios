import Core
import CoreData
import Foundation

/// A trip's ideas measured against one day's plan — the Mac's Ideas inspector
/// beside Plan: "what could we fit in around what we're already doing?".
///
/// Unlike `NearbyIdeas`, which measures from one point (you, or a day's
/// centroid), each idea here is measured to its nearest placed stop on the
/// day, and says which: a day that runs from the Vatican to Trastevere has no
/// useful middle, but "8 min from Da Enzo" tells you exactly when to go.
public struct PlanIdeas {
    public struct Match: Identifiable {
        public let item: SharedItineraryItem
        /// The day's placed stop it's nearest. Nil when the day has none, so
        /// there is nothing to measure to.
        public let nearestStop: SharedItineraryItem?
        public let estimate: WalkingEstimate?

        public var id: NSManagedObjectID { item.objectID }

        /// "3 min from Armando · 250 m", "6 km from Armando", or nil when it
        /// wasn't measured.
        public func detail(locale: Locale = .current) -> String? {
            guard let estimate, let stop = nearestStop else { return nil }
            if estimate.isWalkable {
                return "\(estimate.walkingMinutes) min from \(stop.title) · \(estimate.distanceText(locale: locale))"
            }
            return "\(estimate.distanceText(locale: locale)) from \(stop.title)"
        }
    }

    /// How many ideas the inspector puts under "Closest to the plan" before
    /// the rest go under "Elsewhere". Four fill the inspector's top half at
    /// its default height without scrolling.
    public static let closestLimit = 4

    /// Nearest first, at most `closestLimit`, and only within
    /// `NearbyIdeas.Bucket.worthTheTripMetres` — beyond that nothing is
    /// "close to" the day, however few ideas there are.
    public let closest: [Match]
    /// Every other idea with a place: nearest first when the day has placed
    /// stops, by name otherwise.
    public let elsewhere: [Match]
    /// Ideas with no place, which can't be measured — by name.
    public let unplaced: [SharedItineraryItem]
    /// Whether the day has any stop with a place to measure to.
    public let isMeasured: Bool

    public var count: Int { closest.count + elsewhere.count + unplaced.count }

    public init(ideas: [SharedItineraryItem], stops: [SharedItineraryItem]) {
        let anchors = stops.filter { !$0.isUnassigned }.compactMap { stop in stop.coordinate.map { (stop, $0) } }
        let candidates = ideas.filter(\.isUnassigned)
        func byTitle(_ lhs: SharedItineraryItem, _ rhs: SharedItineraryItem) -> Bool {
            lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }

        let placed = candidates.compactMap { idea -> Match? in
            guard let point = idea.coordinate else { return nil }
            let nearest = anchors
                .map { (stop: $0.0, metres: point.distance(to: $0.1)) }
                .min { $0.metres < $1.metres }
            return Match(item: idea, nearestStop: nearest?.stop, estimate: nearest.map { WalkingEstimate(metres: $0.metres) })
        }

        isMeasured = !anchors.isEmpty
        if isMeasured {
            let ranked = placed.sorted { lhs, rhs in
                let left = lhs.estimate?.metres ?? .infinity, right = rhs.estimate?.metres ?? .infinity
                return left != right ? left < right : byTitle(lhs.item, rhs.item)
            }
            let near = ranked.prefix { ($0.estimate?.metres ?? .infinity) <= NearbyIdeas.Bucket.worthTheTripMetres }
            closest = Array(near.prefix(Self.closestLimit))
            elsewhere = Array(ranked.dropFirst(closest.count))
        } else {
            closest = []
            elsewhere = placed.sorted { byTitle($0.item, $1.item) }
        }
        unplaced = candidates.filter { !$0.hasCoordinate }.sorted(by: byTitle)
    }

    /// `day`'s stops against every idea of `trip`.
    public init(trip: SharedTrip, day: Int) {
        let items = trip.items ?? []
        self.init(ideas: Array(items), stops: items.filter { $0.dayIndex == day })
    }
}
