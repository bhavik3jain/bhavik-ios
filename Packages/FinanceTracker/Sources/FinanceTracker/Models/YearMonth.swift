import Foundation

/// The calendar every date in Finance is read with: Gregorian, in this
/// device's time zone. One place, so a transaction dated the 1st can't land
/// in the previous month because two call sites disagreed about the zone.
public enum FinanceCalendar {
    public static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    /// Midnight at the start of the given day.
    public static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    /// "2026-09-03" — the JSON document's date format. Built by hand rather
    /// than with a `DateFormatter`, which isn't `Sendable` and so can't be a
    /// shared static.
    public static func dayString(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(twoDigits(parts.month ?? 1))-\(twoDigits(parts.day ?? 1))"
    }

    /// Reads "2026-09-03" back; nil for anything else.
    public static func date(fromDayString text: String) -> Date? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// The start of the day `date` falls on.
    public static func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

/// A calendar month, "2026-09". Sortable as a string, which is why that's how
/// `SharedFinanceMonth` stores it.
public struct YearMonth: Hashable, Comparable, Identifiable, Sendable, CustomStringConvertible {
    public let year: Int
    /// 1 to 12.
    public let month: Int

    /// Out-of-range months roll over, so `month + 1` from December is January
    /// of the next year.
    public init(year: Int, month: Int) {
        var year = year
        var month = month
        while month > 12 {
            month -= 12
            year += 1
        }
        while month < 1 {
            month += 12
            year -= 1
        }
        self.year = year
        self.month = month
    }

    /// Reads "2026-09"; nil for anything else.
    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month) else {
            return nil
        }
        self.init(year: year, month: month)
    }

    /// The month `date` falls in.
    public init(containing date: Date) {
        let parts = FinanceCalendar.calendar.dateComponents([.year, .month], from: date)
        self.init(year: parts.year ?? 2000, month: parts.month ?? 1)
    }

    public var id: String { rawValue }

    /// "2026-09".
    public var rawValue: String { "\(year)-\(FinanceCalendar.twoDigits(month))" }

    public var description: String { rawValue }

    public var next: YearMonth { YearMonth(year: year, month: month + 1) }
    public var previous: YearMonth { YearMonth(year: year, month: month - 1) }

    /// Midnight on the 1st.
    public var start: Date { FinanceCalendar.date(year, month, 1) }

    /// Midnight on the 1st of the next month — exclusive.
    public var end: Date { next.start }

    public func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }

    /// "September 2026".
    public var title: String { start.formatted(.dateTime.month(.wide).year()) }

    /// "September".
    public var monthName: String { start.formatted(.dateTime.month(.wide)) }

    /// "Sep".
    public var shortName: String { start.formatted(.dateTime.month(.abbreviated)) }

    /// How far through this month `now` is, from 0 before it starts to 1 once
    /// it's over.
    public func fractionElapsed(asOf now: Date = .now) -> Double {
        let start = start
        let end = end
        guard now > start else { return 0 }
        guard now < end else { return 1 }
        return now.timeIntervalSince(start) / end.timeIntervalSince(start)
    }

    public static func < (lhs: YearMonth, rhs: YearMonth) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }
}
