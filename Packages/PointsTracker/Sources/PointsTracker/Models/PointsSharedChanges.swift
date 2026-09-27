import Core
import CoreData
import Foundation

public extension PointsTrackerModule {
    /// Points' wording for Core's shared-change notifications — see
    /// `SharedChangeNotifier`, which `BhavikApp` hands this to. The root is
    /// always the household.
    static func describeSharedChange(_ object: NSManagedObject, _ change: SharedObjectChange) -> SharedChangeDescription? {
        let inserted = change.kind == .inserted
        switch object {
        case let household as SharedPointsHousehold:
            let action = inserted ? "shared \(householdName(household))" : "updated \(householdName(household))"
            return description(household, action)

        case let owner as SharedPointsOwner:
            guard let household = owner.household else { return nil }
            let name = named(owner.name, fallback: "someone")
            return description(household, inserted ? "added \(name)" : "changed \(name)")

        case let account as SharedPointsAccount:
            guard let household = account.household else { return nil }
            // A new balance also writes a SharedPointsEntry, which says it
            // better; confirming an unchanged one only moves the date.
            if !inserted, change.updatedProperties.isSubset(of: ["balance", "balanceUpdatedAt"]) { return nil }
            let name = named(account.name, fallback: "an account")
            return description(household, inserted ? "added \(name)" : "changed \(name)")

        case let entry as SharedPointsEntry:
            guard let account = entry.account, let household = account.household else { return nil }
            let name = named(account.name, fallback: "an account")
            guard inserted else { return description(household, "changed the history of \(name)") }
            let unit = account.kind.unit.singular
            let balance = "\(entry.balance.formatted()) \(entry.balance == 1 ? unit : unit + "s")"
            return description(household, "updated \(name) to \(balance)")

        default:
            return nil
        }
    }

    private static func description(_ household: SharedPointsHousehold, _ action: String) -> SharedChangeDescription {
        SharedChangeDescription(rootID: household.objectID, rootTitle: householdName(household), action: action)
    }

    private static func householdName(_ household: SharedPointsHousehold) -> String {
        named(household.name, fallback: "Household")
    }

    private static func named(_ text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
