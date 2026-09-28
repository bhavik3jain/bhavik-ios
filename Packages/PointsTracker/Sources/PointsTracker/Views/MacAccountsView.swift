import Core
import CoreData
import SwiftUI

/// Points on the Mac: the household's totals as three cards, then every
/// account in a sortable table — the Mac's way to show rows with columns,
/// where the phone's grouped list, stretched across a window, put each
/// balance a foot away from its name. Sorting by a column stands in for the
/// phone's Person / Type grouping. Double-click (or Return) opens an account.
struct MacAccountsView: View {
    let accounts: [SharedPointsAccount]
    let open: (SharedPointsAccount) -> Void

    @State private var sortOrder = [KeyPathComparator(\SharedPointsAccount.balance, order: .reverse)]
    @State private var selection: SharedPointsAccount.ID?

    private var rows: [SharedPointsAccount] { accounts.sorted(using: sortOrder) }

    var body: some View {
        let total = PointsTotal(accounts)
        let expiring = PointsSummary.expiringSoon(accounts)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                MacStatCard(title: "Points", value: total.points.formatted(), detail: counted(accounts.count { $0.kind.unit == .points }, "account"), symbol: "star.circle.fill", tint: PointsKind.creditCard.color)
                MacStatCard(title: "Miles", value: total.miles.formatted(), detail: counted(accounts.count { $0.kind.unit == .miles }, "airline"), symbol: "airplane.circle.fill", tint: PointsKind.airline.color)
                MacStatCard(
                    title: "Expiring soon",
                    value: expiring.isEmpty ? "None" : String(expiring.count),
                    detail: expiring.first.flatMap { account in account.expiresAt.map { "\(account.displayName) · \($0.formatted(.dateTime.month(.abbreviated).day()))" } } ?? "Nothing in the next 90 days",
                    symbol: "clock.badge.exclamationmark.fill",
                    tint: expiring.isEmpty ? .secondary : .orange
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Account", value: \.displayName) { account in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.displayName.isEmpty ? "Untitled" : account.displayName)
                            if !account.program.isEmpty, account.program != account.displayName {
                                Text(account.program)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: account.kind.symbolName)
                            .foregroundStyle(account.kind.color)
                    }
                }
                .width(min: 180, ideal: 260)
                TableColumn("Person", value: \.ownerName)
                    .width(min: 80, ideal: 110)
                TableColumn("Type", value: \.kindName)
                    .width(min: 70, ideal: 90)
                TableColumn("Balance", value: \.balance) { account in
                    Text("\(account.balance.formatted()) \(account.kind.unit.abbreviation)")
                        .monospacedDigit()
                }
                .width(min: 100, ideal: 130)
                .alignment(.numeric)
                TableColumn("Updated", value: \.balanceUpdatedAt) { account in
                    Text(account.balanceUpdatedAt.formatted(.relative(presentation: .named)))
                        .foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 110)
                TableColumn("Expires", value: \.expirySortKey) { account in
                    if let expiresAt = account.expiresAt {
                        Text(expiresAt.formatted(.dateTime.month(.abbreviated).day().year()))
                            .foregroundStyle(account.expiresSoon() ? Color.orange : Color.secondary)
                    }
                }
                .width(min: 90, ideal: 110)
            }
            // No blank striped rows filling the space under the last one.
            .tableRowBackgroundsPlain()
            .contextMenu(forSelectionType: SharedPointsAccount.ID.self) { _ in
            } primaryAction: { ids in
                if let id = ids.first, let account = accounts.first(where: { $0.id == id }) { open(account) }
            }
        }
    }
}

extension SharedPointsAccount {
    /// For the Mac table's sortable columns.
    var ownerName: String { owner?.name ?? PointsSummary.unassigned }
    var kindName: String { kind.displayName }
    /// No expiry sorts last, as "never".
    var expirySortKey: Date { expiresAt ?? .distantFuture }
}
