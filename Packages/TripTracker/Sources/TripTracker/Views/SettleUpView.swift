import Core
import CoreData
import SwiftUI

/// Settle Up on the phone: the suggested transfers that square everyone up,
/// each with Record, a way to record a different payment, and the payments
/// recorded so far. The Mac lists the suggestions in the Split face's column
/// instead (`SplitSummarySections`).
///
/// The app never moves money: Record only writes down a payment made some
/// other way.
struct SettleUpView: View {
    @ObservedObject var trip: SharedTrip
    let canEdit: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var modelContext
    @Environment(\.tripPersistentContainer) private var container

    @FetchRequest private var expenses: FetchedResults<SharedTripExpense>
    @FetchRequest private var personRows: FetchedResults<SharedTripPerson>
    @State private var recording: PaymentSheet?

    /// A payment form over this sheet.
    private enum PaymentSheet: Identifiable {
        case new(PaymentPrefill)
        case existing(SharedTripExpense)

        var id: String {
            switch self {
            case .new(let prefill): "new-\(prefill.id)"
            case .existing(let payment): "payment-\(payment.objectID.hashValue)"
            }
        }
    }

    init(trip: SharedTrip, canEdit: Bool) {
        self.trip = trip
        self.canEdit = canEdit
        _expenses = FetchRequest(fetchRequest: SplitFetch.expenses(of: trip))
        _personRows = FetchRequest(fetchRequest: SplitFetch.people(of: trip))
    }

