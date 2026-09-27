import Foundation
import Testing
@testable import TripTracker

/// Rome & Amalfi, 6–14 June: nine days, in the current calendar like the
/// model-backed fixtures in Support.swift.
private let rome = TripDates(start: day(6, 6), end: day(6, 14))

// MARK: - Choices

@Test func unassignedRoundTripsThroughItsDayIndex() {
    #expect(DayChoice(dayIndex: SharedItineraryItem.unassignedDayIndex) == .unassigned)
    #expect(DayChoice(dayIndex: -3) == .unassigned, "Any negative day is an idea")
    #expect(DayChoice.unassigned.dayIndex == SharedItineraryItem.unassignedDayIndex)
    #expect(DayChoice(dayIndex: 4) == .day(4))
    #expect(DayChoice.day(4).dayIndex == 4)
}

@Test func everyDayIsOfferedInOrder() {
    let choices = DayChoice.all(in: rome, includingUnassigned: false)
    #expect(choices == (0..<9).map(DayChoice.day))
    #expect(DayChoice.all(in: rome, includingUnassigned: true).last == .unassigned)
}

@Test func aChoiceOffTheTripIsKeptSoThePickerIsNeverBlank() {
    // A picker whose selection matches no tag shows an empty row.
    let past = DayChoice.all(in: rome, includingUnassigned: false, keeping: .day(11))
    #expect(past.last == .day(11))
    let before = DayChoice.all(in: rome, includingUnassigned: false, keeping: .day(-3))
    #expect(before.first == .day(-3))
    let unassigned = DayChoice.all(in: rome, includingUnassigned: false, keeping: .unassigned)
    #expect(unassigned.last == .unassigned)
    #expect(DayChoice.all(in: rome, includingUnassigned: false, keeping: .day(2)).count == 9)
}

@Test func labelsLeadWithTheDateAndEndWithTheDayNumber() {
    let label = DayChoice.day(2).label(in: rome)
    #expect(label.hasSuffix(" · Day 3"))
    #expect(label.contains(rome.date(forDay: 2).formatted(.dateTime.day())))
    #expect(DayChoice.unassigned.label(in: rome) == "No day yet · Ideas")
}

// MARK: - Move targets

@Test func moveTargetsLeaveOutWhereItAlreadyIs() {
    let targets = DayChoice.moveTargets(from: .day(3), in: rome, includingUnassigned: false, asOf: day(5, 1))
    #expect(targets.count == 8)
    #expect(!targets.contains(.day(3)))
    #expect(targets.first == .day(0), "Before the trip, days run in order")
}

@Test func tomorrowComesFirstWhileTheTripIsUnderWay() {
    // 8 June is day 2, so tomorrow is day 3.
    let targets = DayChoice.moveTargets(from: .day(2), in: rome, includingUnassigned: false, asOf: day(6, 8, 9))
    #expect(targets.first == .day(3))
    #expect(targets.count(where: { $0 == .day(3) }) == 1, "Not listed twice")
    #expect(targets.first?.relativeName(in: rome, asOf: day(6, 8, 9)) == "Tomorrow")
    #expect(DayChoice.day(2).relativeName(in: rome, asOf: day(6, 8, 9)) == "Today")
    #expect(DayChoice.day(5).relativeName(in: rome, asOf: day(6, 8, 9)) == nil)
}

@Test func onTheLastDayThereIsNoTomorrowToPromote() {
    let targets = DayChoice.moveTargets(from: .day(8), in: rome, includingUnassigned: false, asOf: day(6, 14, 9))
    #expect(targets == (0..<8).map(DayChoice.day))
}

@Test func unassignedIsAMoveTargetOnlyWhenOffered() {
    #expect(!DayChoice.moveTargets(from: .day(0), in: rome, includingUnassigned: false).contains(.unassigned))
    #expect(DayChoice.moveTargets(from: .day(0), in: rome, includingUnassigned: true).last == .unassigned)
    #expect(!DayChoice.moveTargets(from: .unassigned, in: rome, includingUnassigned: true).contains(.unassigned))
}

@Test func aMomentReadsLikeTheDayPickers() {
    #expect(DayChoice.label(for: day(6, 8, 15), in: rome) == DayChoice.day(2).label(in: rome))
    #expect(DayChoice.label(for: day(6, 5, 15), in: rome).hasSuffix(" · Before the trip"))
    #expect(DayChoice.label(for: day(6, 15, 11), in: rome).hasSuffix(" · After the trip"))
}

// MARK: - Moving one thing

@MainActor
@Test func aMovedItemJoinsTheEndOfItsNewDay() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let dinner = addItem("Dinner", to: trip, in: context, day: 2, sortOrder: 0)
    addItem("Pantheon", to: trip, in: context, day: 4, sortOrder: 0)
    addItem("Gelato", to: trip, in: context, day: 4, sortOrder: 5)

    dinner.move(toDay: 4)

    #expect(dinner.dayIndex == 4)
    #expect(dinner.sortOrder == 6)
    #expect(DayPlan(trip: trip, dayIndex: 4).titles.last == "Dinner")
    #expect(DayPlan(trip: trip, dayIndex: 2).isEmpty)
}

@MainActor
@Test func movingAnItemToItsOwnDayChangesNothing() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let first = addItem("First", to: trip, in: context, day: 1, sortOrder: 0)
    addItem("Second", to: trip, in: context, day: 1, sortOrder: 1)
    // Saved first: a not-yet-saved item is still being placed, and gets a
    // place at the end of its day even when the day doesn't change.
    try context.save()

    first.move(toDay: 1)

    #expect(first.sortOrder == 0)
}

@MainActor
@Test func aMovedFlightTakesItsTimesToTheNewDate() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let flight = addFlight(("BA", "286"), to: trip, in: context, day: 8, departs: day(6, 14, 18, 40), arrives: day(6, 14, 20, 25))

    flight.move(toDay: 6, in: trip.dates)

    #expect(flight.dayIndex == 6)
    #expect(flight.departsAt == day(6, 12, 18, 40))
    #expect(flight.arrivesAt == day(6, 12, 20, 25))
}

@MainActor
@Test func aFlightFiledUnderTheDayItLandsKeepsItsOvernightDeparture() throws {
    // Leaves the evening before day 1, filed under day 1 (index 0). Snapping
    // the departure onto the new day would rebook it for the wrong night.
    let context = try makeContext()
    let trip = makeRome(in: context)
    let flight = addFlight(("BA", "285"), to: trip, in: context, day: 0, departs: day(6, 5, 22, 0), arrives: day(6, 6, 6, 0))

    flight.move(toDay: 1, in: trip.dates)

    #expect(flight.departsAt == day(6, 6, 22, 0))
    #expect(flight.arrivesAt == day(6, 7, 6, 0))
}

@MainActor
@Test func anUntimedFlightJustChangesDay() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let flight = addFlight(("BA", "1"), to: trip, in: context, day: 2)

    flight.move(toDay: 5, in: trip.dates)

    #expect(flight.dayIndex == 5)
    #expect(flight.departsAt == nil)
    #expect(flight.arrivesAt == nil)
}
