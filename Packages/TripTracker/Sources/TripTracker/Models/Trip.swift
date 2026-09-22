import CoreData
import Foundation

/// A trip, backed by Core Data / `NSPersistentCloudKitContainer` rather than
/// SwiftData — see `TripModel.swift` — so it can be shared with another person
/// for live co-editing via `CKShare`, which SwiftData has no support for at
/// all. Its CloudKit-facing record type is `SharedTrip`, not `Trip`: see
/// `TripModel.swift` for why, and for why every initializer here goes through
/// `NSEntityDescription.entity(forEntityName:in:)` instead of this class's own
/// inherited `init(context:)`.
@objc(Trip)
public final class Trip: NSManagedObject, Identifiable {
    @NSManaged public var title: String
    /// What was picked in the destination search, "Rome, Italy".
    @NSManaged public var destination: String
    /// The first day, stored as the start of that local day.
    @NSManaged public var startDate: Date
    /// The last day, inclusive, stored as the start of that local day.
    @NSManaged public var endDate: Date
    @NSManaged public var notes: String
    @NSManaged public var isArchived: Bool
    @NSManaged public var createdAt: Date
    /// The destination's coordinate, which is what weather is fetched for. Both
    /// stay nil when a destination was typed rather than picked from the search,
    /// and the trip then simply shows no weather.
    ///
    /// Stored as `NSNumber?`, not `Double?` directly: `@NSManaged` implies
    /// `@objc dynamic`, and a bare `Double?` can't be represented in
    /// Objective-C (unlike a class type such as `NSNumber`, or a non-optional
    /// scalar). `latitude`/`longitude` below are the `Double?` this class
    /// actually exposes.
    @NSManaged var latitudeNumber: NSNumber?
    @NSManaged var longitudeNumber: NSNumber?

    // No stored phase. "In progress" is a fact about today, and a stored flag
    // would be wrong every morning — nothing runs in the background to flip it
    // (the app has no background work at all). `TripPhase.of(_:asOf:)` derives
    // it each time it is asked.

    @NSManaged public var items: Set<ItineraryItem>?
    @NSManaged public var flights: Set<Flight>?
    @NSManaged public var bookings: Set<Booking>?

    public convenience init(
        context: NSManagedObjectContext,
        title: String,
        destination: String = "",
        startDate: Date,
        endDate: Date,
        calendar: Calendar = .current
    ) {
        let entity = NSEntityDescription.entity(forEntityName: TripModel.EntityName.trip, in: context)!
        self.init(entity: entity, insertInto: context)
        self.title = title
        self.destination = destination
        self.startDate = calendar.startOfDay(for: startDate)
        self.endDate = calendar.startOfDay(for: max(startDate, endDate))
        self.createdAt = .now
    }

    @nonobjc public static func fetchRequest(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<Trip> {
        let request = NSFetchRequest<Trip>(entityName: TripModel.EntityName.trip)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return request
    }
}

public extension Trip {
    var id: NSManagedObjectID { objectID }

    var latitude: Double? {
        get { latitudeNumber?.doubleValue }
        set { latitudeNumber = newValue.map(NSNumber.init) }
    }

    var longitude: Double? {
        get { longitudeNumber?.doubleValue }
        set { longitudeNumber = newValue.map(NSNumber.init) }
    }

    var hasCoordinate: Bool { latitude != nil && longitude != nil }

    var dates: TripDates { TripDates(start: startDate, end: endDate) }

    /// Items with somewhere to put a pin. What the trip list and the PDF call
    /// "places".
    var places: [ItineraryItem] {
        (items ?? []).filter(\.hasCoordinate)
    }

    /// Pulls anything planned past the last day back onto it. Shortening a trip
    /// otherwise left those items on days that no longer exist — on no chip, in
    /// no timeline, still counted as places — with no way to reach them.
    func clampPlanToDates() {
        let last = dates.dayCount - 1
        for item in items ?? [] where item.dayIndex > last || item.dayIndex < 0 {
            item.dayIndex = min(max(item.dayIndex, 0), last)
        }
        for flight in flights ?? [] where flight.dayIndex > last || flight.dayIndex < 0 {
            flight.dayIndex = min(max(flight.dayIndex, 0), last)
        }
    }
}
