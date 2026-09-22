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
    UserDefaults.standard.removeObject(forKey: completedDefaultsKey)
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

@MainActor
@Test func newLegacyVehiclesAddedAfterAFirstImportAreStillPickedUp() throws {
    resetMigrationFlag()
    let legacyContext = try makeLegacyContext()
    let context = try makeContext()
    addLegacyVehicle("My Q5", fills: [(1000, .now)], to: legacyContext)
    try legacyContext.save()

    FuelLegacyMigration.runIfNeeded(from: legacyContext, into: context)
    #expect(try context.count(for: SharedVehicle.fetchRequest()) == 1)

    // A second legacy vehicle only appears later — the dedup check must add
    // it without touching the one already copied.
    resetMigrationFlag()
    addLegacyVehicle("My X3", fills: [(2000, .now)], to: legacyContext)
    try legacyContext.save()
    FuelLegacyMigration.runIfNeeded(from: legacyContext, into: context)

    let names = Set(try context.fetch(SharedVehicle.fetchRequest()).map(\.name))
    #expect(names == ["My Q5", "My X3"])
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
