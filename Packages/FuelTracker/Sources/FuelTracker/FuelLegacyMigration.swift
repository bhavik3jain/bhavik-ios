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

    /// `true` once every legacy vehicle has been confirmed present in the new
    /// store — a fast path only, checked below to skip re-scanning the
    /// SwiftData store on every launch once there is nothing left to do. Also
    /// checked by `FuelDebugSeed`: a store that has already been through this
    /// import may be a real, possibly-shared store, and debug seeding must
    /// never write fake vehicles into that.
    public static var hasRun: Bool {
        UserDefaults.standard.bool(forKey: completedDefaultsKey)
    }

    /// Reads every `Vehicle` (and its fuel entries) out of `legacyContext` and
    /// re-creates it in `context`, skipping any legacy vehicle that already
    /// has a matching `SharedVehicle` (matched by `name`) in the destination
    /// store. Called from `FuelRootView`'s `.task`, ahead of the debug seeder, and only after
    /// `CloudKitImportGate` — the existence check sees only the local store,
    /// so it guards against another device's copies only once those have been
    /// imported.
    ///
    /// The per-vehicle existence check above is the actual guard against
    /// duplicating data — not `completedDefaultsKey` below. A flag plus an
    /// "is the destination store still empty" heuristic (this file's previous
    /// `rearmIfStoreIsEmpty`) is not a reliable guard against re-entry: across
    /// one real device's unusual sequence of test builds — a buggy build,
    /// then a fixed build, then a TestFlight build, all reusing the same
    /// on-disk store — that combination let the same 2 real vehicles get
    /// copied into this store twice, producing 4 duplicate `SharedVehicle`
    /// records (each with its own duplicated `SharedFuelEntry` children) in
    /// the user's real, live Production CloudKit data. Matching by content
    /// means this is safe to run on every launch regardless of how many times
    /// it has run before, or under what previous, broken version of this
    /// import it ran. `completedDefaultsKey` is kept only as a fast path, and
    /// is set only after a re-fetch confirms every legacy vehicle now has a
    /// match — never assumed from the loop below alone.
    @MainActor
    public static func runIfNeeded(from legacyContext: ModelContext, into context: NSManagedObjectContext) {
        guard !hasRun else { return }

        guard let legacyVehicles = try? legacyContext.fetch(FetchDescriptor<Vehicle>()), !legacyVehicles.isEmpty else {
            // Nothing to migrate — a device that has never had a vehicle
            // should not keep re-scanning the SwiftData store on every
            // launch, and should still count as "already migrated" for
            // FuelDebugSeed's guard above.
            UserDefaults.standard.set(true, forKey: completedDefaultsKey)
            return
        }

        for legacyVehicle in legacyVehicles {
            guard !vehicleExists(named: legacyVehicle.name, in: context) else { continue }

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

        if legacyVehicles.allSatisfy({ vehicleExists(named: $0.name, in: context) }) {
            UserDefaults.standard.set(true, forKey: completedDefaultsKey)
        }
    }

    /// Whether `context` already holds a `SharedVehicle` for this legacy
    /// vehicle's natural key. Names are not enforced unique anywhere (see
    /// CLAUDE.md — no `@Attribute(.unique)`, CloudKit doesn't support it), so
    /// this is a best-effort content match, not a database constraint.
    @MainActor
    private static func vehicleExists(named name: String, in context: NSManagedObjectContext) -> Bool {
        let request = SharedVehicle.fetchRequest(predicate: NSPredicate(format: "name == %@", name))
        request.fetchLimit = 1
        return ((try? context.count(for: request)) ?? 0) > 0
    }
}
