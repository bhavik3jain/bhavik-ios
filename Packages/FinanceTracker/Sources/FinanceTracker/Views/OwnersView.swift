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
    @State private var adding = false

    var body: some View {
        let snapshot = data.snapshot
        let isEditable = snapshot.canEdit
        List {
            Section {
                ForEach(snapshot.owners) { owner in
                    Button {
                        if isEditable { editing = owner }
                    } label: {
                        HStack(spacing: 12) {
                            OwnerBadge(owner: owner, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(owner.name)
                                    .fontWeight(.semibold)
                                Text(detail(for: owner))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .tint(.primary)
                    .contextMenu {
                        if isEditable {
                            Button("Edit", systemImage: "pencil") { editing = owner }
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
                Text("Tap someone to rename them or pick their colour. Joint is an owner like anyone else. Deleting someone keeps their accounts and metals, with no owner.")
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
                        adding = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                    .accessibilityLabel("Add Person")
                }
            }
        }
        .sheet(isPresented: $adding) {
            OwnerEditorView(owner: nil, taken: Set(snapshot.owners.map(\.color)))
        }
        .sheet(item: $editing) { owner in
            OwnerEditorView(owner: owner, taken: Set(snapshot.owners.filter { $0 != owner }.map(\.color)))
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
        return SharingStatusResolver.badgeStatus(for: household, in: container).householdBadgeLabel
    }
}

/// Adds a person, or edits one: name, person or joint, and the colour of
/// their badge everywhere in Finance. Colours already used by someone else
/// are marked, but can still be picked.
private struct OwnerEditorView: View {
    let owner: SharedFinanceOwner?
    /// Everyone else's colours, to mark and to start a new person off on a free one.
    let taken: Set<OwnerColor>

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @Environment(\.financePersistentContainer) private var container

    @State private var name = ""
    @State private var kind = OwnerKind.person
    @State private var color = OwnerColor.blue
    @State private var loaded = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        SheetStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Text(initials)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(color.color, in: Circle())
                        TextField("Name", text: $name, prompt: Text("Name"))
                            .textInputAutocapitalization(.words)
                            .font(.title3)
                    }
                    Picker("Kind", selection: $kind) {
                        ForEach(OwnerKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Colour") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 12)], spacing: 12) {
                        ForEach(OwnerColor.allCases) { option in
                            Button {
                                color = option
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(option.color)
                                        .frame(width: 36, height: 36)
                                    if option == color {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(.white)
                                    } else if taken.contains(option) {
                                        // Someone else has it — still allowed.
                                        Circle()
                                            .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                                            .frame(width: 14, height: 14)
                                    }
                                }
                                .frame(width: 44, height: 44)
                                .overlay {
                                    if option == color {
                                        Circle().strokeBorder(option.color, lineWidth: 2)
                                    }
                                }
                                .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.displayName + (taken.contains(option) ? ", used by someone else" : ""))
                            .accessibilityAddTraits(option == color ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(owner == nil ? "Add Person" : "Edit Person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(owner == nil ? "Add" : "Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(trimmedName.isEmpty || !canEdit(owner, in: container))
                }
            }
            .onAppear(perform: load)
        }
    }

    /// The badge's letters as they'll be, typed name and all.
    private var initials: String {
        let letters = trimmedName.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let owner {
            name = owner.name
            kind = owner.kind
            color = owner.color
        } else {
            color = OwnerColor.allCases.first { !taken.contains($0) } ?? .blue
        }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        let target = owner ?? SharedFinanceOwner(
            name: trimmedName,
            kind: kind,
            household: FinanceHouseholdResolver.forWriting(in: context, container: container)
        )
        target.name = trimmedName
        target.kind = kind
        // Only stored once it differs from what they'd get anyway, so an
        // untouched person keeps following the automatic colours.
        if target.hasChosenColor || color != target.color {
            target.color = color
        }
        try? context.saveIfNeeded()
        dismiss()
    }
}
