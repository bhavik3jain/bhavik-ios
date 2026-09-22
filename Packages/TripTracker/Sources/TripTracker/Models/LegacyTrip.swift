import Foundation
import SwiftData

/// The original SwiftData model, kept alive under a `Legacy` name so the real,
/// already-synced CloudKit records it maps to (`CD_Trip` and friends, from
/// before this module moved to Core Data) are never orphaned. This is a pure
/// rename — every stored property, relationship and annotation is byte-for-
/// byte what `Trip` used to be — so it is safe against the schema already
/// deployed to Production.
///
/// `TripTrackerModule.models` still registers this type (as `LegacyTrip.self`)
/// so `AppSchema.models` keeps it in `BhavikApp`'s SwiftData container: the
/// one-time importer in `TripLegacyMigration.swift` reads through it to copy
/// real trips into the new Core Data store. Do NOT remove it from
/// `AppSchema.models` — that is a separate, later, human-gated step, only
/// once the user has confirmed on a real device that their existing data
/// survived that import.
@Model
public final class LegacyTrip {
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

    @Relationship(deleteRule: .cascade, inverse: \LegacyItineraryItem.trip)
    public var items: [LegacyItineraryItem]? = []

    @Relationship(deleteRule: .cascade, inverse: \LegacyFlight.trip)
    public var flights: [LegacyFlight]? = []

    @Relationship(deleteRule: .cascade, inverse: \LegacyBooking.trip)
    public var bookings: [LegacyBooking]? = []

    public init(title: String, destination: String = "", startDate: Date, endDate: Date, calendar: Calendar = .current) {
        self.title = title
        self.destination = destination
        self.startDate = calendar.startOfDay(for: startDate)
        self.endDate = calendar.startOfDay(for: max(startDate, endDate))
        self.createdAt = .now
    }

    public var hasCoordinate: Bool { latitude != nil && longitude != nil }
}
