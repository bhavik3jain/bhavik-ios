import Foundation
import Testing
@testable import TripTracker

/// Rome & Amalfi, 6–14 June: nine days, in the current calendar like the
/// model-backed fixtures in Support.swift.
private let rome = TripDates(start: day(6, 6), end: day(6, 14))

private func to(_ start: (Int, Int), _ end: (Int, Int), _ anchor: ItineraryReschedule.Anchor = .moveWithTrip) -> ItineraryReschedule {
    ItineraryReschedule(from: rome, to: TripDates(start: day(start.0, start.1), end: day(end.0, end.1)), anchor: anchor)
}

// MARK: - Arithmetic

@Test func theShiftCountsCalendarDays() {
    #expect(to((6, 9), (6, 17)).startShift == 3)
    #expect(to((6, 4), (6, 14)).startShift == -2)
    #expect(!to((6, 6), (6, 10)).startMoved)
}

@Test func theEffectSaysWhichWayAndHowFar() {
    #expect(to((6, 9), (6, 17)).effect == "Everything planned moves 3 days later with the trip.")
    #expect(to((6, 5), (6, 14)).effect == "Everything planned moves 1 day earlier with the trip.")
    #expect(to((6, 9), (6, 17), .keepCalendarDates).effect.hasPrefix("Everything planned stays on its date"))
    #expect(to((6, 6), (6, 10)).effect.isEmpty, "Nothing to say when the start hasn't moved")
}

@Test func shiftingWithTheTripKeepsEveryDay() {
    let change = to((6, 9), (6, 17))
    #expect((0..<9).map { change.proposedDay(for: $0) } == Array(0..<9))
    #expect(change.stranding(itemDays: Array(0..<9), flightDays: [0, 8]).isEmpty)
}

@Test func keepingCalendarDatesCountsBackByTheShift() {
    // Three days later: 9 June, once day 3 (index 3), is now the first day.
    let change = to((6, 9), (6, 17), .keepCalendarDates)
    #expect(change.proposedDay(for: 3) == 0)
    #expect(change.proposedDay(for: 8) == 5)
    let stranding = change.stranding(itemDays: [0, 1, 2, 3, 8], flightDays: [])
    #expect(stranding.items == 3)
    #expect(stranding.beforeStart)
    #expect(!stranding.afterEnd)
    #expect(stranding.nearestDayTitle == "Move Them to the First Day")
}

@Test func shrinkingStrandsWhatIsPastTheNewEnd() {
    let change = to((6, 6), (6, 10))
    let stranding = change.stranding(itemDays: [0, 4, 5, 8], flightDays: [8])
    #expect(stranding.items == 2)
    #expect(stranding.flights == 1)
    #expect(stranding.afterEnd && !stranding.beforeStart)
    #expect(stranding.summary == "2 items and 1 flight")
    #expect(stranding.title == "2 items and 1 flight fall outside the new dates")
    #expect(stranding.ideasTitle == "Move Items to Ideas", "The flight isn't going to Ideas")
    let one = change.stranding(itemDays: [8], flightDays: [])
    #expect(one.title == "1 item falls outside the new dates")
    #expect(one.ideasTitle == "Move It to Ideas")
    #expect(one.nearestDayTitle == "Move It to the Last Day")
    #expect(stranding.nearestDayTitle == "Move Them to the Last Day")
    #expect(change.resolvedDay(for: 8, overflow: .nearestDay) == 4)
    #expect(change.resolvedDay(for: 3, overflow: .nearestDay) == 3)
}

@Test func growingStrandsNothing() {
    let change = to((6, 6), (6, 20))
    #expect(change.stranding(itemDays: Array(0..<9), flightDays: [0, 8]).isEmpty)
    #expect(change.resolvedDay(for: 8, overflow: .nearestDay) == 8)
}

@Test func anUnassignedItemIsNeverStranded() {
    let change = to((6, 9), (6, 10), .keepCalendarDates)
    let unassigned = SharedItineraryItem.unassignedDayIndex
    #expect(!change.isStranded(unassigned))
    #expect(change.resolvedDay(for: unassigned, overflow: .nearestDay) == unassigned)
    #expect(change.stranding(itemDays: [unassigned], flightDays: []).isEmpty)
}

@Test func onlyItemsCanGoToIdeas() {
    let change = to((6, 6), (6, 10))
    #expect(change.resolvedDay(for: 8, overflow: .unassigned) == SharedItineraryItem.unassignedDayIndex)
    #expect(change.resolvedDay(for: 8, isFlight: true, overflow: .unassigned) == 4)
}

@Test func strandedAtBothEndsSaysSo() {
    let change = to((6, 8), (6, 10), .keepCalendarDates)
    let stranding = change.stranding(itemDays: [0], flightDays: [8])
    #expect(stranding.beforeStart && stranding.afterEnd)
    #expect(stranding.nearestDayTitle == "Move Them to the First or Last Day")
    #expect(change.stranding(itemDays: [0], flightDays: []).nearestDayTitle == "Move It to the First Day")
}

// MARK: - Applying it

@MainActor
@Test func movingTheTripCarriesTheWholePlanAlong() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let dinner = addItem("Dinner", to: trip, in: context, day: 2, at: (20, 0))
    let flight = addFlight(("BA", "286"), to: trip, in: context, day: 8, departs: day(6, 14, 18, 40), arrives: day(6, 14, 20, 25))
    let hotel = SharedBooking(context: context, title: "Hotel", kind: .lodging)
    hotel.startsAt = day(6, 6, 15)
    hotel.endsAt = day(6, 10, 11)
    hotel.trip = trip

    to((7, 1), (7, 9)).apply(to: trip, overflow: .nearestDay)

    #expect(dinner.dayIndex == 2)
    #expect(flight.dayIndex == 8)
    // The flight's day and its times stay in step, or Codes and the PDF print
    // the old date while the timeline shows the new one.
    #expect(flight.departsAt == day(7, 9, 18, 40))
    #expect(flight.arrivesAt == day(7, 9, 20, 25))
    #expect(hotel.startsAt == day(7, 1, 15))
    #expect(hotel.endsAt == day(7, 5, 11))
}

