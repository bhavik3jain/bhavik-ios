import CoreData
import Foundation
import Testing
@testable import TripTracker

@MainActor
private func trips(in context: NSManagedObjectContext) -> (rome: Trip, tokyo: Trip, lisbon: Trip, reykjavik: Trip) {
    let rome = makeRome(in: context)
    let tokyo = Trip(context: context, title: "Tokyo", startDate: day(10, 2), endDate: day(10, 13))
    let lisbon = Trip(context: context, title: "Lisbon", startDate: day(11, 14), endDate: day(11, 17))
    let reykjavik = Trip(context: context, title: "Reykjavik", startDate: day(3, 1), endDate: day(3, 6))
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
    let booking = Booking(context: context, title: "Hotel", kind: .lodging)
    booking.trip = trip
    try context.save()

    context.delete(trip)
    try context.save()

    #expect(try context.count(for: ItineraryItem.fetchRequest()) == 0)
    #expect(try context.count(for: Flight.fetchRequest()) == 0)
    #expect(try context.count(for: Booking.fetchRequest()) == 0)
}

@MainActor
@Test func togglingDoneStampsAndClearsTheTime() throws {
    let context = try makeContext()
    let item = ItineraryItem(context: context, title: "Galleria", dayIndex: 0)
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
    let item = ItineraryItem(context: context, title: "x", dayIndex: 0)
    item.kindRaw = "spaceport"
    #expect(item.kind == .other)
    let booking = Booking(context: context, title: "x", kind: .car)
    booking.kindRaw = "zeppelin"
    #expect(booking.kind == .other)
}

@MainActor
@Test func flightHeadlineCopesWithMissingParts() throws {
    let context = try makeContext()
    let flight = Flight(context: context, airlineCode: "BA", number: "286", originCode: "FCO", destinationCode: "LHR", dayIndex: 0)
    #expect(flight.headline == "BA 286 · FCO → LHR")
    let bare = Flight(context: context, airlineCode: "", number: "", originCode: "", destinationCode: "", dayIndex: 0)
    #expect(bare.headline == "Flight")
}

@MainActor
@Test func debugSeedRunsOnceAndOnlyIntoAnEmptyStore() throws {
    let context = try makeContext()
    TripDebugSeed.run(context: context)
    let seeded = try context.count(for: Trip.fetchRequest())
    #expect(seeded == 4)
    TripDebugSeed.run(context: context)
    #expect(try context.count(for: Trip.fetchRequest()) == seeded)

    let groups = TripGroups(try context.fetch(Trip.fetchRequest()))
    #expect(groups.inProgress.count == 1)
    #expect(groups.upcoming.count == 2)
    #expect(groups.finished.count == 1)
}
