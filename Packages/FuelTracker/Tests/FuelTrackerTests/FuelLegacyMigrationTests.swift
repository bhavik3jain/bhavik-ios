import Core
import CoreData
import Foundation
import ObjectiveC
import SwiftData
import Testing
@testable import FuelTracker

/// Associated-object key for tying a returned context's lifetime to the
/// container that built it — see `makeContext()` in `FuelTrackerTests.swift`,
/// duplicated here because that helper is file-private.
private nonisolated(unsafe) var associatedContainerKey: UInt8 = 0

@MainActor
private func makeContext() throws -> NSManagedObjectContext {
    let container = CloudSharedStore.makeContainer(
        name: "FuelLegacyMigrationTests-\(UUID().uuidString)",
        model: FuelModel.make(),
        containerID: "iCloud.com.bhavikjain.trackers.tests",
        inMemory: true
    )
    let context = container.viewContext
    objc_setAssociatedObject(context, &associatedContainerKey, container, .OBJC_ASSOCIATION_RETAIN)
    return context
}

/// A fresh, in-memory SwiftData store holding just the legacy `Vehicle`/
/// `FuelEntry` models, standing in for the app-wide SwiftData container
/// `FuelRootView` reads through `@Environment(\.modelContext)`.
@MainActor
private func makeLegacyContext() throws -> ModelContext {
    let schema = Schema([Vehicle.self, FuelEntry.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return ModelContext(container)
}

/// `FuelLegacyMigration.hasRun` reads a fixed `UserDefaults.standard` key, so
/// every test that drives `runIfNeeded` must reset it first — otherwise a
/// flag left `true` by an earlier test (or an earlier run of this same test)
/// makes `runIfNeeded` a no-op before it even looks at the legacy store.
private let completedDefaultsKey = "FuelLegacyMigrationCompleted"

private func resetMigrationFlag() {
    LegacyMigrationLedger.reset(completedDefaultsKey)
}

@MainActor
@discardableResult
private func addLegacyVehicle(_ name: String, fills: [(odometer: Int, date: Date)], to legacyContext: ModelContext) -> Vehicle {
    let vehicle = Vehicle(name: name)
    legacyContext.insert(vehicle)
    for fill in fills {
        let entry = FuelEntry(date: fill.date, odometer: fill.odometer, gallons: 10, totalCost: 40)
        entry.vehicle = vehicle
    }
    return vehicle
}

// MARK: - Idempotent by content, not by the completion flag

@MainActor
@Test func migratesEveryLegacyVehicleAndItsEntries() throws {
    resetMigrationFlag()
    let legacyContext = try makeLegacyContext()
    let context = try makeContext()

    let vehicle = addLegacyVehicle("My Q5", fills: [(1000, .now), (1300, .now)], to: legacyContext)
    let entry = FuelEntry(date: .now, odometer: 1500, gallons: 12, totalCost: 45, octane: "93", station: "Shell")
    entry.vehicle = vehicle
    try legacyContext.save()

    FuelLegacyMigration.runIfNeeded(from: legacyContext, into: context)

    let vehicles = try context.fetch(SharedVehicle.fetchRequest())
    #expect(vehicles.count == 1)
    let migrated = try #require(vehicles.first)
    #expect(migrated.name == "My Q5")
    #expect(migrated.entries?.count == 3)
    #expect(FuelLegacyMigration.hasRun)
}

@MainActor
@Test func runningTwiceInTheSameProcessDoesNotDuplicate() throws {
    resetMigrationFlag()
    let legacyContext = try makeLegacyContext()
    let context = try makeContext()
    addLegacyVehicle("My Q5", fills: [(1000, .now)], to: legacyContext)
    try legacyContext.save()

    FuelLegacyMigration.runIfNeeded(from: legacyContext, into: context)
    FuelLegacyMigration.runIfNeeded(from: legacyContext, into: context)

    #expect(try context.count(for: SharedVehicle.fetchRequest()) == 1)
    #expect(try context.count(for: SharedFuelEntry.fetchRequest()) == 1)
}

/// The actual bug, reproduced directly: `hasRun` alone is not a reliable
/// guard against re-entry — a device could reach `runIfNeeded` again after
/// the flag was reset (e.g. reinstalling across the buggy-build /
/// fixed-build / TestFlight sequence described in this file's doc comment).
/// Content-matching in the destination store must still catch the duplicate
/// even when the flag itself has been cleared.
@MainActor
@Test func reRunningAfterTheCompletionFlagIsClearedStillDoesNotDuplicate() throws {
    resetMigrationFlag()
    let legacyContext = try makeLegacyContext()
    let context = try makeContext()
    addLegacyVehicle("My Q5", fills: [(1000, .now), (1300, .now)], to: legacyContext)
    try legacyContext.save()

    FuelLegacyMigration.runIfNeeded(from: legacyContext, into: context)
    #expect(try context.count(for: SharedVehicle.fetchRequest()) == 1)

    // Simulate the flag having been cleared (or never having synced to this
    // build in the first place) without the destination store being empty —
    // exactly the state a device was found in live.
    resetMigrationFlag()
    FuelLegacyMigration.runIfNeeded(from: legacyContext, into: context)

    #expect(try context.count(for: SharedVehicle.fetchRequest()) == 1, "Re-entry must not create a second SharedVehicle")
    #expect(try context.count(for: SharedFuelEntry.fetchRequest()) == 2, "...or duplicate its fuel entries")
}

/// The duplicate-cars bug: a reinstall wipes the local flag, and the import
/// matched only by name against what iCloud had synced so far — a car renamed
/// since (or not yet downloaded) came back as a second car. A store that
/// already holds any car has been through the import on this account, and is
/// never copied into again.
@MainActor
@Test func aStoreThatAlreadyHoldsCarsIsNeverCopiedIntoAgain() throws {
    resetMigrationFlag()
    let legacyContext = try makeLegacyContext()
    let context = try makeContext()
    addLegacyVehicle("My Q5", fills: [(1000, .now)], to: legacyContext)
    addLegacyVehicle("My X3", fills: [(2000, .now)], to: legacyContext)
    try legacyContext.save()
    FuelLegacyMigration.runIfNeeded(from: legacyContext, into: context)

    // Renamed in the new store, then the app is reinstalled.
    let q5 = try #require(try context.fetch(SharedVehicle.fetchRequest()).first { $0.name == "My Q5" })
    q5.name = "Audi"
    try context.save()
    resetMigrationFlag()
    FuelLegacyMigration.runIfNeeded(from: legacyContext, into: context, importOutcome: .imported)

    #expect(try context.count(for: SharedVehicle.fetchRequest()) == 2, "The renamed car isn't copied back")
    #expect(FuelLegacyMigration.hasRun)
}

/// After the gate's minute runs out this device can't tell "iCloud has no
/// cars" from "they haven't arrived yet": copying then re-created every car a
/// fresh install hadn't downloaded. It waits for the next launch instead.
@MainActor
@Test func nothingIsCopiedWhenICloudHasNotCaughtUp() throws {
    resetMigrationFlag()
    let legacyContext = try makeLegacyContext()
    let context = try makeContext()
    addLegacyVehicle("My Q5", fills: [(1000, .now)], to: legacyContext)
    try legacyContext.save()

    FuelLegacyMigration.runIfNeeded(from: legacyContext, into: context, importOutcome: .timedOut)
    #expect(try context.count(for: SharedVehicle.fetchRequest()) == 0)
    #expect(!FuelLegacyMigration.hasRun, "Tried again next launch")

    FuelLegacyMigration.runIfNeeded(from: legacyContext, into: context, importOutcome: .imported)
    #expect(try context.count(for: SharedVehicle.fetchRequest()) == 1)
}

@MainActor
@Test func emptyLegacyStoreStillMarksTheFastPathFlag() throws {
    resetMigrationFlag()
    let legacyContext = try makeLegacyContext()
    let context = try makeContext()

    FuelLegacyMigration.runIfNeeded(from: legacyContext, into: context)

    #expect(try context.count(for: SharedVehicle.fetchRequest()) == 0)
    #expect(FuelLegacyMigration.hasRun)
}

// MARK: - Merging duplicates

@MainActor
private func car(_ name: String, created: Date, fills: [(odometer: Int, gallons: Double, cost: Double)], in context: NSManagedObjectContext) -> SharedVehicle {
    let vehicle = SharedVehicle(context: context, name: name)
    vehicle.createdAt = created
    for fill in fills {
        // A fill-up's date is its own, not the car's: a copy carries the
        // original's dates however much later the copy was made.
        let date = Date(timeIntervalSinceReferenceDate: 780_000_000 + Double(fill.odometer) * 3_600)
        let entry = SharedFuelEntry(context: context, date: date, odometer: fill.odometer, gallons: fill.gallons, totalCost: fill.cost)
        entry.vehicle = vehicle
    }
    return vehicle
}

@MainActor
@Test func duplicateCarsMergeIntoTheOldestKeepingEveryFillUpOnce() throws {
    let context = try makeContext()
    let t0 = Date(timeIntervalSinceReferenceDate: 780_000_000)
    let original = car("My X3", created: t0, fills: [(1000, 12, 48), (1300, 11.5, 46)], in: context)
    // The reinstall's copy: the same log, plus one fill-up only it has.
    _ = car("my x3 ", created: t0.addingTimeInterval(86_400 * 90), fills: [(1000, 12, 48), (1300, 11.5, 46), (1600, 12.2, 50)], in: context)
    _ = car("My Q5", created: t0, fills: [(500, 10, 40)], in: context)
    try context.save()

    let duplicates = FuelDuplicates(vehicles: try context.fetch(SharedVehicle.fetchRequest()), isOwn: { _ in true }, isShared: { _ in false })
    #expect(duplicates.groups.count == 1, "Names match ignoring case and spaces; My Q5 is alone")
    #expect(duplicates.groups.first?.keep == original, "The oldest is kept")
    #expect(duplicates.groups.first?.entriesToMove == 1)

    let result = duplicates.merge()
    try context.save()
    #expect(result.carsRemoved == 1 && result.entriesMoved == 1)
    #expect(try context.count(for: SharedVehicle.fetchRequest()) == 2)
    #expect(original.orderedFillUps.map(\.odometer) == [1000, 1300, 1600])
    #expect(try context.count(for: SharedFuelEntry.fetchRequest()) == 4, "The copy's duplicate fill-ups are gone with it")
}

@MainActor
@Test func aSharedCopyIsTheOneKeptAndPartnersCarsAreNeverTouched() throws {
    let context = try makeContext()
    let t0 = Date(timeIntervalSinceReferenceDate: 780_000_000)
    let old = car("My X3", created: t0, fills: [(1000, 12, 48)], in: context)
    let shared = car("My X3", created: t0.addingTimeInterval(60), fills: [(1000, 12, 48)], in: context)
    let partners = car("Their Civic", created: t0, fills: [], in: context)
    let partnersCopy = car("Their Civic", created: t0, fills: [], in: context)
    try context.save()

    let duplicates = FuelDuplicates(
        vehicles: try context.fetch(SharedVehicle.fetchRequest()),
        isOwn: { $0 != partners && $0 != partnersCopy },
        isShared: { $0 == shared }
    )
    #expect(duplicates.groups.map(\.keep) == [shared], "Deleting the shared one would delete it for the partner")
    #expect(duplicates.groups.first?.extras == [old])

    let twoShared = FuelDuplicates(vehicles: [old, shared], isOwn: { _ in true }, isShared: { _ in true })
    #expect(twoShared.isEmpty, "Two shared copies: no safe pick")
}
