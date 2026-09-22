import CoreData
import Foundation
import Testing
@testable import TripTracker

// MARK: - Ordering

@MainActor
@Test func timedEntriesComeFirstInTimeOrder() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Dinner", to: trip, in: context, day: 2, at: (20, 0))
    addItem("Wander Trastevere", to: trip, in: context, day: 2)
    addItem("Galleria Borghese", to: trip, in: context, day: 2, at: (9, 30))
    addItem("Lunch", to: trip, in: context, day: 2, at: (13, 0))

    let plan = DayPlan(trip: trip, dayIndex: 2)
    #expect(plan.titles == ["Galleria Borghese", "Lunch", "Dinner", "Wander Trastevere"])
    #expect(plan.timed.count == 3)
    #expect(plan.untimed.map(\.title) == ["Wander Trastevere"])
}

@MainActor
@Test func onlyTheChosenDaysEntriesAppear() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Day three", to: trip, in: context, day: 2, at: (9, 0))
    addItem("Day four", to: trip, in: context, day: 3, at: (9, 0))
    addFlight(("BA", "286"), to: trip, in: context, day: 8, departs: day(6, 14, 18, 40))

    #expect(DayPlan(trip: trip, dayIndex: 2).titles == ["Day three"])
    #expect(DayPlan(trip: trip, dayIndex: 8).titles == ["BA 286 · FCO → LHR"])
    #expect(DayPlan(trip: trip, dayIndex: 5).isEmpty)
}

@MainActor
@Test func flightsMergeIntoTheTimelineByDepartureTime() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Breakfast", to: trip, in: context, day: 8, at: (8, 0))
    addItem("Last gelato", to: trip, in: context, day: 8, at: (15, 0))
    addFlight(("BA", "286"), to: trip, in: context, day: 8, departs: day(6, 14, 11, 0))

    #expect(DayPlan(trip: trip, dayIndex: 8).titles == ["Breakfast", "BA 286 · FCO → LHR", "Last gelato"])
}

@MainActor
@Test func aFlightGoesAheadOfAnItemAtTheSameMinute() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Taxi", to: trip, in: context, day: 0, at: (9, 0))
    addFlight(("BA", "285"), to: trip, in: context, day: 0, departs: day(6, 6, 9, 0))

    #expect(DayPlan(trip: trip, dayIndex: 0).titles.first == "BA 285 · FCO → LHR")
}

@MainActor
@Test func sortOrderBreaksTiesThenTitle() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("B second", to: trip, in: context, day: 1, at: (10, 0), sortOrder: 2)
    addItem("Z first", to: trip, in: context, day: 1, at: (10, 0), sortOrder: 1)
    addItem("Anytime two", to: trip, in: context, day: 1, sortOrder: 5)
    addItem("Anytime one", to: trip, in: context, day: 1, sortOrder: 4)
    addItem("Anytime b", to: trip, in: context, day: 1, sortOrder: 9)
    addItem("Anytime a", to: trip, in: context, day: 1, sortOrder: 9)

    let plan = DayPlan(trip: trip, dayIndex: 1)
    #expect(plan.timed.map(\.title) == ["Z first", "B second"])
    #expect(plan.untimed.map(\.title) == ["Anytime one", "Anytime two", "Anytime a", "Anytime b"])
}

@MainActor
@Test func anUntimedFlightTrailsTheAnytimeItems() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addFlight(("AZ", "1"), to: trip, in: context, day: 4)
    addItem("Anytime", to: trip, in: context, day: 4)

    #expect(DayPlan(trip: trip, dayIndex: 4).untimed.map(\.title) == ["Anytime", "AZ 1 · FCO → LHR"])
}

@MainActor
@Test func countsLeaveFlightsOut() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("One", to: trip, in: context, day: 2, at: (9, 0), done: true)
    addItem("Two", to: trip, in: context, day: 2, at: (13, 0), done: true)
    addItem("Three", to: trip, in: context, day: 2, at: (20, 0))
    addItem("Four", to: trip, in: context, day: 2)
    addFlight(("BA", "1"), to: trip, in: context, day: 2, departs: day(6, 8, 7, 0))

    let plan = DayPlan(trip: trip, dayIndex: 2)
    #expect(plan.itemCount == 4)
    #expect(plan.doneCount == 2)
}

// MARK: - Up next

/// The mockup's day: 09:30 and 13:00 done, NOW at 17:00, dinner at 20:00,
/// Trastevere anytime.
@MainActor
private func mockupDay() throws -> (NSManagedObjectContext, Trip) {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Galleria Borghese", to: trip, in: context, day: 2, at: (9, 30), minutes: 90, done: true)
    addItem("Lunch at Armando", to: trip, in: context, day: 2, at: (13, 0), done: true)
    addItem("Da Enzo al 29", to: trip, in: context, day: 2, at: (20, 0))
    addItem("Wander Trastevere", to: trip, in: context, day: 2)
    return (context, trip)
}

