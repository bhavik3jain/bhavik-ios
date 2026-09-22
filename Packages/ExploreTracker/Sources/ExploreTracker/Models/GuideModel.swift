import CoreData
import Foundation

/// Builds the Core Data model behind Explore's two entities, by hand rather
/// than a `.xcdatamodeld` — this repo's convention is hand-written, diffable,
/// comment-heavy Swift, and a `.xcdatamodeld` is an opaque plist directory
/// that does neither.
///
/// Every entity's `NSEntityDescription.name` — its CloudKit-facing record
/// type, via `CloudKitSchemaInitializer`'s "CD_" + name convention — is
/// distinct from the `CD_Guide` / `CD_GuidePlace` record types the `Legacy*`
/// SwiftData models already occupy in the live CloudKit container, so
/// deploying this schema can never collide with them:
///
/// | Swift class  | Core Data entity name |
/// |----------------|------------------------|
/// | `Guide`        | `SharedGuide`          |
/// | `GuidePlace`    | `SharedGuidePlace`     |
///
/// The Swift class name and the entity name are independent
/// (`NSEntityDescription.managedObjectClassName` vs `.name`) — that's what
/// lets the Swift-facing type keep the clean original name (`Guide`, not
/// `SharedGuide`) while the CloudKit-facing record type is the new,
/// non-colliding one.
///
/// Because of that split, `NSManagedObject`'s own `init(context:)`
/// convenience initializer can't be used anywhere in this module: it
/// resolves the entity by matching the class's own name ("Guide") against
/// the model's entity names, and finds nothing, since the entity is named
/// "SharedGuide". Every initializer on these two classes goes through
/// `NSEntityDescription.entity(forEntityName:in:)` explicitly instead — see
/// each class's own file.
///
/// Sharing granularity is one `Guide` (with its `GuidePlace` children), not
/// the whole guide list — `Guide` is the CKShare root.
public enum GuideModel {
    /// Entity names, kept next to the model that defines them rather than
    /// scattered across each class file, so the table above and the code can
    /// never drift apart.
    enum EntityName {
        static let guide = "SharedGuide"
        static let place = "SharedGuidePlace"
    }

    @MainActor
    public static func make() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let guide = NSEntityDescription()
        guide.name = EntityName.guide
        guide.managedObjectClassName = NSStringFromClass(Guide.self)

        let place = NSEntityDescription()
        place.name = EntityName.place
        place.managedObjectClassName = NSStringFromClass(GuidePlace.self)

        guide.properties = [
            string("name", default: ""),
            string("areaLabel", default: ""),
            string("notes", default: ""),
            date("createdAt", optional: false, default: .now),
            date("pinnedAt"),
        ]

        place.properties = [
            string("name", default: ""),
            string("note", default: ""),
            string("address", default: ""),
            string("categoryRaw", default: PlaceCategory.places.rawValue),
            double("latitudeNumber"),
            double("longitudeNumber"),
            bool("isTried", default: false),
            integer("rating", default: 0),
            date("triedAt"),
            date("addedAt", optional: false, default: .now),
        ]

        // MARK: Relationships
        //
        // Both sides need `inverseRelationship` set — unlike SwiftData's
        // single `inverse:` annotation on the to-many side, Core Data
        // validates that two relationships naming each other as inverse
        // actually do so, and a programmatic model with only one side wired
        // throws "no inverse relationship" at container load.

        let (places, placeGuide) = toManyPair(name: "places", inverseName: "guide", from: guide, to: place)
        guide.properties += [places]
        place.properties += [placeGuide]

        model.entities = [guide, place]
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

    /// An optional `Double?` attribute — `latitude`/`longitude` on
    /// `GuidePlace`. No default: nil means "no coordinate", not zero.
    private static func double(_ name: String) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .doubleAttributeType
        attribute.isOptional = true
        return attribute
    }

    /// A to-many relationship from `from` to `to` (cascading — deleting the
    /// guide deletes its whole place list with it, the same rule the
    /// SwiftData models used), plus its to-one inverse, cross-wired to each
    /// other.
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
