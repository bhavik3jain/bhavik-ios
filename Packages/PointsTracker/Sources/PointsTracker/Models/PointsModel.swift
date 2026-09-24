import CoreData
import Foundation

/// Builds the Core Data model behind Points, by hand rather than a
/// `.xcdatamodeld`, the same as `FuelModel` and for the same reasons.
///
/// Core Data rather than SwiftData because the module is shareable with a
/// partner via `CKShare`, which SwiftData has no support for at all. The
/// CKShare root is the **household**: people, accounts and their history all
/// hang off one, so a single share hands over everything and lets the other
/// person add their own people and accounts to it.
///
/// | Swift class             | Core Data entity name  |
/// |-------------------------|------------------------|
/// | `SharedPointsHousehold` | `SharedPointsHousehold` |
/// | `SharedPointsOwner`     | `SharedPointsOwner`     |
/// | `SharedPointsAccount`   | `SharedPointsAccount`   |
/// | `SharedPointsEntry`     | `SharedPointsEntry`     |
///
/// Entity names are CloudKit record types (`CD_` + name) and must never be
/// renamed once in Production — that orphans every record already there.
/// Adding an entity or attribute needs the Console schema ritual (README →
/// Data and sync); `CloudKitSchemaInitializer` covers this model.
public enum PointsModel {
    enum EntityName {
        static let household = "SharedPointsHousehold"
        static let owner = "SharedPointsOwner"
        static let account = "SharedPointsAccount"
        static let entry = "SharedPointsEntry"
    }

    @MainActor
    public static func make() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let household = entity(EntityName.household, SharedPointsHousehold.self)
        let owner = entity(EntityName.owner, SharedPointsOwner.self)
        let account = entity(EntityName.account, SharedPointsAccount.self)
        let entry = entity(EntityName.entry, SharedPointsEntry.self)

        household.properties = [
            string("name", default: ""),
            date("createdAt", optional: false, default: .now),
        ]
        owner.properties = [
            string("name", default: ""),
            date("createdAt", optional: false, default: .now),
        ]
        account.properties = [
            string("name", default: ""),
            string("program", default: ""),
            string("kindRaw", default: PointsKind.creditCard.rawValue),
            integer("balance", default: 0),
            string("memberNumber", default: ""),
            string("status", default: ""),
            date("expiresAt"),
            string("notes", default: ""),
            date("createdAt", optional: false, default: .now),
            date("balanceUpdatedAt", optional: false, default: .now),
        ]
        entry.properties = [
            date("recordedAt", optional: false, default: .now),
            integer("balance", default: 0),
            integer("delta", default: 0),
            string("note", default: ""),
        ]

        // Both sides of every pair carry `inverseRelationship` — Core Data
        // throws "no inverse relationship" at container load otherwise.
        let (owners, ownerHousehold) = toManyPair("owners", inverse: "household", from: household, to: owner, rule: .cascadeDeleteRule)
        let (accounts, accountHousehold) = toManyPair("accounts", inverse: "household", from: household, to: account, rule: .cascadeDeleteRule)
        // Nullify: removing a person must never throw away the balances they
        // held — those accounts fall back to "Unassigned".
        let (ownerAccounts, accountOwner) = toManyPair("accounts", inverse: "owner", from: owner, to: account, rule: .nullifyDeleteRule)
        let (entries, entryAccount) = toManyPair("entries", inverse: "account", from: account, to: entry, rule: .cascadeDeleteRule)

        household.properties += [owners, accounts]
        owner.properties += [ownerHousehold, ownerAccounts]
        account.properties += [accountHousehold, accountOwner, entries]
        entry.properties += [entryAccount]

        model.entities = [household, owner, account, entry]
        return model
    }

    // MARK: - Builders

    private static func entity(_ name: String, _ type: NSManagedObject.Type) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = name
        entity.managedObjectClassName = NSStringFromClass(type)
        return entity
    }

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

    private static func integer(_ name: String, default value: Int) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .integer64AttributeType
        attribute.isOptional = false
        attribute.defaultValue = value
        return attribute
    }

    private static func toManyPair(
        _ name: String,
        inverse inverseName: String,
        from: NSEntityDescription,
        to: NSEntityDescription,
        rule: NSDeleteRule
    ) -> (toMany: NSRelationshipDescription, toOne: NSRelationshipDescription) {
        let toMany = NSRelationshipDescription()
        toMany.name = name
        toMany.destinationEntity = to
        toMany.minCount = 0
        toMany.maxCount = 0 // 0 means "to-many" to Core Data.
        toMany.deleteRule = rule
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
