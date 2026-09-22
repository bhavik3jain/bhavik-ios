import Core
import Foundation
import SwiftData

/// The original SwiftData models. These keep their original class names —
/// `Guide` / `GuidePlace` — because SwiftData ties a model's identity, and its
/// CloudKit record type (`CD_Guide` / `CD_GuidePlace`), directly to the Swift
/// class name, with no way to preserve identity across a rename without an
/// explicit `VersionedSchema`/`SchemaMigrationPlan` (this repo has never used
/// one). Renaming this class would make SwiftData treat it as a brand-new,
/// unrelated entity and orphan every already-synced `CD_Guide` record in
/// Production. This is the new Core Data side that got the `Shared` prefix
/// instead — see `SharedGuide.swift`/`SharedGuidePlace.swift`. This file is a
/// pure rename of the SwiftData models — every stored property, relationship
/// and annotation is byte-for-byte what they have always been — so it is safe
/// against the schema already deployed to Production.
///
/// `ExploreTrackerModule.models` still registers these types (as
/// `Guide.self`/`GuidePlace.self`) so `AppSchema.models` keeps them in
/// `BhavikApp`'s SwiftData container: the one-time importer in
/// `ExploreLegacyMigration.swift` reads through them to copy real guides into
/// the new Core Data store. Do NOT remove them from `AppSchema.models` — that
/// is a separate, later, human-gated step, only once the user has confirmed
/// on a real device that their existing data survived that import.
///
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
    ///
    /// Inlined against `PlaceOrdering.Key`/`.precedes` rather than calling
    /// `PlaceOrdering.ordered(_:)` — that helper is typed for the new Core
    /// Data `GuidePlace`, and this legacy model has nothing left to migrate
    /// to that type for.
    public func places(in category: PlaceCategory) -> [GuidePlace] {
        allPlaces
            .filter { $0.category == category }
            .sorted {
                PlaceOrdering.precedes(
                    PlaceOrdering.Key(name: $0.name, isTried: $0.isTried, rating: $0.rating, addedAt: $0.addedAt),
                    PlaceOrdering.Key(name: $1.name, isTried: $1.isTried, rating: $1.rating, addedAt: $1.addedAt)
                )
            }
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
