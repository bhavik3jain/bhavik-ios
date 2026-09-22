import CoreData
import Foundation

/// A booking on a trip — a stay, a car, tickets — backed by Core Data /
/// `NSPersistentCloudKitContainer` rather than SwiftData, so a trip's whole
/// plan can be shared for live co-editing. Its CloudKit-facing record type is
/// `SharedBooking`, not `Booking`: see `TripModel.swift` for why, and for why
/// every initializer here goes through
/// `NSEntityDescription.entity(forEntityName:in:)` instead of this class's own
/// inherited `init(context:)`.
@objc(Booking)
public final class Booking: NSManagedObject, Identifiable {
    /// "Hotel de Russie".
    @NSManaged public var title: String
    /// Who it's with, "Avis".
    @NSManaged public var provider: String
    /// The confirmation code, the thing the Codes screen exists to copy.
    @NSManaged public var code: String
    @NSManaged public var kindRaw: String
    /// Check-in, pick-up, doors open.
    @NSManaged public var startsAt: Date?
    /// Check-out, drop-off.
    @NSManaged public var endsAt: Date?
    @NSManaged public var contactPhone: String
    @NSManaged public var notes: String
    @NSManaged public var sortOrder: Int
    /// Door codes, key-safe PINs. Encrypted end to end in CloudKit rather than
    /// only at rest (`TripModel.make()` sets `.allowsCloudEncryption = true` on
    /// this attribute, the direct Core Data equivalent of SwiftData's
    /// `@Attribute(.allowsCloudEncryption)`), masked on screen until asked for,
    /// and never passed to the PDF's page model — a shared itinerary goes to
    /// people who shouldn't be able to open the flat.
    @NSManaged public var secureNote: String

    @NSManaged public var trip: Trip?

    public convenience init(
        context: NSManagedObjectContext,
        title: String,
        kind: BookingKind,
        code: String = "",
        provider: String = ""
    ) {
        let entity = NSEntityDescription.entity(forEntityName: TripModel.EntityName.booking, in: context)!
        self.init(entity: entity, insertInto: context)
        self.title = title
        self.kindRaw = kind.rawValue
        self.code = code
        self.provider = provider
    }

    @nonobjc public static func fetchRequest(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<Booking> {
        let request = NSFetchRequest<Booking>(entityName: TripModel.EntityName.booking)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return request
    }
}

public extension Booking {
    var id: NSManagedObjectID { objectID }

    var kind: BookingKind {
        get { BookingKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }
}
