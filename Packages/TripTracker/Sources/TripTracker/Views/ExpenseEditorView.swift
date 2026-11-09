import Core
import CoreData
import SwiftUI

/// Adds an expense to a trip's split, or edits one: how much, what for, who
/// paid and how it's divided. Save stays off until the split adds up
/// (`ExpenseEditorState.canSave`).
struct ExpenseEditorView: View {
    @ObservedObject var trip: SharedTrip
    let expense: SharedTripExpense?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var modelContext
    @Environment(\.tripPersistentContainer) private var container

    @FetchRequest private var personRows: FetchedResults<SharedTripPerson>
    @State private var state: ExpenseEditorState?
    @State private var addingPerson = false
    @State private var newPersonName = ""
    @State private var confirmingDelete = false

    init(trip: SharedTrip, expense: SharedTripExpense?) {
        self.trip = trip
        self.expense = expense
        _personRows = FetchRequest(fetchRequest: SplitFetch.people(of: trip))
    }

    // Gated on the trip, the share's root object, like every other editor.
    private var canEditShare: Bool {
        guard let container else { return true }
        return SharingStatusResolver.canEdit(trip, in: container)
    }

    private var people: TripPeople {
        SplitSnapshot.people(of: trip, in: container, rows: personRows.map(\.record)).1
    }

