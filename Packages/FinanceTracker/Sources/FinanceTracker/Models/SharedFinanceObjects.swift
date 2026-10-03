import CoreData
import Foundation

/// The CKShare root: everything in Finance belongs to one household. Sharing
/// it hands a partner every person, account, month and transaction inside it.
@objc(SharedFinanceHousehold)
public final class SharedFinanceHousehold: NSManagedObject, Identifiable {
    @NSManaged public var name: String
    @NSManaged public var createdAt: Date

    @NSManaged public var owners: Set<SharedFinanceOwner>?
    @NSManaged public var accounts: Set<SharedFinanceAccount>?
    @NSManaged public var months: Set<SharedFinanceMonth>?
    @NSManaged public var metalItems: Set<SharedFinanceMetalItem>?
    @NSManaged public var transactions: Set<SharedFinanceTransaction>?

    public convenience init(context: NSManagedObjectContext, name: String = "Household") {
        let entity = NSEntityDescription.entity(forEntityName: FinanceModel.EntityName.household, in: context)!
        self.init(entity: entity, insertInto: context)
        self.name = name
        self.createdAt = .now
    }

    @nonobjc public static func fetchRequest(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<SharedFinanceHousehold> {
        let request = NSFetchRequest<SharedFinanceHousehold>(entityName: FinanceModel.EntityName.household)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return request
    }
}

/// Someone accounts and metals can belong to — a person, or "Joint".
@objc(SharedFinanceOwner)
public final class SharedFinanceOwner: NSManagedObject, Identifiable {
    @NSManaged public var name: String
    @NSManaged public var kindRaw: String
    @NSManaged public var sortOrder: Int
    @NSManaged public var createdAt: Date

    @NSManaged public var household: SharedFinanceHousehold?
    @NSManaged public var accounts: Set<SharedFinanceAccount>?
    @NSManaged public var metalItems: Set<SharedFinanceMetalItem>?

    /// Inserted into the household's own store: Core Data can't relate
    /// objects across stores, and a household shared with this device lives
    /// in the shared one.
    public convenience init(name: String, kind: OwnerKind = .person, household: SharedFinanceHousehold) {
        let context = household.managedObjectContext!
        let entity = NSEntityDescription.entity(forEntityName: FinanceModel.EntityName.owner, in: context)!
        self.init(entity: entity, insertInto: context)
        context.assignToStore(of: household, self)
        self.name = name
        self.kindRaw = kind.rawValue
        self.sortOrder = ((household.owners ?? []).map(\.sortOrder).max() ?? -1) + 1
        self.createdAt = .now
        self.household = household
    }

    @nonobjc public static func fetchRequest(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<SharedFinanceOwner> {
        let request = NSFetchRequest<SharedFinanceOwner>(entityName: FinanceModel.EntityName.owner)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return request
    }
}

/// One row of the balance sheet: a bank account, a brokerage, a 401(k), a
/// car, a credit card or a loan.
@objc(SharedFinanceAccount)
public final class SharedFinanceAccount: NSManagedObject, Identifiable {
    /// "Capital One", "Chase". May be empty.
    @NSManaged public var institution: String
    /// "Checkings", "Sapphire Preferred".
    @NSManaged public var name: String
    @NSManaged public var categoryRaw: String
    /// Credit limit, for cards.
    @NSManaged public var limit: Double
    /// Cards only.
    @NSManaged public var annualFee: Double
    @NSManaged public var sortOrder: Int
    /// Closed accounts stay for their history but stop rolling into new months.
    @NSManaged public var isArchived: Bool
    @NSManaged public var createdAt: Date

    @NSManaged public var household: SharedFinanceHousehold?
    @NSManaged public var owner: SharedFinanceOwner?
    @NSManaged public var balances: Set<SharedFinanceBalance>?
    /// For a card: everything charged to it.
    @NSManaged public var transactions: Set<SharedFinanceTransaction>?

