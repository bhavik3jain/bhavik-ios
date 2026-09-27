import Core
import CoreData
import Foundation

public extension FinanceTrackerModule {
    /// Finance's wording for Core's shared-change notifications — see
    /// `SharedChangeNotifier`, which `BhavikApp` hands this to. The root is
    /// always the household.
    ///
    /// Never an amount: a notification shows on the lock screen, and a
    /// balance or a charge is nobody else's business.
    static func describeSharedChange(_ object: NSManagedObject, _ change: SharedObjectChange) -> SharedChangeDescription? {
        let inserted = change.kind == .inserted
        switch object {
        case let household as SharedFinanceHousehold:
            return description(household, inserted ? "shared \(householdName(household))" : "updated \(householdName(household))")

        case let owner as SharedFinanceOwner:
            guard let household = owner.household else { return nil }
            let name = named(owner.name, fallback: "someone")
            return description(household, inserted ? "added \(name)" : "changed \(name)")

        case let account as SharedFinanceAccount:
            guard let household = account.household else { return nil }
            let name = named(account.name, fallback: "an account")
            return description(household, inserted ? "added \(name)" : "changed \(name)")

        case let month as SharedFinanceMonth:
            guard let household = month.household else { return nil }
            let title = month.period?.title ?? "a month"
            let action: String
            if inserted {
                action = "started \(title)"
            } else if change.updatedProperties.contains("closedAt") {
                action = month.closedAt == nil ? "reopened \(title)" : "closed \(title)"
            } else {
                action = "updated \(title)"
            }
            return description(household, action)

        case let balance as SharedFinanceBalance:
            guard let household = balance.month?.household ?? balance.account?.household else { return nil }
            let name = named(balance.account?.name ?? "", fallback: "a balance")
            let month = balance.month?.period.map { " for \($0.title)" } ?? ""
            return description(household, "updated \(name)\(month)")

        case let budget as SharedFinanceBudget:
            guard let household = budget.month?.household else { return nil }
            // "the", never "a", in front of the category: a hard-coded "a"
            // read "set a Entertainment budget" for any category starting
            // with a vowel. A blank category still reads "set the budget".
            let category = budget.category.trimmingCharacters(in: .whitespacesAndNewlines)
            let budgetName = category.isEmpty ? "budget" : "\(category) budget"
            let month = budget.month?.period.map { " for \($0.title)" } ?? ""
            return description(household, inserted ? "set the \(budgetName)\(month)" : "changed the \(budgetName)\(month)")

        case let item as SharedFinanceMetalItem:
            guard let household = item.household else { return nil }
            let name = named(item.name, fallback: "a metal item")
            return description(household, inserted ? "added \(name)" : "changed \(name)")

        case let transaction as SharedFinanceTransaction:
            guard let household = transaction.household ?? transaction.card?.household else { return nil }
            let merchant = transaction.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
            // The merchant goes after "at", never after an article: "a \(merchant)
            // transaction" read "added a Amazon transaction" on the lock screen.
            let what = merchant.isEmpty ? "a transaction" : "a transaction at \(merchant)"
            return description(household, inserted ? "added \(what)" : "changed \(what)")

        default:
            return nil
        }
    }

    private static func description(_ household: SharedFinanceHousehold, _ action: String) -> SharedChangeDescription {
        SharedChangeDescription(rootID: household.objectID, rootTitle: householdName(household), action: action)
    }

    private static func householdName(_ household: SharedFinanceHousehold) -> String {
        named(household.name, fallback: "Household")
    }

    private static func named(_ text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
