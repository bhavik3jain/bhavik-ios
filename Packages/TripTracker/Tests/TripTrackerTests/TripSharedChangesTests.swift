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

    // The first expense sets the trip's currency; its own insert is the notice.
    #expect(describe(trip, .updated, ["currencyCode"]) == nil)
    #expect(describe(trip, .updated, ["currencyCode", "notes"])?.action == "updated Rome & Amalfi")

    let arrival = try #require(describe(trip, .inserted))
    #expect(arrival.rootID == trip.objectID, "A root's own insert is what holds back the download after accepting a share")
}

@MainActor
@Test func somethingLooseFromItsTripIsNotDescribed() throws {
    let context = try makeContext()
    let orphan = SharedItineraryItem(context: context, title: "Nowhere", dayIndex: 0)
    #expect(describe(orphan, .inserted) == nil)
}

@MainActor
@Test func expensesAndPaymentsNameTheirAmountButNeverTheNote() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    trip.currencyCode = "EUR"
    let saloni = PersonKey.participant(recordName: "_saloni")
    let dinner = SharedTripExpense(context: context, title: "Dinner at Ramiro", amountMinor: 23_640, currencyCode: "", payer: .owner, split: .equal([.owner, saloni]))
    dinner.note = "Saloni owes for the wine"
    dinner.trip = trip
    let payment = SharedTripExpense(context: context, title: "", amountMinor: 4_000, currencyCode: "EUR", payer: saloni, split: .payment(to: .owner, amountMinor: 4_000), kind: .payment)
    payment.trip = trip
    try context.save()

    let added = try #require(describe(dinner, .inserted))
    #expect(added.rootID == trip.objectID)
    #expect(added.action.hasPrefix("added Dinner at Ramiro ("))
    #expect(added.action.contains("236"))
    dinner.amountMinor = 24_000
    #expect(describe(dinner, .updated, ["amountMinor"])?.action.hasPrefix("changed Dinner at Ramiro to ") == true)
    #expect(describe(dinner, .updated, ["note"])?.action == "changed Dinner at Ramiro")
    #expect(describe(dinner, .deleted)?.action == "deleted Dinner at Ramiro")
    for kind in [SharedChangeKind.inserted, .updated] {
        #expect(describe(dinner, kind, ["note"])?.action.contains("wine") == false)
    }

    let recorded = try #require(describe(payment, .inserted)?.action)
    #expect(recorded.hasPrefix("recorded a "))
    #expect(recorded.hasSuffix(" payment"))
    #expect(recorded.contains("40"))
}

@MainActor
@Test func aManualPersonIsAnnouncedButSnapshotRowsSayNothing() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let alex = SharedTripPerson(context: context, manualName: "Alex")
    alex.trip = trip
    let snapshot = SharedTripPerson(context: context, key: .participant(recordName: "_saloni"), name: "Saloni", kind: .participant)
    snapshot.trip = trip
    let loose = SharedTripExpense(context: context, title: "Nowhere", amountMinor: 100, currencyCode: "EUR", payer: .owner, split: .equal([.owner]))
    try context.save()

    #expect(describe(alex, .inserted)?.action == "added Alex to the split")
    #expect(describe(alex, .updated, ["isHidden"]) == nil)
    #expect(describe(snapshot, .inserted) == nil)
    #expect(describe(loose, .inserted) == nil)
}
