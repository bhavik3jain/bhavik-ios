import Core
import CoreData
import Foundation

/// Which household new people and accounts go into.
///
/// Normally there's exactly one: this person's own, created the first time
/// anything is added. Accepting a partner's share adds theirs alongside it,
/// and from then on new things go into the shared one so both people see
/// them. Everything already in the private household stays put and is still
/// listed — the app shows every household merged — it just isn't shared
/// unless that one is shared too.
public enum HouseholdResolver {
    /// Preference order: an editable household shared with this device, then
    /// this device's own oldest, then a new one in the private store.
    ///
    /// Two private households can exist if a second device added something
    /// before its first sync arrived; oldest-first means both devices settle
    /// on the same one once it does.
    @MainActor
    public static func forWriting(in context: NSManagedObjectContext, container: NSPersistentCloudKitContainer?) -> SharedPointsHousehold {
        let households = (try? context.fetch(SharedPointsHousehold.fetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \SharedPointsHousehold.createdAt, ascending: true)]
        ))) ?? []
        let privateStore = container?.privatePersistentStore

        if let container, let privateStore {
            let sharedWithMe = households.first {
                $0.objectID.persistentStore != privateStore && SharingStatusResolver.canEdit($0, in: container)
            }
            if let sharedWithMe { return sharedWithMe }
        }
        return own(in: context, container: container, among: households)
    }

    /// This device's own household — the one it can share, rather than one a
    /// partner shared with it. Share with Partner goes through this, not
    /// `forWriting`: once a partner's share was accepted, `forWriting` handed
    /// back *their* household, so the button opened their share as a mere
    /// participant and this person's own accounts could never be shared.
    @MainActor
    public static func own(in context: NSManagedObjectContext, container: NSPersistentCloudKitContainer?) -> SharedPointsHousehold {
        let households = (try? context.fetch(SharedPointsHousehold.fetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \SharedPointsHousehold.createdAt, ascending: true)]
        ))) ?? []
        return own(in: context, container: container, among: households)
    }

    @MainActor
    private static func own(
        in context: NSManagedObjectContext,
        container: NSPersistentCloudKitContainer?,
        among households: [SharedPointsHousehold]
    ) -> SharedPointsHousehold {
        let privateStore = container?.privatePersistentStore
        if let own = households.first(where: { privateStore == nil || $0.objectID.persistentStore == privateStore }) {
            return own
        }

        // `name:` must be spelled out. A bare `SharedPointsHousehold(context:)`
        // resolves to NSManagedObject's inherited `init(context:)` rather than
        // our defaulted `init(context:name:)` — Swift prefers the overload with
        // no defaulted arguments — so the body never ran: `name`/`createdAt`
        // were left unset, and the entity was looked up by class name, logging
        // "Failed to find a unique match for an NSEntityDescription" once a
        // second copy of PointsModel was loaded (the tests, the schema run).
        let household = SharedPointsHousehold(context: context, name: "Household")
        if let privateStore {
            context.assign(household, to: privateStore)
        }
        try? context.obtainPermanentIDs(for: [household])
        return household
    }
}
