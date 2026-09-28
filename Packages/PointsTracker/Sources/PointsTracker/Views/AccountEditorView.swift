import Core // Only reached on macOS, where Core stands in for the iOS-only SwiftUI API below.
import CoreData
import SwiftUI

/// Adds an account, or edits one when handed it. The balance is only entered
/// here for a new account; after that it changes through Update Balance, so
/// every change lands in the history.
struct AccountEditorView: View {
    let account: SharedPointsAccount?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @Environment(\.pointsPersistentContainer) private var container
    /// Every person, filtered to `household` below. Fetched rather than read
    /// off `household.owners` so a person added from this screen appears in
    /// the picker straight away.
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \SharedPointsOwner.name, ascending: true)])
    private var ownerResults: FetchedResults<SharedPointsOwner>

    @State private var name = ""
    @State private var program = ""
    @State private var kind = PointsKind.creditCard
    @State private var owner: SharedPointsOwner?
    /// The household this account is in, or will go into. An account can only
    /// belong to someone in its own household — Core Data can't relate
    /// objects across stores, and a partner's shared household is a
    /// different store from this device's own.
    @State private var household: SharedPointsHousehold?
    @State private var balanceText = ""
    @State private var memberNumber = ""
    @State private var status = ""
    @State private var hasExpiry = false
    @State private var expiresAt = Calendar.current.date(byAdding: .year, value: 1, to: .now) ?? .now
    @State private var notes = ""
    @State private var addingPerson = false
    @State private var newPersonName = ""
    @State private var loaded = false

    private var isNew: Bool { account == nil }
    private var owners: [SharedPointsOwner] { ownerResults.filter { $0.household == household } }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty || !program.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        SheetStack {
            Form {
                Section {
                    TextField("Name, e.g. Sapphire Reserve", text: $name)
                    TextField("Programme (optional)", text: $program)
                    Picker("Type", selection: $kind) {
                        ForEach(PointsKind.allCases) { option in
                            Label(option.displayName, systemImage: option.symbolName).tag(option)
                        }
                    }
                }

                Section {
                    Picker("Person", selection: $owner) {
                        Text("No one").tag(SharedPointsOwner?.none)
                        ForEach(owners) { person in
                            Text(person.name).tag(SharedPointsOwner?.some(person))
                        }
                    }
                    Button("Add Person…") {
                        newPersonName = ""
                        addingPerson = true
                    }
                } footer: {
                    Text("Whose account this is, so a household's balances stay apart.")
                }

                if isNew {
                    Section("Balance") {
                        TextField("Current \(kind.unit.singular)s", text: $balanceText)
                            .keyboardType(.numberPad)
                    }
                }

                Section {
                    TextField("Member number", text: $memberNumber)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    if kind != .creditCard {
                        TextField("Status, e.g. Gold", text: $status)
                    }
                    Toggle("Points expire", isOn: $hasExpiry.animation())
                    if hasExpiry {
                        DatePicker("Expires", selection: $expiresAt, displayedComponents: .date)
                    }
                }

                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle(isNew ? "Add Account" : "Edit Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(!canSave || !canEdit(account, in: container))
                }
            }
            .textPrompt("Add Person", isPresented: $addingPerson, text: $newPersonName, prompt: "Name") {
                addPerson()
            }
            .onAppear(perform: load)
            // Cancel is the only way out: it rolls back a person added from
            // the alert. A swipe-down skipped that, and the half-made person
            // was saved by the next unrelated save and synced to the partner.
            .interactiveDismissDisabled()
        }
    }

    /// Once only: `onAppear` fires again when the alert closes, and reloading
    /// then would throw away whatever had been typed.
    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let account else {
            household = HouseholdResolver.forWriting(in: context, container: container)
            return
        }
        household = account.household
        name = account.name
        program = account.program
        kind = account.kind
        owner = account.owner
        memberNumber = account.memberNumber
        status = account.status
        hasExpiry = account.expiresAt != nil
        if let date = account.expiresAt { expiresAt = date }
        notes = account.notes
    }

    private func addPerson() {
        let trimmed = newPersonName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Picking an existing name rather than making a second person with it.
        if let existing = owners.first(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            owner = existing
            return
        }
        guard let household else { return }
        owner = SharedPointsOwner(name: trimmed, household: household)
    }

    /// Cancel also has to throw away a person added from the alert, which is
    /// only saved along with the account.
    private func cancel() {
        context.rollback()
        dismiss()
    }

    private func save() {
        let household = household ?? HouseholdResolver.forWriting(in: context, container: container)
        let target = account ?? SharedPointsAccount(name: "", kind: kind, household: household)
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.program = program.trimmingCharacters(in: .whitespaces)
        target.kind = kind
        target.owner = owner
        target.memberNumber = memberNumber.trimmingCharacters(in: .whitespaces)
        // A credit card has no tier, and the field is hidden for one — don't
        // keep a status typed in while it was briefly set to a hotel.
        target.status = kind == .creditCard ? "" : status.trimmingCharacters(in: .whitespaces)
        target.expiresAt = hasExpiry ? expiresAt : nil
        target.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if account == nil {
            target.recordBalance(PointsInput.parse(balanceText) ?? 0, note: "Opening balance")
        }
        try? context.saveIfNeeded()
        dismiss()
    }
}
