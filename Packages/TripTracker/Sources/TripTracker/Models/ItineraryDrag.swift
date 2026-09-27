import CoreData
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

public extension UTType {
    /// A stop or idea being dragged within a trip. Exported in both targets'
    /// Info.plist (`UTExportedTypeDeclarations` in project.yml): an
    /// undeclared exported type is treated as a dynamic one, and a drop
    /// destination waiting for this identifier never matched it.
    static let tripItineraryItem = UTType(exportedAs: "com.bhavikjain.trackers.itinerary-item")
}

/// What dragging a stop or an idea carries: the item's Core Data URI, not the
/// item itself.
///
/// A managed object can't cross a drag session, and its title isn't unique —
/// two "Dinner"s on one trip is ordinary. The URI names exactly one row of
/// this device's store, and `ItineraryDrop` turns it back into that row only
/// if it still exists and belongs to the trip it was dropped on.
public struct ItineraryItemDrag: Codable, Hashable, Sendable, Transferable {
    public let uri: URL

    public init(_ item: SharedItineraryItem) {
        uri = item.objectID.uriRepresentation()
    }

    public init(uri: URL) {
        self.uri = uri
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .tripItineraryItem)
    }
}

/// Dropping dragged items onto a day of the plan, or back among the ideas.
public enum ItineraryDrop {
    /// The dragged items that are still `trip`'s own, in the order dragged.
    /// A URI from another trip, another store, or an item deleted mid-drag
    /// resolves to nothing rather than to whatever now sits at that address.
    @MainActor
    public static func items(for drags: [ItineraryItemDrag], in trip: SharedTrip) -> [SharedItineraryItem] {
        guard let context = trip.managedObjectContext,
              let coordinator = context.persistentStoreCoordinator else { return [] }
        var seen = Set<NSManagedObjectID>()
        return drags.compactMap { drag in
            guard let id = coordinator.managedObjectID(forURIRepresentation: drag.uri),
                  seen.insert(id).inserted,
                  let item = try? context.existingObject(with: id) as? SharedItineraryItem,
                  !item.isDeleted,
                  item.trip == trip
            else { return nil }
            return item
        }
    }

    /// Puts the dragged items on `day` — `SharedItineraryItem.unassignedDayIndex`
    /// for the ideas — each after what's already there. Returns whether
    /// anything moved, so the caller only saves when something did.
    @MainActor
    @discardableResult
    public static func move(_ drags: [ItineraryItemDrag], toDay day: Int, in trip: SharedTrip) -> Bool {
        let target = day < 0 ? SharedItineraryItem.unassignedDayIndex : min(day, trip.dates.dayCount - 1)
        var moved = false
        for item in items(for: drags, in: trip) {
            let wasOn = item.dayIndex
            item.move(toDay: target)
            moved = moved || item.dayIndex != wasOn
        }
        return moved
    }
}
