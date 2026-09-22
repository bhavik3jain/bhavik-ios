import Foundation

/// The chips above a trip's map.
public enum MapDayFilter: Hashable, Sendable {
    case allDays
    case day(Int)

    /// Today's chip while the trip runs, otherwise everything — a map opened
    /// mid-trip is almost always asking "where am I going today".
    public static func initial(for dates: TripDates, asOf now: Date = .now) -> MapDayFilter {
        dates.dayIndex(of: now).map(MapDayFilter.day) ?? .allDays
    }

    /// Whether an item gets a pin under this filter. Only placed items ever do;
    /// a stay shows under every day, because the hotel is where each day starts
    /// and ends even though it was entered once, on the day of check-in.
    public func shows(_ item: SharedItineraryItem) -> Bool {
        guard item.hasCoordinate else { return false }
        switch self {
        case .allDays: return true
        case .day(let index): return item.dayIndex == index || item.kind == .lodging
        }
    }
}
