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
    ///
    /// The error comes back as an error. This used to be `try?`, so a lookup
    /// that failed answered "no share", and Share went on to call `share()`
    /// for an object that might already be in one — each call a new zone.
    ///
    /// On a queue of its own, concurrent, not the serial one below: a lookup
    /// stuck behind a sync that never finishes held up every later Share tap
    /// queued after it, Try Again included.
    func lookUpShareInBackground(
        for objectID: NSManagedObjectID,
        completion: @escaping @Sendable (Result<CKShare?, any Error>) -> Void
    ) {
        Self.lookupQueue.async {
            completion(Result { try self.fetchShares(matching: [objectID])[objectID] })
        }
    }

    /// The record Core Data mirrors `objectID` to, from its local metadata —
    /// for Share's check for zones earlier tries left (`LeftoverShareZones`).
    /// On the lookup queue, for the same reason: it waits on the executor too
    /// ("Wait timed out during call to recordForManagedObjectID").
    func recordIDInBackground(
        for objectID: NSManagedObjectID,
        completion: @escaping @Sendable (CKRecord.ID?) -> Void
    ) {
        Self.lookupQueue.async {
            completion(self.recordID(for: objectID))
        }
    }

    private static let lookupQueue = DispatchQueue(
        label: "com.bhavikjain.trackers.cloud-share-lookup",
        qos: .userInitiated,
        attributes: .concurrent
    )

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

    /// The identifiers `CloudSyncMonitor`'s ledger knows this container's
    /// iCloud-backed stores by. Empty for an in-memory container.
    var cloudKitStoreIdentifiers: Set<String> {
        Set(persistentStoreDescriptions.compactMap { description -> String? in
            guard description.cloudKitContainerOptions != nil, let url = description.url else { return nil }
            return persistentStoreCoordinator.persistentStore(for: url)?.identifier
        })
    }

    /// The iCloud container this one mirrors, for CloudKit calls of its own.
    var cloudKitContainerIdentifier: String? {
        persistentStoreDescriptions.lazy.compactMap { $0.cloudKitContainerOptions?.containerIdentifier }.first
    }

    /// The CloudKit database `store` mirrors: an accepted share lives in the
    /// shared one, everything this person owns in the private one.
    func databaseScope(of store: NSPersistentStore) -> CKDatabase.Scope {
        persistentStoreDescriptions
            .first { $0.url == store.url }?
            .cloudKitContainerOptions?.databaseScope ?? .private
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
