import CoreData
import Foundation
import Testing
@testable import TripTracker

@MainActor
private func trips(in context: NSManagedObjectContext) -> (rome: SharedTrip, tokyo: SharedTrip, lisbon: SharedTrip, reykjavik: SharedTrip) {
    let rome = makeRome(in: context)
    let tokyo = SharedTrip(context: context, title: "Tokyo", startDate: day(10, 2), endDate: day(10, 13))
    let lisbon = SharedTrip(context: context, title: "Lisbon", startDate: day(11, 14), endDate: day(11, 17))
    let reykjavik = SharedTrip(context: context, title: "Reykjavik", startDate: day(3, 1), endDate: day(3, 6))
    return (rome, tokyo, lisbon, reykjavik)
}

// MARK: - Grouping

@MainActor
@Test func tripsGroupByPhaseForTheMomentAsked() throws {
    let context = try makeContext()
    let all = trips(in: context)
    let list = [all.lisbon, all.reykjavik, all.tokyo, all.rome]

    let groups = TripGroups(list, asOf: day(6, 8))
    #expect(groups.inProgress.map(\.title) == ["Rome & Amalfi"])
    #expect(groups.upcoming.map(\.title) == ["Tokyo", "Lisbon"], "Soonest first")
    #expect(groups.finished.map(\.title) == ["Reykjavik"])

    let later = TripGroups(list, asOf: day(6, 15))
    #expect(later.inProgress.isEmpty, "Moves on by itself — nothing is stored")
    #expect(later.finished.map(\.title) == ["Rome & Amalfi", "Reykjavik"], "Most recent first")
}

@MainActor
@Test func archivedTripsAreLeftOut() throws {
    let context = try makeContext()
    let all = trips(in: context)
    all.rome.isArchived = true

    let groups = TripGroups([all.rome, all.tokyo], asOf: day(6, 8))
    #expect(groups.inProgress.isEmpty)
    #expect(groups.upcoming.map(\.title) == ["Tokyo"])
}

// MARK: - Home row

@MainActor
@Test func homeDetailNamesTheTripUnderWay() throws {
    let context = try makeContext()
    let all = trips(in: context)
    #expect(TripOverview.homeDetail(trips: [all.tokyo, all.rome], asOf: day(6, 8)) == "Rome & Amalfi · day 3 of 9")
}

@MainActor
@Test func homeDetailCountsDownToTheNextTrip() throws {
    let context = try makeContext()
    let all = trips(in: context)
    #expect(TripOverview.homeDetail(trips: [all.lisbon, all.tokyo], asOf: day(9, 20)) == "Tokyo in 12 days")
    #expect(TripOverview.homeDetail(trips: [all.tokyo], asOf: day(10, 1, 22)) == "Tokyo tomorrow")
}

@MainActor
@Test func homeDetailWithNothingAhead() throws {
    let context = try makeContext()
    let all = trips(in: context)
    #expect(TripOverview.homeDetail(trips: [], asOf: day(6, 8)) == "No trips yet")
    #expect(TripOverview.homeDetail(trips: [all.reykjavik], asOf: day(6, 8)) == "Nothing coming up")
}

@Test func countdownHeadlineSplitsTheFigureFromTheWords() {
    #expect(TripOverview.countdownHeadline(days: 0) == ("Today", ""))
    #expect(TripOverview.countdownHeadline(days: 1) == ("1", "day to go"))
    #expect(TripOverview.countdownHeadline(days: 44) == ("44", "days to go"))
}

@Test func planProgressCountsDaysStopsAndIdeas() {
    // Day 0 twice, day 2, two ideas (any negative day), and a stop left past
    // the last day by an old build.
    let plan = TripOverview.planProgress(dayIndices: [0, 0, 2, -1, -5, 9], flightCount: 2, dayCount: 7)
    #expect(plan.daysPlanned == 2)
    #expect(plan.stops == 4)
    #expect(plan.ideas == 2)
    #expect(plan.flights == 2)
    #expect(abs(plan.fractionPlanned - 2.0 / 7.0) < 0.0001)

    let empty = TripOverview.planProgress(dayIndices: [], flightCount: 0, dayCount: 0)
    #expect(empty.fractionPlanned == 0, "A trip with no days doesn't divide by zero")
}

@Test func countdownWords() {
    #expect(TripOverview.countdown(days: 0) == "today")
    #expect(TripOverview.countdown(days: 1) == "tomorrow")
    #expect(TripOverview.countdown(days: 116) == "in 116 days")
}

// MARK: - Map

@MainActor
@Test func mapFilterShowsOnlyPlacedItemsForTheDay() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let today = addItem("Galleria", to: trip, in: context, day: 2, placed: true)
    let tomorrow = addItem("Pantheon", to: trip, in: context, day: 3, placed: true)
    let unplaced = addItem("Nap", to: trip, in: context, day: 2)
    let hotel = addItem("Hotel", to: trip, in: context, day: 0, kind: .lodging, placed: true)

    let filter = MapDayFilter.day(2)
    #expect(filter.shows(today))
    #expect(!filter.shows(tomorrow))
    #expect(!filter.shows(unplaced), "Nothing without a coordinate gets a pin")
    #expect(filter.shows(hotel), "The stay shows under every day")
    #expect(MapDayFilter.allDays.shows(tomorrow))
    #expect(!MapDayFilter.allDays.shows(unplaced))
}

