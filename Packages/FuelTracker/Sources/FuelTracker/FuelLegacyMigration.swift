import Core
import CoreData
import Foundation
import SwiftData

/// Copies every vehicle (and its fuel entries) still reachable through the
/// original SwiftData models (`Vehicle`, `FuelEntry` in the `SwiftData*.swift`
/// files) into the module's new Core Data store (`SharedVehicle` and
/// `SharedFuelEntry`), once per device — the real, live data those models
/// hold has to survive this module's move off SwiftData.
///
/// This is not a schema drop: `FuelTrackerModule.models` keeps registering
/// the original SwiftData types in `AppSchema.models` (see `Vehicle`'s own
/// doc comment, in `SwiftDataVehicle.swift`) precisely so this has something
/// to read. Nothing here deletes the old records or their CloudKit zone —
/// that stays a separate, later, human-gated step, once the user has
/// confirmed on a real device that the import below actually carried
/// everything over.
public enum FuelLegacyMigration {
    private static let completedDefaultsKey = "FuelLegacyMigrationCompleted"

    /// `true` once the import below has run on this device — whether or not it
    /// found anything to copy. Checked by `FuelDebugSeed` too: a store that has
    /// already been through this import may be a real, possibly-shared store,
    /// and debug seeding must never write fake vehicles into that.
    public static var hasRun: Bool {
        UserDefaults.standard.bool(forKey: completedDefaultsKey)
    }

    /// One-time re-arm for devices that already ran the *previous*, broken
    /// version of this importer — the one from before the SwiftData/Core Data
    /// class names were swapped back to their correct sides. That version read
    /// through a `LegacyVehicle` type whose CloudKit record type
    /// (`CD_LegacyVehicle`) had already come unglued from the user's real,
    /// already-synced `CD_Vehicle` data, so it found nothing to copy, copied
    /// nothing, and still marked `completedDefaultsKey` done — permanently
    /// skipping the corrected importer below on every device that had already
    /// launched once.
    ///
    /// Only clears the flag when the new Core Data store is still completely
    /// empty of `SharedVehicle` objects: every real user is in exactly that
    /// state right now, since the previous run copied nothing, but a store
    /// that already holds something — from manual testing, or a future real
    /// `CKShare` — must never be re-imported into blindly.
    ///
    /// Safe to delete once this fix has shipped and been confirmed working on
    /// real devices; it exists only to give the corrected importer below its
    /// one missed chance to run.
    @MainActor
    private static func rearmIfStoreIsEmpty(context: NSManagedObjectContext) {
        guard hasRun else { return }
        guard let count = try? context.count(for: SharedVehicle.fetchRequest()), count == 0 else { return }
        UserDefaults.standard.set(false, forKey: completedDefaultsKey)
    }

    /// Reads every `Vehicle` (and its fuel entries) out of `legacyContext` and
    /// re-creates it in `context`. Called from `FuelRootView`'s `.task`, ahead
    /// of the debug seeder.
    @MainActor
    public static func runIfNeeded(from legacyContext: ModelContext, into context: NSManagedObjectContext) {
        rearmIfStoreIsEmpty(context: context)
        guard !hasRun else { return }
        // Marked done even when there was nothing to copy — a device that has
        // never had a vehicle should not keep re-scanning the SwiftData store
        // on every launch, and should still count as "already migrated" for
        // FuelDebugSeed's guard above.
        defer { UserDefaults.standard.set(true, forKey: completedDefaultsKey) }

        guard let legacyVehicles = try? legacyContext.fetch(FetchDescriptor<Vehicle>()), !legacyVehicles.isEmpty else { return }

        for legacyVehicle in legacyVehicles {
            let vehicle = SharedVehicle(context: context, name: legacyVehicle.name)
            vehicle.createdAt = legacyVehicle.createdAt

            for legacyEntry in legacyVehicle.entries ?? [] {
                let entry = SharedFuelEntry(
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
