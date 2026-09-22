import CoreData
import Foundation

/// A vehicle, backed by Core Data / `NSPersistentCloudKitContainer` rather
/// than SwiftData — see `FuelModel.swift` — so it (and its whole fuel log) can
/// be shared with another person for live co-editing via `CKShare`, which
/// SwiftData has no support for at all. `Vehicle` is the CKShare root:
/// sharing granularity is one vehicle, not the whole garage. Its
/// CloudKit-facing record type is `SharedVehicle`, not `Vehicle`: see
/// `FuelModel.swift` for why, and for why every initializer here goes through
/// `NSEntityDescription.entity(forEntityName:in:)` instead of this class's
/// own inherited `init(context:)`.
@objc(Vehicle)
public final class Vehicle: NSManagedObject, Identifiable {
    @NSManaged public var name: String
    @NSManaged public var createdAt: Date

    @NSManaged public var entries: Set<FuelEntry>?

    public convenience init(context: NSManagedObjectContext, name: String) {
        let entity = NSEntityDescription.entity(forEntityName: FuelModel.EntityName.vehicle, in: context)!
        self.init(entity: entity, insertInto: context)
        self.name = name
        self.createdAt = .now
    }

    @nonobjc public static func fetchRequest(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<Vehicle> {
        let request = NSFetchRequest<Vehicle>(entityName: FuelModel.EntityName.vehicle)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return request
    }
}

public extension Vehicle {
    var id: NSManagedObjectID { objectID }

    /// Fill-ups only, oldest first. Odometer order is authoritative because
    /// exported logs sometimes carry mistyped dates.
    var orderedFillUps: [FuelEntry] {
        (entries ?? [])
            .filter { $0.kind == .fillUp }
            .sorted { $0.odometer < $1.odometer }
    }

    var orderedServices: [FuelEntry] {
        (entries ?? [])
            .filter { $0.kind == .service }
            .sorted { $0.date > $1.date }
    }
}
