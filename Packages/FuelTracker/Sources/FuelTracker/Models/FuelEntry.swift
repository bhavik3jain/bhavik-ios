import CoreData
import Foundation

/// A fill-up or service record, backed by Core Data /
/// `NSPersistentCloudKitContainer` rather than SwiftData, so it travels with
/// its vehicle when that vehicle is shared for live co-editing. Its
/// CloudKit-facing record type is `SharedFuelEntry`, not `FuelEntry`: see
/// `FuelModel.swift` for why, and for why every initializer here goes through
/// `NSEntityDescription.entity(forEntityName:in:)` instead of this class's
/// own inherited `init(context:)`.
@objc(FuelEntry)
public final class FuelEntry: NSManagedObject, Identifiable {
    @NSManaged public var kindRaw: String
    @NSManaged public var date: Date
    @NSManaged public var odometer: Int
    @NSManaged public var gallons: Double
    @NSManaged public var pricePerGallon: Double
    @NSManaged public var totalCost: Double
    /// A partial fill leaves the tank in an unknown state, so its distance
    /// carries forward into the next full tank rather than yielding its own MPG.
    @NSManaged public var isFullTank: Bool
    @NSManaged public var octane: String
    @NSManaged public var station: String
    @NSManaged public var notes: String
    /// Service work performed, comma-separated as it appears in exports.
    @NSManaged public var services: String

    @NSManaged public var vehicle: Vehicle?

    public convenience init(
        context: NSManagedObjectContext,
        kind: EntryKind = .fillUp,
        date: Date,
        odometer: Int,
        gallons: Double = 0,
        pricePerGallon: Double = 0,
        totalCost: Double = 0,
        isFullTank: Bool = true,
        octane: String = "",
        station: String = "",
        notes: String = "",
        services: String = ""
    ) {
        let entity = NSEntityDescription.entity(forEntityName: FuelModel.EntityName.entry, in: context)!
        self.init(entity: entity, insertInto: context)
        self.kindRaw = kind.rawValue
        self.date = date
        self.odometer = odometer
        self.gallons = gallons
        self.pricePerGallon = pricePerGallon
        self.totalCost = totalCost
        self.isFullTank = isFullTank
        self.octane = octane
        self.station = station
        self.notes = notes
        self.services = services
    }

    @nonobjc public static func fetchRequest(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<FuelEntry> {
        let request = NSFetchRequest<FuelEntry>(entityName: FuelModel.EntityName.entry)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return request
    }
}

public extension FuelEntry {
    var id: NSManagedObjectID { objectID }

    var kind: EntryKind {
        get { EntryKind(rawValue: kindRaw) ?? .fillUp }
        set { kindRaw = newValue.rawValue }
    }
}
