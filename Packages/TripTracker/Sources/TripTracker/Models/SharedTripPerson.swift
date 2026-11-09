import CoreData
import Foundation

/// Someone on a trip's split: either a person without the app, added by hand
/// (`personKey` "manual:<UUID>"), or a snapshot of a share participant's name
/// (`owner` / "ck:<recordName>").
///
/// Snapshot rows are written the first time a participant is used in a saved
/// expense, and when their name changes — never on opening Split, which would
/// ping the partner through iCloud's zone alert subscriptions on every visit
/// (`TripPeople.participantRowChanges`). Two devices can each write the same
/// snapshot; nothing looks a person up by object, and rows are folded by key
/// on read (`TripPeople.fold`), so duplicates are harmless and never deleted.
@objc(SharedTripPerson)
public final class SharedTripPerson: NSManagedObject, Identifiable {
    @NSManaged public var personKey: String
    @NSManaged public var name: String
    @NSManaged public var kindRaw: String
    /// A manual person linked to a participant: the key they now count as.
    /// No expense is rewritten — Unlink clears this and everything reads as
    /// before.
    @NSManaged public var mergedIntoKey: String
    /// Kept out of new splits but kept in the figures — what removing a
    /// manual person someone's expense still mentions does instead.
    @NSManaged public var isHidden: Bool
    @NSManaged public var sortOrder: Int
    @NSManaged public var createdAt: Date?
    @NSManaged public var updatedAt: Date?

    @NSManaged public var trip: SharedTrip?

    public convenience init(
        context: NSManagedObjectContext,
        key: PersonKey,
        name: String,
        kind: PersonRowKind,
        asOf now: Date = .now
    ) {
        let entity = NSEntityDescription.entity(forEntityName: TripModel.EntityName.person, in: context)!
        self.init(entity: entity, insertInto: context)
        self.personKey = key.raw
        self.name = name
        self.kindRaw = kind.rawValue
        self.createdAt = now
        self.updatedAt = now
    }

    /// Someone without the app, with a fresh `manual:<UUID>` key.
    public convenience init(context: NSManagedObjectContext, manualName name: String, asOf now: Date = .now) {
        self.init(context: context, key: .manual(), name: name, kind: .manual, asOf: now)
    }

    @nonobjc public static func fetchRequest(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<SharedTripPerson> {
        let request = NSFetchRequest<SharedTripPerson>(entityName: TripModel.EntityName.person)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return request
    }
}

public extension SharedTripPerson {
    var id: NSManagedObjectID { objectID }

    var kind: PersonRowKind {
        get { PersonRowKind(rawValue: kindRaw) ?? .manual }
        set { kindRaw = newValue.rawValue }
    }

    var key: PersonKey { PersonKey(personKey) }

    var mergedInto: PersonKey? {
        get { mergedIntoKey.isEmpty ? nil : PersonKey(mergedIntoKey) }
        set { mergedIntoKey = newValue?.raw ?? "" }
    }

    var record: PersonRecord {
        PersonRecord(
            key: key,
            name: name,
            kind: kind,
            mergedInto: mergedInto,
            isHidden: isHidden,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
