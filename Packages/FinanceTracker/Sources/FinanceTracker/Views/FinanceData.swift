import Core
import CoreData
import SwiftUI

/// Every Finance entity, fetched together so any change anywhere re-renders
/// the screen that reads it. The screens add things up across relationships
/// (a month's balances, a card's transactions), and a relationship read alone
/// never tells SwiftUI to redraw: a balance typed on the month screen left
/// the Summary's net worth stale until something else moved.
@MainActor
struct FinanceFetches: DynamicProperty {
    @Environment(\.financePersistentContainer) private var container
    @Environment(\.financeCanCreateHousehold) private var canCreateHousehold

    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \SharedFinanceHousehold.createdAt, ascending: true)])
    private var households: FetchedResults<SharedFinanceHousehold>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \SharedFinanceOwner.sortOrder, ascending: true)])
    private var owners: FetchedResults<SharedFinanceOwner>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \SharedFinanceAccount.sortOrder, ascending: true)])
    private var accounts: FetchedResults<SharedFinanceAccount>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \SharedFinanceMonth.yearMonth, ascending: true)])
    private var months: FetchedResults<SharedFinanceMonth>
    @FetchRequest(sortDescriptors: [])
    private var balances: FetchedResults<SharedFinanceBalance>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \SharedFinanceMetalItem.sortOrder, ascending: true)])
    private var metals: FetchedResults<SharedFinanceMetalItem>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \SharedFinanceTransaction.date, ascending: false)])
    private var transactions: FetchedResults<SharedFinanceTransaction>
    @FetchRequest(sortDescriptors: [])
    private var budgets: FetchedResults<SharedFinanceBudget>

    /// The shown household's slice of everything. See
    /// `FinanceHouseholdResolver.forDisplay` for which household that is.
    var snapshot: FinanceSnapshot {
        let household = FinanceHouseholdResolver.forDisplay(among: Array(households), container: container)
        return FinanceSnapshot(
            household: household,
            owners: owners.filter { $0.household == household }.sorted(by: SharedFinanceOwner.displayOrder),
            accounts: accounts.filter { $0.household == household }.sorted(by: SharedFinanceAccount.displayOrder),
            // One per period until `FinanceFold` has folded a duplicate.
            months: FinanceFold.distinctMonths(months.filter { $0.household == household && $0.period != nil }),
            metals: metals.filter { $0.household == household }.sorted(by: SharedFinanceMetalItem.displayOrder),
            transactions: transactions.filter { $0.household == household },
            // With no household yet, adding anything would create one —
            // which waits for iCloud. See `financeCanCreateHousehold`.
            canEdit: household.map { canEdit($0, in: container) } ?? canCreateHousehold,
            // Read so a balance or budget edit counts as a change to this
            // view; the figures themselves come through the months.
            revision: balances.count &+ budgets.count,
            // Read here, in the body, so a fetch landing redraws the screen.
            live: MetalPriceFeed.shared.live
        )
    }
}

/// One household's data, ready for the screens.
struct FinanceSnapshot {
    let household: SharedFinanceHousehold?
    let owners: [SharedFinanceOwner]
    /// Category order, archived included.
    let accounts: [SharedFinanceAccount]
    /// Oldest first.
    let months: [SharedFinanceMonth]
    let metals: [SharedFinanceMetalItem]
    /// Newest first.
    let transactions: [SharedFinanceTransaction]
    /// Whether the reader can add to and change what's shown.
    let canEdit: Bool
    let revision: Int
    /// `MetalPriceFeed`'s prices, which value the latest month while it's open.
    let live: MetalPrices?

    /// Nothing here yet, and nothing can be added until iCloud has had its
    /// chance to bring an existing household in.
    var isWaitingForICloud: Bool { household == nil && !canEdit }

    var cards: [SharedFinanceAccount] { accounts.filter { $0.category == .card } }
    var latestMonth: SharedFinanceMonth? { months.last }

    func summary(for month: SharedFinanceMonth, filter: OwnerFilter = .all) -> MonthSummary {
        MonthSummary(month: month, cards: cards, metals: metals, filter: filter, live: live)
    }

    func history(filter: OwnerFilter = .all) -> FinanceHistory {
        FinanceHistory(months: months, filter: filter, live: live)
    }

    /// What the latest month's metals are valued at: live while it's open.
    var currentPrices: MetalPrices {
        latestMonth.map { MetalPriceFeed.effectivePrices(for: $0, live: live) } ?? live ?? MetalPrices()
    }

    func progress(of month: SharedFinanceMonth) -> MonthProgress {
        MonthRollover.progress(of: month, live: live)
    }

    /// Every location already used, for the metal editor's chips.
    var metalLocations: [String] {
        MetalHoldings.locations(metals).map(\.name)
    }
}
