import CloudKit
import CoreData

/// Modules register their own `NSPersistentCloudKitContainer` here at launch,
/// keyed by their CloudKit record type prefix (e.g. "CD_SharedTrip" —
/// `CloudKitSchemaInitializer.swift` already derives every Core Data record
/// type as "CD_" + entity name), so the app shell's single share-accept
/// delegate method can route an incoming CKShare invitation to the right
/// module's container without the app shell — or this router — needing to
/// import any module's models directly. Trip/Vehicle/Guide don't exist as
/// Core Data models yet; this phase only builds the routing mechanism.
@MainActor
public final class ShareAcceptRouter {
    public static let shared = ShareAcceptRouter()
    private init() {}

    private var containersByRecordTypePrefix: [String: NSPersistentCloudKitContainer] = [:]

    public func register(recordTypePrefix: String, container: NSPersistentCloudKitContainer) {
        containersByRecordTypePrefix[recordTypePrefix] = container
    }

    /// Called from the app shell's share-accept delegate method on both
    /// platforms (`userDidAcceptCloudKitShareWith(metadata:)`, under whichever
    /// scene/app-delegate hook each platform delivers it through). Looks at the
    /// share's root record type to find which registered container should
    /// accept it.
    ///
    /// `metadata.rootRecord` is only populated when whatever fetched this
    /// metadata asked for it — `CKFetchShareMetadataOperation.shouldFetchRootRecord
    /// = true`, or the equivalent on the scene/app-delegate path. The OS doesn't
    /// guarantee it's already there, so the app shell's delegate must fetch with
    /// that flag set before calling here, or every invitation reads as unroutable.
    public func accept(_ metadata: CKShare.Metadata, completion: (@Sendable (Error?) -> Void)? = nil) {
        guard let recordType = metadata.rootRecord?.recordType,
              let container = containersByRecordTypePrefix[recordType] else {
            completion?(CocoaError(.coderInvalidValue))
            return
        }
        // acceptShareInvitations wants the loaded NSPersistentStore, not the
        // NSPersistentStoreDescription it was configured from — the two are
        // different types, and the store is only reachable through the
        // coordinator, keyed by the URL its description was given.
        guard let sharedStoreURL = container.persistentStoreDescriptions
                .first(where: { $0.cloudKitContainerOptions?.databaseScope == .shared })?.url,
              let sharedStore = container.persistentStoreCoordinator.persistentStore(for: sharedStoreURL) else {
            completion?(CocoaError(.coderInvalidValue))
            return
        }
        container.acceptShareInvitations(from: [metadata], into: sharedStore) { _, error in
            completion?(error)
        }
    }
}
