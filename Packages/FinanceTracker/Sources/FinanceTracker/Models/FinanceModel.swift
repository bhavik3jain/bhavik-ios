import CoreData
import Foundation

/// Builds the Core Data model behind Finance, by hand rather than a
/// `.xcdatamodeld`, the same as `PointsModel` and for the same reasons.
///
/// Core Data rather than SwiftData because the module is shareable with a
/// partner via `CKShare`, which SwiftData has no support for at all. The
/// CKShare root is the **household**: people, accounts, months, metals and
/// transactions all hang off one, so a single share hands over the whole
/// balance sheet and lets the other person type into it too.
///
/// | Swift class               | Core Data entity name       |
/// |---------------------------|-----------------------------|
/// | `SharedFinanceHousehold`  | `SharedFinanceHousehold`    |
/// | `SharedFinanceOwner`      | `SharedFinanceOwner`        |
/// | `SharedFinanceAccount`    | `SharedFinanceAccount`      |
/// | `SharedFinanceMonth`      | `SharedFinanceMonth`        |
/// | `SharedFinanceBalance`    | `SharedFinanceBalance`      |
/// | `SharedFinanceMetalItem`  | `SharedFinanceMetalItem`    |
/// | `SharedFinanceTransaction`| `SharedFinanceTransaction`  |
/// | `SharedFinanceBudget`     | `SharedFinanceBudget`       |
///
/// Entity names are CloudKit record types (`CD_` + name) and must never be
/// renamed once in Production — that orphans every record already there.
/// Adding an entity or attribute needs the Console schema ritual (README →
/// Data and sync); `CloudKitSchemaInitializer` has to list this model.
///
/// CloudKit's rules, all followed here: every attribute optional or
/// defaulted, every relationship optional with an inverse, no unique
/// constraints (the importer de-duplicates by hand).
public enum FinanceModel {
    enum EntityName {
        static let household = "SharedFinanceHousehold"
        static let owner = "SharedFinanceOwner"
        static let account = "SharedFinanceAccount"
        static let month = "SharedFinanceMonth"
        static let balance = "SharedFinanceBalance"
        static let metalItem = "SharedFinanceMetalItem"
        static let transaction = "SharedFinanceTransaction"
        static let budget = "SharedFinanceBudget"
    }

    @MainActor
    public static func make() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let household = entity(EntityName.household, SharedFinanceHousehold.self)
        let owner = entity(EntityName.owner, SharedFinanceOwner.self)
        let account = entity(EntityName.account, SharedFinanceAccount.self)
        let month = entity(EntityName.month, SharedFinanceMonth.self)
        let balance = entity(EntityName.balance, SharedFinanceBalance.self)
        let metal = entity(EntityName.metalItem, SharedFinanceMetalItem.self)
        let transaction = entity(EntityName.transaction, SharedFinanceTransaction.self)
        let budget = entity(EntityName.budget, SharedFinanceBudget.self)

        household.properties = [
            string("name", default: ""),
            date("createdAt", optional: false, default: .now),
        ]
        owner.properties = [
            string("name", default: ""),
            string("kindRaw", default: OwnerKind.person.rawValue),
            integer("sortOrder", default: 0),
            date("createdAt", optional: false, default: .now),
        ]
        account.properties = [
            string("institution", default: ""),
            string("name", default: ""),
            string("categoryRaw", default: AccountCategory.cash.rawValue),
            double("limit", default: 0),
            double("annualFee", default: 0),
            integer("sortOrder", default: 0),
            boolean("isArchived", default: false),
            date("createdAt", optional: false, default: .now),
        ]
        month.properties = [
            string("yearMonth", default: ""),
            double("goldPricePerOz", default: 0),
            double("silverPricePerOz", default: 0),
            date("closedAt"),
            date("createdAt", optional: false, default: .now),
        ]
        balance.properties = [
            double("amount", default: 0),
            boolean("edited", default: false),
        ]
        metal.properties = [
            string("name", default: ""),
            string("metalRaw", default: MetalKind.gold.rawValue),
            double("grams", default: 0),
            string("location", default: ""),
            double("pricePaidPerOz", default: 0),
            double("purchaseValue", default: 0),
            double("manualValue", default: 0),
            boolean("hasManualValue", default: false),
            integer("sortOrder", default: 0),
            date("createdAt", optional: false, default: .now),
        ]
        transaction.properties = [
            date("date", optional: false, default: .now),
            double("cost", default: 0),
            double("actualCost", default: 0),
            string("merchant", default: ""),
            string("category", default: ""),
            string("expense", default: ""),
            string("breakDown", default: ""),
            date("createdAt", optional: false, default: .now),
        ]
        budget.properties = [
            string("category", default: ""),
            double("limit", default: 0),
        ]

