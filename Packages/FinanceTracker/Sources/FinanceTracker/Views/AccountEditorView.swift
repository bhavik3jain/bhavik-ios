import Core
import CoreData
import SwiftUI

/// Adds an account, or edits one when handed it. A card takes a limit and
/// annual fee; everything else takes its balance for the latest month.
struct AccountEditorView: View {
    let account: SharedFinanceAccount?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @Environment(\.financePersistentContainer) private var container
    var data = FinanceFetches()

    @State private var institution = ""
    @State private var name = ""
    @State private var category = AccountCategory.cash
    @State private var owner: SharedFinanceOwner?
    @State private var limitText = ""
    @State private var annualFeeText = ""
    @State private var balanceText = ""
    @State private var isArchived = false
    @State private var loaded = false

    private var isNew: Bool { account == nil }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && canEdit(account, in: container)
    }

    var body: some View {
        let snapshot = data.snapshot
        let latest = snapshot.latestMonth
        SheetStack {
            Form {
                Section {
                    // A label and a short example rather than a sentence of
                    // placeholder: on the Mac's form the label sits beside
                    // the field.
                    TextField("Institution", text: $institution, prompt: Text("Capital One"))
                        .textInputAutocapitalization(.words)
                    TextField("Account", text: $name, prompt: Text("Checking"))
                        .textInputAutocapitalization(.words)
                    Picker("Whose", selection: $owner) {
                        Text("No one").tag(SharedFinanceOwner?.none)
                        ForEach(snapshot.owners) { person in
                            Text(person.name).tag(SharedFinanceOwner?.some(person))
                        }
                    }
                }

                Section("Category") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                        ForEach(AccountCategory.allCases) { option in
                            CategoryTile(category: option, isSelected: option == category) {
                                category = option
                            }
                            // Changing an existing account into or out of a
                            // card would strand its balances or its
                            // transactions; only a new one can be anything.
                            // A cash account that's been paid from can't
                            // leave the categories that take transactions.
                            .disabled(!isNew && ((option == .card) != (account?.category == .card)
                                || ((account?.transactionCount ?? 0) > 0 && !option.takesTransactions)))
                        }
                    }
                    .padding(.vertical, 4)
                }

                if category == .card {
                    Section("Card") {
                        LabeledContent("Limit") {
                            TextField("0", text: $limitText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Annual fee") {
                            TextField("0", text: $annualFeeText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } else {
                    Section {
                        LabeledContent(category == .loan ? "Still owed" : "Balance") {
                            TextField("0", text: $balanceText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                    } header: {
                        Text(latest.map { "\($0.title) balance" } ?? "Balance")
                    } footer: {
                        if latest == nil {
                            Text("Starts \(YearMonth(containing: .now).title).")
                        }
                    }
                }

                if !isNew {
                    Section {
                        Toggle("Archived", isOn: $isArchived)
                    } footer: {
                        Text("Keeps its history; left out of new months.")
                    }
                }
            }
            .navigationTitle(isNew ? "New Account" : "Edit Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .onAppear { load(latest: latest) }
        }
    }

    private func load(latest: SharedFinanceMonth?) {
        guard !loaded else { return }
        loaded = true
        guard let account else { return }
        institution = account.institution
        name = account.name
        category = account.category
        owner = account.owner
        limitText = FinanceFormat.editable(account.limit)
        annualFeeText = FinanceFormat.editable(account.annualFee)
        if let latest, let balance = latest.balance(for: account) {
            balanceText = FinanceFormat.editable(balance.amount)
        }
        isArchived = account.isArchived
    }

    private func save() {
        let household = account?.household ?? FinanceHouseholdResolver.forWriting(in: context, container: container)
        let target = account ?? SharedFinanceAccount(institution: "", name: "", category: category, household: household)
        target.institution = institution.trimmingCharacters(in: .whitespaces)
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.category = category
        // A person from another household can't be related across stores;
        // the picker only offers the shown household's, which is this one
        // unless a view-only share is showing — and then Save is disabled.
        target.owner = owner?.household == household ? owner : nil
        target.isArchived = isArchived
        if category == .card {
            target.limit = FinanceInput.parse(limitText) ?? 0
            target.annualFee = FinanceInput.parse(annualFeeText) ?? 0
        } else {
            let typed = FinanceInput.parse(balanceText)
            // The first account ever also starts the first month, so its
            // balance has somewhere to go.
            let month = household.latestMonth ?? MonthRollover.startFirstMonth(in: household)
            // Only a changed figure counts as updated: saving the editor
            // for a new name mustn't tick off a balance nobody checked.
            if let typed, typed != month.balance(for: target)?.amount {
                month.setBalance(typed, for: target)
            } else if month.balance(for: target) == nil, !target.isArchived {
                // No figure yet: a zero still counts it into the month, as
                // not yet updated.
                _ = SharedFinanceBalance(account: target, month: month, amount: 0, edited: false)
            }
        }
        try? context.saveIfNeeded()
        dismiss()
    }
}

private struct CategoryTile: View {
    let category: AccountCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: category.symbolName)
                    .font(.title3)
                Text(category.singularName)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                isSelected ? FinanceTrackerModule.accent.color : Color.secondary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
        .buttonStyle(.plain)
    }
}
