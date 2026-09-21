import Foundation
import Testing
@testable import Core

// A fixed calendar and clock, so the window's edges don't move with the
// machine's time zone or the day the suite happens to run.
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

private func day(_ offset: Int, from base: Date = now) -> Date {
    calendar.date(byAdding: .day, value: offset, to: base)!
}

/// Mid-afternoon, so an off-by-one on the start of the day shows up as a failure.
private let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 15))!

// MARK: - Forecast window

@Test func todayAndTheNextNineDaysAreForecastable() {
    #expect(ForecastWindow.covers(now, asOf: now, calendar: calendar))
    #expect(ForecastWindow.covers(day(9), asOf: now, calendar: calendar), "The tenth day counting today")
}

@Test func tenDaysOutIsBeyondTheForecast() {
    #expect(!ForecastWindow.covers(day(10), asOf: now, calendar: calendar))
    #expect(!ForecastWindow.covers(day(11), asOf: now, calendar: calendar))
}

@Test func theWindowIsMeasuredInDaysNotHours() {
    // Early on the ninth day out is under 9×24 hours away from mid-afternoon
    // today, late on it is over; both are the same day and both are covered.
    let ninthDay = calendar.startOfDay(for: day(9))
    #expect(ForecastWindow.covers(ninthDay, asOf: now, calendar: calendar))
    #expect(ForecastWindow.covers(ninthDay.addingTimeInterval(23 * 3600), asOf: now, calendar: calendar))
    #expect(!ForecastWindow.covers(calendar.startOfDay(for: day(10)), asOf: now, calendar: calendar))
}

@Test func pastDaysAreAlwaysCovered() {
    #expect(ForecastWindow.covers(day(-1), asOf: now, calendar: calendar))
    #expect(ForecastWindow.covers(day(-400), asOf: now, calendar: calendar), "History, not forecast")
}

@Test func aForecastAppearsNineDaysAhead() {
    let trip = day(30)
    let first = ForecastWindow.firstForecastDate(for: trip, calendar: calendar)
    #expect(first == calendar.startOfDay(for: day(21)))
    #expect(ForecastWindow.covers(trip, asOf: first, calendar: calendar))
    #expect(!ForecastWindow.covers(trip, asOf: day(-1, from: first), calendar: calendar), "The day before it appears")
}

// MARK: - Formatting

@Test func temperaturesFollowTheLocalesUnit() {
    #expect(WeatherFormat.temperature(28.3, locale: Locale(identifier: "en_US")) == "83°")
    #expect(WeatherFormat.temperature(28.3, locale: Locale(identifier: "en_GB")) == "28°")
    #expect(WeatherFormat.temperature(28.3, locale: Locale(identifier: "fr_FR")) == "28°")
}

@Test func temperaturesCarryNoUnitLetterOrNegativeZero() {
    #expect(WeatherFormat.temperature(0, locale: Locale(identifier: "en_US")) == "32°")
    #expect(WeatherFormat.temperature(-0.3, locale: Locale(identifier: "en_GB")) == "0°")
    #expect(WeatherFormat.temperature(-5, locale: Locale(identifier: "en_GB")) == "-5°")
}

// MARK: - Stub provider

@Test func theStubGivesOneDayPerDayInRange() async throws {
    let days = try await StubWeatherProvider().daily(latitude: 48.86, longitude: 2.35, from: .now, to: Calendar.current.date(byAdding: .day, value: 6, to: .now)!)
    #expect(days.count == 7, "Both ends are included")
    #expect(Set(days.map(\.date)).count == 7)
    #expect(days.allSatisfy { $0.date == Calendar.current.startOfDay(for: $0.date) })
    #expect(days.allSatisfy { $0.lowCelsius < $0.highCelsius })
}

@Test func theStubIsDeterministic() async throws {
    let end = Calendar.current.date(byAdding: .day, value: 4, to: .now)!
    let first = try await StubWeatherProvider().daily(latitude: 35.68, longitude: 139.69, from: .now, to: end)
    let second = try await StubWeatherProvider().daily(latitude: 35.68, longitude: 139.69, from: .now, to: end)
    #expect(first == second)
    let currentA = try await StubWeatherProvider().current(latitude: 35.68, longitude: 139.69)
    let currentB = try await StubWeatherProvider().current(latitude: 35.68, longitude: 139.69)
    #expect(currentA == currentB)
}

@Test func theStubVariesFromDayToDay() async throws {
    let days = try await StubWeatherProvider().daily(latitude: 40.71, longitude: -74.0, from: .now, to: Calendar.current.date(byAdding: .day, value: 1, to: .now)!)
    #expect(days.count == 2)
    #expect(days[0].symbolName != days[1].symbolName)
}

@Test func anEmptyRangeGivesNoDays() async throws {
    let days = try await StubWeatherProvider().daily(latitude: 0, longitude: 0, from: .now, to: Calendar.current.date(byAdding: .day, value: -1, to: .now)!)
    #expect(days.isEmpty)
}
