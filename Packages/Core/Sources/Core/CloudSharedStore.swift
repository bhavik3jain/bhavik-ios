import CoreData

/// Builds an `NSPersistentCloudKitContainer` configured for CloudKit sharing — a
/// private store plus a shared-scope store, the pattern CKShare requires. This
/// exists because SwiftData has no sharing support at all (confirmed on Apple's
/// developer forums), so the three modules migrating to CKShare — Trips, Fuel,
/// Explore — go through Core Data instead. Every other module stays on SwiftData;
/// nothing here is wired into `AppSchema` yet.
public enum CloudSharedStore {
    /// NSPersistentCloudKitContainer needs BOTH of these options on every store
    /// description or CloudKit mirroring silently never happens — there is no
    /// error at load time, sync just never occurs.
    private static func configureForCloudKitMirroring(_ description: NSPersistentStoreDescription) {
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
    }

    /// `name` becomes the sqlite filename stem (kept distinct per module so the
    /// three modules' stores never collide on disk). `inMemory` is for tests — no
    /// CloudKit container options are attached in that mode, so tests never touch
    /// the network (this repo's tests are never allowed to touch CloudKit, per
    /// CLAUDE.md), and the stores use Core Data's own in-memory store type rather
    /// than the sqlite-at-/dev/null trick, since NSPersistentHistoryTrackingKey
    /// needs a real (or true in-memory) store and isn't meaningful for either.
    ///
    /// Both descriptions are left on the default (nil) configuration, so both
    /// stores claim every entity in `model` — that's deliberate, not an oversight:
    /// it's the same fan-out Apple's own CloudKit-sharing sample uses. A new
    /// object inserted without an explicit store assignment lands in the first
    /// store in `persistentStoreDescriptions` (the private one); an object is only
    /// ever in the shared store because `acceptShareInvitations` or
    /// `shareManagedObjects` put it there.
    @MainActor
    public static func makeContainer(
        name: String,
        model: NSManagedObjectModel,
        containerID: String,
        inMemory: Bool = false
    ) -> NSPersistentCloudKitContainer {
        let container = NSPersistentCloudKitContainer(name: name, managedObjectModel: model)

        let privateDescription = container.persistentStoreDescriptions.first ?? NSPersistentStoreDescription()
        // NSPersistentStoreDescription's own -copy always returns another instance
        // of itself, so this can't fail.
        let sharedDescription = privateDescription.copy() as! NSPersistentStoreDescription

        // Two descriptions that started life as copies of each other are, to
        // Core Data, the same store — it keys on URL, not on identity or type,
        // and refuses to add either an on-disk or an in-memory store twice under
        // the same URL ("Can't add the same store twice"). So the shared
        // description needs its own URL in every mode, in-memory included.
        if let base = privateDescription.url {
            sharedDescription.url = base.deletingLastPathComponent()
                .appendingPathComponent(base.deletingPathExtension().lastPathComponent + "-shared")
                .appendingPathExtension(base.pathExtension)
        }

        if inMemory {
            privateDescription.type = NSInMemoryStoreType
            sharedDescription.type = NSInMemoryStoreType
            // The default description picks up the entitlements' iCloud container
            // on its own, and the copy inherits it: two stores, one container, one
            // scope, which Core Data throws on ("Cannot assign the same iCloud
            // Container Identifier to multiple persistent stores with the same
            // database scope"). Tests have no entitlements so never saw it; the
            // -InitializeCloudKitSchema launch crashed on it.
            privateDescription.cloudKitContainerOptions = nil
            sharedDescription.cloudKitContainerOptions = nil
        } else {
            configureForCloudKitMirroring(privateDescription)
            configureForCloudKitMirroring(sharedDescription)

            privateDescription.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: containerID)

            let sharedOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: containerID)
            // NSPersistentCloudKitContainerOptions.h's own doc comment claims only
            // .private and .public are supported — that's stale; .shared is exactly
            // how Apple's WWDC21 CloudKit-sharing sample configures a store's
            // second description, and it's the only way NSPersistentCloudKitContainer
            // exposes the shared database at all.
            sharedOptions.databaseScope = .shared
            sharedDescription.cloudKitContainerOptions = sharedOptions
        }

        container.persistentStoreDescriptions = [privateDescription, sharedDescription]

        // Before loading, not after: mirroring starts the moment a store loads,
        // and a first import that finished before anyone subscribed would
        // never be seen — leaving the legacy importers waiting on it for their
        // whole timeout. See CloudKitImportGate.swift.
        CloudKitImportGate.track(container)

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError {
            fatalError("Failed to load \(name) store: \(loadError)")
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        return container
    }
}

public extension NSPersistentCloudKitContainer {
    /// The store backed by the owner's private CloudKit database — where data
    /// that must never reach a share participant has to be written, via
    /// `NSManagedObjectContext.assign(_:to:)`.
    ///
    /// Found by the description's database scope rather than by position, so
    /// it can't silently become the shared store if the description order in
    /// `CloudSharedStore.makeContainer` ever changes. An in-memory (test)
    /// container carries no CloudKit options at all, so there it falls back
    /// to the first description — which `makeContainer` always makes the
    /// private one.
    var privatePersistentStore: NSPersistentStore? {
        let description = persistentStoreDescriptions.first { $0.cloudKitContainerOptions?.databaseScope == .private }
            ?? persistentStoreDescriptions.first
        guard let url = description?.url else { return nil }
        return persistentStoreCoordinator.persistentStore(for: url)
    }
}
