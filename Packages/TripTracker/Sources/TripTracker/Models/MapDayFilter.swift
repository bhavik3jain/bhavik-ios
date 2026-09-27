import Foundation

/// The chips above a trip's map.
public enum MapDayFilter: Hashable, Sendable {
    case allDays
    case day(Int)
    /// Only the trip's ideas — items on no day yet.
    case ideas

    /// Today's chip while the trip runs, otherwise everything — a map opened
    /// mid-trip is almost always asking "where am I going today".
    public static func initial(for dates: TripDates, asOf now: Date = .now) -> MapDayFilter {
        dates.dayIndex(of: now).map(MapDayFilter.day) ?? .allDays
    }

    /// Whether an item gets a pin under this filter. Only placed items ever do;
    /// a stay shows under every day, because the hotel is where each day starts
    /// and ends even though it was entered once, on the day of check-in. An
    /// idea shows under All days (drawn apart from the plan) and under Ideas,
    /// never under a day — not even a stay: a hotel still being weighed up
    /// isn't where any day starts.
    public func shows(_ item: SharedItineraryItem) -> Bool {
        guard item.hasCoordinate else { return false }
        switch self {
        case .allDays: return true
        case .day(let index): return !item.isUnassigned && (item.dayIndex == index || item.kind == .lodging)
        case .ideas: return item.isUnassigned
        }
    }
}
