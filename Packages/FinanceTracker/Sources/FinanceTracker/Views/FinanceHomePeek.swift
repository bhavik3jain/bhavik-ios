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
