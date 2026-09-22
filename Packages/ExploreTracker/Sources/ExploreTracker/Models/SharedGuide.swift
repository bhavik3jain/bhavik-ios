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
    /// When the guide was pinned to the top of the list; `nil` when it isn't.
    /// A date rather than a Bool so pinned guides keep the order they were
    /// pinned in, instead of reshuffling each time another is pinned.
    @NSManaged public var pinnedAt: Date?

    @NSManaged public var places: Set<SharedGuidePlace>?

    public convenience init(context: NSManagedObjectContext, name: String, areaLabel: String = "", notes: String = "") {
        let entity = NSEntityDescription.entity(forEntityName: GuideModel.EntityName.guide, in: context)!
        self.init(entity: entity, insertInto: context)
        self.name = name
        self.areaLabel = areaLabel
        self.notes = notes
        self.createdAt = .now
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

    var isPinned: Bool { pinnedAt != nil }

    /// Pinning an already-pinned guide keeps its original date, so it doesn't
    /// jump behind guides pinned after it.
    func setPinned(_ pinned: Bool, asOf now: Date = .now) {
        if pinned {
            if pinnedAt == nil { pinnedAt = now }
        } else {
            pinnedAt = nil
        }
    }

    /// One category's places in the order the guide lists them.
    func places(in category: PlaceCategory) -> [SharedGuidePlace] {
        PlaceOrdering.ordered(allPlaces.filter { $0.category == category })
    }
}
