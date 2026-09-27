import Core
import CoreData
import Testing
@testable import TripTracker

@MainActor
private func describe(_ object: NSManagedObject, _ kind: SharedChangeKind, _ properties: Set<String> = []) -> SharedChangeDescription? {
    TripTrackerModule.describeSharedChange(object, SharedObjectChange(kind: kind, updatedProperties: properties))
}

@MainActor
@Test func anAddedItemNamesItsDayUnderTheTrip() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let gelato = addItem("Gelato at Giolitti", to: trip, in: context, day: 2)
    try context.save()

    let description = try #require(describe(gelato, .inserted))
    #expect(description.rootID == trip.objectID)
    #expect(description.rootTitle == "Rome & Amalfi")
    #expect(description.action == "added Gelato at Giolitti to Day 3")
}

@MainActor
@Test func itemUpdatesSayWhatChanged() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let pantheon = addItem("Pantheon", to: trip, in: context, day: 0, done: true)
    try context.save()

    #expect(describe(pantheon, .updated, ["isDone", "doneAt"])?.action == "ticked off Pantheon")
    #expect(describe(pantheon, .updated, ["dayIndex"])?.action == "moved Pantheon to Day 1")
    #expect(describe(pantheon, .updated, ["startTime"])?.action == "changed Pantheon")
}

@MainActor
@Test func anItemOnNoDayIsAddedWithoutOne() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let idea = addItem("Villa Borghese", to: trip, in: context, day: -1)
    #expect(describe(idea, .inserted)?.action == "added Villa Borghese")
}

@MainActor
@Test func flightsBookingsAndTheTripItself() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let flight = addFlight(("AZ", "204"), to: trip, in: context, day: 0)
    let booking = SharedBooking(context: context, title: "Hotel Artemide", kind: .other)
    booking.secureNote = "Door code 4471"
    booking.trip = trip
    try context.save()

    #expect(describe(flight, .inserted)?.action == "added flight AZ204")
    #expect(describe(booking, .updated, ["notes"])?.action == "changed Hotel Artemide")
    #expect(describe(booking, .updated, ["secureNote"])?.action.contains("4471") == false)
    #expect(describe(trip, .updated, ["endDate"])?.action == "changed the dates of Rome & Amalfi")
    #expect(describe(trip, .updated, ["title"])?.action == "renamed a trip to Rome & Amalfi")

    let arrival = try #require(describe(trip, .inserted))
    #expect(arrival.rootID == trip.objectID, "A root's own insert is what holds back the download after accepting a share")
}

@MainActor
@Test func somethingLooseFromItsTripIsNotDescribed() throws {
    let context = try makeContext()
    let orphan = SharedItineraryItem(context: context, title: "Nowhere", dayIndex: 0)
    #expect(describe(orphan, .inserted) == nil)
}
