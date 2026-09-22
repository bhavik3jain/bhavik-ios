import Core
import CoreData
import Foundation
import SwiftData

/// Copies every trip still reachable through the `Legacy*` SwiftData models
/// into the module's new Core Data store, once per device — the real, live
/// data those models hold has to survive this module's move off SwiftData.
///
/// This is not a schema drop: `TripTrackerModule.models` keeps registering the
/// `Legacy*` types in `AppSchema.models` (see its own doc comment) precisely
/// so this has something to read. Nothing here deletes the old records or
/// their CloudKit zone — that stays a separate, later, human-gated step, once
/// the user has confirmed on a real device that the import below actually
/// carried everything over.
public enum TripLegacyMigration {
    private static let completedDefaultsKey = "TripLegacyMigrationCompleted"

    /// `true` once the import below has run on this device — whether or not it
    /// found anything to copy. Checked by `TripDebugSeed` too: a store that has
    /// already been through this import may be a real, possibly-shared store,
    /// and debug seeding must never write fake trips into that.
    public static var hasRun: Bool {
        UserDefaults.standard.bool(forKey: completedDefaultsKey)
    }

    /// Reads every `LegacyTrip` (and its items, flights and bookings) out of
    /// `legacyContext` and re-creates it in `context`. Called from
    /// `TripRootView`'s `.task`, ahead of the debug seeder.
    @MainActor
    public static func runIfNeeded(from legacyContext: ModelContext, into context: NSManagedObjectContext) {
        guard !hasRun else { return }
        // Marked done even when there was nothing to copy — a device that has
        // never had a trip should not keep re-scanning the SwiftData store on
        // every launch, and should still count as "already migrated" for
        // TripDebugSeed's guard above.
        defer { UserDefaults.standard.set(true, forKey: completedDefaultsKey) }

        guard let legacyTrips = try? legacyContext.fetch(FetchDescriptor<LegacyTrip>()), !legacyTrips.isEmpty else { return }

        for legacyTrip in legacyTrips {
            let trip = Trip(
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
                let item = ItineraryItem(
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
                let flight = Flight(
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
                let booking = Booking(
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
