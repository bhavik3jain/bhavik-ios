import Core
import CoreData
import SwiftUI

public extension FinanceTrackerModule {
    /// The Mac Overview's Finance card: the latest month's spending, as on
    /// the phone's hub row (`FinanceHome.homeDetail`) — never the net worth,
    /// which the Overview leaves on screen for anyone passing. `container`
    /// picks the household the module shows — see `FinanceHome.latestMonth`.
    @MainActor
    static func overviewCard(
        months: [SharedFinanceMonth],
        container: NSPersistentCloudKitContainer?,
        open: @escaping () -> Void
    ) -> some View {
        FinanceOverviewCard(latest: FinanceHome.latestMonth(months, container: container), open: open)
    }

    /// The short month beside Finance in the Mac sidebar: "Sep".
    @MainActor
    static func sidebarDetail(months: [SharedFinanceMonth], container: NSPersistentCloudKitContainer?) -> String? {
        FinanceHome.latestMonth(months, container: container)?.period?.start
            .formatted(.dateTime.month(.abbreviated))
    }
}

struct FinanceOverviewCard: View {
    let latest: SharedFinanceMonth?
    let open: () -> Void

    var body: some View {
        OverviewCard(
            accent: FinanceTrackerModule.accent,
            icon: FinanceTrackerModule.symbolName,
            detail: latest?.monthName ?? "",
            open: open
        ) {
            if let latest {
                let transactions = FinanceHome.transactions(in: latest)
                VStack(alignment: .leading, spacing: 4) {
                    OverviewValue(FinanceFormat.money(SpendingSummary.total(transactions)))
                    OverviewCaption("Spent in \(latest.monthName) · \(counted(transactions.count, "transaction"))")
                    Spacer(minLength: 6)
                    if let top = SpendingSummary.byCategory(transactions).first {
                        OverviewFootnote(
                            "Most on \(top.name) · \(FinanceFormat.money(top.total))",
                            symbol: "chart.pie",
                            tint: FinanceTrackerModule.accent.color
                        )
                    }
                }
            } else {
                OverviewEmptyState("No months yet", message: "Start this month's balance sheet in Finance.")
            }
        }
    }
}
