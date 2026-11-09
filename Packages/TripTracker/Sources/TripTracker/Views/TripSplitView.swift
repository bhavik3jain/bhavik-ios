import Core
import CoreData
import SwiftUI

/// The Split face: who's paid for what on this trip, who owes whom, and the
/// fewest payments that square everyone up.
///
/// On the phone one list — the balance card, Balances, then the expenses by
/// trip day. On the Mac (`moduleLayout == .sidebar`) the expenses take the
/// width and the card, Balances and Settle Up sit in a 300 pt column beside
/// them, each suggestion with its own Record, so nothing needs a sheet.
///
/// Opening it writes nothing: participant rows are written only when someone
/// is first used in a saved expense (`SharedTrip.recordParticipants`). A write
/// here would sync, and iCloud's zone alert subscriptions would ping the
/// partner on every visit.
struct TripSplitView: View {
    @ObservedObject var trip: SharedTrip
    let canEdit: Bool
    let present: (TripSheet) -> Void

    @Environment(\.tripPersistentContainer) private var container
    @Environment(\.moduleLayout) private var layout
    @Environment(\.managedObjectContext) private var modelContext

    @FetchRequest private var expenses: FetchedResults<SharedTripExpense>
    @FetchRequest private var personRows: FetchedResults<SharedTripPerson>

    init(trip: SharedTrip, canEdit: Bool, present: @escaping (TripSheet) -> Void) {
        self.trip = trip
        self.canEdit = canEdit
        self.present = present
        _expenses = FetchRequest(fetchRequest: SplitFetch.expenses(of: trip))
        _personRows = FetchRequest(fetchRequest: SplitFetch.people(of: trip))
    }

