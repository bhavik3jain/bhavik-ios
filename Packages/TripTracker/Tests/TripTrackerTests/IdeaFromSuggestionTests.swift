import Core
import CoreData
import Foundation
import Testing
@testable import TripTracker

private let capitoline = PlaceSuggestion(
    place: FoundPlace(name: "Capitoline Museums", category: "Museum", latitude: 41.8933, longitude: 12.4829, address: "Piazza del Campidoglio 1"),
    why: "Indoor art and a view of the Forum for the rainy afternoon.",
    metres: 650
)

@MainActor
@Test func aSuggestionBecomesAnIdeaAfterTheExistingOnes() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Pantheon", to: trip, in: context, day: SharedItineraryItem.unassignedDayIndex, sortOrder: 0)
    addItem("Giolitti", to: trip, in: context, day: SharedItineraryItem.unassignedDayIndex, sortOrder: 3)
    addItem("Colosseum", to: trip, in: context, day: 0, sortOrder: 9)

    let idea = SharedItineraryItem.add(capitoline, to: trip, in: context)

    #expect(idea.dayIndex == SharedItineraryItem.unassignedDayIndex)
    #expect(idea.isUnassigned)
    #expect(idea.sortOrder == 4, "After the ideas, not after the day's stops")
    #expect(idea.trip === trip)
    #expect(idea.title == "Capitoline Museums")
    #expect(idea.kind == .sight)
    #expect(idea.address == "Piazza del Campidoglio 1")
    #expect(idea.latitude == 41.8933)
    #expect(idea.longitude == 12.4829)
    #expect(idea.detail == "Indoor art and a view of the Forum for the rainy afternoon.")
    #expect(idea.startTime == nil)
    #expect(trip.ideas.count == 3)
    try context.save()
}

@MainActor
@Test func aSuggestionCanGoStraightOntoADay() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Colosseum", to: trip, in: context, day: 1, sortOrder: 2)

    let stop = SharedItineraryItem.add(capitoline, to: trip, in: context, day: 1)

    #expect(stop.dayIndex == 1)
    #expect(stop.sortOrder == 3)
    #expect(DayPlan(trip: trip, dayIndex: 1).titles == ["Colosseum", "Capitoline Museums"])
}

@MainActor
@Test func addingTheSamePlaceTwiceKeepsOneItem() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)

    let first = SharedItineraryItem.add(capitoline, to: trip, in: context)
    let second = SharedItineraryItem.add(capitoline, to: trip, in: context)
    #expect(first === second)
    #expect(trip.items?.count == 1)

    // Chosen again with a day: the idea moves onto it rather than doubling.
    let third = SharedItineraryItem.add(capitoline, to: trip, in: context, day: 2)
    #expect(third === first)
    #expect(first.dayIndex == 2)
    #expect(trip.items?.count == 1)
}

@MainActor
@Test func aWhylessSuggestionLeavesTheDetailEmpty() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let plain = PlaceSuggestion(place: FoundPlace(name: "Parco del Colle Oppio", category: "Park", latitude: 41.8925, longitude: 12.4962), why: "", metres: nil)

    let idea = SharedItineraryItem.add(plain, to: trip, in: context)

    #expect(idea.detail.isEmpty)
    #expect(idea.kind == .activity)
    #expect(idea.address.isEmpty)
}