    var body: some View {
        let split = SplitSnapshot.make(trip: trip, container: container, expenses: expenses, rows: personRows)
        let wording = split.wording
        let payments = split.records.filter(\.isPayment)
        SheetStack {
            List {
                Section {
                    let transfers = split.ledger.transfers
                    if transfers.isEmpty {
                        Label("Everyone's square", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(transfers) { transfer in
                        TransferRow(transfer: transfer, wording: wording, canEdit: canEdit) {
                            recording = .new(PaymentPrefill(transfer))
                        }
                    }
                } header: {
                    Text("Suggested")
                } footer: {
                    Text("The fewest payments that square everyone up, one currency at a time. Recording one doesn't send any money.")
                }

                if canEdit {
                    Section {
                        Button("Record a Different Payment") { recording = .new(PaymentPrefill()) }
                    }
                }

                if !payments.isEmpty {
                    Section("Recorded") {
                        ForEach(payments) { record in
                            ExpenseRow(record: record, wording: wording, ledger: split.ledger)
                                .contentShape(.rect)
                                .onTapGesture {
                                    if canEdit, let object = split.objects[record.id] { recording = .existing(object) }
                                }
                                .swipeActions {
                                    if canEdit, let object = split.objects[record.id] {
                                        Button(role: .destructive) {
                                            modelContext.delete(object)
                                            try? modelContext.saveIfNeeded()
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                        }
                    }
                }
            }
            .navigationTitle("Settle Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(item: $recording) { sheet in
            switch sheet {
            case .new(let prefill):
                RecordPaymentView(trip: trip, payment: nil, prefill: prefill)
            case .existing(let payment):
                RecordPaymentView(trip: trip, payment: payment, prefill: nil)
            }
        }
    }
}

/// Records a payment between two of the trip's people, or edits one: from,
/// to, how much, when, and how ("via Venmo"). Stored as an expense whose kind
/// is `payment` and whose split gives the whole amount to the person paid,
/// so every balance goes through one code path.
struct RecordPaymentView: View {
    @ObservedObject var trip: SharedTrip
    let payment: SharedTripExpense?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var modelContext
    @Environment(\.tripPersistentContainer) private var container

    @FetchRequest private var personRows: FetchedResults<SharedTripPerson>
    @State private var draft: PaymentDraft
    @State private var confirmingDelete = false

    init(trip: SharedTrip, payment: SharedTripExpense?, prefill: PaymentPrefill?) {
        self.trip = trip
        self.payment = payment
        _personRows = FetchRequest(fetchRequest: SplitFetch.people(of: trip))
        if let payment {
            let record = payment.record()
            _draft = State(initialValue: PaymentDraft(
                from: record.payer,
                to: record.split.keys.first,
                amountMinor: record.amountMinor,
                currencyCode: record.currencyCode,
                date: record.date,
                via: payment.note
            ))
        } else {
            let prefill = prefill ?? PaymentPrefill()
            _draft = State(initialValue: PaymentDraft(
                from: prefill.from,
                to: prefill.to,
                amountMinor: prefill.amountMinor,
                currencyCode: prefill.currencyCode.isEmpty ? trip.defaultCurrencyCode() : prefill.currencyCode,
                date: .now
            ))
        }
    }

    private var canEditShare: Bool {
        guard let container else { return true }
        return SharingStatusResolver.canEdit(trip, in: container)
    }

    var body: some View {
        let (share, people) = SplitSnapshot.people(of: trip, in: container, rows: personRows.map(\.record))
        let choices = choices(people)
        SheetStack {
            Form {
                Section {
                    Picker("From", selection: $draft.from) {
                        if draft.from == nil { Text("Choose").tag(PersonKey?.none) }
                        ForEach(choices, id: \.self) { Text(people.label(for: $0)).tag(Optional($0)) }
                    }
                    Picker("To", selection: $draft.to) {
                        if draft.to == nil { Text("Choose").tag(PersonKey?.none) }
                        ForEach(choices, id: \.self) { Text(people.label(for: $0)).tag(Optional($0)) }
                    }
                } footer: {
                    if let from = draft.from, from == draft.to {
                        Text("A payment needs two different people.")
                    }
                }
                Section {
                    MoneyField(title: "Amount", text: $draft.amountText, currencyCode: $draft.currencyCode)
                    DatePicker("Date", selection: $draft.date, displayedComponents: .date)
                    TextField("Via (Venmo, cash)", text: $draft.via)
                } footer: {
                    Text("Writes the payment down; no money moves.")
                }
                if payment != nil, canEditShare {
                    Section {
                        Button("Delete Payment", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .navigationTitle(payment == nil ? "Record Payment" : "Edit Payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(payment == nil ? "Record" : "Save") { save(share: share.snapshot) }
                        .fontWeight(.semibold)
                        .disabled(!draft.canSave() || !canEditShare)
                }
            }
            .confirmationDialog("Delete this payment?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let payment {
                        modelContext.delete(payment)
                        try? modelContext.saveIfNeeded()
                    }
                    dismiss()
                }
            }
        }
    }

    /// Anyone a payment can be to or from — including someone who has left and
    /// still owes or is owed — plus whoever this payment already names.
    private func choices(_ people: TripPeople) -> [PersonKey] {
        var keys = people.roster.filter(\.canSettle).compactMap(\.key)
        for key in [draft.from, draft.to].compactMap({ $0 }) where !keys.contains(key) {
            keys.append(key)
        }
        return keys
    }

    private func save(share: ShareSnapshot?) {
        guard draft.canSave(), canEditShare, let from = draft.from, let to = draft.to, let amount = draft.amountMinor() else { return }
        let target = payment ?? SharedTripExpense(
            context: modelContext,
            title: "Payment",
            amountMinor: amount,
            currencyCode: draft.currencyCode,
            payer: from,
            split: .payment(to: to, amountMinor: amount),
            kind: .payment
        )
        target.amountMinor = amount
        target.currencyCode = draft.currencyCode
        target.payer = from
        target.split = .payment(to: to, amountMinor: amount)
        target.kind = .payment
        target.spentAt = draft.date
        target.note = draft.via.trimmingCharacters(in: .whitespacesAndNewlines)
        target.updatedAt = .now
        if payment == nil {
            target.trip = trip
        }
        trip.recordParticipants(of: target, share: share)
        try? modelContext.saveIfNeeded()
        dismiss()
    }
}