@MainActor
@Test func keepingCalendarDatesLeavesEverythingWhereItWas() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let pantheon = addItem("Pantheon", to: trip, in: context, day: 3)
    let flight = addFlight(("BA", "286"), to: trip, in: context, day: 8, departs: day(6, 14, 18, 40))
    let hotel = SharedBooking(context: context, title: "Hotel", kind: .lodging)
    hotel.startsAt = day(6, 6, 15)
    hotel.trip = trip

    // A day added at the front: 5–14 June.
    to((6, 5), (6, 14), .keepCalendarDates).apply(to: trip, overflow: .nearestDay)

    #expect(pantheon.dayIndex == 4, "Still 9 June")
    #expect(flight.dayIndex == 9)
    #expect(flight.departsAt == day(6, 14, 18, 40))
    #expect(hotel.startsAt == day(6, 6, 15))
}

@MainActor
@Test func shrinkingPutsStrandedItemsAtTheEndOfTheLastDay() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let lunch = addItem("Lunch", to: trip, in: context, day: 4, sortOrder: 0)
    let late = addItem("Late", to: trip, in: context, day: 7, sortOrder: 0)
    let later = addItem("Later", to: trip, in: context, day: 8, sortOrder: 0)
    let flight = addFlight(("BA", "286"), to: trip, in: context, day: 8, departs: day(6, 14, 18, 40))

    let change = to((6, 6), (6, 10))
    change.apply(to: trip, overflow: .nearestDay)

    #expect([lunch, late, later].map(\.dayIndex) == [4, 4, 4])
    #expect(DayPlan(trip: trip, dayIndex: 4).titles == ["BA 286 · FCO → LHR", "Lunch", "Late", "Later"])
    #expect(flight.dayIndex == 4)
    #expect(flight.departsAt == day(6, 10, 18, 40), "Pulled in with its day")
    #expect(change.stranding(of: trip).isEmpty, "Nothing left stranded")
}

@MainActor
@Test func shrinkingCanSendStrandedItemsToIdeasButNotFlights() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let late = addItem("Late", to: trip, in: context, day: 8)
    let flight = addFlight(("BA", "286"), to: trip, in: context, day: 8)

    to((6, 6), (6, 10)).apply(to: trip, overflow: .unassigned)

    #expect(late.isUnassigned)
    #expect(flight.dayIndex == 4)
}

@MainActor
@Test func mixedItemsAndFlightsSurviveAShiftAndAShrinkTogether() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let early = addItem("Colosseum", to: trip, in: context, day: 1, at: (9, 0))
    let early2 = addItem("Forum", to: trip, in: context, day: 1, sortOrder: 1)
    let late = addItem("Path of the Gods", to: trip, in: context, day: 6)
    let outbound = addFlight(("BA", "285"), to: trip, in: context, day: 0, departs: day(6, 6, 8, 5))
    let home = addFlight(("BA", "286"), to: trip, in: context, day: 8, departs: day(6, 14, 18, 40))

    // Two days later and two days shorter, keeping calendar dates: 8–12 June.
    let change = to((6, 8), (6, 12), .keepCalendarDates)
    let stranding = change.stranding(of: trip)
    #expect(stranding.items == 2)
    #expect(stranding.flights == 2)
    change.apply(to: trip, overflow: .nearestDay)

    #expect(early.dayIndex == 0)
    #expect(early2.dayIndex == 0)
    #expect(late.dayIndex == 4)
    #expect(outbound.dayIndex == 0)
    #expect(outbound.departsAt == day(6, 8, 8, 5))
    #expect(home.dayIndex == 4)
    #expect(home.departsAt == day(6, 12, 18, 40))
    // Measured against the new dates as they stand: the change itself would
    // count back by the shift a second time.
    #expect(ItineraryReschedule(from: change.new, to: change.new).stranding(of: trip).isEmpty)
}

@MainActor
@Test func anItemPulledBackOntoItsOwnDayStillGoesLast() throws {
    // Two days earlier, keeping calendar dates: 4–12 June. Day 9 (14 June) is
    // past the new end and comes back to day 9 — where it already was — while
    // day 7's items move up onto it.
    let context = try makeContext()
    let trip = makeRome(in: context)
    let stranded = addItem("Last night", to: trip, in: context, day: 8, sortOrder: 0)
    let moved = addItem("Boat", to: trip, in: context, day: 6, sortOrder: 0)

    to((6, 4), (6, 12), .keepCalendarDates).apply(to: trip, overflow: .nearestDay)

    #expect(moved.dayIndex == 8)
    #expect(stranded.dayIndex == 8)
    #expect(DayPlan(trip: trip, dayIndex: 8).titles == ["Boat", "Last night"])
}

@MainActor
@Test func ideasStayIdeasThroughAReschedule() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let idea = addItem("Maybe Capri", to: trip, in: context, day: SharedItineraryItem.unassignedDayIndex)

    to((6, 9), (6, 11), .keepCalendarDates).apply(to: trip, overflow: .nearestDay)
    trip.startDate = day(6, 9)
    trip.endDate = day(6, 11)
    trip.clampPlanToDates()

    #expect(idea.isUnassigned)
}
