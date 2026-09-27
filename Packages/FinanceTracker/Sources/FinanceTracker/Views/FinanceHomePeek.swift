import Core
import CoreData
import SwiftUI

public extension FinanceTrackerModule {
    /// What long-pressing Finance on the home screen shows: the latest net
    /// worth, how far through typing in its month we are, and what's gone on
    /// the cards. `container` picks the household the module shows — see
    /// `FinanceHome.latestMonth`.
    @MainActor
    static func homePeek(months: [SharedFinanceMonth], container: NSPersistentCloudKitContainer?) -> some View {
        FinanceHomePeek(latest: FinanceHome.latestMonth(months, container: container))
    }

    /// The home screen's one-line summary: "Net worth $557,506".
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
            subtitle: latest?.title ?? ""
        ) {
            if let latest {
                let summary = MonthSummary(month: latest)
                let delta = FinanceHistory(months: Array(latest.household?.months ?? [])).delta(.netWorth, at: latest.period ?? YearMonth(containing: .now))
                VStack(alignment: .leading, spacing: 12) {
                    PeekRow(
                        "Net worth",
                        detail: delta.map { "\(FinanceFormat.signedMoney($0)) on last month" } ?? "",
                        value: FinanceFormat.money(summary.netWorth),
                        tint: FinanceTrackerModule.accent.color
                    )
                    if !latest.isClosed {
                        PeekRow(
                            "\(latest.monthName) in progress",
                            detail: MonthRollover.progress(of: latest).label
                        )
                    }
                    PeekRow(
                        "Card spend",
                        detail: latest.monthName,
                        value: FinanceFormat.money(summary.cardSpend)
                    )
                }
            } else {
                PeekEmpty("No months yet.")
            }
        }
    }
}
