import Core
import CoreData
import SwiftUI

/// Holdings' accounts on the Mac: one table, a section per category with its
/// total, and this month beside last so a moved balance stands out. The
/// phone's list put each account in its own full-width card, one figure a
/// window-width from its name. Double-click edits.
struct MacHoldingsView: View {
    let snapshot: FinanceSnapshot
    let isEditable: Bool
    let edit: (SharedFinanceAccount) -> Void
    let delete: (SharedFinanceAccount) -> Void
    let toggleArchived: (SharedFinanceAccount) -> Void

    @State private var selection: NSManagedObjectID?

    private var latest: SharedFinanceMonth? { snapshot.latestMonth }
    private var previous: SharedFinanceMonth? { snapshot.months.dropLast().last }

    var body: some View {
        Table(of: SharedFinanceAccount.self, selection: $selection) {
            TableColumn("Account") { account in
                HStack(spacing: 8) {
                    OwnerBadge(owner: account.owner)
                    Text(account.displayName.isEmpty ? "Untitled" : account.displayName)
                        .lineLimit(1)
                    if account.isArchived {
                        Text("Archived")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .opacity(account.isArchived ? 0.6 : 1)
            }
            .width(min: 200, ideal: 300)
            TableColumn("Person") { account in
                Text(account.owner?.name ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 100)
            // Last month and the change only once there is one: a household's
            // first month showed two columns of dashes.
            if let previous {
                TableColumn(previous.title) { account in
                    Text(FinanceFormat.money(account.value(in: previous)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .alignment(.numeric)
            }
            TableColumn(latest?.title ?? "This month") { account in
                Text(FinanceFormat.money(value(of: account)))
                    .fontWeight(.medium)
                    .monospacedDigit()
            }
            .alignment(.numeric)
            if let previous {
                TableColumn("Change") { account in
                    DeltaText(
                        delta: value(of: account) - account.value(in: previous),
                        upIsGood: !account.category.isLiability
                    )
                }
                .alignment(.numeric)
            }
        } rows: {
            ForEach(AccountCategory.allCases) { category in
                let accounts = snapshot.accounts.filter { $0.category == category }
                if !accounts.isEmpty {
                    Section {
                        ForEach(accounts) { TableRow($0) }
                    } header: {
                        HStack {
                            Text(category.displayName)
                            Spacer()
                            Text(FinanceFormat.money(accounts.reduce(0) { $0 + value(of: $1) }))
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .tableRowBackgroundsPlain()
        .contextMenu(forSelectionType: NSManagedObjectID.self) { ids in
            if isEditable, let account = account(for: ids) {
                Button("Edit…", systemImage: "pencil") { edit(account) }
                Button(account.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox") {
                    toggleArchived(account)
                }
                Divider()
                Button("Delete…", systemImage: "trash", role: .destructive) { delete(account) }
            }
        } primaryAction: { ids in
            if isEditable, let account = account(for: ids) { edit(account) }
        }
    }

    private func value(of account: SharedFinanceAccount) -> Double {
        latest.map { account.value(in: $0) } ?? 0
    }

    private func account(for ids: Set<NSManagedObjectID>) -> SharedFinanceAccount? {
        ids.first.flatMap { id in snapshot.accounts.first { $0.objectID == id } }
    }
}
