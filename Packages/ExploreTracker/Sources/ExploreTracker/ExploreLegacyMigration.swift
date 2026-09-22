import Core
import CoreData
import Foundation
import SwiftData

/// Copies every guide (and its places) still reachable through the `Legacy*`
/// SwiftData models into the module's new Core Data store, once per device —
/// the real, live data those models hold has to survive this module's move
/// off SwiftData.
///
/// This is not a schema drop: `ExploreTrackerModule.models` keeps registering
/// the `Legacy*` types in `AppSchema.models` (see its own doc comment)
/// precisely so this has something to read. Nothing here deletes the old
/// records or their CloudKit zone — that stays a separate, later, human-gated
/// step, once the user has confirmed on a real device that the import below
/// actually carried everything over.
public enum ExploreLegacyMigration {
    private static let completedDefaultsKey = "ExploreLegacyMigrationCompleted"

    /// `true` once the import below has run on this device — whether or not
    /// it found anything to copy. Checked by `ExploreDebugSeed` too: a store
    /// that has already been through this import may be a real, possibly-
    /// shared store, and debug seeding must never write fake guides into that.
    public static var hasRun: Bool {
        UserDefaults.standard.bool(forKey: completedDefaultsKey)
    }

    /// Reads every `LegacyGuide` (and its places) out of `legacyContext` and
    /// re-creates it in `context`. Called from `ExploreRootView`'s `.task`,
    /// ahead of the debug seeder.
    @MainActor
    public static func runIfNeeded(from legacyContext: ModelContext, into context: NSManagedObjectContext) {
        guard !hasRun else { return }
        // Marked done even when there was nothing to copy — a device that has
        // never had a guide should not keep re-scanning the SwiftData store
        // on every launch, and should still count as "already migrated" for
        // ExploreDebugSeed's guard above.
        defer { UserDefaults.standard.set(true, forKey: completedDefaultsKey) }

        guard let legacyGuides = try? legacyContext.fetch(FetchDescriptor<LegacyGuide>()), !legacyGuides.isEmpty else { return }

        for legacyGuide in legacyGuides {
            let guide = Guide(context: context, name: legacyGuide.name, areaLabel: legacyGuide.areaLabel, notes: legacyGuide.notes)
            guide.createdAt = legacyGuide.createdAt
            guide.pinnedAt = legacyGuide.pinnedAt

            for legacyPlace in legacyGuide.allPlaces {
                let place = GuidePlace(
                    context: context,
                    name: legacyPlace.name,
                    category: legacyPlace.category,
                    note: legacyPlace.note,
                    address: legacyPlace.address,
                    latitude: legacyPlace.latitude,
                    longitude: legacyPlace.longitude
                )
                place.isTried = legacyPlace.isTried
                place.rating = legacyPlace.rating
                place.triedAt = legacyPlace.triedAt
                place.addedAt = legacyPlace.addedAt
                place.guide = guide
            }
        }

        try? context.saveIfNeeded()
    }
}
