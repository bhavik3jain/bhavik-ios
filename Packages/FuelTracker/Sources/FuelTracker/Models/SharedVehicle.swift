import CoreData
import Foundation

/// A vehicle, backed by Core Data / `NSPersistentCloudKitContainer` rather
/// than SwiftData — see `FuelModel.swift` — so it (and its whole fuel log) can
/// be shared with another person for live co-editing via `CKShare`, which
/// SwiftData has no support for at all. Its CloudKit-facing record type is
/// `SharedVehicle`, and as of this class the Swift class name matches it
/// exactly — see `FuelModel.swift` for why that split exists, and for why
/// every initializer here goes through `NSEntityDescription.entity(forEntityName:in:)`
/// instead of this class's own inherited `init(context:)`. `SharedVehicle` is
/// the CKShare root: sharing granularity is one vehicle, not the whole garage.
///
/// Named `SharedVehicle`, not `Vehicle`: the plain name belongs to the *other*
/// `Vehicle` type in this module — the original SwiftData `@Model` in
/// `SwiftDataVehicle.swift` — which must keep it, because SwiftData ties a
/// model's identity, and its CloudKit record type (`CD_<ClassName>`), to the
/// Swift class name with no way to decouple the two short of a
/// `VersionedSchema`/`SchemaMigrationPlan` this repo has never used. An
/// earlier version of this migration had that backwards — it renamed the
/// SwiftData class to `LegacyVehicle`, which silently orphaned every real,
/// already-synced `CD_Vehicle` record in Production, and renamed this Core
/// Data class to the clean `Vehicle` instead. Core Data has no such constraint
/// (`NSEntityDescription.name` is independent of the Swift class name), so
/// this is the side that can safely carry a different name.
@objc(SharedVehicle)
public final class SharedVehicle: NSManagedObject, Identifiable {
    @NSManaged public var name: String
    @NSManaged public var createdAt: Date

    @NSManaged public var entries: Set<SharedFuelEntry>?

    public convenience init(context: NSManagedObjectContext, name: String) {
        let entity = NSEntityDescription.entity(forEntityName: FuelModel.EntityName.vehicle, in: context)!
        self.init(entity: entity, insertInto: context)
        self.name = name
        self.createdAt = .now
    }

    @nonobjc public static func fetchRequest(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<SharedVehicle> {
        let request = NSFetchRequest<SharedVehicle>(entityName: FuelModel.EntityName.vehicle)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return request
    }
}

public extension SharedVehicle {
    var id: NSManagedObjectID { objectID }

    /// Fill-ups only, oldest first. Odometer order is authoritative because
    /// exported logs sometimes carry mistyped dates.
    var orderedFillUps: [SharedFuelEntry] {
        (entries ?? [])
            .filter { $0.kind == .fillUp }
            .sorted { $0.odometer < $1.odometer }
    }

    var orderedServices: [SharedFuelEntry] {
        (entries ?? [])
            .filter { $0.kind == .service }
            .sorted { $0.date > $1.date }
    }
}
