import CoreData
import Foundation

/// Cars that appear more than once in this person's own garage, and how to
/// fold each set back into one.
///
/// Every reinstall used to copy the cars out of the old SwiftData store again,
/// matching only what iCloud had already synced down, by name — so a car not
/// yet downloaded, or renamed since, came back as a second car with a copy of
/// its whole log (see `LegacyMigrationLedger`). The import no longer does
/// that, but the copies it made are real records in iCloud, and only merging
/// removes them. It is run by the person, from Garage, after saying what it
/// will do — never on its own: this is real data, and a car can have the same
/// name as another on purpose.
///
/// Rules, each for a reason:
/// - Only cars in this person's own (private) store. A car a partner shared
///   is theirs to tidy.
/// - Cars count as the same when their names match, ignoring case and spaces
///   at the ends.
/// - The one kept is the one this person shared, if one was — deleting a
///   shared car deletes it for the partner too — else the oldest. Two shared
///   copies of one name are left alone: there's no safe way to pick.
/// - Every fill-up and service on a copy moves to the car kept, except those
///   it already has (same kind, day, odometer, gallons and cost), which the
///   copy's log almost always is.
public struct FuelDuplicates {
    public struct Group: Identifiable {
        public let name: String
        public let keep: SharedVehicle
        public let extras: [SharedVehicle]
        /// Entries on the extras the car kept doesn't have yet.
        public let entriesToMove: Int

        public var id: NSManagedObjectID { keep.objectID }
    }

    public let groups: [Group]

    public var isEmpty: Bool { groups.isEmpty }
    /// How many cars merging removes.
    public var extraCount: Int { groups.reduce(0) { $0 + $1.extras.count } }

    /// `isOwn`: whether a car is in this person's own store. `isShared`:
    /// whether this person has shared it.
    public init(
        vehicles: [SharedVehicle],
        isOwn: (SharedVehicle) -> Bool,
        isShared: (SharedVehicle) -> Bool
    ) {
        let own = vehicles.filter { !$0.isDeleted && isOwn($0) }
        let byName = Dictionary(grouping: own) { Self.normalized($0.name) }
        groups = byName.values
            .filter { $0.count > 1 }
            .compactMap { cars -> Group? in
                let shared = cars.filter(isShared)
                guard shared.count <= 1 else { return nil }
                let oldestFirst = cars.sorted {
                    $0.createdAt != $1.createdAt
                        ? $0.createdAt < $1.createdAt
                        : $0.objectID.uriRepresentation().absoluteString < $1.objectID.uriRepresentation().absoluteString
                }
                let keep = shared.first ?? oldestFirst[0]
                let extras = oldestFirst.filter { $0 != keep }
                var seen = Set((keep.entries ?? []).map(EntryKey.init))
                var moving = 0
                for entry in extras.flatMap({ $0.entries ?? [] }) where seen.insert(EntryKey(entry)).inserted {
                    moving += 1
                }
                return Group(name: keep.name, keep: keep, extras: extras, entriesToMove: moving)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Folds every group into the car it keeps: moves the entries it doesn't
    /// have, deletes the rest with the extra cars. Doesn't save. Returns how
    /// many cars and entries it removed and moved.
    @discardableResult
    public func merge() -> (carsRemoved: Int, entriesMoved: Int) {
        var removed = 0
        var moved = 0
        for group in groups {
            var seen = Set((group.keep.entries ?? []).map(EntryKey.init))
            for extra in group.extras {
                for entry in extra.entries ?? [] {
                    if seen.insert(EntryKey(entry)).inserted {
                        entry.vehicle = group.keep
                        moved += 1
                    } else {
                        extra.managedObjectContext?.delete(entry)
                    }
                }
                extra.managedObjectContext?.delete(extra)
                removed += 1
            }
        }
        return (removed, moved)
    }

    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// What makes two entries the same fill-up or service: a copy made by the
    /// import has every one of these equal. The day, not the instant, and
    /// amounts to the cent or thousandth of a gallon, so float noise from a
    /// round trip through CloudKit never splits a pair.
    struct EntryKey: Hashable {
        let kind: String
        let day: Int
        let odometer: Int
        let gallons: Int
        let cost: Int

        init(_ entry: SharedFuelEntry) {
            kind = entry.kindRaw
            day = Int((entry.date.timeIntervalSinceReferenceDate / 86_400).rounded(.down))
            odometer = entry.odometer
            gallons = Int((entry.gallons * 1_000).rounded())
            cost = Int((entry.totalCost * 100).rounded())
        }
    }
}
