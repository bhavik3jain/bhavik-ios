import Foundation
import SwiftData

/// The original SwiftData model, kept alive under a `Legacy` name so the real,
/// already-synced CloudKit records it maps to (`CD_Vehicle` and friends, from
/// before this module moved to Core Data) are never orphaned. This is a pure
/// rename — every stored property, relationship and annotation is byte-for-
/// byte what `Vehicle` used to be — so it is safe against the schema already
/// deployed to Production.
///
/// `FuelTrackerModule.models` still registers this type (as `LegacyVehicle.self`)
/// so `AppSchema.models` keeps it in `BhavikApp`'s SwiftData container: the
/// one-time importer in `FuelLegacyMigration.swift` reads through it to copy
/// real vehicles into the new Core Data store. Do NOT remove it from
/// `AppSchema.models` — that is a separate, later, human-gated step, only
/// once the user has confirmed on a real device that their existing data
/// survived that import.
@Model
public final class LegacyVehicle {
    public var name: String = ""
    public var createdAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \LegacyFuelEntry.vehicle)
    public var entries: [LegacyFuelEntry]? = []

    public init(name: String) {
        self.name = name
        self.createdAt = .now
    }

    /// Fill-ups only, oldest first. Odometer order is authoritative because
    /// exported logs sometimes carry mistyped dates.
    public var orderedFillUps: [LegacyFuelEntry] {
        (entries ?? [])
            .filter { $0.kind == .fillUp }
            .sorted { $0.odometer < $1.odometer }
    }

    public var orderedServices: [LegacyFuelEntry] {
        (entries ?? [])
            .filter { $0.kind == .service }
            .sorted { $0.date > $1.date }
    }
}
