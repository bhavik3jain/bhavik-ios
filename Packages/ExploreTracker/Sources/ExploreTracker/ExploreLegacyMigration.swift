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

    /// `true` once every legacy guide has been confirmed present in the new
    /// store — a fast path only, checked below to skip re-scanning the
    /// SwiftData store on every launch once there is nothing left to do. Also
    /// checked by `ExploreDebugSeed`: a store that has already been through
    /// this import may be a real, possibly-shared store, and debug seeding
    /// must never write fake guides into that.
    public static var hasRun: Bool {
        UserDefaults.standard.bool(forKey: completedDefaultsKey)
    }

    /// Reads every `Guide` (and its places) out of `legacyContext` and
    /// re-creates it in `context`, skipping any legacy guide that already has
    /// a matching `SharedGuide` (matched by `name` and `areaLabel`) in the
    /// destination store — when a guide already exists, its places are
    /// assumed to have already been copied along with it, so they are not
    /// re-walked. Called from `ExploreRootView`'s `.task`, ahead of the debug
    /// seeder, and only after `CloudKitImportGate` — the existence check below
    /// sees only the local store, so it's only a guard against another
    /// device's copies once those have been imported.
    ///
    /// The per-guide existence check above is the actual guard against
    /// duplicating data — not `completedDefaultsKey` below. A flag plus an
    /// "is the destination store still empty" heuristic (this file's previous
    /// `rearmIfStoreIsEmpty`) is not a reliable guard against re-entry: across
    /// one real device's unusual sequence of test builds — a buggy build,
    /// then a fixed build, then a TestFlight build, all reusing the same
    /// on-disk store — that combination let the Fuel module's equivalent
    /// importer copy the same 2 real vehicles into its store twice, producing
    /// 4 duplicate `SharedVehicle` records (each with its own duplicated
    /// `SharedFuelEntry` children) in the user's real, live Production
    /// CloudKit data; this importer shares the exact same flag+emptiness
    /// design and was just as capable of the same failure, even though it
    /// hadn't yet been caught doing it. Matching by content means this is
    /// safe to run on every launch regardless of how many times it has run
    /// before, or under what previous, broken version of this import it ran.
    /// `completedDefaultsKey` is kept only as a fast path, and is set only
    /// after a re-fetch confirms every legacy guide now has a match — never
    /// assumed from the loop below alone.
    @MainActor
    public static func runIfNeeded(from legacyContext: ModelContext, into context: NSManagedObjectContext) {
        guard !hasRun else { return }

        guard let legacyGuides = try? legacyContext.fetch(FetchDescriptor<Guide>()), !legacyGuides.isEmpty else {
            // Nothing to migrate — a device that has never had a guide should
            // not keep re-scanning the SwiftData store on every launch, and
            // should still count as "already migrated" for ExploreDebugSeed's
            // guard above.
            UserDefaults.standard.set(true, forKey: completedDefaultsKey)
            return
        }

        for legacyGuide in legacyGuides {
            guard !guideExists(matching: legacyGuide, in: context) else { continue }

            let guide = SharedGuide(context: context, name: legacyGuide.name, areaLabel: legacyGuide.areaLabel, notes: legacyGuide.notes)
            guide.createdAt = legacyGuide.createdAt
            // Derived, not the random UUID the initializer gave it: if two
            // devices ever do both import this guide, their pins at least key
            // to the same value.
            guide.identifier = GuideIdentity.derived(for: guide)
            // Into the retired field on purpose: `GuidePins.migrateRetiredPinnedAt`,
            // which runs straight after this, is the one place that turns a
            // `pinnedAt` into a private-store `GuidePin` and clears it, whether
            // it came from here or from a guide already in the store.
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

        if legacyGuides.allSatisfy({ guideExists(matching: $0, in: context) }) {
            UserDefaults.standard.set(true, forKey: completedDefaultsKey)
        }
    }

    /// Whether `context` already holds a `SharedGuide` for this legacy
    /// guide's natural key. Names are not enforced unique anywhere (see
    /// CLAUDE.md — no `@Attribute(.unique)`, CloudKit doesn't support it), so
    /// this is a best-effort content match, not a database constraint.
    @MainActor
    private static func guideExists(matching legacyGuide: Guide, in context: NSManagedObjectContext) -> Bool {
        let request = SharedGuide.fetchRequest(predicate: NSPredicate(
            format: "name == %@ AND areaLabel == %@",
            legacyGuide.name, legacyGuide.areaLabel
        ))
        request.fetchLimit = 1
        return ((try? context.count(for: request)) ?? 0) > 0
    }
}
