import Foundation

/// The days an idea can be moved onto, as a menu reads them.
public enum IdeaDays {
    public struct Choice: Hashable, Identifiable, Sendable {
        public let dayIndex: Int
        /// "Today · Day 3", "Day 5 · Wed 10 Jun".
        public let title: String
        public let isToday: Bool
        public var id: Int { dayIndex }
    }

    /// Every day of the trip in order — except that while the trip runs,
    /// today comes first and isn't repeated further down. Mid-trip, "put it on
    /// today" is what the menu is nearly always for.
    public static func choices(for dates: TripDates, asOf now: Date = .now) -> [Choice] {
        let today = dates.dayIndex(of: now)
        let days = (0..<dates.dayCount).map { index in
            Choice(
                dayIndex: index,
                title: index == today ? "Today · Day \(index + 1)" : "Day \(index + 1) · \(dayLabel(index, dates: dates))",
                isToday: index == today
            )
        }
        return days.filter(\.isToday) + days.filter { !$0.isToday }
    }

    /// "Wed 10 Jun".
    public static func dayLabel(_ index: Int, dates: TripDates) -> String {
        dates.date(forDay: index).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// The short name for where an item sits: "Idea", "Today", "Day 4".
    public static func shortName(forDay index: Int, dates: TripDates, asOf now: Date = .now) -> String {
        if index < 0 { return "Idea" }
        return dates.dayIndex(of: now) == index ? "Today" : "Day \(index + 1)"
    }
}
