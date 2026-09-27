import Core
import CoreData
import Foundation
import Testing
@testable import FuelTracker

/// A container kept alive for the test's whole body — a context doesn't
/// retain its own container (see `makeContext()` in FuelTrackerTests.swift).
@MainActor
private func withContext(_ body: (NSManagedObjectContext) throws -> Void) throws {
    let container = CloudSharedStore.makeContainer(
        name: "FuelSharedChangeTests-\(UUID().uuidString)",
        model: FuelModel.make(),
        containerID: "iCloud.com.bhavikjain.trackers.tests",
        inMemory: true
    )
    try withExtendedLifetime(container) { try body(container.viewContext) }
}

@MainActor
private func describe(_ object: NSManagedObject, _ kind: SharedChangeKind, _ properties: Set<String> = []) -> SharedChangeDescription? {
    FuelTrackerModule.describeSharedChange(object, SharedObjectChange(kind: kind, updatedProperties: properties))
}

@MainActor
@Test func aFillUpIsLoggedAgainstItsVehicle() throws {
    try withContext { context in
        let car = SharedVehicle(context: context, name: "My X3")
        let fillUp = SharedFuelEntry(context: context, date: .now, odometer: 37_057, gallons: 14.2, station: "Costco")
        fillUp.vehicle = car
        try context.save()

        let description = try #require(describe(fillUp, .inserted))
        #expect(description.rootID == car.objectID)
        #expect(description.rootTitle == "My X3")
        #expect(description.action == "logged a fill-up at Costco")
        #expect(describe(fillUp, .updated, ["gallons"])?.action == "edited a fill-up at Costco")
    }
}

@MainActor
@Test func servicesAndStationlessFillUps() throws {
    try withContext { context in
        let car = SharedVehicle(context: context, name: "My Q5")
        let service = SharedFuelEntry(context: context, kind: .service, date: .now, odometer: 40_000, services: "Oil change")
        service.vehicle = car
        let fillUp = SharedFuelEntry(context: context, date: .now, odometer: 40_100)
        fillUp.vehicle = car

        #expect(describe(service, .inserted)?.action == "logged a service (Oil change)")
        #expect(describe(fillUp, .inserted)?.action == "logged a fill-up")
    }
}

@MainActor
@Test func theVehicleItselfAndALooseEntry() throws {
    try withContext { context in
        let car = SharedVehicle(context: context, name: "My X3")
        #expect(describe(car, .updated, ["name"])?.action == "renamed a vehicle to My X3")
        #expect(describe(car, .inserted)?.rootID == car.objectID)

        let loose = SharedFuelEntry(context: context, date: .now, odometer: 1)
        #expect(describe(loose, .inserted) == nil, "No vehicle, no root to notify about")
    }
}
