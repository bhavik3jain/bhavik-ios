import Core
import CoreData
import Foundation
import ObjectiveC
import SwiftData
import Testing
@testable import ExploreTracker

/// Associated-object key for tying a returned context's lifetime to the
/// container that built it — see `makeContext()` in `ExploreTrackerTests.swift`,
/// duplicated here because that helper is file-private.
private nonisolated(unsafe) var associatedContainerKey: UInt8 = 0

@MainActor
private func makeContext() throws -> NSManagedObjectContext {
    let container = CloudSharedStore.makeContainer(
        name: "ExploreLegacyMigrationTests-\(UUID().uuidString)",
        model: GuideModel.make(),
        containerID: "iCloud.com.bhavikjain.trackers.tests",
        inMemory: true
    )
    let context = container.viewContext
    objc_setAssociatedObject(context, &associatedContainerKey, container, .OBJC_ASSOCIATION_RETAIN)
    return context
}

/// A fresh, in-memory SwiftData store holding just the legacy `Guide`/
/// `GuidePlace` models, standing in for the app-wide SwiftData container
/// `ExploreRootView` reads through `@Environment(\.modelContext)`.
@MainActor
private func makeLegacyContext() throws -> ModelContext {
    let schema = Schema([Guide.self, GuidePlace.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return ModelContext(container)
}

/// `ExploreLegacyMigration.hasRun` reads a fixed `UserDefaults.standard` key,
/// so every test that drives `runIfNeeded` must reset it first — otherwise a
/// flag left `true` by an earlier test (or an earlier run of this same test)
/// makes `runIfNeeded` a no-op before it even looks at the legacy store.
private let completedDefaultsKey = "ExploreLegacyMigrationCompleted"

private func resetMigrationFlag() {
    UserDefaults.standard.removeObject(forKey: completedDefaultsKey)
}

@MainActor
@discardableResult
private func addLegacyGuide(_ name: String, areaLabel: String = "", to legacyContext: ModelContext) -> Guide {
    let guide = Guide(name: name, areaLabel: areaLabel)
    legacyContext.insert(guide)
    return guide
}

// MARK: - Idempotent by content, not by the completion flag

@MainActor
@Test func migratesALegacyGuideWithItsPlaces() throws {
    resetMigrationFlag()
    let legacyContext = try makeLegacyContext()
    let context = try makeContext()

    let guide = addLegacyGuide("Kyoto", areaLabel: "Kyoto, Japan", to: legacyContext)
    let place = GuidePlace(name: "Yasaka Shrine", category: .places)
    place.guide = guide
    try legacyContext.save()

    ExploreLegacyMigration.runIfNeeded(from: legacyContext, into: context)

    let guides = try context.fetch(SharedGuide.fetchRequest())
    #expect(guides.count == 1)
    let migrated = try #require(guides.first)
    #expect(migrated.name == "Kyoto")
    #expect(migrated.areaLabel == "Kyoto, Japan")
    #expect(migrated.allPlaces.count == 1)
    #expect(ExploreLegacyMigration.hasRun)
}

@MainActor
@Test func runningTwiceInTheSameProcessDoesNotDuplicate() throws {
    resetMigrationFlag()
    let legacyContext = try makeLegacyContext()
    let context = try makeContext()
    addLegacyGuide("Kyoto", areaLabel: "Kyoto, Japan", to: legacyContext)
    try legacyContext.save()

    ExploreLegacyMigration.runIfNeeded(from: legacyContext, into: context)
    ExploreLegacyMigration.runIfNeeded(from: legacyContext, into: context)

    #expect(try context.count(for: SharedGuide.fetchRequest()) == 1)
}

/// The actual bug, reproduced directly: `hasRun` alone is not a reliable
/// guard against re-entry — a device could reach `runIfNeeded` again after
/// the flag was reset (e.g. reinstalling across the buggy-build /
/// fixed-build / TestFlight sequence described in this file's doc comment,
/// which is exactly what happened to the Fuel module's equivalent importer
/// live). Content-matching in the destination store must still catch the
/// duplicate even when the flag itself has been cleared.
@MainActor
@Test func reRunningAfterTheCompletionFlagIsClearedStillDoesNotDuplicate() throws {
    resetMigrationFlag()
    let legacyContext = try makeLegacyContext()
    let context = try makeContext()
    let guide = addLegacyGuide("Kyoto", areaLabel: "Kyoto, Japan", to: legacyContext)
    let place = GuidePlace(name: "Yasaka Shrine", category: .places)
    place.guide = guide
    try legacyContext.save()

    ExploreLegacyMigration.runIfNeeded(from: legacyContext, into: context)
    #expect(try context.count(for: SharedGuide.fetchRequest()) == 1)

    // Simulate the flag having been cleared (or never having synced to this
    // build in the first place) without the destination store being empty —
    // exactly the state a device was found in live.
    resetMigrationFlag()
    ExploreLegacyMigration.runIfNeeded(from: legacyContext, into: context)

    #expect(try context.count(for: SharedGuide.fetchRequest()) == 1, "Re-entry must not create a second SharedGuide")
    #expect(try context.count(for: SharedGuidePlace.fetchRequest()) == 1, "...or duplicate its places")
}

@MainActor
@Test func newLegacyGuidesAddedAfterAFirstImportAreStillPickedUp() throws {
    resetMigrationFlag()
    let legacyContext = try makeLegacyContext()
    let context = try makeContext()
    addLegacyGuide("Kyoto", areaLabel: "Kyoto, Japan", to: legacyContext)
    try legacyContext.save()

    ExploreLegacyMigration.runIfNeeded(from: legacyContext, into: context)
    #expect(try context.count(for: SharedGuide.fetchRequest()) == 1)

    resetMigrationFlag()
    addLegacyGuide("SoMa", areaLabel: "San Francisco", to: legacyContext)
    try legacyContext.save()
    ExploreLegacyMigration.runIfNeeded(from: legacyContext, into: context)

    let names = Set(try context.fetch(SharedGuide.fetchRequest()).map(\.name))
    #expect(names == ["Kyoto", "SoMa"])
}

/// Two guides can legitimately share a name in different areas ("Downtown"
/// guides for two different cities) — the natural key is name *and*
/// areaLabel together, so this must be treated as two distinct guides.
@MainActor
@Test func guidesWithTheSameNameButDifferentAreasAreNotTreatedAsDuplicates() throws {
    resetMigrationFlag()
    let legacyContext = try makeLegacyContext()
    let context = try makeContext()
    addLegacyGuide("Downtown", areaLabel: "Boston", to: legacyContext)
    addLegacyGuide("Downtown", areaLabel: "Chicago", to: legacyContext)
    try legacyContext.save()

    ExploreLegacyMigration.runIfNeeded(from: legacyContext, into: context)

    #expect(try context.count(for: SharedGuide.fetchRequest()) == 2)
}

@MainActor
@Test func emptyLegacyStoreStillMarksTheFastPathFlag() throws {
    resetMigrationFlag()
    let legacyContext = try makeLegacyContext()
    let context = try makeContext()

    ExploreLegacyMigration.runIfNeeded(from: legacyContext, into: context)

    #expect(try context.count(for: SharedGuide.fetchRequest()) == 0)
    #expect(ExploreLegacyMigration.hasRun)
}

// MARK: - Pins and identifiers

@MainActor
@Test func aPinnedLegacyGuideArrivesPinnedThroughAPrivateGuidePin() throws {
    resetMigrationFlag()
    let legacyContext = try makeLegacyContext()
    let context = try makeContext()
    let container = try #require(objc_getAssociatedObject(context, &associatedContainerKey) as? NSPersistentCloudKitContainer)
    let pins = GuidePins(context: context, container: container)

    let pinnedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let legacy = addLegacyGuide("Kyoto", areaLabel: "Kyoto, Japan", to: legacyContext)
    legacy.pinnedAt = pinnedAt
    try legacyContext.save()

    // The order `ExploreRootView`'s `.task` runs them in.
    ExploreLegacyMigration.runIfNeeded(from: legacyContext, into: context)
    pins.migrateRetiredPinnedAt()

    let guide = try #require(try context.fetch(SharedGuide.fetchRequest()).first)
    #expect(guide.identifier == GuideIdentity.derived(name: "Kyoto", areaLabel: "Kyoto, Japan", createdAt: legacy.createdAt))
    #expect(pins.pinnedAt(for: guide) == pinnedAt)
    #expect(guide.pinnedAt == nil)
}
