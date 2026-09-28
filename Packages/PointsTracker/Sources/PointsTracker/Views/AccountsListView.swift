import Core
import CoreData
import SwiftUI

struct AccountsListView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.pointsPersistentContainer) private var container

    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \SharedPointsAccount.createdAt, ascending: true)])
    private var accountResults: FetchedResults<SharedPointsAccount>
    private var accounts: [SharedPointsAccount] { Array(accountResults) }

    @AppStorage("points.grouping") private var groupingRaw = PointsGrouping.owner.rawValue
    @State private var showingAdd = false

    private var grouping: PointsGrouping { PointsGrouping(rawValue: groupingRaw) ?? .owner }
    private var sections: [PointsSection] { PointsSummary.sections(accounts, by: grouping) }
    private var expiring: [SharedPointsAccount] { PointsSummary.expiringSoon(accounts) }

    var body: some View {
        NavigationStack {
            Group {
                if accounts.isEmpty {
                    ContentUnavailableView {
                        Label("No accounts", systemImage: "star.circle")
                    } description: {
                        Text("Add a credit card, hotel or airline programme to keep its balance in one place.")
                    } actions: {
                        Button("Add Account") { showingAdd = true }
                            .primaryActionStyle(tint: PointsTrackerModule.accent.color)
                    }
                    .scrollsForRefresh()
                } else {
                    List {
                        Section {
                            Picker("Group by", selection: $groupingRaw) {
                                ForEach(PointsGrouping.allCases) { option in
                                    Text(option.displayName).tag(option.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                        }

                        if !expiring.isEmpty {
                            Section("Expiring soon") {
                                ForEach(expiring) { account in
                                    row(for: account, showsOwner: true)
                                }
                            }
                        }

                        ForEach(sections) { section in
                            Section {
                                ForEach(section.accounts) { account in
                                    row(for: account, showsOwner: grouping == .kind)
                                }
                                .onDelete { delete(section.accounts, at: $0) }
                            } header: {
                                HStack {
                                    PointsSectionTitle(section: section)
                                    Spacer()
                                    Text(section.total.summary)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                }
            }
            .refreshesFromCloud()
            .navigationTitle("Points")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Account")
                }
                ToolbarItem(placement: .secondaryAction) {
                    ShareHouseholdButton()
                }
            }
            .sheet(isPresented: $showingAdd) {
                AccountEditorView(account: nil)
            }
        }
    }

    private func row(for account: SharedPointsAccount, showsOwner: Bool) -> some View {
        NavigationLink {
            AccountDetailView(account: account)
        } label: {
            AccountRow(account: account, showsOwner: showsOwner)
        }
    }

    private func delete(_ source: [SharedPointsAccount], at offsets: IndexSet) {
        // A view-only participant's swipe is dropped rather than hidden —
        // `onDelete` offers the gesture to every row alike.
        for index in offsets where canEdit(source[index], in: container) {
            context.delete(source[index])
        }
        try? context.saveIfNeeded()
    }
}

/// A section's title, with its kind's icon in its colour when it's one kind.
struct PointsSectionTitle: View {
    let section: PointsSection

    var body: some View {
        if let kind = section.kind {
            Label {
                Text(section.title)
            } icon: {
                Image(systemName: kind.symbolName)
                    .foregroundStyle(kind.color)
            }
        } else {
            Text(section.title)
        }
    }
}

struct AccountRow: View {
    @ObservedObject var account: SharedPointsAccount
    let showsOwner: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: account.kind.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(account.kind.color, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName.isEmpty ? "Untitled" : account.displayName)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(account.balance.formatted())
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text(account.kind.unit.abbreviation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        var parts: [String] = []
        if showsOwner { parts.append(account.owner?.name ?? PointsSummary.unassigned) }
        if !account.program.isEmpty, account.program != account.displayName { parts.append(account.program) }
        if !account.status.isEmpty { parts.append(account.status) }
        if let expiresAt = account.expiresAt, account.expiresSoon() {
            parts.append("\(expiresAt < .now ? "expired" : "expires") \(expiresAt.formatted(.dateTime.month(.abbreviated).day()))")
        }
        return parts.joined(separator: " · ")
    }
}
