import Core
import Foundation
import Testing
@testable import TripTracker

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

private func date(_ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
}

private func weather(_ month: Int, _ day: Int, high: Double) -> DayWeather {
    DayWeather(date: calendar.startOfDay(for: date(month, day)), highCelsius: high, lowCelsius: high - 8, symbolName: "sun.max.fill", summary: "Sunny")
}

/// 6–14 June.
private let rome = TripDates(start: date(6, 6), end: date(6, 14), calendar: calendar)

@Test func eachChipGetsItsOwnDaysWeather() {
    let now = date(6, 8)
    let days = (6...14).map { weather(6, $0, high: Double($0)) }

    let slots = TripForecast.byDay(days, dates: rome, asOf: now)
    #expect(slots.count == 9)
    #expect(slots.map { $0?.highCelsius } == (6...14).map { Double($0) })
}

@Test func daysBeyondTheWindowShowADashEvenIfAValueArrived() {
    // Today is 1 June: the window runs through 10 June.
    let now = date(6, 1)
    let days = (6...14).map { weather(6, $0, high: 20) }

    let slots = TripForecast.byDay(days, dates: rome, asOf: now)
    #expect(slots[0...4].allSatisfy { $0 != nil }, "6–10 June are within ten days")
    #expect(slots[5...8].allSatisfy { $0 == nil }, "11–14 June are a dash")
}

@Test func aMissingDayIsADashNotANeighbour() {
    let days = [weather(6, 6, high: 20), weather(6, 8, high: 25)]
    let slots = TripForecast.byDay(days, dates: rome, asOf: date(6, 7))
    #expect(slots[0]?.highCelsius == 20)
    #expect(slots[1] == nil)
    #expect(slots[2]?.highCelsius == 25)
}

@Test func noWeatherIsAllDashes() {
    let slots = TripForecast.byDay([], dates: rome, asOf: date(6, 8))
    #expect(slots.count == 9)
    #expect(slots.allSatisfy { $0 == nil })
}

@Test func weatherAlignsEvenWhenStampedMidDay() {
    let stamped = DayWeather(date: date(6, 7, 15), highCelsius: 30, lowCelsius: 20, symbolName: "sun.max.fill", summary: "Sunny")
    let slots = TripForecast.byDay([stamped], dates: rome, asOf: date(6, 7))
    #expect(slots[1]?.highCelsius == 30)
}

@Test func pastDaysKeepTheirRecordedWeather() {
    let days = (6...14).map { weather(6, $0, high: 18) }
    let slots = TripForecast.byDay(days, dates: rome, asOf: date(7, 1))
    #expect(slots.allSatisfy { $0 != nil }, "A finished trip still shows what the weather was")
}

@Test func requestRangeStopsAtTheLastForecastableDay() {
    let range = TripForecast.requestRange(for: rome, asOf: date(6, 1))
    #expect(range?.lowerBound == calendar.startOfDay(for: date(6, 6)))
    #expect(range?.upperBound == calendar.startOfDay(for: date(6, 10)))
}

@Test func requestRangeCoversAWholeTripInReach() {
    let range = TripForecast.requestRange(for: rome, asOf: date(6, 8))
    #expect(range == calendar.startOfDay(for: date(6, 6))...calendar.startOfDay(for: date(6, 14)))
}

@Test func nothingToRequestForATripBeyondTheWindow() {
    #expect(TripForecast.requestRange(for: rome, asOf: date(5, 1)) == nil)
    #expect(TripForecast.availableFrom(for: rome, asOf: date(5, 1)) == calendar.startOfDay(for: date(5, 28)))
    #expect(TripForecast.availableFrom(for: rome, asOf: date(6, 1)) == nil)
}

@Test func theStubProvidersDaysLandOnTheirChips() async throws {
    // The stub reads the current calendar, so the trip does too here.
    let now = Date.now
    let start = Calendar.current.date(byAdding: .day, value: -2, to: now)!
    let dates = TripDates(start: start, end: Calendar.current.date(byAdding: .day, value: 14, to: start)!)
    let range = try #require(TripForecast.requestRange(for: dates, asOf: now))

    let days = try await StubWeatherProvider().daily(latitude: 41.9, longitude: 12.5, from: range.lowerBound, to: range.upperBound)
    let slots = TripForecast.byDay(days, dates: dates, asOf: now)

    #expect(slots.count == 15)
    // Two days gone, today and nine ahead are covered; the last three are not.
    #expect(slots.prefix(12).allSatisfy { $0 != nil })
    #expect(slots.suffix(3).allSatisfy { $0 == nil })
    for (index, slot) in slots.enumerated() {
        if let slot { #expect(slot.date == dates.date(forDay: index)) }
    }
}
