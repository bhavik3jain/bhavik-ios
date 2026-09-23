import Core
import CoreData
import Foundation
import SwiftData

/// Copies every trip still reachable through the original SwiftData models
/// (`Trip`, `ItineraryItem`, `Flight`, `Booking` in the `SwiftData*.swift`
/// files) into the module's new Core Data store (`SharedTrip` and friends),
/// once per device — the real, live data those models hold has to survive
/// this module's move off SwiftData.
///
/// This is not a schema drop: `TripTrackerModule.models` keeps registering the
/// original SwiftData types in `AppSchema.models` (see `Trip`'s own doc
/// comment, in `SwiftDataTrip.swift`) precisely so this has something to
/// read. Nothing here deletes the old records or their CloudKit zone — that
/// stays a separate, later, human-gated step, once the user has confirmed on
/// a real device that the import below actually carried everything over.
public enum TripLegacyMigration {
    private static let completedDefaultsKey = "TripLegacyMigrationCompleted"

    /// `true` once every legacy trip has been confirmed present in the new
    /// store — a fast path only, checked below to skip re-scanning the
    /// SwiftData store on every launch once there is nothing left to do. Also
    /// checked by `TripDebugSeed`: a store that has already been through this
    /// import may be a real, possibly-shared store, and debug seeding must
    /// never write fake trips into that.
    public static var hasRun: Bool {
        UserDefaults.standard.bool(forKey: completedDefaultsKey)
    }

    /// Reads every `Trip` (and its items, flights and bookings) out of
    /// `legacyContext` and re-creates it in `context`, skipping any legacy
    /// trip that already has a matching `SharedTrip` (matched by `title`,
    /// `startDate` and `endDate`) in the destination store — when a trip
    /// already exists, its items/flights/bookings are assumed to have already
    /// been copied along with it, so they are not re-walked. Called from
    /// `TripRootView`'s `.task`, ahead of the debug seeder, and only after
    /// `CloudKitImportGate` — the existence check sees only the local store,
    /// so it guards against another device's copies only once those have been
    /// imported.
    ///
    /// The per-trip existence check above is the actual guard against
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
    /// after a re-fetch confirms every legacy trip now has a match — never
    /// assumed from the loop below alone.
    @MainActor
    public static func runIfNeeded(from legacyContext: ModelContext, into context: NSManagedObjectContext) {
        guard !hasRun else { return }

        guard let legacyTrips = try? legacyContext.fetch(FetchDescriptor<Trip>()), !legacyTrips.isEmpty else {
            // Nothing to migrate — a device that has never had a trip should
            // not keep re-scanning the SwiftData store on every launch, and
            // should still count as "already migrated" for TripDebugSeed's
            // guard above.
            UserDefaults.standard.set(true, forKey: completedDefaultsKey)
            return
        }

        for legacyTrip in legacyTrips {
            guard !tripExists(matching: legacyTrip, in: context) else { continue }

            let trip = SharedTrip(
                context: context,
                title: legacyTrip.title,
                destination: legacyTrip.destination,
                startDate: legacyTrip.startDate,
                endDate: legacyTrip.endDate
            )
            trip.notes = legacyTrip.notes
            trip.isArchived = legacyTrip.isArchived
            trip.createdAt = legacyTrip.createdAt
            trip.latitude = legacyTrip.latitude
            trip.longitude = legacyTrip.longitude

            for legacyItem in legacyTrip.items ?? [] {
                let item = SharedItineraryItem(
                    context: context,
                    title: legacyItem.title,
                    kind: legacyItem.kind,
                    dayIndex: legacyItem.dayIndex,
                    startTime: legacyItem.startTime,
                    sortOrder: legacyItem.sortOrder
                )
                item.detail = legacyItem.detail
                item.durationMinutes = legacyItem.durationMinutes
                item.address = legacyItem.address
                item.latitude = legacyItem.latitude
                item.longitude = legacyItem.longitude
                item.isDone = legacyItem.isDone
                item.doneAt = legacyItem.doneAt
                item.trip = trip
            }

            for legacyFlight in legacyTrip.flights ?? [] {
                let flight = SharedFlight(
                    context: context,
                    airlineCode: legacyFlight.airlineCode,
                    number: legacyFlight.number,
                    originCode: legacyFlight.originCode,
                    destinationCode: legacyFlight.destinationCode,
                    dayIndex: legacyFlight.dayIndex
                )
                flight.departsAt = legacyFlight.departsAt
                flight.arrivesAt = legacyFlight.arrivesAt
                flight.seat = legacyFlight.seat
                flight.terminal = legacyFlight.terminal
                flight.confirmationCode = legacyFlight.confirmationCode
                flight.notes = legacyFlight.notes
                flight.trip = trip
            }

            for legacyBooking in legacyTrip.bookings ?? [] {
                let booking = SharedBooking(
                    context: context,
                    title: legacyBooking.title,
                    kind: legacyBooking.kind,
                    code: legacyBooking.code,
                    provider: legacyBooking.provider
                )
                booking.startsAt = legacyBooking.startsAt
                booking.endsAt = legacyBooking.endsAt
                booking.contactPhone = legacyBooking.contactPhone
                booking.notes = legacyBooking.notes
                booking.sortOrder = legacyBooking.sortOrder
                booking.secureNote = legacyBooking.secureNote
                booking.trip = trip
            }
        }

        try? context.saveIfNeeded()

        if legacyTrips.allSatisfy({ tripExists(matching: $0, in: context) }) {
            UserDefaults.standard.set(true, forKey: completedDefaultsKey)
        }
    }

    /// Whether `context` already holds a `SharedTrip` for this legacy trip's
    /// natural key. Titles are not enforced unique anywhere (see CLAUDE.md —
    /// no `@Attribute(.unique)`, CloudKit doesn't support it), so this is a
    /// best-effort content match, not a database constraint.
    @MainActor
    private static func tripExists(matching legacyTrip: Trip, in context: NSManagedObjectContext) -> Bool {
        let request = SharedTrip.fetchRequest(predicate: NSPredicate(
            format: "title == %@ AND startDate == %@ AND endDate == %@",
            legacyTrip.title, legacyTrip.startDate as NSDate, legacyTrip.endDate as NSDate
        ))
        request.fetchLimit = 1
        return ((try? context.count(for: request)) ?? 0) > 0
    }
}
