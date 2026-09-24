import CoreData
import Foundation

/// The CKShare root: everything in Points belongs to one household. Sharing
/// it hands a partner every person, account and balance inside it.
@objc(SharedPointsHousehold)
public final class SharedPointsHousehold: NSManagedObject, Identifiable {
    @NSManaged public var name: String
    @NSManaged public var createdAt: Date

    @NSManaged public var owners: Set<SharedPointsOwner>?
    @NSManaged public var accounts: Set<SharedPointsAccount>?

    public convenience init(context: NSManagedObjectContext, name: String = "Household") {
        let entity = NSEntityDescription.entity(forEntityName: PointsModel.EntityName.household, in: context)!
        self.init(entity: entity, insertInto: context)
        self.name = name
        self.createdAt = .now
    }

    @nonobjc public static func fetchRequest(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<SharedPointsHousehold> {
        let request = NSFetchRequest<SharedPointsHousehold>(entityName: PointsModel.EntityName.household)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return request
    }
}

/// Someone in the household who holds loyalty accounts.
@objc(SharedPointsOwner)
public final class SharedPointsOwner: NSManagedObject, Identifiable {
    @NSManaged public var name: String
    @NSManaged public var createdAt: Date

    @NSManaged public var household: SharedPointsHousehold?
    @NSManaged public var accounts: Set<SharedPointsAccount>?

    /// Inserted into the household's own store: Core Data can't relate
    /// objects across stores, and a household shared with this device lives
    /// in the shared one.
    public convenience init(name: String, household: SharedPointsHousehold) {
        let context = household.managedObjectContext!
        let entity = NSEntityDescription.entity(forEntityName: PointsModel.EntityName.owner, in: context)!
        self.init(entity: entity, insertInto: context)
        context.assignToStore(of: household, self)
        self.name = name
        self.createdAt = .now
        self.household = household
    }

    @nonobjc public static func fetchRequest(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<SharedPointsOwner> {
        let request = NSFetchRequest<SharedPointsOwner>(entityName: PointsModel.EntityName.owner)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return request
    }
}

/// One loyalty account: a card's rewards, a hotel programme, an airline's
/// frequent-flyer miles.
@objc(SharedPointsAccount)
public final class SharedPointsAccount: NSManagedObject, Identifiable {
    /// What the reader calls it — "Sapphire Reserve", "Bonvoy".
    @NSManaged public var name: String
    /// The programme behind it, if that differs from the name — "Ultimate Rewards".
    @NSManaged public var program: String
    @NSManaged public var kindRaw: String
    @NSManaged public var balance: Int
    @NSManaged public var memberNumber: String
    /// Elite tier, for hotels and airlines — "Platinum", "Gold".
    @NSManaged public var status: String
    @NSManaged public var expiresAt: Date?
    @NSManaged public var notes: String
    @NSManaged public var createdAt: Date
    /// When the balance was last confirmed, which is what makes a figure
    /// trustworthy — not when the account was last edited.
    @NSManaged public var balanceUpdatedAt: Date

    @NSManaged public var household: SharedPointsHousehold?
    @NSManaged public var owner: SharedPointsOwner?
    @NSManaged public var entries: Set<SharedPointsEntry>?

    public convenience init(name: String, kind: PointsKind, household: SharedPointsHousehold, owner: SharedPointsOwner? = nil) {
        let context = household.managedObjectContext!
        let entity = NSEntityDescription.entity(forEntityName: PointsModel.EntityName.account, in: context)!
        self.init(entity: entity, insertInto: context)
        context.assignToStore(of: household, self)
        self.name = name
        self.kindRaw = kind.rawValue
        self.createdAt = .now
        self.balanceUpdatedAt = .now
        self.household = household
        self.owner = owner
    }

