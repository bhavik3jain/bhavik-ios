import Foundation
import SwiftData

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

    public var dates: TripDates { TripDates(start: startDate, end: endDate) }

    /// Items with somewhere to put a pin. What the trip list and the PDF call
    /// "places".
    public var places: [ItineraryItem] {
        (items ?? []).filter(\.hasCoordinate)
    }

    /// Pulls anything planned past the last day back onto it. Shortening a trip
    /// otherwise left those items on days that no longer exist — on no chip, in
    /// no timeline, still counted as places — with no way to reach them.
    public func clampPlanToDates() {
        let last = dates.dayCount - 1
        for item in items ?? [] where item.dayIndex > last || item.dayIndex < 0 {
            item.dayIndex = min(max(item.dayIndex, 0), last)
        }
        for flight in flights ?? [] where flight.dayIndex > last || flight.dayIndex < 0 {
            flight.dayIndex = min(max(flight.dayIndex, 0), last)
        }
    }
}
