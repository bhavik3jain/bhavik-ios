import Core
import CoreData
import SwiftUI

/// Who's on the trip's split: everyone in its share (pulled in from iCloud,
/// never typed), invitees who haven't accepted yet, people who've left, and
/// people without the app added by hand.
///
/// Share participants can't be removed here — they leave through sharing,
/// and their history and balance stay. A manual person can be renamed,
/// linked to the participant they turned out to be (one record; no expense is
/// rewritten, and Unlink reverses it), hidden from new splits, or deleted
/// while no expense mentions them.
struct TripPeopleSheet: View {
    @ObservedObject var trip: SharedTrip
    let canEdit: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var modelContext
    @Environment(\.tripPersistentContainer) private var container

    @FetchRequest private var expenses: FetchedResults<SharedTripExpense>
    @FetchRequest private var personRows: FetchedResults<SharedTripPerson>

    @State private var adding = false
    // The key apart from the prompt's flag: an alert can clear what it's
    // presented by before its button's action runs.
    @State private var renaming: PersonKey?
    @State private var showsRename = false
    @State private var name = ""

    init(trip: SharedTrip, canEdit: Bool) {
        self.trip = trip
        self.canEdit = canEdit
        _expenses = FetchRequest(fetchRequest: SplitFetch.expenses(of: trip))
        _personRows = FetchRequest(fetchRequest: SplitFetch.people(of: trip))
    }

    var body: some View {
        let split = SplitSnapshot.make(trip: trip, container: container, expenses: expenses, rows: personRows)
        let people = split.people
        let mentioned = TripLedger.mentionedKeys(in: split.records)
        let onICloud = people.roster.filter { $0.source == .iCloud }
        let pending = people.roster.filter { $0.source == .pending }
        let left = people.roster.filter { $0.source == .left }
        let manual = people.roster.filter { $0.source == .manual }
        let linked = people.rows.values
            .filter { $0.kind == .manual && $0.mergedInto != nil && people.resolve($0.key) != $0.key }
            .sorted { ($0.name, $0.key) < ($1.name, $1.key) }
        let linkTargets = onICloud.filter { $0.key != nil }

        SheetStack {
            List {
                Section {
                    ForEach(onICloud) { person in
                        HStack(spacing: 6) {
                            Text(person.label)
                            PersonBadge(person: person)
                        }
                    }
                } header: {
                    Text("On iCloud")
                } footer: {
                    Text("Everyone this trip is shared with is on the split. Share the trip to add someone with the app.")
                }

                if !pending.isEmpty {
                    Section {
                        ForEach(pending) { person in
                            Text(person.label).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Invited")
                    } footer: {
                        Text("Joins the split when they accept. Until then, add them below and link them once they do.")
                    }
                }

                if !left.isEmpty {
                    Section("Left the trip") {
                        ForEach(left) { person in
                            HStack(spacing: 6) {
                                Text(person.label)
                                PersonBadge(person: person)
                            }
                        }
                    }
                }

                Section {
                    ForEach(manual) { person in
                        if let key = person.key {
                            manualRow(person.label, key: key, isHidden: person.isHidden, linkedTo: nil, people: people, targets: linkTargets, canDelete: !mentioned.contains(key))
                        }
                    }
                    ForEach(linked, id: \.key) { row in
                        manualRow(row.name, key: row.key, isHidden: row.isHidden, linkedTo: row.mergedInto, people: people, targets: linkTargets, canDelete: false)
                    }
                    if canEdit {
                        Button {
                            name = ""
                            adding = true
                        } label: {
                            Label("Add Person", systemImage: "person.badge.plus")
                        }
                    }
                } header: {
                    Text("Without the app")
                } footer: {
                    if manual.isEmpty && linked.isEmpty {
                        Text("Add anyone on the trip who doesn't have the app, to split with them too.")
                    }
                }
            }
            .navigationTitle("People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .textPrompt("Add Person", isPresented: $adding, text: $name, prompt: "Name", action: add)
        .textPrompt(
            "Rename",
            isPresented: $showsRename,
            text: $name,
            prompt: "Name",
            actionTitle: "Rename",
            action: rename
        )
    }

    @ViewBuilder
    private func manualRow(
        _ label: String,
        key: PersonKey,
        isHidden: Bool,
        linkedTo: PersonKey?,
        people: TripPeople,
        targets: [TripPerson],
        canDelete: Bool
    ) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label.isEmpty ? "Someone" : label)
                if let linkedTo {
                    Text("Counts as \(people.label(for: linkedTo))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if isHidden {
                    Text("Hidden from new splits")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if canEdit {
                Menu {
                    Button {
                        name = label
                        renaming = key
                        showsRename = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    if linkedTo != nil {
                        Button {
                            update(key) { $0.mergedInto = nil }
                        } label: {
                            Label("Unlink", systemImage: "link.badge.plus")
                        }
                    } else if !targets.isEmpty {
                        Menu {
                            ForEach(targets) { target in
                                if let targetKey = target.key {
                                    Button(target.label) {
                                        update(key) { $0.mergedInto = targetKey }
                                    }
                                }
                            }
                        } label: {
                            Label("Link to…", systemImage: "link")
                        }
                    }
                    if linkedTo == nil {
                        Button {
                            update(key) { $0.isHidden.toggle() }
                        } label: {
                            Label(isHidden ? "Show in New Splits" : "Hide from New Splits", systemImage: isHidden ? "eye" : "eye.slash")
                        }
                    }
                    if canDelete {
                        Divider()
                        Button(role: .destructive) {
                            for row in personRows where row.key == key { modelContext.delete(row) }
                            try? modelContext.saveIfNeeded()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .accessibilityLabel("Options for \(label)")
            }
        }
    }

    /// Every row with `key` — normally one; two devices can each have
    /// written the same person.
    private func update(_ key: PersonKey, _ change: (SharedTripPerson) -> Void) {
        guard canEdit else { return }
        for row in personRows where row.key == key {
            change(row)
            row.updatedAt = .now
        }
        try? modelContext.saveIfNeeded()
    }

    private func add() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canEdit else { return }
        let person = SharedTripPerson(context: modelContext, manualName: trimmed)
        person.sortOrder = (personRows.map(\.sortOrder).max() ?? -1) + 1
        person.trip = trip
        try? modelContext.saveIfNeeded()
    }

    private func rename() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = renaming, !trimmed.isEmpty else { return }
        update(key) { $0.name = trimmed }
        renaming = nil
    }
}
