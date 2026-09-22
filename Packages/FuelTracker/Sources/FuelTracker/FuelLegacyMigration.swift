import Core
import CoreData
import Foundation
import SwiftData

/// Copies every vehicle (and its fuel entries) still reachable through the
/// `Legacy*` SwiftData models into the module's new Core Data store, once per
/// device — the real, live data those models hold has to survive this
/// module's move off SwiftData.
///
/// This is not a schema drop: `FuelTrackerModule.models` keeps registering the
/// `Legacy*` types in `AppSchema.models` (see its own doc comment) precisely
/// so this has something to read. Nothing here deletes the old records or
/// their CloudKit zone — that stays a separate, later, human-gated step, once
/// the user has confirmed on a real device that the import below actually
/// carried everything over.
public enum FuelLegacyMigration {
    private static let completedDefaultsKey = "FuelLegacyMigrationCompleted"

    /// `true` once the import below has run on this device — whether or not it
    /// found anything to copy. Checked by `FuelDebugSeed` too: a store that has
    /// already been through this import may be a real, possibly-shared store,
    /// and debug seeding must never write fake vehicles into that.
    public static var hasRun: Bool {
        UserDefaults.standard.bool(forKey: completedDefaultsKey)
    }

    /// Reads every `LegacyVehicle` (and its fuel entries) out of
    /// `legacyContext` and re-creates it in `context`. Called from
    /// `FuelRootView`'s `.task`, ahead of the debug seeder.
    @MainActor
    public static func runIfNeeded(from legacyContext: ModelContext, into context: NSManagedObjectContext) {
        guard !hasRun else { return }
        // Marked done even when there was nothing to copy — a device that has
        // never had a vehicle should not keep re-scanning the SwiftData store
        // on every launch, and should still count as "already migrated" for
        // FuelDebugSeed's guard above.
        defer { UserDefaults.standard.set(true, forKey: completedDefaultsKey) }

        guard let legacyVehicles = try? legacyContext.fetch(FetchDescriptor<LegacyVehicle>()), !legacyVehicles.isEmpty else { return }

        for legacyVehicle in legacyVehicles {
            let vehicle = Vehicle(context: context, name: legacyVehicle.name)
            vehicle.createdAt = legacyVehicle.createdAt

            for legacyEntry in legacyVehicle.entries ?? [] {
                let entry = FuelEntry(
                    context: context,
                    kind: legacyEntry.kind,
                    date: legacyEntry.date,
                    odometer: legacyEntry.odometer,
                    gallons: legacyEntry.gallons,
                    pricePerGallon: legacyEntry.pricePerGallon,
                    totalCost: legacyEntry.totalCost,
                    isFullTank: legacyEntry.isFullTank,
                    octane: legacyEntry.octane,
                    station: legacyEntry.station,
                    notes: legacyEntry.notes,
                    services: legacyEntry.services
                )
                entry.vehicle = vehicle
            }
        }

        try? context.saveIfNeeded()
    }
}
