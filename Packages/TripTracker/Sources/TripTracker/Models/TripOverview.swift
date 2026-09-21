import Core
import Foundation

/// The trips a list, a peek or the home row needs to talk about, sorted into
/// phases for a given moment.
///
/// The phase is worked out here in Swift rather than in a `#Predicate`: a query
/// filtered on dates freezes "today" at the moment the view was built, so a list
/// left open past midnight kept yesterday's trip in progress.
public struct TripGroups {
    public let inProgress: [Trip]
    public let upcoming: [Trip]
    public let finished: [Trip]

    public init(_ trips: [Trip], asOf now: Date = .now, calendar: Calendar = .current) {
        let live = trips.filter { !$0.isArchived }
        func phase(_ trip: Trip) -> TripPhase { TripPhase.of(trip, asOf: now, calendar: calendar) }
        inProgress = live.filter { phase($0) == .inProgress }.sorted { $0.startDate < $1.startDate }
        upcoming = live.filter { phase($0) == .upcoming }.sorted { $0.startDate < $1.startDate }
        // Most recent first: the trip you just got back from is the one you look up.
        finished = live.filter { phase($0) == .finished }.sorted { $0.endDate > $1.endDate }
    }

    public var isEmpty: Bool { inProgress.isEmpty && upcoming.isEmpty && finished.isEmpty }
}

public enum TripOverview {
    /// "Day 3 of 9".
    public static func dayOfTrip(_ dates: TripDates, asOf now: Date = .now) -> String? {
        dates.dayNumber(asOf: now).map { "Day \($0) of \(dates.dayCount)" }
    }

    /// "today", "tomorrow", "in 12 days".
    public static func countdown(days: Int) -> String {
        switch days {
        case ..<1: "today"
        case 1: "tomorrow"
        default: "in \(counted(days, "day"))"
        }
    }

    /// The line under "Trips" on the home screen. Lives here rather than in
    /// `HomeView` so it can be tested — the app target carries no suite.
    public static func homeDetail(trips: [Trip], asOf now: Date = .now, calendar: Calendar = .current) -> String {
        let groups = TripGroups(trips, asOf: now, calendar: calendar)
        if let current = groups.inProgress.first {
            let dates = TripDates(start: current.startDate, end: current.endDate, calendar: calendar)
            return "\(current.title) · day \(dates.offset(of: now) + 1) of \(dates.dayCount)"
        }
        if let next = groups.upcoming.first {
            let dates = TripDates(start: next.startDate, end: next.endDate, calendar: calendar)
            return "\(next.title) \(countdown(days: dates.daysUntilStart(asOf: now)))"
        }
        return groups.isEmpty ? "No trips yet" : "Nothing coming up"
    }

    /// The next flight still ahead of `now`. A flight with a departure time
    /// counts until it leaves; one without counts through the day it sits under.
    public static func nextFlight(in trip: Trip, asOf now: Date = .now) -> Flight? {
        let dates = trip.dates
        let today = dates.offset(of: now)
        return (trip.flights ?? [])
            .filter { flight in
                if let departs = flight.departsAt { return departs >= now }
                return flight.dayIndex >= today
            }
            .min { lhs, rhs in
                let left = lhs.departsAt ?? dates.date(forDay: lhs.dayIndex)
                let right = rhs.departsAt ?? dates.date(forDay: rhs.dayIndex)
                return left < right
            }
    }
}