    var body: some View {
        let people = people
        SheetStack {
            Group {
                if let binding = Binding($state) {
                    form(binding, people: people)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(expense == nil ? "Add Expense" : "Edit Expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(expense == nil ? "Add" : "Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(!(state?.canSave() ?? false) || !canEditShare)
                }
            }
        }
        .onAppear { if state == nil { state = initialState(people: people) } }
        .textPrompt("Add Person", isPresented: $addingPerson, text: $newPersonName, prompt: "Name") {
            addPerson(order: people.splittable.compactMap(\.key))
        }
        .confirmationDialog("Delete \(state?.resolvedTitle ?? "expense")?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let expense {
                    modelContext.delete(expense)
                    try? modelContext.saveIfNeeded()
                }
                dismiss()
            }
        }
    }

    private func initialState(people: TripPeople) -> ExpenseEditorState {
        if let expense {
            return ExpenseEditorState(record: expense.record(), note: expense.note)
        }
        let everyone = people.splittable.compactMap(\.key)
        // Not a guess at who's paying when this device can't tell who "you"
        // are yet (a partner's device before the share is cached): Save stays
        // off until someone's picked.
        let payer = people.me.flatMap { me in everyone.contains(me) ? me : nil }
        return ExpenseEditorState(
            currencyCode: trip.defaultCurrencyCode(),
            payer: payer,
            people: everyone,
            date: ExpenseEditorState.defaultDate(for: trip.dates)
        )
    }

    @ViewBuilder
    private func form(_ state: Binding<ExpenseEditorState>, people: TripPeople) -> some View {
        let value = state.wrappedValue
        // Everyone a split can include now, plus anyone this expense already
        // names who no longer can (left, or hidden) so editing keeps them.
        let candidates = people.splittable.compactMap(\.key)
        let listed = candidates + value.included.filter { !candidates.contains($0) }
        let preview = Dictionary(value.preview().map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })

        Form {
            Section {
                MoneyField(title: "Amount", text: state.amountText, currencyCode: state.currencyCode)
                TextField("What for (Dinner at Ramiro)", text: state.title)
                    .textInputAutocapitalization(.sentences)
                Picker("Category", selection: state.category) {
                    ForEach(ExpenseCategory.allCases, id: \.self) { category in
                        Label(category.displayName, systemImage: category.symbolName).tag(category)
                    }
                }
                DatePicker("Date", selection: state.date, displayedComponents: .date)
            } footer: {
                Text(DayChoice.label(for: value.date, in: trip.dates))
            }

            Section {
                Picker("Paid by", selection: state.payer) {
                    if value.payer == nil {
                        Text("Choose").tag(PersonKey?.none)
                    }
                    ForEach(payerChoices(people: people, current: value.payer), id: \.self) { key in
                        Text(people.listLabel(for: key)).tag(Optional(key))
                    }
                }
            }

            Section {
                Picker("Split", selection: Binding(get: { value.mode }, set: { state.wrappedValue.setMode($0) })) {
                    ForEach(ExpenseSplitMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                ForEach(listed, id: \.self) { key in
                    personRow(key, state: state, people: people, order: listed, preview: preview[key])
                }

                if canEditShare {
                    Button {
                        newPersonName = ""
                        addingPerson = true
                    } label: {
                        Label("Add someone without the app…", systemImage: "person.badge.plus")
                    }
                }
            } header: {
                Text("Split")
            } footer: {
                if let remaining = value.remainingText() {
                    Text(remaining)
                        .foregroundStyle(value.addsUp() ? Color.secondary : Color.orange)
                } else if value.included.isEmpty {
                    Text("Tick at least one person.")
                }
            }

            Section("Note") {
                TextField("Note", text: state.note, axis: .vertical)
                    .lineLimit(1...4)
            }

            if expense != nil, canEditShare {
                Section {
                    Button("Delete Expense", role: .destructive) { confirmingDelete = true }
                }
            }
        }
    }

    @ViewBuilder
    private func personRow(
        _ key: PersonKey,
        state: Binding<ExpenseEditorState>,
        people: TripPeople,
        order: [PersonKey],
        preview: Int64?
    ) -> some View {
        let value = state.wrappedValue
        let included = value.isIncluded(key)
        HStack(spacing: 10) {
            Button {
                state.wrappedValue.toggle(key, order: order)
            } label: {
                Image(systemName: included ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(included ? TripTrackerModule.accent.color : .secondary)
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(included ? "Leave \(people.listLabel(for: key)) out" : "Include \(people.listLabel(for: key))")

            Text(people.listLabel(for: key))
                .foregroundStyle(included ? .primary : .secondary)
            Spacer(minLength: 8)

            if included {
                switch value.mode {
                case .equal:
                    EmptyView()
                case .exact:
                    TextField("0", text: text(for: key, state: state))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100)
                case .percent:
                    HStack(spacing: 2) {
                        TextField("0", text: text(for: key, state: state))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 70)
                        Text("%").foregroundStyle(.secondary)
                    }
                case .shares:
                    Stepper(
                        counted(Int(value.weights[key] ?? 1), "share"),
                        value: Binding(
                            get: { Int(state.wrappedValue.weights[key] ?? 1) },
                            set: { state.wrappedValue.weights[key] = Int64($0) }
                        ),
                        in: 0...20
                    )
                    .fixedSize()
                }
                if value.mode != .exact, let preview {
                    Text(TripMoney.format(preview, code: value.currencyCode))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 70, alignment: .trailing)
                }
            }
        }
    }

    private func text(for key: PersonKey, state: Binding<ExpenseEditorState>) -> Binding<String> {
        Binding(
            get: { state.wrappedValue.texts[key] ?? "" },
            set: { state.wrappedValue.texts[key] = $0 }
        )
    }

    private func payerChoices(people: TripPeople, current: PersonKey?) -> [PersonKey] {
        var keys = people.splittable.compactMap(\.key)
        if let current, !keys.contains(current) { keys.append(current) }
        return keys
    }

    /// Someone without the app, saved at once — like Add Person in the People
    /// sheet — and ticked into this split.
    private func addPerson(order: [PersonKey]) {
        let name = newPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, canEditShare else { return }
        let person = SharedTripPerson(context: modelContext, manualName: name)
        person.sortOrder = (personRows.map(\.sortOrder).max() ?? -1) + 1
        person.trip = trip
        try? modelContext.saveIfNeeded()
        state?.toggle(person.key, order: order + [person.key])
    }

    private func save() {
        guard let state, state.canSave(), canEditShare, let amount = state.amountMinor(), let payer = state.payer else { return }
        let target = expense ?? SharedTripExpense(
            context: modelContext,
            title: "",
            amountMinor: 0,
            currencyCode: state.currencyCode,
            payer: payer,
            split: .equal([])
        )
        target.title = state.resolvedTitle
        target.amountMinor = amount
        target.currencyCode = state.currencyCode
        target.payer = payer
        target.split = state.split()
        target.category = state.category
        target.kind = .expense
        target.spentAt = state.date
        target.note = state.note
        target.updatedAt = .now
        if expense == nil {
            target.trip = trip
        }
        // The first expense fixes the trip's currency, so the next one
        // starts in it even on a device in another region.
        if trip.currencyCode.isEmpty {
            trip.currencyCode = state.currencyCode
        }
        // Names for anyone from the share this expense uses for the first
        // time — written now, on a save that syncs anyway, never on opening
        // Split.
        trip.recordParticipants(of: target, share: SplitSnapshot.shareState(of: trip, in: container).snapshot)
        try? modelContext.saveIfNeeded()
        dismiss()
    }
}
