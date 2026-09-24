import Core
import SwiftUI

public extension PointsTrackerModule {
    /// What long-pressing Points on the home screen shows: each person's
    /// totals, and anything about to expire.
    @MainActor
    static func homePeek(accounts: [SharedPointsAccount]) -> some View {
        PointsHomePeek(
            sections: PointsSummary.sections(accounts, by: .owner),
            expiring: PointsSummary.expiringSoon(accounts)
        )
    }

    /// The home screen's one-line summary.
    static func homeDetail(accounts: [SharedPointsAccount]) -> String {
        PointsSummary.homeDetail(for: accounts)
    }
}

struct PointsHomePeek: View {
    let sections: [PointsSection]
    let expiring: [SharedPointsAccount]

    var body: some View {
        ModulePeekCard(
            accent: PointsTrackerModule.accent,
            icon: "star.circle.fill",
            subtitle: expiring.isEmpty ? "" : "\(counted(expiring.count, "account")) expiring soon"
        ) {
            if sections.isEmpty {
                PeekEmpty("No accounts yet.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(sections.prefix(4)) { section in
                        PeekRow(
                            section.title,
                            detail: counted(section.accounts.count, "account"),
                            value: section.total.summary,
                            tint: PointsTrackerModule.accent.color
                        )
                    }
                    ForEach(expiring.prefix(2)) { account in
                        PeekRow(
                            account.displayName,
                            detail: account.owner?.name ?? PointsSummary.unassigned,
                            value: account.expiresAt?.formatted(.dateTime.month(.abbreviated).day()) ?? "",
                            tint: .orange
                        )
                    }
                }
            }
        }
    }
}
