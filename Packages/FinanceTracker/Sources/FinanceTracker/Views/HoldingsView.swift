import Core
import CoreData
import SwiftUI

/// What the household holds: every account by category, and the gold and
/// silver.
struct HoldingsView: View {
    @Environment(\.moduleLayout) private var layout
    @Environment(\.managedObjectContext) private var context
    @Environment(\.financePersistentContainer) private var container
    var data = FinanceFetches()

    private enum Mode: String, CaseIterable, Identifiable {
        case accounts = "Accounts"
        case metals = "Gold & silver"
        var id: String { rawValue }
    }

    @State private var mode = Mode.accounts
    @State private var collapsed: Set<AccountCategory> = []
    @State private var editingAccount: SharedFinanceAccount?
    @State private var addingAccount = false
    @State private var pendingDelete: SharedFinanceAccount?
    @State private var editingMetal: SharedFinanceMetalItem?
    @State private var addingMetal = false
    /// nil shows every location.
    @State private var locationFilter: String?
    @State private var showingPeople = false

    var body: some View {
        let snapshot = data.snapshot
        let isEditable = snapshot.canEdit
        NavigationStack {
            Group {
                if layout == .sidebar, mode == .accounts, !snapshot.accounts.isEmpty {
                    MacHoldingsView(
                        snapshot: snapshot,
                        isEditable: isEditable,
                        edit: { editingAccount = $0 },
                        delete: { pendingDelete = $0 },
                        toggleArchived: { account in
                            account.isArchived.toggle()
                            try? context.saveIfNeeded()
                        }
                    )
                    .navigationDestination(isPresented: $showingPeople) { OwnersView() }
                } else {
                    list(snapshot, isEditable: isEditable)
                }
            }
            .navigationTitle("Holdings")
            .toolbar {
                if layout == .sidebar {
                    ToolbarItem(placement: .primaryAction) {
                        Picker("View", selection: $mode) {
                            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                if layout == .sidebar, mode == .accounts, !snapshot.accounts.isEmpty {
                    // The phone's "people" row, which has no row to live in
                    // above a table.
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingPeople = true
                        } label: {
                            Label("People", systemImage: "person.2")
                        }
                        .help(sharingLabel(snapshot.household) ?? "Manage people and sharing")
                    }
                }
                if isEditable {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            switch mode {
                            case .accounts: addingAccount = true
                            case .metals: addingMetal = true
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(mode == .accounts ? "New Account" : "Add Gold or Silver")
                    }
                }
                ToolbarItem(placement: layout.secondaryToolbarPlacement) {
                    ShareHouseholdButton()
                }
            }
            .sheet(isPresented: $addingAccount) {
                AccountEditorView(account: nil)
            }
            .sheet(item: $editingAccount) { account in
                AccountEditorView(account: account)
            }
            .sheet(isPresented: $addingMetal) {
                MetalEditorView(item: nil)
            }
            .sheet(item: $editingMetal) { item in
                MetalEditorView(item: item)
            }
            .confirmationDialog(
                "Delete \(pendingDelete?.displayName ?? "account")?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Account", role: .destructive) {
                    if let pendingDelete { context.delete(pendingDelete) }
                    pendingDelete = nil
                    try? context.saveIfNeeded()
                }
            } message: {
                Text(deleteMessage(for: pendingDelete))
            }
        }
    }

