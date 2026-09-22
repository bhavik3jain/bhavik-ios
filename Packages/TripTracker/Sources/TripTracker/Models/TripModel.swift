import CoreData
import Foundation

/// Builds the Core Data model behind Trips' four entities, by hand rather than
/// a `.xcdatamodeld` — this repo's convention is hand-written, diffable,
/// comment-heavy Swift, and a `.xcdatamodeld` is an opaque plist directory that
/// does neither.
///
/// Every entity's `NSEntityDescription.name` — its CloudKit-facing record type,
/// via `CloudKitSchemaInitializer`'s "CD_" + name convention — is distinct from
/// the `CD_Trip` / `CD_ItineraryItem` / `CD_Flight` / `CD_Booking` record types
/// the original SwiftData models (`Trip`, `ItineraryItem`, `Flight`, `Booking`
/// in the `SwiftData*.swift` files) already occupy in the live CloudKit
/// container, so deploying this schema can never collide with them:
///
/// | Swift class            | Core Data entity name  |
/// |-------------------------|------------------------|
/// | `SharedTrip`            | `SharedTrip`           |
/// | `SharedItineraryItem`   | `SharedItineraryItem`  |
/// | `SharedFlight`          | `SharedFlight`         |
/// | `SharedBooking`         | `SharedBooking`        |
///
/// The Swift class name and the entity name are independent
/// (`NSEntityDescription.managedObjectClassName` vs `.name`) — nothing requires
/// them to match. They happen to match here (`SharedTrip` the class,
/// `SharedTrip` the entity) because that split is what let the *other* side of
/// this module, the SwiftData models, keep their exact original names (`Trip`,
/// not `LegacyTrip`) instead: SwiftData has no such split, so it was these
/// Core Data classes that had to take the `Shared` prefix rather than the
/// SwiftData ones, or the SwiftData side's CloudKit record type would have
/// silently changed out from under the real data already in Production. See
/// `SharedTrip.swift`'s doc comment for the full story.
///
/// Because of that split, `NSManagedObject`'s own `init(context:)` convenience
/// initializer can't be used anywhere in this module: it resolves the entity
/// by matching the class's own name ("SharedTrip") against the model's entity
/// names, which does find a match here — but every initializer on these four
/// classes still goes through `NSEntityDescription.entity(forEntityName:in:)`
/// explicitly rather than relying on that, since the two are independent by
/// design and lining up is incidental. See each class's own file.
public enum TripModel {
    /// Entity names, kept next to the model that defines them rather than
    /// scattered across each class file, so the table above and the code can
    /// never drift apart.
    enum EntityName {
        static let trip = "SharedTrip"
        static let item = "SharedItineraryItem"
        static let flight = "SharedFlight"
        static let booking = "SharedBooking"
    }

    @MainActor
    public static func make() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let trip = NSEntityDescription()
        trip.name = EntityName.trip
        trip.managedObjectClassName = NSStringFromClass(SharedTrip.self)

        let item = NSEntityDescription()
        item.name = EntityName.item
        item.managedObjectClassName = NSStringFromClass(SharedItineraryItem.self)

        let flight = NSEntityDescription()
        flight.name = EntityName.flight
        flight.managedObjectClassName = NSStringFromClass(SharedFlight.self)

        let booking = NSEntityDescription()
        booking.name = EntityName.booking
        booking.managedObjectClassName = NSStringFromClass(SharedBooking.self)

        trip.properties = [
            string("title", default: ""),
            string("destination", default: ""),
            date("startDate", optional: false, default: .now),
            date("endDate", optional: false, default: .now),
            string("notes", default: ""),
            bool("isArchived", default: false),
            date("createdAt", optional: false, default: .now),
            // "latitudeNumber"/"longitudeNumber", not "latitude"/"longitude" —
            // see Trip.latitudeNumber's doc comment: the Swift property name
            // and this attribute's name must match exactly for `@NSManaged` to
            // resolve it via KVC.
            double("latitudeNumber"),
            double("longitudeNumber"),
        ]

        item.properties = [
            string("title", default: ""),
            string("detail", default: ""),
            string("address", default: ""),
            string("kindRaw", default: ItemKind.other.rawValue),
            integer("dayIndex", default: 0),
            integer("sortOrder", default: 0),
            integer("durationMinutes", default: 0),
            bool("isDone", default: false),
            date("startTime"),
            date("doneAt"),
            double("latitudeNumber"),
            double("longitudeNumber"),
        ]

        flight.properties = [
            string("airlineCode", default: ""),
            string("number", default: ""),
            string("originCode", default: ""),
            string("destinationCode", default: ""),
            string("seat", default: ""),
            string("terminal", default: ""),
            string("confirmationCode", default: ""),
            string("notes", default: ""),
            integer("dayIndex", default: 0),
            date("departsAt"),
            date("arrivesAt"),
        ]

        let secureNote = string("secureNote", default: "")
        // The one Core Data equivalent of SwiftData's `@Attribute(.allowsCloudEncryption)`
        // this module needs — a real, direct attribute flag, no extra CloudKit
        // plumbing required.
        secureNote.allowsCloudEncryption = true

        booking.properties = [
            string("title", default: ""),
            string("provider", default: ""),
            string("code", default: ""),
            string("kindRaw", default: BookingKind.other.rawValue),
            string("contactPhone", default: ""),
            string("notes", default: ""),
            integer("sortOrder", default: 0),
            date("startsAt"),
            date("endsAt"),
            secureNote,
        ]

        // MARK: Relationships
        //
        // Every to-many/to-one pair below needs its `inverseRelationship` set on
        // BOTH sides — unlike SwiftData's single `inverse:` annotation on the
        // to-many side, Core Data validates that two relationships naming each
        // other as inverse actually do so, and a programmatic model with only
        // one side wired throws "no inverse relationship" at container load.

        let (items, itemTrip) = toManyPair(name: "items", inverseName: "trip", from: trip, to: item)
        let (flights, flightTrip) = toManyPair(name: "flights", inverseName: "trip", from: trip, to: flight)
        let (bookings, bookingTrip) = toManyPair(name: "bookings", inverseName: "trip", from: trip, to: booking)

        trip.properties += [items, flights, bookings]
        item.properties += [itemTrip]
        flight.properties += [flightTrip]
        booking.properties += [bookingTrip]

        model.entities = [trip, item, flight, booking]
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

    /// An optional `Double?` attribute — `latitude`/`longitude` on both `Trip`
    /// and `ItineraryItem`. No default: nil means "no coordinate", not zero.
    private static func double(_ name: String) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .doubleAttributeType
        attribute.isOptional = true
        return attribute
    }

    /// A to-many relationship from `from` to `to` (cascading — deleting the
    /// trip deletes everything hanging off it, the same rule the SwiftData
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
