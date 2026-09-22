import Foundation
import SwiftData

/// The original SwiftData model — kept under its exact original name, `Trip`.
///
/// This is a pure revert. An earlier version of this migration renamed this
/// class to `LegacyTrip`, on the theory that the `Legacy` prefix was just
/// documentation. It was not: SwiftData ties a model's identity, and its
/// CloudKit record type (`CD_<ClassName>`, via `NSPersistentCloudKitContainer`'s
/// own convention), directly to the Swift class name, with no way to
/// decouple the two short of a `VersionedSchema`/`SchemaMigrationPlan` — and
/// this repo has never used one (see CLAUDE.md). Renaming `Trip` to
/// `LegacyTrip` therefore didn't just rename a file; it made SwiftData treat
/// every trip as belonging to a brand-new, unrelated `CD_LegacyTrip` record
/// type, orphaning every real, already-synced `CD_Trip` record already in
/// Production. Confirmed live on a real device: after that rename, Trips,
/// Fuel and Explore all read empty despite existing data. This file undoes
/// that: every stored property, relationship and annotation below is
/// byte-for-byte what this class has always been, so it reads the schema
/// already deployed to Production again.
///
/// The *new* Core Data model this module is moving to did the right thing
/// from the start — it decouples `NSEntityDescription.name` from the Swift
/// class name, so its classes now carry the `Shared` prefix
/// (`SharedTrip` in `SharedTrip.swift`) while this class keeps the plain
/// name. See that file's doc comment for the full picture.
///
/// `TripTrackerModule.models` still registers this type (as `Trip.self`) so
/// `AppSchema.models` keeps it in `BhavikApp`'s SwiftData container: the
/// one-time importer in `TripLegacyMigration.swift` reads through it to copy
/// real trips into the new Core Data store. Do NOT remove it from
/// `AppSchema.models` — that is a separate, later, human-gated step, only
/// once the user has confirmed on a real device that their existing data
/// survived that import.
///
/// Filename is `SwiftDataTrip.swift`, not `Trip.swift` — `Trip.swift` would
/// collide with nothing today, but the filename carries no meaning to
/// SwiftData or Core Data either way; only the type name below matters. Kept
/// distinct from `SharedTrip.swift` purely for readability.
@Model
public final class Trip {
    public var title: String = ""
    /// What was picked in the destination search, "Rome, Italy".
    public var destination: String = ""
    /// The first day, stored as the start of that local day.
    public var startDate: Date = Date.now
    /// The last day, inclusive, stored as the start of that local day.
    public var endDate: Date = Date.now
    public var notes: String = ""
    public var isArchived: Bool = false
    public var createdAt: Date = Date.now
    /// The destination's coordinate, which is what weather is fetched for. Both
    /// stay nil when a destination was typed rather than picked from the search,
    /// and the trip then simply shows no weather.
    public var latitude: Double?
    public var longitude: Double?

    // No stored phase. "In progress" is a fact about today, and a stored flag
    // would be wrong every morning — nothing runs in the background to flip it
    // (the app has no background work at all). `TripPhase.of(_:asOf:)` derives
    // it each time it is asked.

    @Relationship(deleteRule: .cascade, inverse: \ItineraryItem.trip)
    public var items: [ItineraryItem]? = []

    @Relationship(deleteRule: .cascade, inverse: \Flight.trip)
    public var flights: [Flight]? = []

    @Relationship(deleteRule: .cascade, inverse: \Booking.trip)
    public var bookings: [Booking]? = []

    public init(title: String, destination: String = "", startDate: Date, endDate: Date, calendar: Calendar = .current) {
        self.title = title
        self.destination = destination
        self.startDate = calendar.startOfDay(for: startDate)
        self.endDate = calendar.startOfDay(for: max(startDate, endDate))
        self.createdAt = .now
    }

    public var hasCoordinate: Bool { latitude != nil && longitude != nil }
}
