import CoreData
import Testing
@testable import Core

/// A throwaway single-entity model, built in code rather than loaded from a
/// .xcdatamodeld — there's nothing under Packages/Core worth shipping a model
/// editor file for just to prove the store-loading spike works.
@MainActor
private func makeTestModel() -> NSManagedObjectModel {
    let value = NSAttributeDescription()
    value.name = "value"
    value.attributeType = .stringAttributeType
    value.isOptional = false
    value.defaultValue = ""

    let entity = NSEntityDescription()
    entity.name = "SpikeItem"
    entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
    entity.properties = [value]

    let model = NSManagedObjectModel()
    model.entities = [entity]
    return model
}

// The concrete spike this phase exists to run: does the private+shared
// two-store pattern actually load and round-trip data on this SDK, before any
// module's real models are moved onto it.
@MainActor
@Test func privateAndSharedStoresLoadAndRoundTripAnObject() throws {
    let container = CloudSharedStore.makeContainer(
        name: "SpikeStore",
        model: makeTestModel(),
        containerID: "iCloud.com.bhavikjain.trackers.spike",
        inMemory: true
    )

    #expect(container.persistentStoreDescriptions.count == 2)

    let context = container.viewContext
    let item = NSEntityDescription.insertNewObject(forEntityName: "SpikeItem", into: context)
    item.setValue("round-trips", forKey: "value")
    try context.saveIfNeeded()

    // A fresh fetch, not the object still held above, so this actually proves
    // the store round-trips rather than just holding a reference in memory.
    let request = NSFetchRequest<NSManagedObject>(entityName: "SpikeItem")
    let fetched = try context.fetch(request)

    #expect(fetched.count == 1)
    #expect(fetched.first?.value(forKey: "value") as? String == "round-trips")
}
