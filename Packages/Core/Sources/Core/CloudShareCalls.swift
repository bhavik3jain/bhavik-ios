import CloudKit
import CoreData

/// `NSPersistentCloudKitContainer`'s sharing calls, made from a background
/// queue — never from the main thread.
///
/// They take a completion handler, so they read as asynchronous, but each one
/// first waits, synchronously, for the container's request executor to take
/// the request (`-[_PFRequestExecutor wait]`), and that executor is shared
/// with the mirroring delegate's own imports and exports. Called from a Share
/// button, `persistUpdatedShare` blocked the main thread until iOS killed the
/// app: TestFlight build 16 hung on Share, then died with watchdog 0x8BADF00D
/// ("Failed to terminate gracefully after 5.0s") once it was sent to the
/// background, its main thread still parked in that wait. It was a deadlock,
/// not a slow call: the export holding the executor was itself waiting for the
/// main thread to run `CloudSyncMonitor`'s event observer, which is now
/// delivered asynchronously (see its init).
///
/// Every call here returns at once; the completion still runs on whatever
/// queue CloudKit chooses, exactly as before, so callers hop to the main actor
/// themselves before touching UI state.
public extension NSPersistentCloudKitContainer {
    /// One serial queue for all of them, so a stamp saved on the way into the
    /// share sheet is queued ahead of anything the sheet saves after it.
    private static let shareQueue = DispatchQueue(label: "com.bhavikjain.trackers.cloud-share", qos: .userInitiated)

    /// `fetchShares(matching:)` reads the mirroring delegate's cache rather
    /// than the network, but through the same coordinator an import can hold.
    func fetchShareInBackground(
        for objectID: NSManagedObjectID,
        completion: @escaping @Sendable (CKShare?) -> Void
    ) {
        Self.shareQueue.async {
            completion((try? self.fetchShares(matching: [objectID]))?[objectID])
        }
    }

    /// Many objects' shares in one `fetchShares(matching:)`, on a queue of
    /// their own — for "Shared" badges (`SharingStatusCache`). Their own so a
    /// run of badge lookups, each waiting its turn on the container's
    /// executor, never sits between a Share button and its link: on the Mac,
    /// every badge on screen used to queue one lookup ahead of the share
    /// itself, and making a share cleared them all at once — the link waited
    /// behind a lookup for every trip, car and guide showing.
    func fetchSharesInBackground(
        for objectIDs: [NSManagedObjectID],
        completion: @escaping @Sendable ([NSManagedObjectID: CKShare]) -> Void
    ) {
        Self.badgeQueue.async {
            completion((try? self.fetchShares(matching: objectIDs)) ?? [:])
        }
    }

    private static let badgeQueue = DispatchQueue(label: "com.bhavikjain.trackers.share-badges", qos: .utility)

    func shareInBackground(
        _ object: NSManagedObject,
        completion: @escaping @Sendable (CKShare?, CKContainer?, (any Error)?) -> Void
    ) {
        // Only the object's ID and entity are read off the main thread, and
        // both are immutable once the object has been saved.
        nonisolated(unsafe) let object = object
        Self.shareQueue.async {
            self.share([object], to: nil) { _, share, ckContainer, error in
                completion(share, ckContainer, error)
            }
        }
    }

    func persistUpdatedShareInBackground(
        _ share: CKShare,
        in store: NSPersistentStore,
        completion: @escaping @Sendable (CKShare?, (any Error)?) -> Void = { _, _ in }
    ) {
        nonisolated(unsafe) let store = store
        Self.shareQueue.async {
            self.persistUpdatedShare(share, in: store) { saved, error in
                completion(saved, error)
            }
        }
    }

    func fetchParticipantsInBackground(
        matching lookupInfos: [CKUserIdentity.LookupInfo],
        into store: NSPersistentStore,
        completion: @escaping @Sendable ([CKShare.Participant]?, (any Error)?) -> Void
    ) {
        nonisolated(unsafe) let store = store
        Self.shareQueue.async {
            self.fetchParticipants(matching: lookupInfos, into: store) { participants, error in
                completion(participants, error)
            }
        }
    }

    func acceptShareInvitationsInBackground(
        from metadata: CKShare.Metadata,
        into store: NSPersistentStore,
        completion: @escaping @Sendable ((any Error)?) -> Void
    ) {
        nonisolated(unsafe) let store = store
        Self.shareQueue.async {
            self.acceptShareInvitations(from: [metadata], into: store) { _, error in
                completion(error)
            }
        }
    }
}