    @nonobjc public static func fetchRequest(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<SharedPointsAccount> {
        let request = NSFetchRequest<SharedPointsAccount>(entityName: PointsModel.EntityName.account)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return request
    }
}

/// A balance as it stood at one moment, so an account shows how it got here.
@objc(SharedPointsEntry)
public final class SharedPointsEntry: NSManagedObject, Identifiable {
    @NSManaged public var recordedAt: Date
    @NSManaged public var balance: Int
    /// Difference from the balance before, kept so deleting an older entry
    /// can't change what a later one says happened.
    @NSManaged public var delta: Int
    @NSManaged public var note: String

    @NSManaged public var account: SharedPointsAccount?

    convenience init(account: SharedPointsAccount, balance: Int, delta: Int, note: String, recordedAt: Date) {
        let context = account.managedObjectContext!
        let entity = NSEntityDescription.entity(forEntityName: PointsModel.EntityName.entry, in: context)!
        self.init(entity: entity, insertInto: context)
        context.assignToStore(of: account, self)
        self.balance = balance
        self.delta = delta
        self.note = note
        self.recordedAt = recordedAt
        self.account = account
    }

    @nonobjc public static func fetchRequest(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<SharedPointsEntry> {
        let request = NSFetchRequest<SharedPointsEntry>(entityName: PointsModel.EntityName.entry)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return request
    }
}

extension NSManagedObjectContext {
    /// Puts a new object in the same store as the one it hangs off. Left to
    /// itself Core Data puts every new object in the first store — the private
    /// one — and a person or account added to a household shared *with* this
    /// device would then fail to save as a cross-store relationship.
    func assignToStore(of existing: NSManagedObject, _ new: NSManagedObject) {
        // A temporary ID has no store yet. Making it permanent fixes the store
        // `existing` was itself assigned to — without this, an entry logged
        // on a just-created account in a shared household went private.
        if existing.objectID.isTemporaryID {
            try? obtainPermanentIDs(for: [existing])
        }
        guard let store = existing.objectID.persistentStore else { return }
        assign(new, to: store)
    }
}

// MARK: - Behaviour

public extension SharedPointsHousehold {
    var id: NSManagedObjectID { objectID }

    var sortedOwners: [SharedPointsOwner] {
        (owners ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

public extension SharedPointsOwner {
    var id: NSManagedObjectID { objectID }
}

public extension SharedPointsEntry {
    var id: NSManagedObjectID { objectID }
}

public extension SharedPointsAccount {
    var id: NSManagedObjectID { objectID }

    var kind: PointsKind {
        get { PointsKind(rawValue: kindRaw) ?? .creditCard }
        set { kindRaw = newValue.rawValue }
    }

    /// The name, or the programme when no name was given.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? program : trimmed
    }

    /// Newest first.
    var orderedHistory: [SharedPointsEntry] {
        (entries ?? []).sorted { $0.recordedAt > $1.recordedAt }
    }

    /// Sets a new balance and logs it. An unchanged balance is still a fresh
    /// confirmation, so it moves `balanceUpdatedAt` without adding a history
    /// row — except the very first, since an empty history reads as never
    /// checked.
    func recordBalance(_ newBalance: Int, note: String = "", asOf now: Date = .now) {
        balanceUpdatedAt = now
        guard newBalance != balance || (entries ?? []).isEmpty else { return }
        _ = SharedPointsEntry(account: self, balance: newBalance, delta: newBalance - balance, note: note, recordedAt: now)
        balance = newBalance
    }

    /// Deletes history entries, keeping `balance` in step with what's left.
    /// Deleting the newest entry is how a mistyped update gets undone; left
    /// alone, the header and totals kept showing the deleted figure and the
    /// next update's change was worked out from it.
    func deleteEntries(_ doomed: [SharedPointsEntry]) {
        guard let context = managedObjectContext else { return }
        let ids = Set(doomed.map(\.objectID))
        let remaining = orderedHistory.filter { !ids.contains($0.objectID) }
        doomed.forEach(context.delete)
        balance = remaining.first?.balance ?? 0
    }

    /// Whether the balance expires within `days`, counting an expiry already
    /// passed as soon too — it still needs dealing with.
    func expiresSoon(within days: Int = 90, asOf now: Date = .now) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(TimeInterval(days) * 86_400)
    }
}