    var body: some View {
        let split = SplitSnapshot.make(trip: trip, container: container, expenses: expenses, rows: personRows)
        if split.records.isEmpty {
            empty
        } else if layout == .sidebar {
            HStack(spacing: 0) {
                List {
                    expenseSections(split)
                }
                .tableRowBackgroundsPlain()
                Divider()
                List {
                    SplitSummarySections(trip: trip, split: split, canEdit: canEdit, showsTransfers: true, present: present)
                }
                .frame(width: 300)
            }
        } else {
            List {
                SplitSummarySections(trip: trip, split: split, canEdit: canEdit, showsTransfers: false, present: present)
                expenseSections(split)
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("No expenses yet", systemImage: "divide.circle")
        } description: {
            Text("Add what this trip costs and who it was for. Split works out who owes whom, in as few payments as it can.")
        } actions: {
            // A view-only participant can't add, so is offered nothing.
            if canEdit {
                Button("Add Expense") { present(.newExpense) }
                    .buttonStyle(.borderedProminent)
                Button("People") { present(.people) }
            }
        }
    }

    @ViewBuilder
    private func expenseSections(_ split: SplitSnapshot) -> some View {
        let wording = split.wording
        ForEach(TripLedger.dayGroups(split.records, dates: trip.dates)) { group in
            Section(group.title()) {
                ForEach(group.expenses) { record in
                    let object = split.objects[record.id]
                    ExpenseRow(record: record, wording: wording, ledger: split.ledger)
                        .contentShape(.rect)
                        .onTapGesture {
                            if canEdit, let object { open(object) }
                        }
                        .contextMenu {
                            if canEdit, let object {
                                Button {
                                    open(object)
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    delete(object)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .swipeActions {
                            if canEdit, let object {
                                Button(role: .destructive) {
                                    delete(object)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                }
            }
        }
    }

    private func open(_ expense: SharedTripExpense) {
        present(expense.isPayment ? .payment(expense) : .expense(expense))
    }

    private func delete(_ expense: SharedTripExpense) {
        modelContext.delete(expense)
        try? modelContext.saveIfNeeded()
    }
}

/// The balance card, Balances and — on the Mac's column — the suggested
/// transfers: the phone's list starts with these, and the Mac's column is
/// made of them.
struct SplitSummarySections: View {
    @ObservedObject var trip: SharedTrip
    let split: SplitSnapshot
    let canEdit: Bool
    /// The Mac's column lists Settle Up's transfers in place; the phone opens
    /// them in a sheet.
    let showsTransfers: Bool
    let present: (TripSheet) -> Void

    @Environment(\.managedObjectContext) private var modelContext

    var body: some View {
        let ledger = split.ledger
        let wording = split.wording
        Section {
            hero(ledger: ledger, wording: wording)
        } footer: {
            if !canEdit {
                Text("View only · ask \(ownerName) to record payments")
            }
        }

        Section {
            ForEach(balancePeople(ledger)) { person in
                BalanceRow(person: person, ledger: ledger, wording: wording)
            }
        } header: {
            HStack {
                Text("Balances")
                Spacer()
                Button("People") { present(.people) }
                    .font(.caption)
                    .textCase(nil)
            }
        } footer: {
            if split.people.roster.contains(where: { $0.source == .pending }) {
                Text("Invitees join the split when they accept.")
            }
        }

        if showsTransfers {
            Section("Settle Up") {
                let transfers = ledger.transfers
                if transfers.isEmpty {
                    Label("Everyone's square", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                ForEach(transfers) { transfer in
                    TransferRow(transfer: transfer, wording: wording, canEdit: canEdit) {
                        present(.recordPayment(PaymentPrefill(transfer)))
                    }
                }
                if canEdit {
                    Button("Record a Different Payment") { present(.recordPayment(PaymentPrefill())) }
                }
            }
        }
    }

    private var ownerName: String {
        let name = split.people.name(for: .owner)
        return name.isEmpty ? "the trip's owner" : name
    }

    @ViewBuilder
    private func hero(ledger: TripLedger, wording: SplitWording) -> some View {
        let me = split.people.me
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    if let me {
                        ForEach(ledger.currencies, id: \.self) { code in
                            Text(wording.myBalance(ledger.balance(of: me, in: code), code: code))
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundStyle(tint(ledger.balance(of: me, in: code)))
                        }
                    }
                    Text(totalLine(ledger: ledger))
                        .font(me == nil ? .title3.weight(.bold) : .subheadline)
                        .foregroundStyle(me == nil ? .primary : .secondary)
                }
                Spacer(minLength: 8)
                menu
            }
            if !showsTransfers, !ledger.isSettled {
                Button {
                    present(.settleUp)
                } label: {
                    Label("Settle Up", systemImage: "arrow.left.arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }

    /// "Trip total €1,116.40", one figure per currency.
    private func totalLine(ledger: TripLedger) -> String {
        let totals = ledger.currencies.compactMap { code in
            ledger.totals[code].map { TripMoney.format($0, code: code) }
        }
        return totals.isEmpty ? "Nothing spent yet" : "Trip total " + totals.joined(separator: " · ")
    }

    private var menu: some View {
        Menu {
            Button {
                present(.people)
            } label: {
                Label("People", systemImage: "person.2")
            }
            if !split.ledger.isSettled {
                Button {
                    present(.settleUp)
                } label: {
                    Label("Settle Up", systemImage: "arrow.left.arrow.right")
                }
            }
            if canEdit {
                Picker(selection: currency) {
                    ForEach(currencyCodes, id: \.self) { Text($0).tag($0) }
                } label: {
                    Label("Trip Currency", systemImage: "banknote")
                }
                .pickerStyle(.menu)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .accessibilityLabel("Split options")
    }

    /// The trip's currency for new expenses. Changing it never touches an
    /// expense already saved: each keeps the code it was made with.
    private var currency: Binding<String> {
        Binding {
            trip.defaultCurrencyCode()
        } set: { code in
            guard code != trip.currencyCode else { return }
            trip.currencyCode = code
            try? modelContext.saveIfNeeded()
        }
    }

    private var currencyCodes: [String] {
        let menu = TripMoney.menuCodes()
        let current = trip.defaultCurrencyCode()
        return menu.contains(current) ? menu : [current] + menu
    }

    /// Everyone with a key, and pending invitees greyed out beneath. Someone
    /// hidden from new splits still shows while they owe or are owed.
    private func balancePeople(_ ledger: TripLedger) -> [TripPerson] {
        split.people.roster.filter { person in
            guard let key = person.key else { return person.source == .pending }
            return !person.isHidden || !ledger.balances(of: key).isEmpty
        }
    }

    private func tint(_ minor: Int64) -> Color {
        minor > 0 ? .green : minor < 0 ? .orange : .secondary
    }
}

/// One person's balances on the Split face.
struct BalanceRow: View {
    let person: TripPerson
    let ledger: TripLedger
    let wording: SplitWording

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(person.label)
                .fontWeight(person.isMe ? .semibold : .regular)
            PersonBadge(person: person)
            Spacer(minLength: 8)
            if let key = person.key {
                let balances = ledger.balances(of: key)
                VStack(alignment: .trailing, spacing: 2) {
                    if balances.isEmpty {
                        Text(wording.balance(0, code: "", isMe: person.isMe))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(balances.keys.sorted(), id: \.self) { code in
                        let minor = balances[code] ?? 0
                        Text(wording.balance(minor, code: code, isMe: person.isMe))
                            .foregroundStyle(minor > 0 ? Color.green : Color.orange)
                    }
                }
                .font(.subheadline.monospacedDigit())
            } else {
                Text("Joins when they accept")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(person.source == .pending ? .secondary : .primary)
    }
}

/// A suggested transfer, with Record for someone who can edit.
struct TransferRow: View {
    let transfer: SettleUp.Transfer
    let wording: SplitWording
    let canEdit: Bool
    let record: () -> Void

    var body: some View {
        HStack {
            Text(wording.transfer(transfer))
                .font(.subheadline)
            Spacer(minLength: 8)
            if canEdit {
                Button("Record", action: record)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}

/// One expense or payment in the Split face's list.
struct ExpenseRow: View {
    let record: ExpenseRecord
    let wording: SplitWording
    let ledger: TripLedger

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.isPayment ? "arrow.left.arrow.right" : record.category.symbolName)
                .foregroundStyle(TripTrackerModule.accent.color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.isPayment ? wording.payment(record) : record.title)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                Text(record.isPayment ? TripMoney.format(record.amountMinor, code: record.currencyCode) : wording.paidBy(record))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !record.splitReadsAsStored {
                    Label("Split needs a look", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            if !record.isPayment, let me = wording.people.me,
               let text = wording.involvement(ledger.involvement(of: me, in: record), code: record.currencyCode) {
                Text(text)
                    .font(.caption.monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(tint(ledger.involvement(of: me, in: record)))
            }
        }
    }

    private func tint(_ involvement: ExpenseInvolvement) -> Color {
        switch involvement {
        case .lent: .green
        case .borrowed: .orange
        default: .secondary
        }
    }
}
