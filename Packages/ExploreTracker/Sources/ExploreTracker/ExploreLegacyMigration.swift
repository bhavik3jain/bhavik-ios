import Core
import CoreData
import Foundation
import SwiftData

/// Copies every guide (and its places) still reachable through the original
/// SwiftData models (`Guide`, `GuidePlace` in `SwiftDataGuide.swift`) into the
/// module's new Core Data store (`SharedGuide` and `SharedGuidePlace`), once
/// per device — the real, live data those models hold has to survive this
/// module's move off SwiftData.
///
/// This is not a schema drop: `ExploreTrackerModule.models` keeps registering
/// the original SwiftData types in `AppSchema.models` (see `Guide`'s own doc
/// comment, in `SwiftDataGuide.swift`) precisely so this has something to
/// read. Nothing here deletes the old records or their CloudKit zone — that
/// stays a separate, later, human-gated step, once the user has confirmed on
/// a real device that the import below actually carried everything over.
public enum ExploreLegacyMigration {
    private static let completedDefaultsKey = "ExploreLegacyMigrationCompleted"

    /// `true` once the import below has run on this device — whether or not
    /// it found anything to copy. Checked by `ExploreDebugSeed` too: a store
    /// that has already been through this import may be a real, possibly-
    /// shared store, and debug seeding must never write fake guides into that.
    public static var hasRun: Bool {
        UserDefaults.standard.bool(forKey: completedDefaultsKey)
    }

    /// One-time re-arm for devices that already ran the *previous*, broken
    /// version of this importer — the one from before the SwiftData/Core Data
    /// class names were swapped back to their correct sides. That version read
    /// through a `LegacyGuide` type whose CloudKit record type (`CD_LegacyGuide`)
    /// had already come unglued from the user's real, already-synced `CD_Guide`
    /// data, so it found nothing to copy, copied nothing, and still marked
    /// `completedDefaultsKey` done — permanently skipping the corrected
    /// importer below on every device that had already launched once.
    ///
    /// Only clears the flag when the new Core Data store is still completely
    /// empty of `SharedGuide` objects: every real user is in exactly that
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
        guard let count = try? context.count(for: SharedGuide.fetchRequest()), count == 0 else { return }
        UserDefaults.standard.set(false, forKey: completedDefaultsKey)
    }

    /// Reads every `Guide` (and its places) out of `legacyContext` and
    /// re-creates it in `context`. Called from `ExploreRootView`'s `.task`,
    /// ahead of the debug seeder.
    @MainActor
    public static func runIfNeeded(from legacyContext: ModelContext, into context: NSManagedObjectContext) {
        rearmIfStoreIsEmpty(context: context)
        guard !hasRun else { return }
        // Marked done even when there was nothing to copy — a device that has
        // never had a guide should not keep re-scanning the SwiftData store
        // on every launch, and should still count as "already migrated" for
        // ExploreDebugSeed's guard above.
        defer { UserDefaults.standard.set(true, forKey: completedDefaultsKey) }

        guard let legacyGuides = try? legacyContext.fetch(FetchDescriptor<Guide>()), !legacyGuides.isEmpty else { return }

        for legacyGuide in legacyGuides {
            let guide = SharedGuide(context: context, name: legacyGuide.name, areaLabel: legacyGuide.areaLabel, notes: legacyGuide.notes)
            guide.createdAt = legacyGuide.createdAt
            guide.pinnedAt = legacyGuide.pinnedAt

            for legacyPlace in legacyGuide.allPlaces {
                let place = SharedGuidePlace(
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
