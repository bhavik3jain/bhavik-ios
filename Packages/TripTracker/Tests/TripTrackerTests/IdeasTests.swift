import CoreData
import Foundation
import Testing
@testable import TripTracker

// MARK: - Unassigned days

@MainActor
@Test func anIdeaIsOnNoDay() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let idea = addItem("Aventine keyhole", to: trip, in: context, day: SharedItineraryItem.unassignedDayIndex)
    let planned = addItem("Pantheon", to: trip, in: context, day: 0)

    #expect(idea.isUnassigned)
    #expect(!planned.isUnassigned)
    #expect(trip.ideas == [idea])
}

@MainActor
@Test func noDaysPlanIncludesAnIdea() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Aventine keyhole", to: trip, in: context, day: SharedItineraryItem.unassignedDayIndex)
    addItem("Pantheon", to: trip, in: context, day: 0)

    #expect(DayPlan(trip: trip, dayIndex: 0).titles == ["Pantheon"])
    for index in 0..<trip.dates.dayCount {
        #expect(!DayPlan(trip: trip, dayIndex: index).titles.contains("Aventine keyhole"))
    }
}

@MainActor
@Test func theDayBeforeATripHasNoPlanEvenWithIdeas() throws {
    // `dates.offset(of:)` is -1 the day before departure — the same number
    // as an idea's day. Asked for that day, the plan must be empty, not the
    // ideas.
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Aventine keyhole", to: trip, in: context, day: SharedItineraryItem.unassignedDayIndex)
    let eve = day(6, 5)

    let plan = DayPlan(trip: trip, dayIndex: trip.dates.offset(of: eve))
    #expect(trip.dates.offset(of: eve) == -1)
    #expect(plan.isEmpty)
    #expect(plan.upNext(asOf: eve) == nil)
}

@MainActor
@Test func changingATripsDatesLeavesIdeasUnassigned() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let idea = addItem("Aventine keyhole", to: trip, in: context, day: SharedItineraryItem.unassignedDayIndex)
    let late = addItem("Day nine", to: trip, in: context, day: 8)

    trip.endDate = day(6, 10)
    trip.clampPlanToDates()
    #expect(idea.dayIndex == SharedItineraryItem.unassignedDayIndex, "Not pulled onto day 1")
    #expect(late.dayIndex == 4)

    trip.startDate = day(7, 1)
    trip.endDate = day(7, 12)
    trip.clampPlanToDates()
    #expect(idea.isUnassigned)
}

@MainActor
@Test func aNegativeFlightIsStillPulledOntoTheTrip() throws {
    // Only items can be ideas; a flight always keeps a day.
    let context = try makeContext()
    let trip = makeRome(in: context)
    let flight = addFlight(("BA", "285"), to: trip, in: context, day: -1)

    trip.clampPlanToDates()
    #expect(flight.dayIndex == 0)
}

@MainActor
@Test func theOpeningDayIsNeverAnIdeasDay() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    for moment in [day(1, 1), day(6, 5), day(6, 6), day(6, 10), day(6, 14), day(12, 31)] {
        #expect(TripDates.initialDay(for: trip, asOf: moment) >= 0)
    }
}

// MARK: - Moving

@MainActor
@Test func movingAnIdeaOntoADayPutsItAfterWhatsThere() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Borghese", to: trip, in: context, day: 2, sortOrder: 0)
    addItem("Trastevere", to: trip, in: context, day: 2, sortOrder: 4)
    let idea = addItem("Giolitti", to: trip, in: context, day: SharedItineraryItem.unassignedDayIndex, sortOrder: 0)
    try context.save()

    idea.move(toDay: 2)
    #expect(idea.dayIndex == 2)
    #expect(idea.sortOrder == 5)
    #expect(DayPlan(trip: trip, dayIndex: 2).titles.last == "Giolitti")
}

@MainActor
@Test func movingAnItemBackToIdeasJoinsTheEndOfThem() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Ostia Antica", to: trip, in: context, day: SharedItineraryItem.unassignedDayIndex, sortOrder: 3)
    let item = addItem("Borghese", to: trip, in: context, day: 2, sortOrder: 0)
    try context.save()

    item.move(toDay: SharedItineraryItem.unassignedDayIndex)
    #expect(item.isUnassigned)
    #expect(item.sortOrder == 4)
    #expect(DayPlan(trip: trip, dayIndex: 2).isEmpty)
}

