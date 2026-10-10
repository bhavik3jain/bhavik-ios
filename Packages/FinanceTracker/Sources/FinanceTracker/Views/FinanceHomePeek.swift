import Core
import CoreData
import SwiftUI

public extension FinanceTrackerModule {
    /// What long-pressing Finance on the home screen shows: the net worth,
    /// then investments, cash and retirement, from the last month filled in
    /// (`FinanceHome.reportedMonth`). The hub row itself shows only spending —
    /// see `FinanceHome.homeDetail`. `container` picks the household the
    /// module shows — see `FinanceHome.latestMonth`.
    @MainActor
    static func homePeek(months: [SharedFinanceMonth], container: NSPersistentCloudKitContainer?) -> some View {
        FinanceHomePeek(latest: FinanceHome.latestMonth(months, container: container))
    }

    /// The home screen's one-line summary: "October · $2,345 spent".
    @MainActor
    static func homeDetail(months: [SharedFinanceMonth], container: NSPersistentCloudKitContainer?) -> String {
        FinanceHome.homeDetail(for: months, container: container)
    }

    /// Whether the peek's menu offers Add Transaction: the household the
    /// module shows (`FinanceHouseholdResolver.forDisplay`) has a card or cash
    /// account to pay with, and this person may add to it. Never before a
    /// household exists — the editor adds to one, it doesn't make one, and
    /// making one waits for iCloud (`financeCanCreateHousehold`).
    @MainActor
    static func canAddTransaction(context: NSManagedObjectContext?, container: NSPersistentCloudKitContainer?) -> Bool {
        guard let context else { return false }
        let households = (try? context.fetch(SharedFinanceHousehold.fetchRequest())) ?? []
        guard let household = FinanceHouseholdResolver.forDisplay(among: households, container: container) else { return false }
        let canPay = (household.accounts ?? []).contains { $0.category.takesTransactions && !$0.isArchived }
        return canPay && canEdit(household, in: container)
    }

    /// The transaction editor on its own, for the peek's Add Transaction:
    /// over the home screen, without opening the module. It gets Finance's
    /// store here as `rootView` does — the hub's own `managedObjectContext`
    /// is Trips'.
    @MainActor
    static func addTransactionView(context: NSManagedObjectContext, container: NSPersistentCloudKitContainer) -> some View {
        TransactionEditorView(transaction: nil, defaultDate: .now)
            .environment(\.managedObjectContext, context)
            .environment(\.financePersistentContainer, container)
            .tint(accent.color)
    }
}

struct FinanceHomePeek: View {
    let latest: SharedFinanceMonth?

    var body: some View {
        ModulePeekCard(
            accent: FinanceTrackerModule.accent,
            icon: FinanceTrackerModule.symbolName,
            subtitle: latest.map { FinanceHome.reportedMonth(for: $0, live: MetalPriceFeed.shared.live).title } ?? ""
        ) {
            if let latest {
                // Net worth from the last month filled in; see
                // `FinanceHome.reportedMonth`.
                let reported = FinanceHome.reportedMonth(for: latest, live: MetalPriceFeed.shared.live)
                let summary = MonthSummary(month: reported, live: MetalPriceFeed.shared.live)
                let delta = FinanceHistory(months: Array(latest.household?.months ?? []), live: MetalPriceFeed.shared.live).delta(.netWorth, at: reported.period ?? YearMonth(containing: .now))
                VStack(alignment: .leading, spacing: 12) {
                    PeekRow(
                        "Net worth",
                        detail: delta.map { "\(FinanceFormat.signedMoney($0)) on last month" } ?? "",
                        value: FinanceFormat.money(summary.netWorth),
                        tint: FinanceTrackerModule.accent.color
                    )
                    PeekRow("Investments", value: FinanceFormat.money(summary.investments))
                    PeekRow("Cash", value: FinanceFormat.money(summary.cash))
                    PeekRow("Retirement", value: FinanceFormat.money(summary.retirement))
                }
            } else {
                PeekEmpty("No months yet.")
            }
        }
        .task { await MetalPriceFeed.shared.refreshIfStale() }
    }
}
