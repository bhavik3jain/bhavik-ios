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

    /// `true` once the import below has run on this device — whether or not it
    /// found anything to copy. Checked by `TripDebugSeed` too: a store that has
    /// already been through this import may be a real, possibly-shared store,
    /// and debug seeding must never write fake trips into that.
    public static var hasRun: Bool {
        UserDefaults.standard.bool(forKey: completedDefaultsKey)
    }

    /// One-time re-arm for devices that already ran the *previous*, broken
    /// version of this importer — the one from before the SwiftData/Core Data
    /// class names were swapped back to their correct sides. That version read
    /// through a `LegacyTrip` type whose CloudKit record type
    /// (`CD_LegacyTrip`) had already come unglued from the user's real,
    /// already-synced `CD_Trip` data, so it found nothing to copy, copied
    /// nothing, and still marked `completedDefaultsKey` done — permanently
    /// skipping the corrected importer below on every device that had already
    /// launched once.
    ///
    /// Only clears the flag when the new Core Data store is still completely
    /// empty of `SharedTrip` objects: every real user is in exactly that state
    /// right now, since the previous run copied nothing, but a store that
    /// already holds something — from manual testing, or a future real
    /// `CKShare` — must never be re-imported into blindly.
    ///
    /// Safe to delete once this fix has shipped and been confirmed working on
    /// real devices; it exists only to give the corrected importer below its
    /// one missed chance to run.
    @MainActor
    private static func rearmIfStoreIsEmpty(context: NSManagedObjectContext) {
        guard hasRun else { return }
        guard let count = try? context.count(for: SharedTrip.fetchRequest()), count == 0 else { return }
        UserDefaults.standard.set(false, forKey: completedDefaultsKey)
    }

    /// Reads every `Trip` (and its items, flights and bookings) out of
    /// `legacyContext` and re-creates it in `context`. Called from
    /// `TripRootView`'s `.task`, ahead of the debug seeder.
    @MainActor
    public static func runIfNeeded(from legacyContext: ModelContext, into context: NSManagedObjectContext) {
        rearmIfStoreIsEmpty(context: context)
        guard !hasRun else { return }
        // Marked done even when there was nothing to copy — a device that has
        // never had a trip should not keep re-scanning the SwiftData store on
        // every launch, and should still count as "already migrated" for
        // TripDebugSeed's guard above.
        defer { UserDefaults.standard.set(true, forKey: completedDefaultsKey) }

        guard let legacyTrips = try? legacyContext.fetch(FetchDescriptor<Trip>()), !legacyTrips.isEmpty else { return }

        for legacyTrip in legacyTrips {
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
    }
}
