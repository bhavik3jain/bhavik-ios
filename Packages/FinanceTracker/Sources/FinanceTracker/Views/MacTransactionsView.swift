import Core
import CoreData
import SwiftUI

/// Spending's transactions on the Mac: the month's categories as one bar,
/// then every transaction in a sortable, searchable table. The phone's list —
/// a card per transaction under a header per day — spread across a desktop
/// window, put each amount a foot from its merchant. Double-click edits.
struct MacTransactionsView<Filter: View>: View {
    let transactions: [SharedFinanceTransaction]
    let isEditable: Bool
    let edit: (SharedFinanceTransaction) -> Void
    let delete: (SharedFinanceTransaction) -> Void
    /// The card filter, at the summary's trailing edge: in the toolbar it
    /// pushed Add into the overflow menu at ordinary window widths.
    @ViewBuilder let filter: () -> Filter

    @State private var sortOrder = [KeyPathComparator(\SharedFinanceTransaction.date, order: .reverse)]
    @State private var selection: NSManagedObjectID?
    @State private var search = ""

    private var shown: [SharedFinanceTransaction] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? transactions : transactions.filter { transaction in
            [transaction.merchant, transaction.category, transaction.expense, transaction.cardName]
                .contains { $0.localizedStandardContains(query) }
        }
        return matching.sorted(using: sortOrder)
    }

    var body: some View {
        let categories = SpendingSummary.byCategory(transactions)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(FinanceFormat.cents(SpendingSummary.total(transactions)))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text("spent · \(counted(transactions.count, "transaction"))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    filter()
                }
                if !categories.isEmpty {
                    CategoryBar(totals: categories)
                }
            }
            .padding(16)
            .background(.background.secondary, in: .rect(cornerRadius: 14))
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Table(shown, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Date", value: \.date) { transaction in
                    Text(transaction.date.formatted(.dateTime.month(.abbreviated).day()))
                        .monospacedDigit()
                }
                .width(min: 60, ideal: 70)
                TableColumn("Merchant", value: \.merchant) { transaction in
                    Text(transaction.merchant.isEmpty ? "Untitled" : transaction.merchant)
                }
                .width(min: 140, ideal: 200)
                TableColumn("Category", value: \.category) { transaction in
                    Text([transaction.category, transaction.expense].filter { !$0.isEmpty }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                .width(min: 110, ideal: 170)
                TableColumn("Card", value: \.cardName) { transaction in
                    Text(transaction.cardName)
                        .foregroundStyle(.secondary)
                }
                .width(min: 110, ideal: 170)
                TableColumn("Amount", value: \.actualCost) { transaction in
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(FinanceFormat.cents(transaction.actualCost))
                            .monospacedDigit()
                            .foregroundStyle(transaction.isRefund ? Color.green : Color.primary)
                        if transaction.isSplit {
                            Text("of \(FinanceFormat.cents(transaction.cost))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .width(min: 80, ideal: 100)
                .alignment(.numeric)
            }
            .tableRowBackgroundsPlain()
            .contextMenu(forSelectionType: NSManagedObjectID.self) { ids in
                if isEditable, let transaction = transaction(for: ids) {
                    Button("Edit…", systemImage: "pencil") { edit(transaction) }
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(transaction) }
                }
            } primaryAction: { ids in
                if isEditable, let transaction = transaction(for: ids) { edit(transaction) }
            }
            .searchable(text: $search, placement: .toolbar, prompt: "Merchant, category or card")
        }
    }

    private func transaction(for ids: Set<NSManagedObjectID>) -> SharedFinanceTransaction? {
        ids.first.flatMap { id in transactions.first { $0.objectID == id } }
    }
}

extension SharedFinanceTransaction {
    /// For the Mac table's Card column.
    var cardName: String { card.map { $0.name.isEmpty ? $0.displayName : $0.name } ?? "" }
}
