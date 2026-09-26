import CoreData
import Foundation

/// One day of a trip as a single timeline: its itinerary items and its flights,
/// merged and put in the order the day will actually happen.
///
/// Timed entries come first, earliest first; then everything with no set time
/// ("Anytime"). Items sharing a time, or both untimed, fall back to their
/// `sortOrder` and then their title, so the order never depends on fetch order —
/// Core Data's `Set<T>?` relationships return in no promised order (SwiftData's
/// arrays didn't either), and two untimed items used to swap places between
/// launches.
public struct DayPlan {
    public enum Entry: Identifiable {
        case item(SharedItineraryItem)
        case flight(SharedFlight)

        public var id: NSManagedObjectID {
            switch self {
            case .item(let item): item.objectID
            case .flight(let flight): flight.objectID
            }
        }

        public var title: String {
            switch self {
            case .item(let item): item.title
            case .flight(let flight): flight.headline
            }
        }

        /// Flights are facts, not plans — there is nothing to tick off.
        public var isDone: Bool {
            switch self {
            case .item(let item): item.isDone
            case .flight: false
            }
        }
    }

    public let dayIndex: Int
    public let dates: TripDates
    public let timed: [Entry]
    public let untimed: [Entry]

    public var entries: [Entry] { timed + untimed }
    public var isEmpty: Bool { timed.isEmpty && untimed.isEmpty }

    public init(dayIndex: Int, items: [SharedItineraryItem], flights: [SharedFlight], dates: TripDates) {
        self.dayIndex = dayIndex
        self.dates = dates

        // No day below 0 has a plan. Ideas sit at `unassignedDayIndex` (-1),
        // and `dates.offset(of:)` — which the trip list and home peek pass
        // straight in as "today" — is -1 the day before a trip starts. They
        // only ask about trips already under way, but with the equality filter
        // alone, any caller that didn't would get every idea back as the
        // day's plan.
        let dayItems = dayIndex < 0 ? [] : items.filter { $0.dayIndex == dayIndex }
        let dayFlights = dayIndex < 0 ? [] : flights.filter { $0.dayIndex == dayIndex }

        struct Keyed {
            let entry: Entry
            let minute: Int?
            /// Flights ahead of items at the same minute: you can't be at dinner
            /// and on the plane, and the plane won't wait.
            let rank: Int
            let sortOrder: Int
            let title: String
        }

        var keyed: [Keyed] = dayItems.map { item in
            Keyed(entry: .item(item), minute: item.startTime.map(dates.minuteOfDay), rank: 1, sortOrder: item.sortOrder, title: item.title)
        }
        keyed += dayFlights.map { flight in
            Keyed(entry: .flight(flight), minute: flight.departsAt.map(dates.minuteOfDay), rank: 0, sortOrder: 0, title: flight.headline)
        }

        func ordered(_ lhs: Keyed, _ rhs: Keyed) -> Bool {
            if lhs.minute != rhs.minute { return (lhs.minute ?? 0) < (rhs.minute ?? 0) }
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }

        timed = keyed.filter { $0.minute != nil }.sorted(by: ordered).map(\.entry)
        // Untimed items keep the order they were arranged in; an untimed flight
        // — booked, time not yet known — trails them.
        untimed = keyed.filter { $0.minute == nil }
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
                return ordered(lhs, rhs)
            }
            .map(\.entry)
    }

    public init(trip: SharedTrip, dayIndex: Int) {
        self.init(dayIndex: dayIndex, items: Array(trip.items ?? []), flights: Array(trip.flights ?? []), dates: trip.dates)
    }

    // MARK: - Moments

    /// When an entry starts, on this day.
    public func start(of entry: Entry) -> Date? {
        switch entry {
        case .item(let item): item.startTime.map { dates.moment(day: dayIndex, time: $0) }
        case .flight(let flight): flight.departsAt.map { dates.moment(day: dayIndex, time: $0) }
        }
    }

    /// When an entry is over: its start plus its length, or just its start when
    /// it has no set length.
    public func end(of entry: Entry) -> Date? {
        guard let start = start(of: entry) else { return nil }
        switch entry {
        case .item(let item):
            return start.addingTimeInterval(TimeInterval(item.durationMinutes * 60))
        case .flight(let flight):
            // An arrival before departure is an overnight flight typed as a time
            // of day; fall back to the departure rather than a negative span.
            guard let arrives = flight.arrivesAt, let departs = flight.departsAt, arrives > departs else { return start }
            return start.addingTimeInterval(arrives.timeIntervalSince(departs))
        }
    }

    public func isToday(asOf now: Date = .now) -> Bool {
        dates.offset(of: now) == dayIndex
    }

    // MARK: - Up next

    /// What's next today: the first unfinished timed entry that isn't already
    /// over — one in progress still counts — and failing that, the first
    /// unfinished "Anytime" item. Nil on any day but today, and once everything
    /// is done.
    public func upNext(asOf now: Date = .now) -> Entry? {
        guard isToday(asOf: now) else { return nil }
        if let timedNext = timed.first(where: { entry in
            guard !entry.isDone, let end = end(of: entry) else { return false }
            return end >= now
        }) {
            return timedNext
        }
        return untimed.first { entry in
            if case .item(let item) = entry { return !item.isDone }
            return false
        }
    }

    /// Where the NOW line goes among the timed entries: before the first one
    /// that hasn't started. `timed.count` puts it after them all. Nil on any day
    /// but today.
    public func nowLineIndex(asOf now: Date = .now) -> Int? {
        guard isToday(asOf: now) else { return nil }
        return timed.firstIndex { entry in
            guard let start = start(of: entry) else { return false }
            return start > now
        } ?? timed.count
    }

    // MARK: - Counts

    /// Items only: flights are never "done".
    public var itemCount: Int {
        entries.count { if case .item = $0 { true } else { false } }
    }

    public var doneCount: Int {
        entries.count { if case .item(let item) = $0 { item.isDone } else { false } }
    }
}
