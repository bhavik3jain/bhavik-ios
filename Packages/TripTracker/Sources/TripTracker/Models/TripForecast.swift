import Core
import Foundation

/// Which weather goes on which day of a trip.
///
/// Kept apart from the views so the rule is testable: a day outside
/// `ForecastWindow` shows a dash even if some provider handed back a value for
/// it, and a day inside the window with nothing matching also shows a dash
/// rather than borrowing a neighbour's.
public enum TripForecast {
    /// The span worth asking a provider about: the trip's first day through its
    /// last day or the last forecastable day, whichever comes first. Nil when
    /// the trip starts beyond the window — there is nothing to fetch yet.
    public static func requestRange(for dates: TripDates, asOf now: Date = .now) -> ClosedRange<Date>? {
        guard ForecastWindow.covers(dates.start, asOf: now, calendar: dates.calendar) else { return nil }
        var last = dates.end
        while last > dates.start, !ForecastWindow.covers(last, asOf: now, calendar: dates.calendar) {
            last = dates.calendar.date(byAdding: .day, value: -1, to: last) ?? dates.start
        }
        return dates.start...last
    }

    /// One slot per trip day, in order: that day's weather, or nil for a dash.
    public static func byDay(_ weather: [DayWeather], dates: TripDates, asOf now: Date = .now) -> [DayWeather?] {
        var byDate: [Date: DayWeather] = [:]
        for day in weather {
            byDate[dates.calendar.startOfDay(for: day.date)] = day
        }
        return (0..<dates.dayCount).map { index in
            let date = dates.date(forDay: index)
            guard ForecastWindow.covers(date, asOf: now, calendar: dates.calendar) else { return nil }
            return byDate[date]
        }
    }

    /// "Forecast from 22 Sep" under an upcoming trip still out of range, or nil
    /// once its first day is forecastable.
    public static func availableFrom(for dates: TripDates, asOf now: Date = .now) -> Date? {
        guard !ForecastWindow.covers(dates.start, asOf: now, calendar: dates.calendar) else { return nil }
        return ForecastWindow.firstForecastDate(for: dates.start, calendar: dates.calendar)
    }
}
