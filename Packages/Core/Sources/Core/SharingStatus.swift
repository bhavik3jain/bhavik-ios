import CloudKit
import CoreData

/// Whether an object participates in a `CKShare`, and if so, this device's
/// relationship to it. Purely descriptive: nothing here mutates a share or an
/// object, so a view can show a "Shared" badge or an owner/participant label
/// without importing CloudKit itself.
public enum SharingStatus: Equatable {
    case notShared
    /// This device owns the share. `participantCount` is
    /// `CKShare.participants.count`, which includes the owner.
    case owned(participantCount: Int)
    case sharedWithMe(role: CKShare.ParticipantRole, permission: CKShare.ParticipantPermission)
}

public enum SharingStatusResolver {
    /// Looks up whether `object` participates in a `CKShare` at all, and if so
    /// whether the current device is the owner or a participant.
    ///
    /// Returns `.notShared` if the object isn't shared, if it has no
    /// `currentUserParticipant` (shouldn't happen for a share this device can
    /// see, but read as unshared rather than guess), or if the lookup itself
    /// fails — CloudKit unreachable, no iCloud account, the object not yet
    /// saved (`fetchShares(matching:)` simply omits an unsaved object's ID
    /// from the result rather than throwing, per its own header comment, so
    /// that case falls out of the same `nil` check). Sharing status is
    /// cosmetic UI, never something to crash or block editing over.
    @MainActor
    public static func status(for object: NSManagedObject, in container: NSPersistentCloudKitContainer) -> SharingStatus {
        guard let shares = try? container.fetchShares(matching: [object.objectID]),
              let share = shares[object.objectID],
              let currentUser = share.currentUserParticipant else {
            return .notShared
        }
        if currentUser.role == .owner {
            return .owned(participantCount: share.participants.count)
        }
        return .sharedWithMe(role: currentUser.role, permission: currentUser.permission)
    }

    /// Whether the current user can edit `object` right now — wraps
    /// `NSPersistentCloudKitContainer.canUpdateRecord(forManagedObjectWith:)`.
    ///
    /// That method already defaults permissively on its own (its header
    /// comment lists a temporary objectID, a store not backed by CloudKit, or
    /// the private database as all returning `true` unconditionally), so
    /// there's no error path to catch here — the permissive default this
    /// method's own doc comment promises falls straight out of Apple's own
    /// implementation for every case that matters to an object that was never
    /// shared.
    @MainActor
    public static func canEdit(_ object: NSManagedObject, in container: NSPersistentCloudKitContainer) -> Bool {
        container.canUpdateRecord(forManagedObjectWith: object.objectID)
    }
}
