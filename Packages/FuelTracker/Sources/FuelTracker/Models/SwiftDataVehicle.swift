import Foundation
import SwiftData

/// The original SwiftData model — kept under its exact original name, `Vehicle`.
///
/// This is a pure revert. An earlier version of this migration renamed this
/// class to `LegacyVehicle`, on the theory that the `Legacy` prefix was just
/// documentation. It was not: SwiftData ties a model's identity, and its
/// CloudKit record type (`CD_<ClassName>`, via `NSPersistentCloudKitContainer`'s
/// own convention), directly to the Swift class name, with no way to
/// decouple the two short of a `VersionedSchema`/`SchemaMigrationPlan` — and
/// this repo has never used one (see CLAUDE.md). Renaming `Vehicle` to
/// `LegacyVehicle` therefore didn't just rename a file; it made SwiftData treat
/// every vehicle as belonging to a brand-new, unrelated `CD_LegacyVehicle`
/// record type, orphaning every real, already-synced `CD_Vehicle` record
/// already in Production. Confirmed live on a real device: after that rename,
/// Trips, Fuel and Explore all read empty despite existing data. This file
/// undoes that: every stored property, relationship and annotation below is
/// byte-for-byte what this class has always been, so it reads the schema
/// already deployed to Production again.
///
/// The *new* Core Data model this module is moving to did the right thing
/// from the start — it decouples `NSEntityDescription.name` from the Swift
/// class name, so its classes now carry the `Shared` prefix
/// (`SharedVehicle` in `SharedVehicle.swift`) while this class keeps the plain
/// name. See that file's doc comment for the full picture.
///
/// `FuelTrackerModule.models` still registers this type (as `Vehicle.self`) so
/// `AppSchema.models` keeps it in `BhavikApp`'s SwiftData container: the
/// one-time importer in `FuelLegacyMigration.swift` reads through it to copy
/// real vehicles into the new Core Data store. Do NOT remove it from
/// `AppSchema.models` — that is a separate, later, human-gated step, only
/// once the user has confirmed on a real device that their existing data
/// survived that import.
///
/// Filename is `SwiftDataVehicle.swift`, not `Vehicle.swift` — `Vehicle.swift`
/// would collide with nothing today, but the filename carries no meaning to
/// SwiftData or Core Data either way; only the type name below matters. Kept
/// distinct from `SharedVehicle.swift` purely for readability.
@Model
public final class Vehicle {
    public var name: String = ""
    public var createdAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \FuelEntry.vehicle)
    public var entries: [FuelEntry]? = []

    public init(name: String) {
        self.name = name
        self.createdAt = .now
    }

    /// Fill-ups only, oldest first. Odometer order is authoritative because
    /// exported logs sometimes carry mistyped dates.
    public var orderedFillUps: [FuelEntry] {
        (entries ?? [])
            .filter { $0.kind == .fillUp }
            .sorted { $0.odometer < $1.odometer }
    }

    public var orderedServices: [FuelEntry] {
        (entries ?? [])
            .filter { $0.kind == .service }
            .sorted { $0.date > $1.date }
    }
}
