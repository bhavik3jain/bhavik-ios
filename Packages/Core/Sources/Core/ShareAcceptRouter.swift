import CloudKit
import CoreData

/// Modules register their own `NSPersistentCloudKitContainer` here at launch,
/// keyed by their CloudKit record type prefix (e.g. "CD_SharedTrip" —
/// `CloudKitSchemaInitializer.swift` already derives every Core Data record
/// type as "CD_" + entity name), so the app shell's single share-accept
/// delegate method can route an incoming CKShare invitation to the right
/// module's container without the app shell — or this router — needing to
/// import any module's models directly.
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
    /// **Confirmed finding**: `metadata.rootRecord` is *not* reliably populated
    /// on the metadata the OS hands this callback. `CKShare.Metadata`'s own
    /// header doc comment says `rootRecord` is only filled in "if you set the
    /// `shouldFetchRootRecord` property of the operation that fetches the
    /// metadata to `true`" — and Apple's own sample code for this exact
    /// callback, in `CKAcceptSharesOperation.h`'s header comment, accepts the
    /// share first and only *then* "schedule[s] a fetch of the share's root
    /// record", which would be pointless if the root record were already
    /// sitting on the metadata the OS just handed over. So this re-fetches the
    /// metadata itself with `shouldFetchRootRecord = true` before routing,
    /// rather than trusting `metadata.rootRecord` as originally written here.
    public func accept(_ metadata: CKShare.Metadata, completion: (@Sendable (Error?) -> Void)? = nil) {
        guard let shareURL = metadata.share.url else {
            completion?(CocoaError(.coderInvalidValue))
            return
        }
        let cloudKitContainer = CKContainer(identifier: metadata.containerIdentifier)
        let operation = CKFetchShareMetadataOperation(shareURLs: [shareURL])
        operation.shouldFetchRootRecord = true
        operation.perShareMetadataResultBlock = { [weak self] _, result in
            Task { @MainActor in
                switch result {
                case .success(let refetchedMetadata):
                    self?.routeAndAccept(refetchedMetadata, completion: completion)
                case .failure(let error):
                    completion?(error)
                }
            }
        }
        cloudKitContainer.add(operation)
    }

    private func routeAndAccept(_ metadata: CKShare.Metadata, completion: (@Sendable (Error?) -> Void)?) {
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
