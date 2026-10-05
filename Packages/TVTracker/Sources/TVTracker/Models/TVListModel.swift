import CoreData
import Foundation

/// Builds the Core Data model behind TV's shared watch lists, by hand rather
/// than a `.xcdatamodeld`, the same as `PointsModel` and for the same reasons.
///
/// The rest of TV — shows, episodes, films — stays in SwiftData. A watch list
/// is the one thing in it that two people keep together, and SwiftData has no
/// `CKShare` support at all, so lists live in a store of their own
/// (`TVListStore`, built in `BhavikApp.init()`) the way Points and Finance
/// were born. The CKShare root is **one list**: sharing it hands its items
/// over and lets whoever it's shared with add to it. Lists aren't linked to
/// the library — "Add to My Library" copies a title into this person's own
/// SwiftData library, which never syncs to anyone else.
///
/// | Swift class           | Core Data entity name  |
/// |-----------------------|------------------------|
/// | `SharedWatchList`     | `SharedWatchList`      |
/// | `SharedWatchListItem` | `SharedWatchListItem`  |
///
/// Entity names are CloudKit record types (`CD_` + name) and must never be
/// renamed once in Production — that orphans every record already there.
/// Adding an entity or attribute needs the Console schema ritual (README →
/// Data and sync); `CloudKitSchemaInitializer` covers this model.
///
/// No unique constraints (CloudKit can't have them): two devices adding the
/// same title offline both keep theirs, and `WatchListDuplicates` folds them
/// when the list is next shown.
public enum TVListModel {
    enum EntityName {
        static let list = "SharedWatchList"
        static let item = "SharedWatchListItem"
    }

    @MainActor
    public static func make() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let list = entity(EntityName.list, SharedWatchList.self)
        let item = entity(EntityName.item, SharedWatchListItem.self)

        list.properties = [
            string("name", default: ""),
            string("notes", default: ""),
            date("createdAt", optional: false, default: .now),
        ]
        item.properties = [
            // TMDB's id; zero for a title typed by someone with no TMDB key.
            integer("tmdbID", default: 0),
            string("mediaTypeRaw", default: WatchListMediaType.show.rawValue),
            string("title", default: ""),
            string("posterPath", default: ""),
            string("overview", default: ""),
            // Zero when nobody knows the year.
            integer("year", default: 0),
            date("addedAt", optional: false, default: .now),
            // Blank unless the list's share said who this device's user is.
            string("addedByName", default: ""),
            string("note", default: ""),
            date("watchedAt"),
            double("sortIndex", default: 0),
        ]

        // Both sides carry `inverseRelationship` — Core Data throws "no
        // inverse relationship" at container load otherwise (see FuelModel).
        let (items, itemList) = toManyPair("items", inverse: "list", from: list, to: item)
        list.properties += [items]
        item.properties += [itemList]

        model.entities = [list, item]
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

    private static func double(_ name: String, default value: Double) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .doubleAttributeType
        attribute.isOptional = false
        attribute.defaultValue = value
        return attribute
    }

    /// The list's items, cascading — deleting a list takes its items with it —
    /// plus the item's to-one inverse, cross-wired to each other.
    private static func toManyPair(
        _ name: String,
        inverse inverseName: String,
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
