import Core
import CoreData
import Foundation
import SwiftData
import Testing
@testable import TripTracker

/// A fresh, in-memory SwiftData store holding just the legacy `Trip`/
/// `ItineraryItem`/`Flight`/`Booking` models, standing in for the app-wide
/// SwiftData container `TripRootView` reads through `@Environment(\.modelContext)`.
@MainActor
private func makeLegacyContext() throws -> ModelContext {
    let schema = Schema([Trip.self, ItineraryItem.self, Flight.self, Booking.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return ModelContext(container)
}

/// `TripLegacyMigration.hasRun` reads a fixed `UserDefaults.standard` key, so
/// every test that drives `runIfNeeded` must reset it first — otherwise a
/// flag left `true` by an earlier test (or an earlier run of this same test)
/// makes `runIfNeeded` a no-op before it even looks at the legacy store.
private let completedDefaultsKey = "TripLegacyMigrationCompleted"

private func resetMigrationFlag() {
    LegacyMigrationLedger.reset(completedDefaultsKey)
}

@MainActor
@discardableResult
private func addLegacyTrip(
    _ title: String,
    destination: String = "",
    start: Date,
    end: Date,
    to legacyContext: ModelContext
) -> Trip {
    let trip = Trip(title: title, destination: destination, startDate: start, endDate: end)
    legacyContext.insert(trip)
    return trip
}

// MARK: - Idempotent by content, not by the completion flag

@MainActor
@Test func migratesALegacyTripWithItsItemsFlightsAndBookings() throws {
    resetMigrationFlag()
    let legacyContext = try makeLegacyContext()
    let context = try makeContext()

    let trip = addLegacyTrip("Rome & Amalfi", destination: "Rome, Italy", start: day(6, 6), end: day(6, 14), to: legacyContext)
    let item = ItineraryItem(title: "Colosseum", kind: .sight, dayIndex: 0)
    item.trip = trip
    let flight = Flight(airlineCode: "BA", number: "285", originCode: "LHR", destinationCode: "FCO", dayIndex: 0)
    flight.trip = trip
    let booking = Booking(title: "Hotel de Russie", kind: .lodging)
    booking.trip = trip
    try legacyContext.save()

    TripLegacyMigration.runIfNeeded(from: legacyContext, into: context)

    let trips = try context.fetch(SharedTrip.fetchRequest())
    #expect(trips.count == 1)
    let migrated = try #require(trips.first)
    #expect(migrated.title == "Rome & Amalfi")
    #expect(migrated.items?.count == 1)
    #expect(migrated.flights?.count == 1)
    #expect(migrated.bookings?.count == 1)
    #expect(TripLegacyMigration.hasRun)
}

@MainActor
@Test func runningTwiceInTheSameProcessDoesNotDuplicate() throws {
    resetMigrationFlag()
    let legacyContext = try makeLegacyContext()
    let context = try makeContext()
    addLegacyTrip("Rome & Amalfi", start: day(6, 6), end: day(6, 14), to: legacyContext)
    try legacyContext.save()

    TripLegacyMigration.runIfNeeded(from: legacyContext, into: context)
    TripLegacyMigration.runIfNeeded(from: legacyContext, into: context)

    #expect(try context.count(for: SharedTrip.fetchRequest()) == 1)
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
    let trip = addLegacyTrip("Rome & Amalfi", start: day(6, 6), end: day(6, 14), to: legacyContext)
    let item = ItineraryItem(title: "Colosseum", kind: .sight, dayIndex: 0)
    item.trip = trip
    try legacyContext.save()

    TripLegacyMigration.runIfNeeded(from: legacyContext, into: context)
    #expect(try context.count(for: SharedTrip.fetchRequest()) == 1)

    // Simulate the flag having been cleared (or never having synced to this
    // build in the first place) without the destination store being empty —
    // exactly the state a device was found in live.
    resetMigrationFlag()
    TripLegacyMigration.runIfNeeded(from: legacyContext, into: context)

    #expect(try context.count(for: SharedTrip.fetchRequest()) == 1, "Re-entry must not create a second SharedTrip")
    #expect(try context.count(for: SharedItineraryItem.fetchRequest()) == 1, "...or duplicate its itinerary items")
}

@MainActor
/// A reinstall wipes the local flag; the import used to copy again whatever
/// didn't match by title and dates — a trip renamed or re-dated since came
/// back twice. A store that already holds trips is never copied into again.
@Test func aStoreThatAlreadyHoldsTripsIsNeverCopiedIntoAgain() throws {
    resetMigrationFlag()
    let legacyContext = try makeLegacyContext()
    let context = try makeContext()
    addLegacyTrip("Rome & Amalfi", start: day(6, 6), end: day(6, 14), to: legacyContext)
    try legacyContext.save()

    TripLegacyMigration.runIfNeeded(from: legacyContext, into: context)
    #expect(try context.count(for: SharedTrip.fetchRequest()) == 1)

    resetMigrationFlag()
    addLegacyTrip("Lisbon long weekend", start: day(7, 1), end: day(7, 4), to: legacyContext)
    try legacyContext.save()
    TripLegacyMigration.runIfNeeded(from: legacyContext, into: context)

    let titles = Set(try context.fetch(SharedTrip.fetchRequest()).map(\.title))
    #expect(titles == ["Rome & Amalfi"], "Nothing is copied into a store that has trips")
    #expect(TripLegacyMigration.hasRun)
}

/// Two trips can legitimately share a title ("Weekend trip" booked twice in
/// different years) — the natural key is title *and* dates together, so this
/// must be treated as two distinct trips, not deduplicated into one.
@MainActor
@Test func tripsWithTheSameTitleButDifferentDatesAreNotTreatedAsDuplicates() throws {
    resetMigrationFlag()
    let legacyContext = try makeLegacyContext()
    let context = try makeContext()
    addLegacyTrip("Long weekend", start: day(3, 1), end: day(3, 4), to: legacyContext)
    addLegacyTrip("Long weekend", start: day(9, 1), end: day(9, 4), to: legacyContext)
    try legacyContext.save()

    TripLegacyMigration.runIfNeeded(from: legacyContext, into: context)

    #expect(try context.count(for: SharedTrip.fetchRequest()) == 2)
}

@MainActor
@Test func emptyLegacyStoreStillMarksTheFastPathFlag() throws {
    resetMigrationFlag()
    let legacyContext = try makeLegacyContext()
    let context = try makeContext()

    TripLegacyMigration.runIfNeeded(from: legacyContext, into: context)

    #expect(try context.count(for: SharedTrip.fetchRequest()) == 0)
    #expect(TripLegacyMigration.hasRun)
}