@MainActor
@Test func upNextIsTheNextUnfinishedTimedEntry() throws {
    let (_, trip) = try mockupDay()
    let plan = DayPlan(trip: trip, dayIndex: 2)
    #expect(plan.upNext(asOf: day(6, 8, 17, 0))?.title == "Da Enzo al 29")
}

@MainActor
@Test func somethingUnderWayIsStillUpNext() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Vatican", to: trip, in: context, day: 2, at: (9, 0), minutes: 180)
    addItem("Lunch", to: trip, in: context, day: 2, at: (13, 0))

    let plan = DayPlan(trip: trip, dayIndex: 2)
    #expect(plan.upNext(asOf: day(6, 8, 10, 30))?.title == "Vatican")
    #expect(plan.upNext(asOf: day(6, 8, 12, 1))?.title == "Lunch", "Over once its length has passed")
}

@MainActor
@Test func aMissedUntickedItemIsNotUpNext() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Missed", to: trip, in: context, day: 2, at: (9, 0))
    addItem("Later", to: trip, in: context, day: 2, at: (18, 0))

    #expect(DayPlan(trip: trip, dayIndex: 2).upNext(asOf: day(6, 8, 12, 0))?.title == "Later")
}

@MainActor
@Test func upNextFallsBackToAnytimeOnceTimedThingsAreOver() throws {
    let (_, trip) = try mockupDay()
    let plan = DayPlan(trip: trip, dayIndex: 2)
    #expect(plan.upNext(asOf: day(6, 8, 21, 0))?.title == "Wander Trastevere")
}

@MainActor
@Test func nothingIsUpNextWhenAllIsDone() throws {
    let (_, trip) = try mockupDay()
    for item in trip.items ?? [] { item.isDone = true }
    #expect(DayPlan(trip: trip, dayIndex: 2).upNext(asOf: day(6, 8, 17, 0)) == nil)
}

@MainActor
@Test func upNextIsOnlyForToday() throws {
    let (_, trip) = try mockupDay()
    #expect(DayPlan(trip: trip, dayIndex: 2).upNext(asOf: day(6, 7, 17, 0)) == nil)
    #expect(DayPlan(trip: trip, dayIndex: 3).upNext(asOf: day(6, 8, 17, 0)) == nil)
}

@MainActor
@Test func aFlightCanBeUpNext() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Breakfast", to: trip, in: context, day: 8, at: (8, 0), done: true)
    addFlight(("BA", "286"), to: trip, in: context, day: 8, departs: day(6, 14, 18, 40))

    #expect(DayPlan(trip: trip, dayIndex: 8).upNext(asOf: day(6, 14, 12, 0))?.title == "BA 286 · FCO → LHR")
}

@MainActor
@Test func nowLineSitsBeforeTheFirstEntryNotYetStarted() throws {
    let (_, trip) = try mockupDay()
    let plan = DayPlan(trip: trip, dayIndex: 2)
    #expect(plan.nowLineIndex(asOf: day(6, 8, 17, 0)) == 2)
    #expect(plan.nowLineIndex(asOf: day(6, 8, 7, 0)) == 0)
    #expect(plan.nowLineIndex(asOf: day(6, 8, 22, 0)) == 3, "After everything")
    #expect(plan.nowLineIndex(asOf: day(6, 9, 17, 0)) == nil, "Not on another day")
}

// MARK: - Next flight

@MainActor
@Test func nextFlightIsTheSoonestStillAhead() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addFlight(("BA", "285"), to: trip, in: context, day: 0, departs: day(6, 6, 8, 5))
    addFlight(("BA", "286"), to: trip, in: context, day: 8, departs: day(6, 14, 18, 40))

    #expect(TripOverview.nextFlight(in: trip, asOf: day(6, 1))?.number == "285")
    #expect(TripOverview.nextFlight(in: trip, asOf: day(6, 8))?.number == "286")
    #expect(TripOverview.nextFlight(in: trip, asOf: day(6, 14, 19)) == nil, "Gone once it has left")
}

@MainActor
@Test func anUntimedFlightCountsThroughItsDay() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addFlight(("AZ", "7"), to: trip, in: context, day: 4)

    #expect(TripOverview.nextFlight(in: trip, asOf: day(6, 10, 23))?.number == "7")
    #expect(TripOverview.nextFlight(in: trip, asOf: day(6, 11, 1)) == nil)
}
