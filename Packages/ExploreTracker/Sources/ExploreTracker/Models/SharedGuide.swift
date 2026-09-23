import CoreData
import Foundation

/// A named collection of places: somewhere to eat, something to see,
/// something to do — backed by Core Data / `NSPersistentCloudKitContainer`
/// rather than SwiftData, so it (and its whole place list) can be shared with
/// another person for live co-editing via `CKShare`, which SwiftData has no
/// support for at all. `SharedGuide` is the CKShare root: sharing granularity
/// is one guide, not the whole guide list. Its CloudKit-facing record type is
/// `SharedGuide`, matching this Swift class name (see `GuideModel.swift` for
/// the entity/class split and for why every initializer here goes through
/// `NSEntityDescription.entity(forEntityName:in:)` instead of this class's
/// own inherited `init(context:)`).
///
/// Deliberately has no centre, radius or dates. Its map and its weather are
/// worked out from where its places are (`GuideRegion`), so a guide for Kyoto
/// can be built from a sofa in Boston and still show Kyoto's weather. Dated
/// plans belong to Trips.
@objc(SharedGuide)
public final class SharedGuide: NSManagedObject, Identifiable {
    @NSManaged public var name: String
    /// Free text shown under the name, "Kyoto, Japan". Never geocoded.
    @NSManaged public var areaLabel: String
    @NSManaged public var notes: String
    @NSManaged public var createdAt: Date
    /// **Retired — nothing reads it and only `GuidePins.migrateRetiredPinnedAt`
    /// writes it, to clear it.** Pins live in `GuidePin` now.
    ///
    /// A pin stored on the guide record was shared with the guide: once a
    /// guide was shared, one person pinning it reordered everyone's list, and
    /// a read-only participant's pin saved locally but could never be written
    /// to CloudKit, so it silently never synced. Kept in the model only
    /// because a field can't be removed from a deployed CloudKit schema.
    @NSManaged public var pinnedAt: Date?
    /// Stable across devices and share participants because it syncs with
    /// the record — unlike `objectID`, which is per store and per device. The
    /// key `GuidePin` rows point at. A random UUID for a guide made on this
    /// build; `GuideIdentity.derived` for one that predates the field.
    @NSManaged public var identifier: String

    @NSManaged public var places: Set<SharedGuidePlace>?

    public convenience init(context: NSManagedObjectContext, name: String, areaLabel: String = "", notes: String = "") {
        let entity = NSEntityDescription.entity(forEntityName: GuideModel.EntityName.guide, in: context)!
        self.init(entity: entity, insertInto: context)
        self.name = name
        self.areaLabel = areaLabel
        self.notes = notes
        self.createdAt = .now
        // Here, not in `awakeFromInsert`: that also fires when CloudKit's
        // import inserts a guide some other device made, and a record from
        // before this field existed would then keep a random local UUID
        // instead of reaching `GuideIdentity.backfill` — each device keying
        // its pins to a different value for the same guide.
        self.identifier = UUID().uuidString
    }

    @nonobjc public static func fetchRequest(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<SharedGuide> {
        let request = NSFetchRequest<SharedGuide>(entityName: GuideModel.EntityName.guide)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return request
    }
}

public extension SharedGuide {
    var id: NSManagedObjectID { objectID }

    var allPlaces: [SharedGuidePlace] { Array(places ?? []) }

    /// One category's places in the order the guide lists them.
    func places(in category: PlaceCategory) -> [SharedGuidePlace] {
        PlaceOrdering.ordered(allPlaces.filter { $0.category == category })
    }
}