    public convenience init(
        institution: String,
        name: String,
        category: AccountCategory,
        household: SharedFinanceHousehold,
        owner: SharedFinanceOwner? = nil
    ) {
        let context = household.managedObjectContext!
        let entity = NSEntityDescription.entity(forEntityName: FinanceModel.EntityName.account, in: context)!
        self.init(entity: entity, insertInto: context)
        context.assignToStore(of: household, self)
        self.institution = institution
        self.name = name
        self.categoryRaw = category.rawValue
        self.sortOrder = ((household.accounts ?? []).map(\.sortOrder).max() ?? -1) + 1
        self.createdAt = .now
        self.household = household
        self.owner = owner
    }

    @nonobjc public static func fetchRequest(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<SharedFinanceAccount> {
        let request = NSFetchRequest<SharedFinanceAccount>(entityName: FinanceModel.EntityName.account)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return request
    }
}

/// One month of the balance sheet: its metal prices, a balance per account
/// and its budgets. Card spend isn't stored — it's worked out from the
/// month's transactions.
@objc(SharedFinanceMonth)
public final class SharedFinanceMonth: NSManagedObject, Identifiable {
    /// "2026-09" — sortable as a string. See `YearMonth`.
    @NSManaged public var yearMonth: String
    @NSManaged public var goldPricePerOz: Double
    @NSManaged public var silverPricePerOz: Double
    /// Set by Close; nil while the month is still being filled in.
    @NSManaged public var closedAt: Date?
    @NSManaged public var createdAt: Date

    @NSManaged public var household: SharedFinanceHousehold?
    @NSManaged public var balances: Set<SharedFinanceBalance>?
    @NSManaged public var budgets: Set<SharedFinanceBudget>?

    public convenience init(period: YearMonth, household: SharedFinanceHousehold) {
        let context = household.managedObjectContext!
        let entity = NSEntityDescription.entity(forEntityName: FinanceModel.EntityName.month, in: context)!
        self.init(entity: entity, insertInto: context)
        context.assignToStore(of: household, self)
        self.yearMonth = period.rawValue
        self.createdAt = .now
        self.household = household
    }

    @nonobjc public static func fetchRequest(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<SharedFinanceMonth> {
        let request = NSFetchRequest<SharedFinanceMonth>(entityName: FinanceModel.EntityName.month)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return request
    }
}

/// What one account stood at in one month. Loans store remaining principal.
@objc(SharedFinanceBalance)
public final class SharedFinanceBalance: NSManagedObject, Identifiable {
    @NSManaged public var amount: Double
    /// False until someone has filled it in this month — a new month starts
    /// every balance at zero, not edited. The month's progress counts these.
    @NSManaged public var edited: Bool

    @NSManaged public var account: SharedFinanceAccount?
    @NSManaged public var month: SharedFinanceMonth?

    public convenience init(account: SharedFinanceAccount, month: SharedFinanceMonth, amount: Double, edited: Bool) {
        let context = month.managedObjectContext!
        let entity = NSEntityDescription.entity(forEntityName: FinanceModel.EntityName.balance, in: context)!
        self.init(entity: entity, insertInto: context)
        context.assignToStore(of: month, self)
        self.amount = amount
        self.edited = edited
        self.account = account
        self.month = month
    }

    @nonobjc public static func fetchRequest(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<SharedFinanceBalance> {
        let request = NSFetchRequest<SharedFinanceBalance>(entityName: FinanceModel.EntityName.balance)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return request
    }
}

/// A piece of gold or silver: a bar, a coin, a chain. Weight is always
/// stored in grams, whatever it was typed in.
@objc(SharedFinanceMetalItem)
public final class SharedFinanceMetalItem: NSManagedObject, Identifiable {
    @NSManaged public var name: String
    @NSManaged public var metalRaw: String
    @NSManaged public var grams: Double
    /// Free text — "Locker", "Home".
    @NSManaged public var location: String
    /// 0 means unknown.
    @NSManaged public var pricePaidPerOz: Double
    /// What it cost in total; 0 means unknown.
    @NSManaged public var purchaseValue: Double
    /// Used instead of weight × price when `hasManualValue` — a ring with
    /// stones is worth more than its gold.
    @NSManaged public var manualValue: Double
    @NSManaged public var hasManualValue: Bool
    @NSManaged public var sortOrder: Int
    @NSManaged public var createdAt: Date

    @NSManaged public var household: SharedFinanceHousehold?
    @NSManaged public var owner: SharedFinanceOwner?

