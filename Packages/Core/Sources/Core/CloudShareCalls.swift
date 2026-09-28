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
/// background, its main thread still parked in that wait.
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
        nonisolated(unsafe) let container = self
        Self.shareQueue.async {
            completion((try? container.fetchShares(matching: [objectID]))?[objectID])
        }
    }

    func shareInBackground(
        _ object: NSManagedObject,
        completion: @escaping @Sendable (CKShare?, CKContainer?, (any Error)?) -> Void
    ) {
        // Only the object's ID and entity are read off the main thread, and
        // both are immutable once the object has been saved.
        nonisolated(unsafe) let container = self
        nonisolated(unsafe) let object = object
        Self.shareQueue.async {
            container.share([object], to: nil) { _, share, ckContainer, error in
                completion(share, ckContainer, error)
            }
        }
    }

    func persistUpdatedShareInBackground(
        _ share: CKShare,
        in store: NSPersistentStore,
        completion: @escaping @Sendable (CKShare?, (any Error)?) -> Void = { _, _ in }
    ) {
        nonisolated(unsafe) let container = self
        nonisolated(unsafe) let share = share
        nonisolated(unsafe) let store = store
        Self.shareQueue.async {
            container.persistUpdatedShare(share, in: store) { saved, error in
                completion(saved, error)
            }
        }
    }

    func fetchParticipantsInBackground(
        matching lookupInfos: [CKUserIdentity.LookupInfo],
        into store: NSPersistentStore,
        completion: @escaping @Sendable ([CKShare.Participant]?, (any Error)?) -> Void
    ) {
        nonisolated(unsafe) let container = self
        nonisolated(unsafe) let store = store
        nonisolated(unsafe) let lookupInfos = lookupInfos
        Self.shareQueue.async {
            container.fetchParticipants(matching: lookupInfos, into: store) { participants, error in
                completion(participants, error)
            }
        }
    }

    func acceptShareInvitationsInBackground(
        from metadata: CKShare.Metadata,
        into store: NSPersistentStore,
        completion: @escaping @Sendable ((any Error)?) -> Void
    ) {
        nonisolated(unsafe) let container = self
        nonisolated(unsafe) let metadata = metadata
        nonisolated(unsafe) let store = store
        Self.shareQueue.async {
            container.acceptShareInvitations(from: [metadata], into: store) { _, error in
                completion(error)
            }
        }
    }
}
