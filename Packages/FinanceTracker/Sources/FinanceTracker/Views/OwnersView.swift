import Core
import CoreData
import SwiftUI

/// The household's people — Bhavik, Saloni, Joint to start with. Deleting one
/// keeps what they held, with no owner.
struct OwnersView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.financePersistentContainer) private var container
    var data = FinanceFetches()

    @State private var editing: SharedFinanceOwner?
    @State private var showingNameAlert = false
    @State private var nameDraft = ""
    @State private var kindDraft = OwnerKind.person

    var body: some View {
        let snapshot = data.snapshot
        let isEditable = canEdit(snapshot.household, in: container)
        List {
            Section {
                ForEach(snapshot.owners) { owner in
                    HStack(spacing: 12) {
                        OwnerBadge(owner: owner)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(owner.name)
                                .fontWeight(.semibold)
                            Text(detail(for: owner))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        if isEditable {
                            Button("Rename", systemImage: "pencil") { startEditing(owner) }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if isEditable {
                            Button("Rename", systemImage: "pencil") { startEditing(owner) }
                                .tint(FinanceTrackerModule.accent.color)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets where canEdit(snapshot.owners[index], in: container) {
                        context.delete(snapshot.owners[index])
                    }
                    try? context.saveIfNeeded()
                }
            } footer: {
                Text("Joint is an owner like anyone else: filter on it to see just the joint accounts. Deleting someone keeps their accounts and metals, with no owner.")
            }

            Section {
                if let label = sharingLabel(snapshot.household) {
                    Label(label, systemImage: "person.2.fill")
                        .foregroundStyle(.secondary)
                }
                ShareHouseholdButton()
            } footer: {
                Text("Your partner sees and can edit every account, month and transaction in a shared household.")
            }
        }
        .navigationTitle("People")
        .toolbar {
            if isEditable {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        startEditing(nil)
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                    .accessibilityLabel("Add Person")
                }
            }
        }
        .alert(editing == nil ? "Add Person" : "Rename", isPresented: $showingNameAlert) {
            TextField("Name", text: $nameDraft)
            if editing == nil {
                Button("Add Person") { commit(kind: .person) }
                Button("Add as Joint") { commit(kind: .joint) }
            } else {
                Button("Save") { commit(kind: kindDraft) }
            }
            Button("Cancel", role: .cancel) { editing = nil }
        }
    }

    private func detail(for owner: SharedFinanceOwner) -> String {
        let accounts = owner.accounts?.count ?? 0
        let metals = owner.metalItems?.count ?? 0
        var parts = [owner.kind.displayName, counted(accounts, "account")]
        if metals > 0 { parts.append(counted(metals, "metal item")) }
        return parts.joined(separator: " · ")
    }

    private func sharingLabel(_ household: SharedFinanceHousehold?) -> String? {
        guard let household, let container else { return nil }
        return SharingStatusResolver.status(for: household, in: container).householdBadgeLabel
    }

    private func startEditing(_ owner: SharedFinanceOwner?) {
        editing = owner
        nameDraft = owner?.name ?? ""
        kindDraft = owner?.kind ?? .person
        showingNameAlert = true
    }

    private func commit(kind: OwnerKind) {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespaces)
        defer { editing = nil }
        guard !trimmed.isEmpty else { return }
        if let editing {
            editing.name = trimmed
            editing.kind = kind
        } else {
            _ = SharedFinanceOwner(
                name: trimmed,
                kind: kind,
                household: FinanceHouseholdResolver.forWriting(in: context, container: container)
            )
        }
        try? context.saveIfNeeded()
    }
}
