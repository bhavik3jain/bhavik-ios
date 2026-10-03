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
            detail: latest.map { FinanceHome.reportedMonth(for: $0, live: MetalPriceFeed.shared.live).monthName } ?? "",
            open: open
        ) {
            if let latest {
                let live = MetalPriceFeed.shared.live
                // The last month filled in; see `FinanceHome.reportedMonth`.
                let reported = FinanceHome.reportedMonth(for: latest, live: live)
                let summary = MonthSummary(month: reported, live: live)
                let change = FinanceHome.netWorthChange(for: reported, live: live)
                VStack(alignment: .leading, spacing: 4) {
                    OverviewValue(FinanceFormat.money(summary.netWorth))
                    OverviewCaption("Net worth · \(Self.holdings(in: reported))")
                    Spacer(minLength: 6)
                    let mix = AssetMix(summary)
                    if !mix.shares.isEmpty {
                        mixBar(mix)
                        Text(mix.legend())
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.top, 3)
                            .padding(.bottom, change == nil ? 0 : 6)
                    }
                    if let change {
                        // "since August", not "on last month": the month
                        // before in the list may not be the calendar's.
                        OverviewFootnote(
                            "\(FinanceFormat.signedMoney(change.delta)) since \(change.previous.monthName)",
                            symbol: change.delta < 0 ? "arrow.down.right" : "arrow.up.right",
                            tint: change.delta < 0 ? .red : FinanceTrackerModule.accent.color
                        )
                    }
                }
            } else {
                OverviewEmptyState("No months yet", message: "Start this month's balance sheet in Finance.")
            }
        }
        .task { await MetalPriceFeed.shared.refreshIfStale() }
    }

    /// The month's assets as one bar, largest share first, in the accent at
    /// falling strengths — as Explore's card draws its guides.
    private func mixBar(_ mix: AssetMix) -> some View {
        let accent = FinanceTrackerModule.accent.color
        let strengths: [Double] = [1, 0.7, 0.45, 0.3, 0.2]
        return GeometryReader { proxy in
            let gaps = CGFloat(mix.shares.count - 1) * 3
            HStack(spacing: 3) {
                ForEach(Array(mix.shares.enumerated()), id: \.element.id) { index, share in
                    Capsule()
                        .fill(accent.opacity(strengths[min(index, strengths.count - 1)]))
                        .frame(width: max(4, (proxy.size.width - gaps) * share.fraction))
                        .help("\(share.metric.displayName) · \(FinanceFormat.money(share.amount))")
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    /// "6 accounts · 4 cards": the accounts with a balance that month, and
    /// the household's cards still in use.
    private static func holdings(in month: SharedFinanceMonth) -> String {
        let accounts = Set((month.balances ?? []).compactMap(\.account).filter { $0.category != .card })
        let cards = (month.household?.accounts ?? []).filter { $0.category == .card && !$0.isArchived }
        return "\(counted(accounts.count, "account")) · \(counted(cards.count, "card"))"
    }
}
