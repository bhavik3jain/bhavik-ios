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
            VStack(alignment: .leading, spacing: 4) {
                if accountCount == 0 {
                    OverviewValue("No accounts")
                } else {
                    OverviewValue(total.summary)
                    Text("Household balances · \(counted(accountCount, "account"))")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if expiring > 0 {
                    Text("\(counted(expiring, "account")) expiring soon")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}