        // Both sides of every pair carry `inverseRelationship` — Core Data
        // throws "no inverse relationship" at container load otherwise.
        let (owners, ownerHousehold) = toManyPair("owners", inverse: "household", from: household, to: owner, rule: .cascadeDeleteRule)
        let (accounts, accountHousehold) = toManyPair("accounts", inverse: "household", from: household, to: account, rule: .cascadeDeleteRule)
        let (months, monthHousehold) = toManyPair("months", inverse: "household", from: household, to: month, rule: .cascadeDeleteRule)
        let (metalItems, metalHousehold) = toManyPair("metalItems", inverse: "household", from: household, to: metal, rule: .cascadeDeleteRule)
        let (transactions, transactionHousehold) = toManyPair("transactions", inverse: "household", from: household, to: transaction, rule: .cascadeDeleteRule)
        // Nullify: removing a person must never throw away what they held —
        // those accounts and metals just lose their owner badge.
        let (ownerAccounts, accountOwner) = toManyPair("accounts", inverse: "owner", from: owner, to: account, rule: .nullifyDeleteRule)
        let (ownerMetals, metalOwner) = toManyPair("metalItems", inverse: "owner", from: owner, to: metal, rule: .nullifyDeleteRule)
        let (accountBalances, balanceAccount) = toManyPair("balances", inverse: "account", from: account, to: balance, rule: .cascadeDeleteRule)
        // A card's transactions go with it; the delete confirmation says how many.
        let (cardTransactions, transactionCard) = toManyPair("transactions", inverse: "card", from: account, to: transaction, rule: .cascadeDeleteRule)
        let (monthBalances, balanceMonth) = toManyPair("balances", inverse: "month", from: month, to: balance, rule: .cascadeDeleteRule)
        let (monthBudgets, budgetMonth) = toManyPair("budgets", inverse: "month", from: month, to: budget, rule: .cascadeDeleteRule)

        household.properties += [owners, accounts, months, metalItems, transactions]
        owner.properties += [ownerHousehold, ownerAccounts, ownerMetals]
        account.properties += [accountHousehold, accountOwner, accountBalances, cardTransactions]
        month.properties += [monthHousehold, monthBalances, monthBudgets]
        balance.properties += [balanceAccount, balanceMonth]
        metal.properties += [metalHousehold, metalOwner]
        transaction.properties += [transactionHousehold, transactionCard]
        budget.properties += [budgetMonth]

        model.entities = [household, owner, account, month, balance, metal, transaction, budget]
        return model
    }

    // MARK: - Builders

    private static func entity(_ name: String, _ type: NSManagedObject.Type) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = name
        entity.managedObjectClassName = NSStringFromClass(type)
        return entity
    }

    private static func string(_ name: String, default value: String) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .stringAttributeType
        attribute.isOptional = false
        attribute.defaultValue = value
        return attribute
    }

    private static func date(_ name: String, optional: Bool = true, default value: Date? = nil) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .dateAttributeType
        attribute.isOptional = optional
        attribute.defaultValue = value
        return attribute
    }

    private static func integer(_ name: String, default value: Int) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .integer64AttributeType
        attribute.isOptional = false
        attribute.defaultValue = value
        return attribute
    }

    private static func double(_ name: String, default value: Double) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .doubleAttributeType
        attribute.isOptional = false
        attribute.defaultValue = value
        return attribute
    }

    private static func boolean(_ name: String, default value: Bool) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .booleanAttributeType
        attribute.isOptional = false
        attribute.defaultValue = value
        return attribute
    }

    private static func toManyPair(
        _ name: String,
        inverse inverseName: String,
        from: NSEntityDescription,
        to: NSEntityDescription,
        rule: NSDeleteRule
    ) -> (toMany: NSRelationshipDescription, toOne: NSRelationshipDescription) {
        let toMany = NSRelationshipDescription()
        toMany.name = name
        toMany.destinationEntity = to
        toMany.minCount = 0
        toMany.maxCount = 0 // 0 means "to-many" to Core Data.
        toMany.deleteRule = rule
        toMany.isOptional = true

        let toOne = NSRelationshipDescription()
        toOne.name = inverseName
        toOne.destinationEntity = from
        toOne.minCount = 0
        toOne.maxCount = 1
        toOne.deleteRule = .nullifyDeleteRule
        toOne.isOptional = true

        toMany.inverseRelationship = toOne
        toOne.inverseRelationship = toMany
        return (toMany, toOne)
    }
}
