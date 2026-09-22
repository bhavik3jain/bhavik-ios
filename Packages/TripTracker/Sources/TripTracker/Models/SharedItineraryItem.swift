import CoreData
import Foundation

/// One thing on a trip's plan — backed by Core Data / `NSPersistentCloudKitContainer`
/// rather than SwiftData, so a trip's whole plan can be shared for live
/// co-editing. Its CloudKit-facing record type is `SharedItineraryItem`, and
/// the Swift class name matches it exactly — see `SharedTrip.swift` for why
/// this class carries the `Shared` prefix while the original SwiftData model
/// keeps the plain `ItineraryItem` name, and `TripModel.swift` for why every
/// initializer here goes through `NSEntityDescription.entity(forEntityName:in:)`
/// instead of this class's own inherited `init(context:)`.
@objc(SharedItineraryItem)
public final class SharedItineraryItem: NSManagedObject, Identifiable {
    @NSManaged public var title: String
    @NSManaged public var detail: String
    @NSManaged public var kindRaw: String
    /// Days from the trip's first day, not a date — so moving a trip's dates
    /// carries its whole plan along instead of stranding it on the old days.
    @NSManaged public var dayIndex: Int
    /// Settles order among items that share a time, or have none.
    @NSManaged public var sortOrder: Int
    /// Only the time of day is read; the day comes from `dayIndex`, for the same
    /// reason as above.
    @NSManaged public var startTime: Date?
    /// Zero for "no set length".
    @NSManaged public var durationMinutes: Int
    @NSManaged public var address: String
    /// Stored as `NSNumber?`, not `Double?` directly — see `SharedTrip.latitudeNumber`'s
    /// doc comment for why. `latitude`/`longitude` below are the `Double?` this
    /// class actually exposes.
    @NSManaged var latitudeNumber: NSNumber?
    @NSManaged var longitudeNumber: NSNumber?
    @NSManaged public var isDone: Bool
    @NSManaged public var doneAt: Date?

    @NSManaged public var trip: SharedTrip?

    public convenience init(
        context: NSManagedObjectContext,
        title: String,
        kind: ItemKind = .other,
        dayIndex: Int,
        startTime: Date? = nil,
        sortOrder: Int = 0
    ) {
        let entity = NSEntityDescription.entity(forEntityName: TripModel.EntityName.item, in: context)!
        self.init(entity: entity, insertInto: context)
        self.title = title
        self.kindRaw = kind.rawValue
        self.dayIndex = dayIndex
        self.startTime = startTime
        self.sortOrder = sortOrder
        // Everything else (durationMinutes, address, isDone) keeps the model's
        // own default — see TripModel.swift.
    }

    @nonobjc public static func fetchRequest(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<SharedItineraryItem> {
        let request = NSFetchRequest<SharedItineraryItem>(entityName: TripModel.EntityName.item)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return request
    }
}

public extension SharedItineraryItem {
    var id: NSManagedObjectID { objectID }

    var kind: ItemKind {
        get { ItemKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    var latitude: Double? {
        get { latitudeNumber?.doubleValue }
        set { latitudeNumber = newValue.map(NSNumber.init) }
    }

    var longitude: Double? {
        get { longitudeNumber?.doubleValue }
        set { longitudeNumber = newValue.map(NSNumber.init) }
    }

    var hasCoordinate: Bool { latitude != nil && longitude != nil }

    func toggleDone(asOf now: Date = .now) {
        isDone.toggle()
        doneAt = isDone ? now : nil
    }
}
