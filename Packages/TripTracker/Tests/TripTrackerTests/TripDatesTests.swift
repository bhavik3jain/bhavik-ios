import Foundation
import Testing
@testable import TripTracker

/// A fixed calendar and zone, so these read the same on any machine.
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

private func date(_ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

/// Rome & Amalfi, 6–14 June: nine days.
private let rome = TripDates(start: date(6, 6), end: date(6, 14), calendar: calendar)

// MARK: - Phase

@Test func phaseFollowsTheCalendarDay() {
    #expect(rome.phase(asOf: date(6, 5, 23, 59)) == .upcoming)
    #expect(rome.phase(asOf: date(6, 6, 0, 0)) == .inProgress, "Midnight of the first day is already the trip")
    #expect(rome.phase(asOf: date(6, 8)) == .inProgress)
    #expect(rome.phase(asOf: date(6, 15, 0, 0)) == .finished)
}

@Test func lastDayAtElevenPMIsStillInProgress() {
    // The end is stored as the last day's midnight. Comparing instants called
    // the trip finished from 00:01 on its final day.
    #expect(rome.phase(asOf: date(6, 14, 23, 0)) == .inProgress)
    #expect(rome.phase(asOf: date(6, 14, 23, 59)) == .inProgress)
    #expect(rome.dayNumber(asOf: date(6, 14, 23, 0)) == 9)
}

@MainActor
@Test func phaseOfATripModelMatchesItsDates() throws {
    let context = try makeContext()
    let trip = SharedTrip(context: context, title: "Rome", startDate: date(6, 6), endDate: date(6, 14), calendar: calendar)
    #expect(TripPhase.of(trip, asOf: date(6, 14, 23, 0), calendar: calendar) == .inProgress)
    #expect(TripPhase.of(trip, asOf: date(6, 1), calendar: calendar) == .upcoming)
    #expect(TripPhase.of(trip, asOf: date(7, 1), calendar: calendar) == .finished)
}

// MARK: - Counting days

@Test func dayCountIncludesBothEnds() {
    #expect(rome.dayCount == 9)
    #expect(TripDates(start: date(6, 6), end: date(6, 6), calendar: calendar).dayCount == 1, "A day trip is one day, not zero")
}

@Test func dayCountIgnoresTheTimeOfDayDatesWereTypedAt() {
    let dates = TripDates(start: date(6, 6, 18), end: date(6, 14, 9), calendar: calendar)
    #expect(dates.dayCount == 9)
}

@Test func anEndBeforeTheStartIsOneDay() {
    let dates = TripDates(start: date(6, 10), end: date(6, 6), calendar: calendar)
    #expect(dates.dayCount == 1)
    #expect(dates.end == dates.start)
}

@Test func dayCountSurvivesADaylightSavingChange() {
    // US clocks go forward on 8 March 2026; that day is 23 hours long.
    let dates = TripDates(start: date(3, 6), end: date(3, 10), calendar: calendar)
    #expect(dates.dayCount == 5)
    #expect(dates.dayIndex(of: date(3, 10, 23, 30)) == 4)
}

@Test func dayNumberIsOneBasedAndOnlyDuringTheTrip() {
    #expect(rome.dayNumber(asOf: date(6, 6)) == 1)
    #expect(rome.dayNumber(asOf: date(6, 8)) == 3)
    #expect(rome.dayNumber(asOf: date(6, 5)) == nil)
    #expect(rome.dayNumber(asOf: date(6, 15)) == nil)
}

@Test func dayIndexAndDateRoundTrip() {
    for index in 0..<rome.dayCount {
        #expect(rome.dayIndex(of: rome.date(forDay: index)) == index)
    }
    #expect(rome.dayIndex(of: date(6, 20)) == nil)
    #expect(rome.offset(of: date(6, 4)) == -2)
}

@Test func daysUntilStartCountsCalendarDays() {
    #expect(rome.daysUntilStart(asOf: date(6, 5, 23, 59)) == 1)
    #expect(rome.daysUntilStart(asOf: date(2, 10)) == 116)
    #expect(rome.daysUntilStart(asOf: date(6, 8)) == 0)
}

@Test func progressCountsTodayAsUnderWay() {
    #expect(rome.progress(asOf: date(6, 1)) == 0)
    #expect(abs(rome.progress(asOf: date(6, 8)) - 3.0 / 9.0) < 0.0001)
    #expect(rome.progress(asOf: date(6, 14, 23)) == 1)
    #expect(rome.progress(asOf: date(7, 1)) == 1)
}

// MARK: - Opening day

@Test func opensOnTodayWhileTheTripRuns() {
    #expect(TripDates.initialDay(for: rome, asOf: date(6, 8, 13, 40)) == 2)
    #expect(TripDates.initialDay(for: rome, asOf: date(6, 14, 23)) == 8)
}

@Test func opensOnTheFirstDayBeforeTheTrip() {
    #expect(TripDates.initialDay(for: rome, asOf: date(1, 1)) == 0)
    #expect(TripDates.initialDay(for: rome, asOf: date(6, 5, 23, 59)) == 0)
}

@Test func opensOnTheLastDayAfterTheTrip() {
    #expect(TripDates.initialDay(for: rome, asOf: date(6, 15)) == 8)
    #expect(TripDates.initialDay(for: rome, asOf: date(12, 1)) == 8)
}

// MARK: - Times of day

@Test func momentPlacesATimeOfDayOnTheTripDay() {
    // Typed on some other date entirely; only 20:00 matters.
    let typed = date(1, 3, 20, 0)
    #expect(rome.moment(day: 2, time: typed) == date(6, 8, 20, 0))
    #expect(rome.minuteOfDay(typed) == 20 * 60)
}
