import Core
import CoreData
import Foundation

/// The order places are listed in within one category.
///
/// To try first, because a guide is mostly consulted to pick the next thing to
/// do — in the order they were added, so a new find goes to the bottom rather
/// than shuffling the list. Then the tried ones, best rated first, unrated last.
public enum PlaceOrdering {
    public struct Key: Sendable {
        public let name: String
        public let isTried: Bool
        public let rating: Int
        public let addedAt: Date

        public init(name: String, isTried: Bool, rating: Int, addedAt: Date) {
            self.name = name
            self.isTried = isTried
            self.rating = rating
            self.addedAt = addedAt
        }
    }

    public static func precedes(_ lhs: Key, _ rhs: Key) -> Bool {
        if lhs.isTried != rhs.isTried { return !lhs.isTried }
        if lhs.isTried, lhs.rating != rhs.rating { return lhs.rating > rhs.rating }
        if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    public static func ordered(_ places: [SharedGuidePlace]) -> [SharedGuidePlace] {
        places.sorted { precedes(key($0), key($1)) }
    }

    private static func key(_ place: SharedGuidePlace) -> Key {
        Key(name: place.name, isTried: place.isTried, rating: place.rating, addedAt: place.addedAt)
    }
}

/// Everything the list card, the guide header and the home peek say about a
/// guide, computed once.
///
/// Extracted from the views so the counts and sentences are testable — views
/// are untested by policy.
public struct GuideSummary: Identifiable, Sendable, Equatable {
    public let id: NSManagedObjectID
    public let name: String
    public let areaLabel: String
    public let placeCount: Int
    public let triedCount: Int
    public let counts: [PlaceCategory: Int]
    /// `nil` until at least one place has coordinates.
    public let region: GuideRegion?
    public let isPinned: Bool

    public init(
        id: NSManagedObjectID,
        name: String,
        areaLabel: String,
        placeCount: Int,
        triedCount: Int,
        counts: [PlaceCategory: Int],
        region: GuideRegion?,
        isPinned: Bool = false
    ) {
        self.id = id
        self.name = name
        self.areaLabel = areaLabel
        self.placeCount = placeCount
        self.triedCount = triedCount
        self.counts = counts
        self.region = region
        self.isPinned = isPinned
    }

    public func count(of category: PlaceCategory) -> Int {
        counts[category] ?? 0
    }

    /// "Kyoto, Japan · 12 places · 5 tried".
    public var detailLine: String {
        var parts: [String] = []
        let area = areaLabel.trimmingCharacters(in: .whitespaces)
        if !area.isEmpty { parts.append(area) }
        guard placeCount > 0 else {
            parts.append("No places yet")
            return parts.joined(separator: " · ")
        }
        parts.append(counted(placeCount, "place"))
        parts.append(triedCount == 0 ? "none tried yet" : "\(triedCount) tried")
        return parts.joined(separator: " · ")
    }

    /// A peek row's second line: "Kyoto, Japan · 5 tried". The place count is
    /// the row's trailing value, so it isn't repeated here.
    public var peekDetail: String {
        var parts: [String] = []
        let area = areaLabel.trimmingCharacters(in: .whitespaces)
        if !area.isEmpty { parts.append(area) }
        if placeCount > 0 {
            parts.append(triedCount == 0 ? "none tried yet" : "\(triedCount) tried")
        }
        return parts.joined(separator: " · ")
    }

    /// The category chips, skipping empty categories: "6 food & drinks".
    public var categoryChips: [(category: PlaceCategory, text: String)] {
        PlaceCategory.allCases.compactMap { category in
            let count = count(of: category)
            return count == 0 ? nil : (category, category.countText(count))
        }
    }

    /// The caption under the weather card: "Weather in Kyoto now". Only the
    /// first part of the area label — "in Kyoto, Japan now" reads worse.
    public var weatherCaption: String {
        let town = areaLabel.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return town.isEmpty ? "Weather here now" : "Weather in \(town) now"
    }

    /// "4 guides · 36 places", above the list and on the home peek.
    public static func overview(_ summaries: [GuideSummary]) -> String {
        guard !summaries.isEmpty else { return "" }
        let places = summaries.reduce(0) { $0 + $1.placeCount }
        return "\(counted(summaries.count, "guide")) · \(counted(places, "place"))"
    }

    /// The home screen row's line, for the integration step to use.
    public static func homeDetail(for summaries: [GuideSummary]) -> String {
        summaries.isEmpty ? "No guides yet" : overview(summaries)
    }
}

public extension GuideSummary {
    @MainActor
    static func summarize(_ guide: SharedGuide) -> GuideSummary {
        let places = guide.allPlaces
        var counts: [PlaceCategory: Int] = [:]
        for place in places {
            counts[place.category, default: 0] += 1
        }
        return GuideSummary(
            id: guide.objectID,
            name: guide.name,
            areaLabel: guide.areaLabel,
            placeCount: places.count,
            triedCount: places.count { $0.isTried },
            counts: counts,
            region: GuideRegion.enclosing(places.compactMap(\.point)),
            isPinned: guide.isPinned
        )
    }

    /// Pinned guides first, in the order they were pinned; then the rest,
    /// newest first — the one being built is the one being opened.
    ///
    /// Every guide used to be ordered newest first with the first one drawn as
    /// a large card, so whichever guide happened to be created last looked
    /// featured for no reason. Now all cards are the same size and standing out
    /// is something you choose, by pinning.
    @MainActor
    static func all(_ guides: [SharedGuide]) -> [GuideSummary] {
        guides
            .sorted { lhs, rhs in
                switch (lhs.pinnedAt, rhs.pinnedAt) {
                case let (left?, right?):
                    left < right
                case (_?, nil):
                    true
                case (nil, _?):
                    false
                case (nil, nil):
                    lhs.createdAt > rhs.createdAt
                }
            }
            .map(summarize)
    }
}