    public convenience init(
        name: String,
        metal: MetalKind,
        grams: Double,
        household: SharedFinanceHousehold,
        owner: SharedFinanceOwner? = nil
    ) {
        let context = household.managedObjectContext!
        let entity = NSEntityDescription.entity(forEntityName: FinanceModel.EntityName.metalItem, in: context)!
        self.init(entity: entity, insertInto: context)
        context.assignToStore(of: household, self)
        self.name = name
        self.metalRaw = metal.rawValue
        self.grams = grams
        self.sortOrder = ((household.metalItems ?? []).map(\.sortOrder).max() ?? -1) + 1
        self.createdAt = .now
        self.household = household
        self.owner = owner
    }

    @nonobjc public static func fetchRequest(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<SharedFinanceMetalItem> {
        let request = NSFetchRequest<SharedFinanceMetalItem>(entityName: FinanceModel.EntityName.metalItem)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return request
    }
}

/// One charge on a card. The month it counts towards is the month its date
/// falls in — there's no link to a `SharedFinanceMonth`.
@objc(SharedFinanceTransaction)
public final class SharedFinanceTransaction: NSManagedObject, Identifiable {
    @NSManaged public var date: Date
    /// What the statement says. Negative for a refund.
    @NSManaged public var cost: Double
    /// The part that's ours — equal to `cost` unless a friend owes some of it.
    /// This is the figure every total uses.
    @NSManaged public var actualCost: Double
    @NSManaged public var merchant: String
    /// Free text; the editor suggests the ones already used.
    @NSManaged public var category: String
    /// What it was for.
    @NSManaged public var expense: String
    @NSManaged public var breakDown: String
    @NSManaged public var createdAt: Date

    @NSManaged public var household: SharedFinanceHousehold?
    @NSManaged public var card: SharedFinanceAccount?

    public convenience init(
        date: Date,
        cost: Double,
        merchant: String,
        household: SharedFinanceHousehold,
        card: SharedFinanceAccount? = nil
    ) {
        let context = household.managedObjectContext!
        let entity = NSEntityDescription.entity(forEntityName: FinanceModel.EntityName.transaction, in: context)!
        self.init(entity: entity, insertInto: context)
        context.assignToStore(of: household, self)
        self.date = date
        self.cost = cost
        self.actualCost = cost
        self.merchant = merchant
        self.createdAt = .now
        self.household = household
        self.card = card
    }

    @nonobjc public static func fetchRequest(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<SharedFinanceTransaction> {
        let request = NSFetchRequest<SharedFinanceTransaction>(entityName: FinanceModel.EntityName.transaction)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return request
    }
}

/// A spending limit for one category in one month.
@objc(SharedFinanceBudget)
public final class SharedFinanceBudget: NSManagedObject, Identifiable {
    @NSManaged public var category: String
    @NSManaged public var limit: Double

    @NSManaged public var month: SharedFinanceMonth?

    public convenience init(category: String, limit: Double, month: SharedFinanceMonth) {
        let context = month.managedObjectContext!
        let entity = NSEntityDescription.entity(forEntityName: FinanceModel.EntityName.budget, in: context)!
        self.init(entity: entity, insertInto: context)
        context.assignToStore(of: month, self)
        self.category = category
        self.limit = limit
        self.month = month
    }

    @nonobjc public static func fetchRequest(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<SharedFinanceBudget> {
        let request = NSFetchRequest<SharedFinanceBudget>(entityName: FinanceModel.EntityName.budget)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return request
    }
}

extension NSManagedObjectContext {
    /// Puts a new object in the same store as the one it hangs off. Left to
    /// itself Core Data puts every new object in the first store — the private
    /// one — and anything added to a household shared *with* this device
    /// would then fail to save as a cross-store relationship.
    func assignToStore(of existing: NSManagedObject, _ new: NSManagedObject) {
        // A temporary ID has no store yet. Making it permanent fixes the store
        // `existing` was itself assigned to — without this, a balance added
        // to a just-created month in a shared household went private.
        if existing.objectID.isTemporaryID {
            try? obtainPermanentIDs(for: [existing])
        }
        guard let store = existing.objectID.persistentStore else { return }
        assign(new, to: store)
    }
}
