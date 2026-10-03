import CoreData
import Foundation

/// One person's accounts within a category — "Bhavik" under Cash — for the
/// month entry screen and Holdings.
struct AccountGroup: Identifiable {
    /// nil for accounts that belong to no one.
    let owner: SharedFinanceOwner?
    /// By institution, then name.
    let accounts: [SharedFinanceAccount]

    var id: String { owner.map { $0.objectID.uriRepresentation().absoluteString } ?? "no-one" }

    var title: String { owner?.name ?? "No one" }
}

enum AccountGrouping {
    /// `accounts` split by owner — people in their own order, accounts with
    /// no owner last — and each person's sorted by institution. Empty groups
    /// are left out.
    static func byOwner(_ accounts: [SharedFinanceAccount]) -> [AccountGroup] {
        let owners = Set(accounts.compactMap(\.owner)).sorted(by: SharedFinanceOwner.displayOrder)
        var groups = owners.map { owner in
            AccountGroup(
                owner: owner,
                accounts: accounts.filter { $0.owner == owner }.sorted(by: SharedFinanceAccount.institutionOrder)
            )
        }
        let unowned = accounts.filter { $0.owner == nil }
        if !unowned.isEmpty {
            groups.append(AccountGroup(owner: nil, accounts: unowned.sorted(by: SharedFinanceAccount.institutionOrder)))
        }
        return groups
    }

    /// The same accounts in one list, grouped as `byOwner` groups them: the
    /// order of a table that can't nest sections.
    static func ordered(_ accounts: [SharedFinanceAccount]) -> [SharedFinanceAccount] {
        byOwner(accounts).flatMap(\.accounts)
    }
}
