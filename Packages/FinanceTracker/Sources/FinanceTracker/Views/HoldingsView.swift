import Core
import CoreData
import SwiftUI

/// What the household holds: every account by category, and the gold and
/// the silver — each its own list, split by person.
struct HoldingsView: View {
    @Environment(\.moduleLayout) private var layout
    @Environment(\.managedObjectContext) private var context
    @Environment(\.financePersistentContainer) private var container
    var data = FinanceFetches()

    /// Gold and silver were one list; the user asked for them apart.
    private enum Mode: String, CaseIterable, Identifiable {
        case accounts = "Accounts"
        case gold = "Gold"
        case silver = "Silver"
        var id: String { rawValue }

        /// The metal this mode lists; nil for accounts.
        var metal: MetalKind? {
            switch self {
            case .accounts: nil
            case .gold: .gold
            case .silver: .silver
            }
        }
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
                            if mode.metal == nil {
                                addingAccount = true
                            } else {
                                addingMetal = true
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(mode.metal.map { "Add \($0.displayName)" } ?? "New Account")
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
                MetalEditorView(item: nil, newMetal: mode.metal ?? .gold)
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
        // A review's "Open Gold & Silver": the module's own tab is already
        // built with its mode in @State, so it's asked for, not passed in.
        // Its fixes can be about either metal; Gold unless there's only silver.
        .onChange(of: HoldingsModeRequest.shared.showsMetals, initial: true) { _, showsMetals in
            guard showsMetals else { return }
            let metals = data.snapshot.metals
            mode = !metals.contains { $0.metal == .gold } && metals.contains { $0.metal == .silver } ? .silver : .gold
            HoldingsModeRequest.shared.showsMetals = false
        }
        // A location picked on Gold may hold no silver at all.
        .onChange(of: mode) { locationFilter = nil }
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

            if let metal = mode.metal {
                metalSections(snapshot, metal: metal, isEditable: isEditable)
            } else {
                accountSections(snapshot, isEditable: isEditable)
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
        // The last month filled in, as the Summary shows.
        guard let latest = snapshot.reportedMonth else { return 0 }
        return account.value(in: latest)
    }

    private func sharingLabel(_ household: SharedFinanceHousehold?) -> String? {
        guard let household, let container else { return nil }
        return SharingStatusResolver.badgeStatus(for: household, in: container).householdBadgeLabel
    }

    private func deleteMessage(for account: SharedFinanceAccount?) -> String {
        guard let account else { return "" }
        let count = account.transactionCount
        if account.category == .card {
            return count == 0
                ? "The card has no transactions."
                : "Its \(counted(count, "transaction")) will be deleted too. Archive it instead to keep them."
        }
        // A cash account can be paid from too, and its transactions go with it.
        if count > 0 {
            return "Its balance in every month and its \(counted(count, "transaction")) will be deleted too. Archive it instead to keep them."
        }
        return "Its balance in every month will be deleted too, changing past months' totals. Archive it instead to keep them."
    }

    // MARK: - Gold & silver

    /// One metal: what it's worth, its price, where it's kept, and each
    /// person's pieces under their badge, in their colour.
    @ViewBuilder
    private func metalSections(_ snapshot: FinanceSnapshot, metal: MetalKind, isEditable: Bool) -> some View {
        let prices = snapshot.currentPrices
        let items = MetalGrouping.items(snapshot.metals, of: metal)
        let holdings = MetalHoldings(items, prices: prices)
        let locations = MetalHoldings.locations(items)
        // The header and its bar are the whole metal; the list follows the
        // location chip.
        let everyone = MetalGrouping.byOwner(items, prices: prices)
        let groups = MetalGrouping.byOwner(MetalGrouping.items(items, of: metal, at: locationFilter), prices: prices)

        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(metal.displayName) value")
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
                if everyone.count > 1 {
                    OwnerShareBar(shares: ownerShares(everyone))
                        .padding(.top, 4)
                }
            }
            .padding(.vertical, 4)
        }

        Section {
            LabeledContent(metal.displayName, value: "\(FinanceFormat.cents(prices.price(for: metal))) / oz")
        } header: {
            Text(snapshot.latestMonth.map { "\($0.title) price" } ?? "Price")
        } footer: {
            Text("Change it on the month's page under Months.")
        }

        if !locations.isEmpty {
            Section {
                ChipRow {
                    FinanceChip(title: "All", detail: "\(items.count)", isSelected: locationFilter == nil) {
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

        if items.isEmpty {
            Section {
                Text("No \(metal.displayName.lowercased()) yet. Add each bar, coin or piece of jewellery with its weight; it's valued at the month's price.")
                    .foregroundStyle(.secondary)
            }
        }

        ForEach(groups) { group in
            Section {
                ForEach(group.items) { item in
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
            } header: {
                OwnerGroupHeader(owner: group.owner, title: group.title, total: group.holdings.value)
                    .textCase(nil)
            }
        }
    }

    /// The bar's slices, worked out here rather than in the bar: this view
    /// redraws when someone's colour changes in People, a bar handed the
    /// same owner objects again would not.
    private func ownerShares(_ groups: [MetalGroup]) -> [OwnerShare] {
        zip(groups, MetalGrouping.shares(groups)).map { group, share in
            OwnerShare(
                id: group.id,
                name: group.title,
                color: group.owner?.color.color ?? .gray,
                fraction: share
            )
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

/// A piece of gold or silver. Whose it is is the section it sits in.
private struct MetalRow: View {
    @ObservedObject var item: SharedFinanceMetalItem
    let prices: MetalPrices

    var body: some View {
        HStack(spacing: 10) {
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
        return parts.joined(separator: " · ")
    }
}

/// One person's slice of a metal's value.
private struct OwnerShare: Identifiable {
    let id: String
    let name: String
    let color: Color
    let fraction: Double
}

/// Who holds how much of the gold, or the silver: one bar in each person's
/// colour, and a key with their share.
private struct OwnerShareBar: View {
    let shares: [OwnerShare]

    var body: some View {
        let shown = shares.filter { $0.fraction > 0 }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geometry in
                    let gaps = CGFloat(shown.count - 1) * 2
                    HStack(spacing: 2) {
                        ForEach(shown) { share in
                            Rectangle()
                                .fill(share.color)
                                .frame(width: max(0, (geometry.size.width - gaps) * share.fraction))
                        }
                    }
                }
                .frame(height: 8)
                .clipShape(Capsule())
                HStack(spacing: 12) {
                    ForEach(shares) { share in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(share.color)
                                .frame(width: 8, height: 8)
                            Text(share.name)
                            Text(share.fraction.formatted(.percent.precision(.fractionLength(0))))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .lineLimit(1)
                    }
                }
                .font(.caption)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(shares.map { "\($0.name) \($0.fraction.formatted(.percent.precision(.fractionLength(0))))" }.joined(separator: ", "))
        }
    }
}
