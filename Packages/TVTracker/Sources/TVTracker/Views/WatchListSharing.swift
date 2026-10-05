import Core
import CoreData

/// Sharing-status text for a watch list, for its row and its screen. `nil`
/// says nothing: a list nobody else has shows no badge.
extension SharingStatus {
    var watchListBadgeLabel: String? {
        switch self {
        case .notShared:
            return nil
        case .owned(let participantCount):
            // `participantCount` includes this device's own user.
            let others = max(participantCount - 1, 0)
            return others == 0 ? "Shared" : "Shared with \(counted(others, "person", plural: "people"))"
        case .sharedWithMe(_, let permission):
            return permission == .readOnly ? "Shared with you · View only" : "Shared with you"
        }
    }
}

/// Whose a list is, read off the store it lives in — never off CloudKit.
///
/// A list in the private store is this person's own, shared or not; one in
/// the shared store arrived through someone else's share. That's what
/// decides Delete or Leave, and it must not wait on iCloud: the badge's
/// `SharingStatusResolver.badgeStatus` is `.notShared` until its first
/// lookup lands, which would offer a partner's list a Delete for a moment.
enum WatchListOwnership {
    @MainActor
    static func isOwn(_ list: SharedWatchList, in container: NSPersistentCloudKitContainer?) -> Bool {
        guard let container, let store = list.objectID.persistentStore else { return true }
        return store == container.privatePersistentStore
    }

    @MainActor
    static func canEdit(_ object: NSManagedObject, in container: NSPersistentCloudKitContainer?) -> Bool {
        guard let container else { return true }
        return SharingStatusResolver.canEdit(object, in: container)
    }
}
