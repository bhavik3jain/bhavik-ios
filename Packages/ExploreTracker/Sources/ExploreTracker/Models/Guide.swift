import Core
import Foundation
import SwiftData

/// The three shelves every guide is split into.
public enum PlaceCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case foodAndDrinks
    case places
    case activities

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .foodAndDrinks: "Food & Drinks"
        case .places: "Places"
        case .activities: "Activities"
        }
    }

    /// The map's filter chips are narrower than the segmented control.
    public var shortName: String {
        switch self {
        case .foodAndDrinks: "Food"
        case .places: "Places"
        case .activities: "Activities"
        }
    }

    public var symbolName: String {
        switch self {
        case .foodAndDrinks: "fork.knife"
        case .places: "building.columns.fill"
        case .activities: "figure.walk"
        }
    }

    /// "6 food & drinks", "1 place", "2 activities" — the chips on a guide card.
    public func countText(_ count: Int) -> String {
        switch self {
        case .foodAndDrinks: counted(count, "food & drink", plural: "food & drinks")
        case .places: counted(count, "place")
        case .activities: counted(count, "activity", plural: "activities")
        }
    }
}

/// A named collection of places: somewhere to eat, something to see, something
/// to do.
///
/// Deliberately has no centre, radius or dates. Its map and its weather are
/// worked out from where its places are (`GuideRegion`), so a guide for Kyoto
/// can be built from a sofa in Boston and still show Kyoto's weather. Dated
/// plans belong to Trips.
@Model
public final class Guide {
    public var name: String = ""
    /// Free text shown under the name, "Kyoto, Japan". Never geocoded.
    public var areaLabel: String = ""
    public var notes: String = ""
    public var createdAt: Date = Date.now
    /// When the guide was pinned to the top of the list; `nil` when it isn't.
    /// A date rather than a Bool so pinned guides keep the order they were
    /// pinned in, instead of reshuffling each time another is pinned.
    public var pinnedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \GuidePlace.guide)
    public var places: [GuidePlace]? = []

    public init(name: String, areaLabel: String = "", notes: String = "") {
        self.name = name
        self.areaLabel = areaLabel
        self.notes = notes
        self.createdAt = .now
    }

    public var allPlaces: [GuidePlace] { places ?? [] }

    public var isPinned: Bool { pinnedAt != nil }

    /// Pinning an already-pinned guide keeps its original date, so it doesn't
    /// jump behind guides pinned after it.
    public func setPinned(_ pinned: Bool, asOf now: Date = .now) {
        if pinned {
            if pinnedAt == nil { pinnedAt = now }
        } else {
            pinnedAt = nil
        }
    }

    /// One category's places in the order the guide lists them.
    public func places(in category: PlaceCategory) -> [GuidePlace] {
        PlaceOrdering.ordered(allPlaces.filter { $0.category == category })
    }
}

@Model
public final class GuidePlace {
    public var name: String = ""
    /// A few words of why it's on the list, "go before 11:30".
    public var note: String = ""
    public var address: String = ""
    public var categoryRaw: String = PlaceCategory.places.rawValue
    /// Both `nil` for a place added by hand; such a place is listed but never
    /// drawn on a map or counted toward the guide's region.
    public var latitude: Double?
    public var longitude: Double?
    public var isTried: Bool = false
    /// 1 to 5 once tried; 0 means no rating given.
    public var rating: Int = 0
    public var triedAt: Date?
    public var addedAt: Date = Date.now

    public var guide: Guide?

    public var category: PlaceCategory {
        get { PlaceCategory(rawValue: categoryRaw) ?? .places }
        set { categoryRaw = newValue.rawValue }
    }

    public var point: GeoPoint? {
        guard let latitude, let longitude else { return nil }
        return GeoPoint(latitude: latitude, longitude: longitude)
    }

    public init(
        name: String,
        category: PlaceCategory,
        note: String = "",
        address: String = "",
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.name = name
        self.categoryRaw = category.rawValue
        self.note = note
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.addedAt = .now
    }

    /// Flips a place between To try and Tried. Un-trying drops the rating too:
    /// a rating left behind on a To try place would resurface, unasked for,
    /// the next time it was ticked off.
    public func setTried(_ tried: Bool, asOf now: Date = .now) {
        isTried = tried
        if tried {
            if triedAt == nil { triedAt = now }
        } else {
            triedAt = nil
            rating = 0
        }
    }
}
