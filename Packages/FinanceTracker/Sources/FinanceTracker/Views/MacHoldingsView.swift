import Core
import CoreData
import SwiftUI

/// Holdings' accounts on the Mac: one table, a section per category with its
/// total, person by person within it and by institution under each person,
/// and this month beside last so a moved balance stands out. A table can't
/// nest sections, so a person's name shows on their first row only. The
/// phone's list put each account in its own full-width card, one figure a
/// window-width from its name. Double-click edits.
struct MacHoldingsView: View {
    let snapshot: FinanceSnapshot
    let isEditable: Bool
    let edit: (SharedFinanceAccount) -> Void
    let delete: (SharedFinanceAccount) -> Void
    let toggleArchived: (SharedFinanceAccount) -> Void

    @State private var selection: NSManagedObjectID?

    /// The last month filled in, against the one before it. Against the
    /// latest, a half-filled October read "−$144,100" beside every account
    /// not yet typed in. See `FinanceHome.reportedMonth`.
    private var latest: SharedFinanceMonth? { snapshot.reportedMonth }
    private var previous: SharedFinanceMonth? { latest?.previousMonth }

    var body: some View {
        let grouped = AccountCategory.allCases.map { category in
            (category, AccountGrouping.byOwner(snapshot.accounts.filter { $0.category == category }))
        }
        let firstOfGroup = Set(grouped.flatMap { $0.1.compactMap(\.accounts.first?.objectID) })
        Table(of: SharedFinanceAccount.self, selection: $selection) {
            TableColumn("Person") { account in
                if firstOfGroup.contains(account.objectID) {
                    HStack(spacing: 6) {
                        OwnerBadge(owner: account.owner)
                        Text(account.owner?.name ?? "No one")
                            .fontWeight(.medium)
                    }
                }
            }
            .width(min: 90, ideal: 120)
            TableColumn("Institution") { account in
                Text(account.institution)
                    .opacity(account.isArchived ? 0.6 : 1)
            }
            .width(min: 100, ideal: 160)
            TableColumn("Account") { account in
                HStack(spacing: 8) {
                    Text(account.name.isEmpty ? "Untitled" : account.name)
                        .lineLimit(1)
                    if account.isArchived {
                        Text("Archived")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .opacity(account.isArchived ? 0.6 : 1)
            }
            .width(min: 140, ideal: 200)
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
            ForEach(grouped, id: \.0) { category, groups in
                let accounts = groups.flatMap(\.accounts)
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
