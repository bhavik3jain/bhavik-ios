import Core
import CoreData
import SwiftUI

/// Adds a card transaction, or edits one when handed it.
struct TransactionEditorView: View {
    let transaction: SharedFinanceTransaction?
    let defaultDate: Date

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @Environment(\.financePersistentContainer) private var container
    var data = FinanceFetches()

    @State private var costText = ""
    @State private var isRefund = false
    @State private var merchant = ""
    @State private var expense = ""
    @State private var date = Date.now
    @State private var card: SharedFinanceAccount?
    @State private var category = ""
    @State private var isPartlyOurs = false
    @State private var actualCostText = ""
    @State private var breakDown = ""
    @State private var addingCategory = false
    @State private var newCategory = ""
    @State private var loaded = false

    private var isNew: Bool { transaction == nil }

    private var cost: Double? {
        FinanceInput.parse(costText).map { isRefund ? -abs($0) : abs($0) }
    }

    private var actualCost: Double? {
        guard isPartlyOurs else { return cost }
        return FinanceInput.parse(actualCostText).map { isRefund ? -abs($0) : abs($0) }
    }

    private var canSave: Bool {
        cost != nil && actualCost != nil && card != nil && canEdit(transaction, in: container) && canEdit(card, in: container)
    }

    var body: some View {
        let snapshot = data.snapshot
        let cards = SpendingSummary.cardsByRecentUse(snapshot.cards)
        let categories = SpendingSummary.knownCategories(snapshot.transactions)
        SheetStack {
            Form {
                Section {
                    TextField("Cost", text: $costText)
                        .keyboardType(.decimalPad)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Toggle("Refund", isOn: $isRefund)
                    TextField("Merchant", text: $merchant)
                        .textInputAutocapitalization(.words)
                    TextField("Expense — what it was for", text: $expense)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }

                Section("Card") {
                    Picker("Card", selection: $card) {
                        if card == nil {
                            Text("Choose…").tag(SharedFinanceAccount?.none)
                        }
                        // The card being edited stays pickable even if it's
                        // since been archived.
                        if let current = transaction?.card, !cards.contains(current) {
                            Text(current.displayName).tag(SharedFinanceAccount?.some(current))
                        }
                        ForEach(cards) { option in
                            Text(option.displayName).tag(SharedFinanceAccount?.some(option))
                        }
                    }
                }

                Section("Category") {
                    ChipRow {
                        ForEach(chipCategories(categories), id: \.self) { option in
                            FinanceChip(
                                title: option,
                                isSelected: SpendingSummary.key(option) == SpendingSummary.key(category)
                            ) {
                                category = SpendingSummary.key(option) == SpendingSummary.key(category) ? "" : option
                            }
                        }
                        FinanceChip(title: "+ New", isSelected: false) {
                            newCategory = ""
                            addingCategory = true
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }

                Section {
                    Toggle("Only part of this is ours", isOn: $isPartlyOurs.animation())
                    if isPartlyOurs {
                        LabeledContent("Actual cost") {
                            TextField("Our share", text: $actualCostText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                        }
                    }
                    TextField("Break down (optional)", text: $breakDown, axis: .vertical)
                        .lineLimit(1...4)
                } footer: {
                    Text("Totals and budgets count only our share — the rest is what a friend owes back.")
                }
            }
            .navigationTitle(isNew ? "Add Transaction" : "Edit Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") { save(snapshot: snapshot) }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .textPrompt("New Category", isPresented: $addingCategory, text: $newCategory, prompt: "Name") {
                let trimmed = newCategory.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { category = trimmed }
            }
            .onAppear { load(cards: cards) }
        }
    }

    /// The known categories, plus the chosen one if it's new.
    private func chipCategories(_ known: [String]) -> [String] {
        let trimmed = category.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !known.contains(where: { SpendingSummary.key($0) == SpendingSummary.key(trimmed) }) else {
            return known
        }
        return [trimmed] + known
    }

    /// Once only: `onAppear` fires again when the alert closes, and reloading
    /// then would throw away whatever had been typed.
    private func load(cards: [SharedFinanceAccount]) {
        guard !loaded else { return }
        loaded = true
        guard let transaction else {
            date = defaultDate
            card = cards.first
            return
        }
        isRefund = transaction.cost < 0
        costText = FinanceFormat.editable(abs(transaction.cost))
        merchant = transaction.merchant
        expense = transaction.expense
        date = transaction.date
        card = transaction.card
        category = transaction.category
        isPartlyOurs = transaction.isSplit
        actualCostText = FinanceFormat.editable(abs(transaction.actualCost))
        breakDown = transaction.breakDown
    }

    private func save(snapshot: FinanceSnapshot) {
        guard let cost, let actualCost, let card else { return }
        // Into the card's own household, so the two can never be in
        // different stores.
        guard let household = card.household ?? snapshot.household else { return }
        let target = transaction ?? SharedFinanceTransaction(date: date, cost: cost, merchant: "", household: household)
        target.date = date
        target.cost = cost
        target.actualCost = actualCost
        target.merchant = merchant.trimmingCharacters(in: .whitespaces)
        target.expense = expense.trimmingCharacters(in: .whitespaces)
        target.category = category.trimmingCharacters(in: .whitespaces)
        target.breakDown = breakDown.trimmingCharacters(in: .whitespaces)
        target.card = card
        try? context.saveIfNeeded()
        dismiss()
    }
}
