import Core
import CoreData
import SwiftUI

/// Adds a spending category to a month, with its budget or "No budget", or
/// changes one already there. Before it, a category only appeared once a
/// transaction used it, and the Budget screen needed each one added again by
/// hand — and a budget added there started at $0, so it read as over (orange)
/// at the first purchase.
struct CategoryBudgetEditorView: View {
    /// What the sheet was opened on.
    struct Target: Identifiable {
        let month: SharedFinanceMonth
        /// nil adds a new category.
        let category: String?

        var id: String { "\(month.objectID)|\(category.map(SpendingSummary.key) ?? "+")" }
    }

    let target: Target

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @Environment(\.financePersistentContainer) private var container

    @State private var name = ""
    @State private var hasBudget = true
    @State private var limitText = ""
    @State private var loaded = false

    private var isNew: Bool { target.category == nil }
    private var month: SharedFinanceMonth { target.month }
    private var existing: SharedFinanceBudget? { target.category.flatMap { month.budget(for: $0) } }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var limit: Double? { FinanceInput.parse(limitText).map(abs) }

    private var canSave: Bool {
        !trimmedName.isEmpty && (!hasBudget || limit != nil) && canEdit(month, in: container)
    }

    var body: some View {
        SheetStack {
            Form {
                if isNew {
                    Section {
                        TextField("Name", text: $name)
                            .textInputAutocapitalization(.words)
                    }
                }

                Section {
                    Picker("Budget", selection: $hasBudget.animation()) {
                        Text("Monthly limit").tag(true)
                        Text("No budget").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if hasBudget {
                        LabeledContent("Limit") {
                            TextField("Amount", text: $limitText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                        }
                    }
                } footer: {
                    if hasBudget {
                        Text("For \(month.period?.monthName ?? "this month"). Budgets carry into the next month when it's started.")
                    } else {
                        Text("Its spending still shows under Budget, but never counts against the month or turns orange.")
                    }
                }

                if existing != nil {
                    Section {
                        Button("Remove from Budget", role: .destructive) {
                            if let existing { context.delete(existing) }
                            try? context.saveIfNeeded()
                            dismiss()
                        }
                        .disabled(!canEdit(month, in: container))
                    } footer: {
                        Text("Its transactions keep their category, and it's listed again, with no budget, while they're in the month.")
                    }
                }
            }
            .navigationTitle(target.category ?? "New Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .onAppear(perform: load)
        }
    }

    /// Once only, like the transaction editor: `onAppear` fires again after
    /// anything presented over the sheet closes.
    private func load() {
        guard !loaded else { return }
        loaded = true
        name = target.category ?? ""
        // A category only spent on so far opens ready for a limit; one kept
        // with "No budget" opens on that.
        if let existing {
            hasBudget = existing.hasLimit
            limitText = existing.hasLimit ? FinanceFormat.editable(existing.limit) : ""
        }
    }

    private func save() {
        month.setBudget(hasBudget ? limit : nil, for: trimmedName)
        try? context.saveIfNeeded()
        dismiss()
    }
}
