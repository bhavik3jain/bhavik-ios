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
                let summary = MonthSummary(month: latest, live: MetalPriceFeed.shared.live)
                let period = latest.period ?? YearMonth(containing: .now)
                let history = FinanceHistory(months: Array(latest.household?.months ?? []), live: MetalPriceFeed.shared.live)
                let delta = history.delta(.netWorth, at: period)
                let previous = history.point(before: period)?.period
                VStack(alignment: .leading, spacing: 4) {
                    OverviewValue(FinanceFormat.money(summary.netWorth))
                    Text(Self.holdings(in: latest))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let delta, let previous {
                        // "since August", not "on last month": the month
                        // before in the list may not be the calendar's.
                        Text("\(FinanceFormat.signedMoney(delta)) since \(previous.monthName)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(delta < 0 ? AnyShapeStyle(.red) : AnyShapeStyle(FinanceTrackerModule.accent.color))
                    }
                }
            } else {
                OverviewValue("No months yet")
            }
        }
        .task { await MetalPriceFeed.shared.refreshIfStale() }
    }

    /// "6 accounts · 4 cards": the accounts with a balance that month, and
    /// the household's cards still in use.
    private static func holdings(in month: SharedFinanceMonth) -> String {
        let accounts = Set((month.balances ?? []).compactMap(\.account).filter { $0.category != .card })
        let cards = (month.household?.accounts ?? []).filter { $0.category == .card && !$0.isArchived }
        return "\(counted(accounts.count, "account")) · \(counted(cards.count, "card"))"
    }
}
