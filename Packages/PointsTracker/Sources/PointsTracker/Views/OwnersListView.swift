import Core
import CoreData
import SwiftUI

/// The people in the household. Each shows what they hold across every
/// programme; deleting one keeps their accounts, unassigned.
struct OwnersListView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.pointsPersistentContainer) private var container
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \SharedPointsOwner.name, ascending: true)])
    private var ownerResults: FetchedResults<SharedPointsOwner>
    @FetchRequest(sortDescriptors: [])
    private var accountResults: FetchedResults<SharedPointsAccount>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \SharedPointsHousehold.createdAt, ascending: true)])
    private var householdResults: FetchedResults<SharedPointsHousehold>

    private var owners: [SharedPointsOwner] { Array(ownerResults) }
    private var accounts: [SharedPointsAccount] { Array(accountResults) }

    @State private var editing: SharedPointsOwner?
    @State private var adding = false
    @State private var nameDraft = ""

    /// One line per household that's shared either way, so it's clear who
    /// else can see all this.
    private var sharingLabels: [String] {
        guard let container else { return [] }
        return householdResults.compactMap { SharingStatusResolver.status(for: $0, in: container).householdBadgeLabel }
    }

    private var unassigned: [SharedPointsAccount] { accounts.filter { $0.owner == nil } }

    var body: some View {
        NavigationStack {
            Group {
                if owners.isEmpty {
                    ContentUnavailableView {
                        Label("No people", systemImage: "person.2")
                    } description: {
                        Text("Add everyone in the household who has an account, then pick whose each one is.")
                    } actions: {
                        Button("Add Person") { startAdding() }
                            .primaryActionStyle(tint: PointsTrackerModule.accent.color)
                    }
                } else {
                    List {
                        Section {
                            ForEach(owners) { owner in
                                NavigationLink {
                                    OwnerDetailView(owner: owner)
                                } label: {
                                    OwnerRow(name: owner.name, accounts: Array(owner.accounts ?? []))
                                }
                                .contextMenu {
                                    if canEdit(owner, in: container) {
                                        Button("Rename", systemImage: "pencil") { startRenaming(owner) }
                                    }
                                }
                            }
                            .onDelete(perform: delete)
                        } footer: {
                            Text("Deleting a person keeps their accounts; they move to Unassigned.")
                        }
                        if !sharingLabels.isEmpty {
                            Section {
                                ForEach(sharingLabels, id: \.self) { label in
                                    Label(label, systemImage: "person.2.fill")
                                        .foregroundStyle(.secondary)
                                }
                            } footer: {
                                Text("Everyone in a shared household sees every person and account in it.")
                            }
                        }
                        if !unassigned.isEmpty {
                            Section {
                                OwnerRow(name: PointsSummary.unassigned, accounts: unassigned)
                            }
                        }
                    }
                }
            }
            .navigationTitle("People")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        startAdding()
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                    .accessibilityLabel("Add Person")
                }
                ToolbarItem(placement: .secondaryAction) {
                    ShareHouseholdButton()
                }
            }
            .alert(editing == nil ? "Add Person" : "Rename", isPresented: $adding) {
                TextField("Name", text: $nameDraft)
                Button("Cancel", role: .cancel) { editing = nil }
                Button(editing == nil ? "Add" : "Save", action: commit)
            }
        }
    }

    private func startAdding() {
        editing = nil
        nameDraft = ""
        adding = true
    }

    private func startRenaming(_ owner: SharedPointsOwner) {
        editing = owner
        nameDraft = owner.name
        adding = true
    }

    private func commit() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespaces)
        defer { editing = nil }
        guard !trimmed.isEmpty else { return }
        if let editing {
            editing.name = trimmed
        } else {
            _ = SharedPointsOwner(name: trimmed, household: HouseholdResolver.forWriting(in: context, container: container))
        }
        try? context.saveIfNeeded()
    }

    private func delete(at offsets: IndexSet) {
        let owners = owners
        for index in offsets where canEdit(owners[index], in: container) {
            context.delete(owners[index])
        }
        try? context.saveIfNeeded()
    }
}

private struct OwnerRow: View {
    let name: String
    let accounts: [SharedPointsAccount]

    var body: some View {
        HStack(spacing: 12) {
            Text(initials)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(PointsTrackerModule.accent.color, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .fontWeight(.semibold)
                Text(accounts.isEmpty ? "No accounts" : "\(counted(accounts.count, "account")) · \(PointsTotal(accounts).summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }

    private var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

/// One person's accounts, by type.
private struct OwnerDetailView: View {
    @ObservedObject var owner: SharedPointsOwner

    var body: some View {
        let sections = PointsSummary.sections(Array(owner.accounts ?? []), by: .kind)
        List {
            if sections.isEmpty {
                Text("No accounts yet. Pick \(owner.name) as the person when adding or editing an account.")
                    .foregroundStyle(.secondary)
            }
            ForEach(sections) { section in
                Section {
                    ForEach(section.accounts) { account in
                        NavigationLink {
                            AccountDetailView(account: account)
                        } label: {
                            AccountRow(account: account, showsOwner: false)
                        }
                    }
                } header: {
                    HStack {
                        Text(section.title)
                        Spacer()
                        Text(section.total.summary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .navigationTitle(owner.name)
    }
}
