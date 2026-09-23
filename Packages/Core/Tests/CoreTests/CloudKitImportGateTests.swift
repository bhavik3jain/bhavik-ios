import CoreData
import Testing
@testable import Core

@MainActor
private func makeTestModel() -> NSManagedObjectModel {
    let value = NSAttributeDescription()
    value.name = "value"
    value.attributeType = .stringAttributeType
    value.isOptional = false
    value.defaultValue = ""

    let entity = NSEntityDescription()
    entity.name = "GateItem"
    entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
    entity.properties = [value]

    let model = NSManagedObjectModel()
    model.entities = [entity]
    return model
}

// MARK: - privatePersistentStore

@MainActor
@Test func privatePersistentStoreIsTheFirstStoreAndNotTheSharedOne() throws {
    let container = CloudSharedStore.makeContainer(
        name: "GateStore-\(UUID().uuidString)",
        model: makeTestModel(),
        containerID: "iCloud.com.bhavikjain.trackers.tests",
        inMemory: true
    )
    let stores = container.persistentStoreCoordinator.persistentStores
    #expect(stores.count == 2)

    let privateStore = try #require(container.privatePersistentStore)
    #expect(privateStore.url == container.persistentStoreDescriptions.first?.url)
    #expect(privateStore.url != container.persistentStoreDescriptions.last?.url)
}

// MARK: - CloudKitImportGate

@MainActor
@Test func aContainerWithoutCloudKitNeverWaits() async {
    let container = CloudSharedStore.makeContainer(
        name: "GateStore-\(UUID().uuidString)",
        model: makeTestModel(),
        containerID: "iCloud.com.bhavikjain.trackers.tests",
        inMemory: true
    )
    // A huge timeout: if this waited at all, the test would hang, not pass.
    #expect(await CloudKitImportGate.waitForFirstImport(of: container, timeout: .seconds(3_600)))
    #expect(await CloudKitImportGate.waitForFirstImport(of: nil, timeout: .seconds(3_600)))
}

@Test func aWaiterIsReleasedByAnImportOfItsOwnStoreOnly() async {
    let tracker = ImportTracker()
    let waiter = Task { await tracker.waitForImport(storeIdentifier: "private") }

    // Give the waiter time to register before the import lands, so this
    // exercises the stored-continuation path rather than the fast path.
    try? await Task.sleep(for: .milliseconds(50))
    tracker.markImported(storeIdentifier: "shared")
    #expect(!tracker.hasImported(storeIdentifier: "private"))

    tracker.markImported(storeIdentifier: "private")
    await waiter.value
    #expect(tracker.hasImported(storeIdentifier: "private"))
}

@Test func waitingAfterTheImportReturnsImmediately() async {
    let tracker = ImportTracker()
    tracker.markImported(storeIdentifier: "private")
    await tracker.waitForImport(storeIdentifier: "private")
    #expect(tracker.hasImported(storeIdentifier: "private"))
}

@Test func cancellingAWaiterReleasesItWithoutAnImport() async {
    let tracker = ImportTracker()
    let waiter = Task { await tracker.waitForImport(storeIdentifier: "private") }
    try? await Task.sleep(for: .milliseconds(50))
    waiter.cancel()
    await waiter.value
    #expect(!tracker.hasImported(storeIdentifier: "private"))

    // Cancelled before it could even register.
    let early = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        await tracker.waitForImport(storeIdentifier: "private")
    }
    await early.value
}
