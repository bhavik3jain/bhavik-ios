import Core
import CoreData
import Foundation

/// Which household Finance shows, and which new things go into.
///
/// Named apart from Points' `HouseholdResolver` because the app shell imports
/// both modules, and two public types of one name would make either
/// ambiguous there.
///
/// Normally there's exactly one: this person's own, created (with the default
/// owners) the first time anything is added. Accepting a partner's share adds
/// theirs alongside it, and from then on that's the one shown and typed into,
/// so both people are looking at the same balance sheet. Unlike Points,
/// households aren't merged on screen — two net worths added together would be
/// counting the same money twice.
public enum FinanceHouseholdResolver {
    /// Preference order: an editable household shared with this device, then
    /// this device's own oldest, then a new one in the private store.
    ///
    /// Two private households can exist if a second device added something
    /// before its first sync arrived; oldest-first means both devices settle
    /// on the same one once it does.
    @MainActor
    public static func forWriting(in context: NSManagedObjectContext, container: NSPersistentCloudKitContainer?) -> SharedFinanceHousehold {
        let households = fetchAll(in: context)
        if let container, let privateStore = container.privatePersistentStore {
            let sharedWithMe = households.first {
                $0.objectID.persistentStore != privateStore && SharingStatusResolver.canEdit($0, in: container)
            }
            if let sharedWithMe { return sharedWithMe }
        }
        return own(in: context, container: container, among: households)
    }

    /// The household the screens show, without ever creating one: a
    /// partner's shared with this device (editable first, then view-only),
    /// else this device's own oldest. nil before anything has been added.
    ///
    /// Agrees with `forWriting` whenever the reader can edit, so something
    /// just added always appears. A view-only participant sees the partner's
    /// household, with the edit controls hidden.
    @MainActor
    public static func forDisplay(
        among households: [SharedFinanceHousehold],
        container: NSPersistentCloudKitContainer?
    ) -> SharedFinanceHousehold? {
        let oldestFirst = households.sorted { $0.createdAt < $1.createdAt }
        guard let container, let privateStore = container.privatePersistentStore else {
            return oldestFirst.first
        }
        let shared = oldestFirst.filter { $0.objectID.persistentStore != privateStore }
        if let editable = shared.first(where: { SharingStatusResolver.canEdit($0, in: container) }) {
            return editable
        }
        if let viewOnly = shared.first(where: { !$0.isEmpty }) {
            return viewOnly
        }
        return oldestFirst.first(where: { $0.objectID.persistentStore == privateStore }) ?? oldestFirst.first
    }

    /// This device's own household — the one it can share, rather than one a
    /// partner shared with it. Share with Partner goes through this, not
    /// `forWriting`: once a partner's share was accepted, `forWriting` hands
    /// back *their* household, and Points learned the hard way that sharing
    /// that one opens their share as a mere participant.
    @MainActor
    public static func own(in context: NSManagedObjectContext, container: NSPersistentCloudKitContainer?) -> SharedFinanceHousehold {
        own(in: context, container: container, among: fetchAll(in: context))
    }

    @MainActor
    private static func fetchAll(in context: NSManagedObjectContext) -> [SharedFinanceHousehold] {
        (try? context.fetch(SharedFinanceHousehold.fetchRequest(
            sortDescriptors: [NSSortDescriptor(keyPath: \SharedFinanceHousehold.createdAt, ascending: true)]
        ))) ?? []
    }

    @MainActor
    private static func own(
        in context: NSManagedObjectContext,
        container: NSPersistentCloudKitContainer?,
        among households: [SharedFinanceHousehold]
    ) -> SharedFinanceHousehold {
        let privateStore = container?.privatePersistentStore
        if let own = households.first(where: { privateStore == nil || $0.objectID.persistentStore == privateStore }) {
            return own
        }

        // `name:` must be spelled out. A bare `SharedFinanceHousehold(context:)`
        // resolves to NSManagedObject's inherited `init(context:)` rather than
        // our defaulted `init(context:name:)` — Swift prefers the overload with
        // no defaulted arguments — so the body never runs: `name`/`createdAt`
        // are left unset, and the entity is looked up by class name, logging
        // "Failed to find a unique match for an NSEntityDescription" once a
        // second copy of FinanceModel is loaded (the tests, the schema run).
        // Points hit exactly this.
        let household = SharedFinanceHousehold(context: context, name: "Household")
        if let privateStore {
            context.assign(household, to: privateStore)
        }
        try? context.obtainPermanentIDs(for: [household])
        household.addDefaultOwners()
        return household
    }
}