@MainActor
@Test func stayingOnTheSameDayKeepsItsPlace() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let first = addItem("Borghese", to: trip, in: context, day: 2, sortOrder: 0)
    addItem("Trastevere", to: trip, in: context, day: 2, sortOrder: 1)
    try context.save()

    first.move(toDay: 2)
    #expect(first.sortOrder == 0)
}

@MainActor
@Test func aNewItemGoesAfterEverythingOnItsDay() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Borghese", to: trip, in: context, day: 2, sortOrder: 7)
    try context.save()

    let fresh = SharedItineraryItem(context: context, title: "Gelato", dayIndex: 2)
    fresh.trip = trip
    fresh.move(toDay: 2)
    #expect(fresh.sortOrder == 8)
}

// MARK: - Day menu

@Test func todayComesFirstWhileTheTripRuns() {
    let dates = TripDates(start: day(6, 6), end: day(6, 14), calendar: current)
    let choices = IdeaDays.choices(for: dates, asOf: day(6, 8))

    #expect(choices.map(\.dayIndex) == [2, 0, 1, 3, 4, 5, 6, 7, 8])
    #expect(choices.first?.isToday == true)
    #expect(choices.first?.title == "Today · Day 3")
    #expect(choices.filter(\.isToday).count == 1)
}

@Test func beforeTheTripTheDaysRunInOrder() {
    let dates = TripDates(start: day(6, 6), end: day(6, 14), calendar: current)
    let choices = IdeaDays.choices(for: dates, asOf: day(5, 1))

    #expect(choices.map(\.dayIndex) == Array(0...8))
    #expect(choices.allSatisfy { !$0.isToday })
    #expect(choices[0].title.hasPrefix("Day 1 · "))
}

@Test func anIdeaIsNamedAsOne() {
    let dates = TripDates(start: day(6, 6), end: day(6, 14), calendar: current)
    #expect(IdeaDays.shortName(forDay: -1, dates: dates, asOf: day(6, 8)) == "Idea")
    #expect(IdeaDays.shortName(forDay: 2, dates: dates, asOf: day(6, 8)) == "Today")
    #expect(IdeaDays.shortName(forDay: 3, dates: dates, asOf: day(6, 8)) == "Day 4")
}

// MARK: - Map

@MainActor
@Test func ideasHaveTheirOwnMapChipAndNoDays() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let idea = addPlace("Aventine keyhole", to: trip, in: context, at: (41.8833, 12.4787))
    let hotelIdea = addPlace("Hotel maybe", to: trip, in: context, at: (41.9, 12.48), kind: .lodging)
    let planned = addPlace("Pantheon", to: trip, in: context, day: 0, at: (41.8986, 12.4769))
    let unplacedIdea = addPlace("Cooking class", to: trip, in: context, at: nil)

    #expect(MapDayFilter.ideas.shows(idea))
    #expect(MapDayFilter.ideas.shows(hotelIdea))
    #expect(!MapDayFilter.ideas.shows(planned))
    #expect(!MapDayFilter.ideas.shows(unplacedIdea))

    #expect(MapDayFilter.allDays.shows(idea), "All days includes ideas, drawn apart")
    #expect(!MapDayFilter.day(0).shows(idea))
    #expect(!MapDayFilter.day(3).shows(hotelIdea), "A stay being weighed up isn't every day's hotel")
    #expect(MapDayFilter.day(0).shows(planned))
}

// MARK: - PDF

@MainActor
@Test func theItineraryLeavesIdeasOut() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Galleria Borghese", to: trip, in: context, day: 2, at: (9, 30), placed: true)
    addItem("Aventine keyhole", to: trip, in: context, day: SharedItineraryItem.unassignedDayIndex, placed: true)

    let document = ItineraryDocument(trip: trip)
    guard case .cover(let cover) = document.pages.first else {
        Issue.record("The first page is the cover")
        return
    }
    #expect(cover.facts == "9 days · 1 place", "Ideas aren't counted among the places")
    let titles = document.pages.flatMap { page -> [String] in
        if case .day(let dayPage) = page { dayPage.lines.map(\.title) } else { [] }
    }
    #expect(titles == ["Galleria Borghese"])
}
