import CoreData
import Testing
@testable import Core

@MainActor
private func makeContainer() throws -> NSPersistentContainer {
    let value = NSAttributeDescription()
    value.name = "value"
    value.attributeType = .stringAttributeType
    value.isOptional = false
    value.defaultValue = ""

    let entity = NSEntityDescription()
    entity.name = "FetchItem"
    entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
    entity.properties = [value]

    let model = NSManagedObjectModel()
    model.entities = [entity]

    let container = NSPersistentContainer(name: "FetchTest", managedObjectModel: model)
    let description = NSPersistentStoreDescription()
    description.type = NSInMemoryStoreType
    description.shouldAddStoreAsynchronously = false
    container.persistentStoreDescriptions = [description]
    var loadError: Error?
    container.loadPersistentStores { _, error in loadError = error }
    if let loadError { throw loadError }
    // As CloudSharedStore sets it: imports reach the view context by merge.
    container.viewContext.automaticallyMergesChangesFromParent = true
    return container
}

/// Polls the main run loop until `condition` holds or two seconds pass.
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
@Test func aSaveOnTheWatchedContextRefetches() async throws {
    let container = try makeContainer()
    let fetch = ManagedObjectFetch(NSFetchRequest<NSManagedObject>(entityName: "FetchItem"))
    fetch.start(context: container.viewContext)
    #expect(fetch.results.isEmpty)

    NSEntityDescription.insertNewObject(forEntityName: "FetchItem", into: container.viewContext)
    try container.viewContext.save()

    #expect(await eventually { fetch.results.count == 1 })
}

@MainActor
@Test func aMergeFromAnotherContextRefetches() async throws {
    let container = try makeContainer()
    let fetch = ManagedObjectFetch(NSFetchRequest<NSManagedObject>(entityName: "FetchItem"))
    fetch.start(context: container.viewContext)

    // What a CloudKit import looks like from here: a background context
    // saves, and the view context only merges.
    let background = container.newBackgroundContext()
    try await background.perform {
        NSEntityDescription.insertNewObject(forEntityName: "FetchItem", into: background)
        try background.save()
    }
    #expect(await eventually { fetch.results.count == 1 }, "An imported record shows without a save on this device")

    try await background.perform {
        let all = try background.fetch(NSFetchRequest<NSManagedObject>(entityName: "FetchItem"))
        all.forEach(background.delete)
        try background.save()
    }
    #expect(await eventually { fetch.results.isEmpty }, "A record deleted elsewhere leaves the list")
}