    private func list(_ snapshot: FinanceSnapshot, isEditable: Bool) -> some View {
        List {
            // On the Mac this switch is in the toolbar, not a list row.
            if layout == .tabs {
                Section {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }

            switch mode {
            case .accounts:
                accountSections(snapshot, isEditable: isEditable)
            case .metals:
                metalSections(snapshot, isEditable: isEditable)
            }
        }
    }

    // MARK: - Accounts

    @ViewBuilder
    private func accountSections(_ snapshot: FinanceSnapshot, isEditable: Bool) -> some View {
        Section {
            NavigationLink {
                OwnersView()
            } label: {
                PeopleRow(owners: snapshot.owners, sharingLabel: sharingLabel(snapshot.household))
            }
        }

        if snapshot.accounts.isEmpty {
            Section {
                Text("Add each bank account, brokerage, retirement plan, car, card and loan once. Every month after that is just its balance.")
                    .foregroundStyle(.secondary)
            }
        }

        ForEach(AccountCategory.allCases) { category in
            let accounts = snapshot.accounts.filter { $0.category == category }
            if !accounts.isEmpty {
                let groups = AccountGrouping.byOwner(accounts)
                Section {
                    if !collapsed.contains(category) {
                        ForEach(groups) { group in
                            if group.owner != nil || groups.count > 1 {
                                OwnerGroupHeader(
                                    group: group,
                                    total: group.accounts.reduce(0) { $0 + value(of: $1, snapshot: snapshot) }
                                )
                                .listRowSeparator(.hidden, edges: .bottom)
                            }
                            ForEach(group.accounts) { account in
                                Button {
                                    if isEditable { editingAccount = account }
                                } label: {
                                    AccountRow(account: account, value: value(of: account, snapshot: snapshot))
                                }
                                .tint(.primary)
                                .swipeActions(edge: .trailing) {
                                    if isEditable {
                                        Button("Delete", systemImage: "trash", role: .destructive) {
                                            pendingDelete = account
                                        }
                                        Button(account.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox") {
                                            account.isArchived.toggle()
                                            try? context.saveIfNeeded()
                                        }
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Button {
                        withAnimation {
                            if collapsed.contains(category) {
                                collapsed.remove(category)
                            } else {
                                collapsed.insert(category)
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: collapsed.contains(category) ? "chevron.right" : "chevron.down")
                                .font(.caption.weight(.semibold))
                            Text(category.displayName)
                            Spacer()
                            Text(FinanceFormat.money(accounts.reduce(0) { $0 + value(of: $1, snapshot: snapshot) }))
                                .monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// The latest month's balance, or for a card the latest month's spend.
    private func value(of account: SharedFinanceAccount, snapshot: FinanceSnapshot) -> Double {
        guard let latest = snapshot.latestMonth else { return 0 }
        return account.value(in: latest)
    }

    private func sharingLabel(_ household: SharedFinanceHousehold?) -> String? {
        guard let household, let container else { return nil }
        return SharingStatusResolver.badgeStatus(for: household, in: container).householdBadgeLabel
    }

    private func deleteMessage(for account: SharedFinanceAccount?) -> String {
        guard let account else { return "" }
        if account.category == .card {
            let count = account.transactionCount
            return count == 0
                ? "The card has no transactions."
                : "Its \(counted(count, "transaction")) will be deleted too. Archive it instead to keep them."
        }
        return "Its balance in every month will be deleted too, changing past months' totals. Archive it instead to keep them."
    }

    // MARK: - Gold & silver

    @ViewBuilder
    private func metalSections(_ snapshot: FinanceSnapshot, isEditable: Bool) -> some View {
        let prices = snapshot.currentPrices
        let holdings = MetalHoldings(snapshot.metals, prices: prices)
        let locations = MetalHoldings.locations(snapshot.metals)
        let shown = snapshot.metals.filter { item in
            guard let locationFilter else { return true }
            return item.location.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(locationFilter) == .orderedSame
        }

        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Current value")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(FinanceFormat.money(holdings.value))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Paid").font(.caption).foregroundStyle(.secondary)
                        Text(FinanceFormat.money(holdings.paid)).monospacedDigit()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gain").font(.caption).foregroundStyle(.secondary)
                        DeltaText(delta: holdings.gain)
                    }
                }
                Text("Gain counts only the items with a cost recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }

        Section {
            LabeledContent("Gold", value: "\(FinanceFormat.cents(prices.gold)) / oz")
            LabeledContent("Silver", value: "\(FinanceFormat.cents(prices.silver)) / oz")
        } header: {
            Text(snapshot.latestMonth.map { "\($0.title) prices" } ?? "Prices")
        } footer: {
            Text("Change them on the month's page under Months.")
        }

        if !locations.isEmpty {
            Section {
                ChipRow {
                    FinanceChip(title: "All", detail: "\(snapshot.metals.count)", isSelected: locationFilter == nil) {
                        locationFilter = nil
                    }
                    ForEach(locations) { location in
                        FinanceChip(title: location.name, detail: "\(location.count)", isSelected: locationFilter == location.name) {
                            locationFilter = location.name
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }

        Section {
            if snapshot.metals.isEmpty {
                Text("Add each bar, coin or piece of jewellery with its weight; it's valued at the month's price.")
                    .foregroundStyle(.secondary)
            }
            ForEach(shown) { item in
                Button {
                    if isEditable { editingMetal = item }
                } label: {
                    MetalRow(item: item, prices: prices)
                }
                .tint(.primary)
                .swipeActions(edge: .trailing) {
                    if isEditable {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            context.delete(item)
                            try? context.saveIfNeeded()
                        }
                    }
                }
            }
        }
    }
}

private struct PeopleRow: View {
    let owners: [SharedFinanceOwner]
    let sharingLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: -4) {
                ForEach(owners) { owner in
                    OwnerBadge(owner: owner)
                }
                Text(owners.isEmpty ? "No people yet" : owners.map(\.name).joined(separator: ", "))
                    .lineLimit(1)
                    .padding(.leading, 12)
            }
            Text(sharingLabel ?? "Manage people and sharing")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct AccountRow: View {
    @ObservedObject var account: SharedFinanceAccount
    let value: Double

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                AccountNameText(account: account)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(FinanceFormat.money(value))
                .monospacedDigit()
                .foregroundStyle(account.isArchived ? Color.secondary : Color.primary)
        }
        .opacity(account.isArchived ? 0.6 : 1)
        .contentShape(Rectangle())
    }

    private var detail: String {
        var parts: [String] = []
        if account.isArchived { parts.append("Archived") }
        if account.category == .card {
            if account.limit > 0 { parts.append("Limit \(FinanceFormat.money(account.limit))") }
            if account.annualFee > 0 { parts.append("\(FinanceFormat.money(account.annualFee)) a year") }
        }
        return parts.joined(separator: " · ")
    }
}

private struct MetalRow: View {
    @ObservedObject var item: SharedFinanceMetalItem
    let prices: MetalPrices

    var body: some View {
        HStack(spacing: 10) {
            Text(item.metal.symbol)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(item.metal == .gold ? Color(red: 0.80, green: 0.62, blue: 0.16) : Color.gray, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name.isEmpty ? "Untitled" : item.name)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(FinanceFormat.money(item.value(at: prices)))
                    .monospacedDigit()
                if let gain = item.gain(at: prices) {
                    DeltaText(delta: gain)
                        .font(.caption)
                } else {
                    Text("No cost recorded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var detail: String {
        var parts = [FinanceFormat.grams(item.grams)]
        let location = item.location.trimmingCharacters(in: .whitespaces)
        if !location.isEmpty { parts.append(location) }
        if item.hasManualValue { parts.append("value set by hand") }
        if let owner = item.owner { parts.append(owner.name) }
        return parts.joined(separator: " · ")
    }
}
