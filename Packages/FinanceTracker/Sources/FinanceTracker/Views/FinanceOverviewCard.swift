import Core
import CoreData
import SwiftUI

public extension FinanceTrackerModule {
    /// The Mac Overview's Finance card: the latest month's net worth and how
    /// it moved on the month before. `container` picks the household the
    /// module shows — see `FinanceHome.latestMonth`.
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
                let summary = MonthSummary(month: latest)
                let delta = FinanceHistory(months: Array(latest.household?.months ?? []))
                    .delta(.netWorth, at: latest.period ?? YearMonth(containing: .now))
                VStack(alignment: .leading, spacing: 4) {
                    OverviewValue(FinanceFormat.money(summary.netWorth))
                    Text("Net worth · \(FinanceFormat.money(summary.cardSpend)) on the cards")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let delta {
                        Text("\(FinanceFormat.signedMoney(delta)) on last month")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(delta < 0 ? AnyShapeStyle(.red) : AnyShapeStyle(FinanceTrackerModule.accent.color))
                    }
                }
            } else {
                OverviewValue("No months yet")
            }
        }
    }
}
