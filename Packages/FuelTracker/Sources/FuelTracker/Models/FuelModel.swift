import CoreData
import Foundation

/// Builds the Core Data model behind Fuel's two entities, by hand rather than
/// a `.xcdatamodeld` — this repo's convention is hand-written, diffable,
/// comment-heavy Swift, and a `.xcdatamodeld` is an opaque plist directory
/// that does neither.
///
/// Every entity's `NSEntityDescription.name` — its CloudKit-facing record
/// type, via `CloudKitSchemaInitializer`'s "CD_" + name convention — is
/// distinct from the `CD_Vehicle` / `CD_FuelEntry` record types the original
/// SwiftData models (`Vehicle`, `FuelEntry` in the `SwiftData*.swift` files)
/// already occupy in the live CloudKit container, so deploying this schema
/// can never collide with them:
///
/// | Swift class       | Core Data entity name |
/// |--------------------|------------------------|
/// | `SharedVehicle`    | `SharedVehicle`        |
/// | `SharedFuelEntry`  | `SharedFuelEntry`      |
///
/// The Swift class name and the entity name are independent
/// (`NSEntityDescription.managedObjectClassName` vs `.name`) — nothing
/// requires them to match. They happen to match here (`SharedVehicle` the
/// class, `SharedVehicle` the entity) because that split is what let the
/// *other* side of this module, the SwiftData models, keep their exact
/// original names (`Vehicle`, not `LegacyVehicle`) instead: SwiftData has no
/// such split, so it was these Core Data classes that had to take the
/// `Shared` prefix rather than the SwiftData ones, or the SwiftData side's
/// CloudKit record type would have silently changed out from under the real
/// data already in Production. See `SharedVehicle.swift`'s doc comment for
/// the full story.
///
/// Because of that split, `NSManagedObject`'s own `init(context:)`
/// convenience initializer can't be used anywhere in this module: it
/// resolves the entity by matching the class's own name ("SharedVehicle")
/// against the model's entity names, which does find a match here — but
/// every initializer on these two classes still goes through
/// `NSEntityDescription.entity(forEntityName:in:)` explicitly rather than
/// relying on that, since the two are independent by design and lining up is
/// incidental. See each class's own file.
///
/// Sharing granularity is one `Vehicle` (with its `FuelEntry` children), not
/// the whole garage — `Vehicle` is the CKShare root.
public enum FuelModel {
    /// Entity names, kept next to the model that defines them rather than
    /// scattered across each class file, so the table above and the code can
    /// never drift apart.
    enum EntityName {
        static let vehicle = "SharedVehicle"
        static let entry = "SharedFuelEntry"
    }

    @MainActor
    public static func make() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let vehicle = NSEntityDescription()
        vehicle.name = EntityName.vehicle
        vehicle.managedObjectClassName = NSStringFromClass(SharedVehicle.self)

        let entry = NSEntityDescription()
        entry.name = EntityName.entry
        entry.managedObjectClassName = NSStringFromClass(SharedFuelEntry.self)

        vehicle.properties = [
            string("name", default: ""),
            date("createdAt", optional: false, default: .now),
        ]

        entry.properties = [
            string("kindRaw", default: EntryKind.fillUp.rawValue),
            date("date", optional: false, default: .now),
            integer("odometer", default: 0),
            double("gallons", default: 0),
            double("pricePerGallon", default: 0),
            double("totalCost", default: 0),
            bool("isFullTank", default: true),
            string("octane", default: ""),
            string("station", default: ""),
            string("notes", default: ""),
            string("services", default: ""),
        ]

        // MARK: Relationships
        //
        // Both sides need `inverseRelationship` set — unlike SwiftData's
        // single `inverse:` annotation on the to-many side, Core Data
        // validates that two relationships naming each other as inverse
        // actually do so, and a programmatic model with only one side wired
        // throws "no inverse relationship" at container load.

        let (entries, entryVehicle) = toManyPair(name: "entries", inverseName: "vehicle", from: vehicle, to: entry)
        vehicle.properties += [entries]
        entry.properties += [entryVehicle]

        model.entities = [vehicle, entry]
        return model
    }

    // MARK: - Attribute builders

    private static func string(_ name: String, default value: String) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .stringAttributeType
        attribute.isOptional = false
        attribute.defaultValue = value
        return attribute
    }

    private static func date(_ name: String, optional: Bool = true, default value: Date? = nil) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .dateAttributeType
        attribute.isOptional = optional
        attribute.defaultValue = value
        return attribute
    }

    private static func bool(_ name: String, default value: Bool) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .booleanAttributeType
        attribute.isOptional = false
        attribute.defaultValue = value
        return attribute
    }

    private static func integer(_ name: String, default value: Int) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        // Int64 so it matches Swift's `Int` bit for bit on every platform this
        // app ships on.
        attribute.attributeType = .integer64AttributeType
        attribute.isOptional = false
        attribute.defaultValue = value
        return attribute
    }

    private static func double(_ name: String, default value: Double) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .doubleAttributeType
        attribute.isOptional = false
        attribute.defaultValue = value
        return attribute
    }

    /// A to-many relationship from `from` to `to` (cascading — deleting the
    /// vehicle deletes its whole fuel log with it, the same rule the SwiftData
    /// models used), plus its to-one inverse, cross-wired to each other.
    private static func toManyPair(
        name: String,
        inverseName: String,
        from: NSEntityDescription,
        to: NSEntityDescription
    ) -> (toMany: NSRelationshipDescription, toOne: NSRelationshipDescription) {
        let toMany = NSRelationshipDescription()
        toMany.name = name
        toMany.destinationEntity = to
        toMany.minCount = 0
        toMany.maxCount = 0 // 0 means "to-many" to Core Data.
        toMany.deleteRule = .cascadeDeleteRule
        toMany.isOptional = true

        let toOne = NSRelationshipDescription()
        toOne.name = inverseName
        toOne.destinationEntity = from
        toOne.minCount = 0
        toOne.maxCount = 1
        toOne.deleteRule = .nullifyDeleteRule
        toOne.isOptional = true

        toMany.inverseRelationship = toOne
        toOne.inverseRelationship = toMany

        return (toMany, toOne)
    }
}
