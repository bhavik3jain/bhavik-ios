import CoreData
import Foundation

/// A flight on a trip — backed by Core Data / `NSPersistentCloudKitContainer`
/// rather than SwiftData, so a trip's whole plan can be shared for live
/// co-editing. Its CloudKit-facing record type is `SharedFlight`, not
/// `Flight`: see `TripModel.swift` for why, and for why every initializer
/// here goes through `NSEntityDescription.entity(forEntityName:in:)` instead
/// of this class's own inherited `init(context:)`.
@objc(Flight)
public final class Flight: NSManagedObject, Identifiable {
    /// "BA".
    @NSManaged public var airlineCode: String
    /// "286".
    @NSManaged public var number: String
    /// Airport codes, "FCO".
    @NSManaged public var originCode: String
    @NSManaged public var destinationCode: String
    /// Real moments, unlike an item's time: a flight doesn't move when the trip
    /// around it is rescheduled.
    @NSManaged public var departsAt: Date?
    @NSManaged public var arrivesAt: Date?
    @NSManaged public var seat: String
    @NSManaged public var terminal: String
    @NSManaged public var confirmationCode: String
    /// Which day of the trip the flight sits under.
    @NSManaged public var dayIndex: Int
    @NSManaged public var notes: String

    @NSManaged public var trip: Trip?

    public convenience init(
        context: NSManagedObjectContext,
        airlineCode: String,
        number: String,
        originCode: String,
        destinationCode: String,
        dayIndex: Int
    ) {
        let entity = NSEntityDescription.entity(forEntityName: TripModel.EntityName.flight, in: context)!
        self.init(entity: entity, insertInto: context)
        self.airlineCode = airlineCode
        self.number = number
        self.originCode = originCode
        self.destinationCode = destinationCode
        self.dayIndex = dayIndex
    }

    @nonobjc public static func fetchRequest(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<Flight> {
        let request = NSFetchRequest<Flight>(entityName: TripModel.EntityName.flight)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return request
    }
}

public extension Flight {
    var id: NSManagedObjectID { objectID }

    /// "BA 286", or whatever part of it exists.
    var designator: String {
        [airlineCode, number].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "FCO → LHR".
    var route: String {
        guard !originCode.isEmpty || !destinationCode.isEmpty else { return "" }
        return "\(originCode.isEmpty ? "?" : originCode) → \(destinationCode.isEmpty ? "?" : destinationCode)"
    }

    /// "BA 286 · FCO → LHR".
    var headline: String {
        let parts = [designator, route].filter { !$0.isEmpty }
        return parts.isEmpty ? "Flight" : parts.joined(separator: " · ")
    }
}