@MainActor
@Test func mapOpensOnTodayOnlyWhileTheTripRuns() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    #expect(MapDayFilter.initial(for: trip.dates, asOf: day(6, 8)) == .day(2))
    #expect(MapDayFilter.initial(for: trip.dates, asOf: day(5, 8)) == .allDays)
    #expect(MapDayFilter.initial(for: trip.dates, asOf: day(7, 8)) == .allDays)
}

// MARK: - Model behaviour

@MainActor
@Test func shorteningATripPullsItsPlanOntoTheLastDay() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let late = addItem("Day nine", to: trip, in: context, day: 8)
    let early = addItem("Day two", to: trip, in: context, day: 1)
    let flight = addFlight(("BA", "286"), to: trip, in: context, day: 8)

    trip.endDate = day(6, 10)
    trip.clampPlanToDates()

    #expect(late.dayIndex == 4)
    #expect(flight.dayIndex == 4)
    #expect(early.dayIndex == 1)
}

@MainActor
@Test func deletingATripTakesItsPlanWithIt() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Galleria", to: trip, in: context, day: 2)
    addFlight(("BA", "1"), to: trip, in: context, day: 0)
    let booking = SharedBooking(context: context, title: "Hotel", kind: .lodging)
    booking.trip = trip
    try context.save()

    context.delete(trip)
    try context.save()

    #expect(try context.count(for: SharedItineraryItem.fetchRequest()) == 0)
    #expect(try context.count(for: SharedFlight.fetchRequest()) == 0)
    #expect(try context.count(for: SharedBooking.fetchRequest()) == 0)
}

@MainActor
@Test func togglingDoneStampsAndClearsTheTime() throws {
    let context = try makeContext()
    let item = SharedItineraryItem(context: context, title: "Galleria", dayIndex: 0)
    let now = day(6, 8, 11)
    item.toggleDone(asOf: now)
    #expect(item.isDone)
    #expect(item.doneAt == now)
    item.toggleDone(asOf: now)
    #expect(!item.isDone)
    #expect(item.doneAt == nil)
}

@MainActor
@Test func unknownRawValuesFallBack() throws {
    let context = try makeContext()
    let item = SharedItineraryItem(context: context, title: "x", dayIndex: 0)
    item.kindRaw = "spaceport"
    #expect(item.kind == .other)
    let booking = SharedBooking(context: context, title: "x", kind: .car)
    booking.kindRaw = "zeppelin"
    #expect(booking.kind == .other)
}

@MainActor
@Test func flightHeadlineCopesWithMissingParts() throws {
    let context = try makeContext()
    let flight = SharedFlight(context: context, airlineCode: "BA", number: "286", originCode: "FCO", destinationCode: "LHR", dayIndex: 0)
    #expect(flight.headline == "BA 286 · FCO → LHR")
    let bare = SharedFlight(context: context, airlineCode: "", number: "", originCode: "", destinationCode: "", dayIndex: 0)
    #expect(bare.headline == "Flight")
}

@MainActor
@Test func debugSeedRunsOnceAndOnlyIntoAnEmptyStore() throws {
    let context = try makeContext()
    TripDebugSeed.run(context: context)
    let seeded = try context.count(for: SharedTrip.fetchRequest())
    #expect(seeded == 4)
    TripDebugSeed.run(context: context)
    #expect(try context.count(for: SharedTrip.fetchRequest()) == seeded)

    let groups = TripGroups(try context.fetch(SharedTrip.fetchRequest()))
    #expect(groups.inProgress.count == 1)
    #expect(groups.upcoming.count == 2)
    #expect(groups.finished.count == 1)
}

// MARK: - Mac sidebar

@MainActor
@Test func sidebarDetailCountsTheDayOfATripUnderWay() throws {
    let context = try makeContext()
    let all = trips(in: context)
    #expect(TripTrackerModule.sidebarDetail(trips: [all.tokyo, all.rome], asOf: day(6, 8)) == "Day 3")
}

@MainActor
@Test func sidebarDetailCountsDownWithOnlyTripsAhead() throws {
    let context = try makeContext()
    let all = trips(in: context)
    let detail = TripTrackerModule.sidebarDetail(trips: [all.lisbon, all.tokyo, all.reykjavik], asOf: day(9, 20))
    #expect(detail == TripOverview.countdown(days: all.tokyo.dates.daysUntilStart(asOf: day(9, 20))))
    #expect(detail == "in 12 days")
}

@MainActor
@Test func sidebarDetailIsNilWithNothingAhead() throws {
    let context = try makeContext()
    let all = trips(in: context)
    #expect(TripTrackerModule.sidebarDetail(trips: [all.reykjavik, all.rome], asOf: day(12, 1)) == nil)
    #expect(TripTrackerModule.sidebarDetail(trips: [], asOf: day(12, 1)) == nil)
}

@MainActor
@Test func sidebarTripsPutFinishedOnesInPastNewestFirst() throws {
    let context = try makeContext()
    let all = trips(in: context)
    let groups = TripTrackerModule.sidebarTrips([all.lisbon, all.reykjavik, all.tokyo, all.rome], asOf: day(6, 8))

    #expect(groups.current.map(\.title) == ["Rome & Amalfi", "Tokyo", "Lisbon"], "Under way, then soonest first")
    #expect(groups.past.map(\.title) == ["Reykjavik"])
    #expect(groups.underWay == [all.rome.objectID])

    let later = TripTrackerModule.sidebarTrips([all.lisbon, all.reykjavik, all.tokyo, all.rome], asOf: day(10, 20))
    #expect(later.past.map(\.title) == ["Tokyo", "Rome & Amalfi", "Reykjavik"], "Most recent first")
    #expect(later.underWay.isEmpty)
}
