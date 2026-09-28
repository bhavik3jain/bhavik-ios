import Core
import SwiftUI

public extension PointsTrackerModule {
    /// The Mac Overview's Points card: the whole household's balance, and
    /// anything about to expire.
    @MainActor
    static func overviewCard(accounts: [SharedPointsAccount], asOf now: Date = .now, open: @escaping () -> Void) -> some View {
        PointsOverviewCard(
            total: PointsTotal(accounts),
            accountCount: accounts.count,
            expiring: PointsSummary.expiringSoon(accounts, asOf: now).count,
            open: open
        )
    }
}

struct PointsOverviewCard: View {
    let total: PointsTotal
    let accountCount: Int
    let expiring: Int
    let open: () -> Void

    var body: some View {
        OverviewCard(accent: PointsTrackerModule.accent, icon: PointsTrackerModule.symbolName, open: open) {
            if accountCount == 0 {
                OverviewEmptyState("No accounts yet", message: "Add a loyalty programme in Accounts.")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    OverviewValue(total.summary)
                    OverviewCaption("Household balances · \(counted(accountCount, "account"))")
                    Spacer(minLength: 6)
                    if expiring > 0 {
                        OverviewFootnote("\(counted(expiring, "account")) expiring soon", symbol: "clock.badge.exclamationmark", tint: .orange)
                    }
                }
            }
        }
    }
}
