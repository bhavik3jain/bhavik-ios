import Core // Only reached on macOS, where Core stands in for the iOS-only SwiftUI API below.
import CoreData
import SwiftUI

/// Enters a new balance, either as the figure the programme now shows or as
/// an amount earned or spent.
struct UpdateBalanceView: View {
    let account: SharedPointsAccount

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context

    private enum Mode: String, CaseIterable, Identifiable {
        case total = "New Balance"
        case change = "Earned / Spent"
        var id: String { rawValue }
    }

    @State private var mode = Mode.total
    @State private var amountText = ""
    @State private var isSpend = false
    @State private var note = ""
    @FocusState private var isAmountFocused: Bool

    private var unit: String { "\(account.kind.unit.singular)s" }

    private var newBalance: Int? {
        guard let amount = PointsInput.parse(amountText) else { return nil }
        switch mode {
        case .total: return max(amount, 0)
        case .change: return max(account.balance + (isSpend ? -amount : amount), 0)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Entry", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section {
                    if mode == .change {
                        Picker("", selection: $isSpend) {
                            Text("Earned").tag(false)
                            Text("Spent").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                    TextField(mode == .total ? "Balance in \(unit)" : "How many \(unit)", text: $amountText)
                        .keyboardType(.numberPad)
                        .focused($isAmountFocused)
                    TextField("Note (optional)", text: $note)
                } footer: {
                    if let newBalance {
                        Text("Currently \(account.balance.formatted()). New balance \(newBalance.formatted()) \(unit).")
                    } else {
                        Text("Currently \(account.balance.formatted()) \(unit).")
                    }
                }
            }
            .navigationTitle("Update Balance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(newBalance == nil)
                }
            }
            .onAppear { isAmountFocused = true }
        }
    }

    private func save() {
        guard let newBalance else { return }
        account.recordBalance(newBalance, note: note.trimmingCharacters(in: .whitespaces))
        try? context.saveIfNeeded()
        dismiss()
    }
}
