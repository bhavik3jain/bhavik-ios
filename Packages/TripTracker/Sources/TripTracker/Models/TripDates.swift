import Foundation

/// Where a trip stands relative to today.
public enum TripPhase: String, Sendable, CaseIterable {
    case upcoming
    case inProgress
    case finished

    public var displayName: String {
        switch self {
        case .upcoming: "Upcoming"
        case .inProgress: "In progress"
        case .finished: "Finished"
        }
    }

    /// Derived every time, never stored — see the note on `Trip`.
    public static func of(_ trip: Trip, asOf now: Date = .now, calendar: Calendar = .current) -> TripPhase {
        TripDates(start: trip.startDate, end: trip.endDate, calendar: calendar).phase(asOf: now)
    }
}

/// A trip's days as arithmetic: which day a date falls on, which date a day is,
/// and where today sits among them.
///
/// Comparisons are by calendar day, never by instant. The trip's last day is
/// stored as its midnight, so comparing instants called a trip finished from
/// 00:01 on its last day — the whole final day went missing from "In progress".
public struct TripDates: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let calendar: Calendar

    public init(start: Date, end: Date, calendar: Calendar = .current) {
        self.calendar = calendar
        self.start = calendar.startOfDay(for: start)
        // An end before the start is a typo, not a negative-length trip.
        self.end = max(self.start, calendar.startOfDay(for: end))
    }

    /// Inclusive of both ends: 6–14 June is nine days.
    public var dayCount: Int {
        (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
    }

    /// The start of day `index`, counting the first day as 0.
    public func date(forDay index: Int) -> Date {
        calendar.date(byAdding: .day, value: index, to: start) ?? start
    }

    /// The offset of `date` from the first day — negative before the trip, past
    /// the last index after it.
    public func offset(of date: Date) -> Int {
        calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// The day `date` falls on, or nil outside the trip.
    public func dayIndex(of date: Date) -> Int? {
        let offset = offset(of: date)
        return (0..<dayCount).contains(offset) ? offset : nil
    }

    public func phase(asOf now: Date = .now) -> TripPhase {
        let offset = offset(of: now)
        if offset < 0 { return .upcoming }
        return offset < dayCount ? .inProgress : .finished
    }

    /// "Day 3" of the trip is today — 1-based, and nil unless the trip is under way.
    public func dayNumber(asOf now: Date = .now) -> Int? {
        dayIndex(of: now).map { $0 + 1 }
    }

    /// Whole days until the first day, zero once it has begun.
    public func daysUntilStart(asOf now: Date = .now) -> Int {
        max(0, -offset(of: now))
    }

    /// How far through the trip today is, counting today as under way: day 3 of
    /// 9 reads a third. 0 before, 1 after.
    public func progress(asOf now: Date = .now) -> Double {
        switch phase(asOf: now) {
        case .upcoming: 0
        case .finished: 1
        case .inProgress: Double(offset(of: now) + 1) / Double(dayCount)
        }
    }

    /// The day a trip opens on: today while it runs, the first day before it
    /// starts, and the last day once it's over — a finished trip reads as a log
    /// of how it ended.
    public static func initialDay(for dates: TripDates, asOf now: Date = .now) -> Int {
        switch dates.phase(asOf: now) {
        case .upcoming: 0
        case .inProgress: dates.offset(of: now)
        case .finished: dates.dayCount - 1
        }
    }

    public static func initialDay(for trip: Trip, asOf now: Date = .now) -> Int {
        initialDay(for: trip.dates, asOf: now)
    }

    /// The moment `time`'s hour and minute fall on day `index`.
    public func moment(day index: Int, time: Date) -> Date {
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: date(forDay: index))
            ?? date(forDay: index)
    }

    /// Minutes after midnight, for ordering times of day regardless of which
    /// date they were typed on.
    public func minuteOfDay(_ time: Date) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
