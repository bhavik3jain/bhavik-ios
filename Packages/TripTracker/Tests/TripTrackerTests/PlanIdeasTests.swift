import Core
import CoreData
import Foundation
import Testing
@testable import TripTracker

private let enGB = Locale(identifier: "en_GB")

// MARK: - The Ideas inspector's ranking

@MainActor
@Test func ideasRankByTheirNearestStopOnTheDay() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    // Day 3 runs from the Pantheon to Trastevere — no useful middle between them.
    addPlace("Armando", to: trip, in: context, day: 2, at: (41.8986, 12.4769))
    addPlace("Da Enzo", to: trip, in: context, day: 2, at: (41.8886, 12.4770))
    addPlace("Somewhere else", to: trip, in: context, day: 4, at: (41.9100, 12.4500))
    // Ideas.
    addPlace("Giolitti", to: trip, in: context, at: (41.9010, 12.4776))
    addPlace("Villa Farnesina", to: trip, in: context, at: (41.8935, 12.4675))
    addPlace("Ostia Antica", to: trip, in: context, at: (41.7556, 12.2918))
    addPlace("Pasta class", to: trip, in: context, at: nil)

    let ideas = PlanIdeas(trip: trip, day: 2)

    #expect(ideas.isMeasured)
    #expect(ideas.closest.map(\.item.title) == ["Giolitti", "Villa Farnesina"])
    #expect(ideas.closest.map { $0.nearestStop?.title } == ["Armando", "Da Enzo"])
    #expect(ideas.elsewhere.map(\.item.title) == ["Ostia Antica"], "Beyond worth-the-trip is never 'close'")
    #expect(ideas.unplaced.map(\.title) == ["Pasta class"])
    #expect(ideas.count == 4)
    #expect(!ideas.closest.map(\.item.title).contains("Somewhere else"), "Another day's stop isn't an idea")
}

@MainActor
@Test func onlyTheFirstFewCloseIdeasAreClosest() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addPlace("Pantheon", to: trip, in: context, day: 0, at: (41.8986, 12.4769))
    for index in 0..<6 {
        addPlace("Idea \(index)", to: trip, in: context, at: (41.8986 + Double(index) * 0.001, 12.4769))
    }

    let ideas = PlanIdeas(trip: trip, day: 0)

    #expect(ideas.closest.count == PlanIdeas.closestLimit)
    #expect(ideas.closest.map(\.item.title) == ["Idea 0", "Idea 1", "Idea 2", "Idea 3"])
    #expect(ideas.elsewhere.map(\.item.title) == ["Idea 4", "Idea 5"])
}

@MainActor
@Test func aDayWithNoPlacedStopListsIdeasByName() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Lunch somewhere", to: trip, in: context, day: 1)
    addPlace("Villa Farnesina", to: trip, in: context, at: (41.8935, 12.4675))
    addPlace("Giolitti", to: trip, in: context, at: (41.9010, 12.4776))

    let ideas = PlanIdeas(trip: trip, day: 1)

    #expect(!ideas.isMeasured)
    #expect(ideas.closest.isEmpty)
    #expect(ideas.elsewhere.map(\.item.title) == ["Giolitti", "Villa Farnesina"])
    #expect(ideas.elsewhere.allSatisfy { $0.detail(locale: enGB) == nil })
}

@MainActor
@Test func matchDetailNamesTheStopAndTheWalk() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let armando = addPlace("Armando", to: trip, in: context, day: 2, at: (41.8986, 12.4769))
    let idea = addPlace("Giolitti", to: trip, in: context, at: (41.9010, 12.4776))

    // The distance itself is `WalkingEstimate`'s, in the locale's own road
    // units — en_GB gave "250 yd" and "16 mi", not the metres first expected
    // — so only the sentence around it is pinned here.
    let near = WalkingEstimate(metres: 250)
    let walk = PlanIdeas.Match(item: idea, nearestStop: armando, estimate: near)
    #expect(walk.detail(locale: enGB) == "3 min from Armando · \(near.distanceText(locale: enGB))")

    let far = WalkingEstimate(metres: 25_000)
    let ride = PlanIdeas.Match(item: idea, nearestStop: armando, estimate: far)
    #expect(ride.detail(locale: enGB) == "\(far.distanceText(locale: enGB)) from Armando")
}

// MARK: - Dragging between the plan and the ideas

@MainActor
@Test func droppingAnIdeaOnADayPutsItAtTheEnd() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Breakfast", to: trip, in: context, day: 2, sortOrder: 0)
    addItem("Museum", to: trip, in: context, day: 2, sortOrder: 4)
    let idea = addItem("Gelato", to: trip, in: context, day: SharedItineraryItem.unassignedDayIndex)
    try context.save()

    #expect(ItineraryDrop.move([ItineraryItemDrag(idea)], toDay: 2, in: trip))
    #expect(idea.dayIndex == 2)
    #expect(idea.sortOrder == 5)
}

@MainActor
@Test func droppingAStopOnTheIdeasUnassignsIt() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let stop = addItem("Colosseum", to: trip, in: context, day: 3)
    try context.save()

    #expect(ItineraryDrop.move([ItineraryItemDrag(stop)], toDay: SharedItineraryItem.unassignedDayIndex, in: trip))
    #expect(stop.isUnassigned)
    // Dropping it among the ideas again changes nothing, so nothing is saved.
    #expect(!ItineraryDrop.move([ItineraryItemDrag(stop)], toDay: SharedItineraryItem.unassignedDayIndex, in: trip))
}

@MainActor
@Test func aDropFromAnotherTripOrAStaleURIIsIgnored() throws {
    let context = try makeContext()
    let rome = makeRome(in: context)
    let paris = SharedTrip(context: context, title: "Paris", destination: "Paris", startDate: day(7, 1), endDate: day(7, 4))
    let louvre = addItem("Louvre", to: paris, in: context, day: SharedItineraryItem.unassignedDayIndex)
    let gone = addItem("Gone", to: rome, in: context, day: SharedItineraryItem.unassignedDayIndex)
    try context.save()
    let staleDrag = ItineraryItemDrag(gone)
    context.delete(gone)
    try context.save()

    #expect(ItineraryDrop.items(for: [ItineraryItemDrag(louvre), staleDrag], in: rome).isEmpty)
    #expect(!ItineraryDrop.move([ItineraryItemDrag(louvre)], toDay: 1, in: rome))
    #expect(louvre.isUnassigned)
}

@MainActor
@Test func aDropPastTheLastDayLandsOnTheLastDay() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let idea = addItem("Gelato", to: trip, in: context, day: SharedItineraryItem.unassignedDayIndex)
    try context.save()

    ItineraryDrop.move([ItineraryItemDrag(idea)], toDay: 40, in: trip)
    #expect(idea.dayIndex == trip.dates.dayCount - 1)
}

@Test func aDragSurvivesItsCodableRoundTrip() throws {
    let drag = ItineraryItemDrag(uri: URL(string: "x-coredata://STORE/SharedItineraryItem/p7")!)
    let data = try JSONEncoder().encode(drag)
    #expect(try JSONDecoder().decode(ItineraryItemDrag.self, from: data) == drag)
}
