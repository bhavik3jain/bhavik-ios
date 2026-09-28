import Charts
import Core
import CoreData
import SwiftUI

/// A month's card transactions and how they sit against its budgets.
struct SpendingView: View {
    @Environment(\.moduleLayout) private var layout
    @Environment(\.managedObjectContext) private var context
    @Environment(\.financePersistentContainer) private var container
    var data = FinanceFetches()

    private enum Mode: String, CaseIterable, Identifiable {
        case transactions = "Transactions"
        case categories = "Categories"
        case budget = "Budget"
        var id: String { rawValue }
    }

    /// Remembered, so Spending reopens on the view last used.
    @AppStorage("finance.spendingMode") private var mode = Mode.transactions
    /// nil follows the latest month.
    @State private var chosenPeriod: YearMonth?
    @State private var cardFilter: SharedFinanceAccount?
    @State private var editing: SharedFinanceTransaction?
    @State private var adding = false
    @State private var editingBudgets = false
    @State private var addingBudget = false
    @State private var newBudgetCategory = ""

    var body: some View {
        let snapshot = data.snapshot
        let isEditable = snapshot.canEdit
        let period = chosenPeriod ?? snapshot.latestMonth?.period ?? YearMonth(containing: .now)
        NavigationStack {
            Group {
                if layout == .sidebar, mode == .transactions, !snapshot.cards.isEmpty {
                    macTransactions(snapshot, period: period, isEditable: isEditable)
                } else {
                    list(snapshot, period: period, isEditable: isEditable)
                }
            }
            .navigationTitle("Spending")
            .toolbar {
                if layout == .sidebar {
                    ToolbarItem(placement: .primaryAction) {
                        Picker("View", selection: $mode) {
                            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                ToolbarItem(placement: .navigation) {
                    monthMenu(snapshot, selected: period)
                }
                if isEditable {
                    ToolbarItem(placement: .primaryAction) {
                        switch mode {
                        case .transactions, .categories:
                            Button {
                                adding = true
                            } label: {
                                Image(systemName: "plus")
                            }
                            .accessibilityLabel("Add Transaction")
                            .disabled(snapshot.cards.isEmpty)
                        case .budget:
                            Button(editingBudgets ? "Done" : "Edit") {
                                if editingBudgets { try? context.saveIfNeeded() }
                                editingBudgets.toggle()
                            }
                            .disabled(snapshot.household?.month(for: period) == nil)
                        }
                    }
                }
            }
            .sheet(isPresented: $adding) {
                TransactionEditorView(transaction: nil, defaultDate: Self.defaultDate(in: period))
            }
            .sheet(item: $editing) { transaction in
                TransactionEditorView(transaction: transaction, defaultDate: transaction.date)
            }
            .textPrompt("Add Budget", isPresented: $addingBudget, text: $newBudgetCategory, prompt: "Category") {
                addBudget(in: snapshot.household?.month(for: period))
            }
            .onChange(of: snapshot.cards) { _, cards in
                if let cardFilter, !cards.contains(cardFilter) { self.cardFilter = nil }
            }
        }
    }

    // MARK: - Transactions

    private func list(_ snapshot: FinanceSnapshot, period: YearMonth, isEditable: Bool) -> some View {
        List {
            // On the Mac this switch is in the toolbar, not a list row.
            if layout == .tabs {
                Section {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }

            switch mode {
            case .transactions:
                transactionSections(snapshot, period: period, isEditable: isEditable)
            case .categories:
                categorySections(snapshot, period: period)
            case .budget:
                budgetSections(snapshot, period: period, isEditable: isEditable)
            }
        }
        // Categories on the Mac: a donut and a bar per category read better
        // held to a width than stretched across the window.
        .frame(maxWidth: layout == .sidebar && mode == .categories ? 900 : .infinity)
        .frame(maxWidth: .infinity)
    }

    /// A chip per card, filtering Transactions and Categories alike.
    private func cardChips(_ snapshot: FinanceSnapshot, period: YearMonth, monthTransactions: [SharedFinanceTransaction]) -> some View {
        ChipRow {
            FinanceChip(
                title: "All",
                detail: FinanceFormat.money(SpendingSummary.total(monthTransactions)),
                isSelected: cardFilter == nil
            ) { cardFilter = nil }
            ForEach(snapshot.cards.filter { !$0.isArchived || $0.spend(in: period) != 0 }) { card in
                FinanceChip(
                    title: card.name.isEmpty ? card.displayName : card.name,
                    detail: FinanceFormat.money(card.spend(in: period)),
                    isSelected: cardFilter == card
                ) { cardFilter = card }
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    // MARK: - Categories

    @ViewBuilder
    private func categorySections(_ snapshot: FinanceSnapshot, period: YearMonth) -> some View {
        let monthTransactions = SpendingSummary.transactions(snapshot.transactions, in: period)
        let shown = cardFilter.map { card in monthTransactions.filter { $0.card == card } } ?? monthTransactions
        if snapshot.cards.count > 1 {
            Section {
                cardChips(snapshot, period: period, monthTransactions: monthTransactions)
            }
        }
        CategoryBreakdownSections(transactions: shown, periodTitle: period.title)
    }

    /// The Mac's transactions: a table, with the card filter in the toolbar
    /// rather than a row of chips above it.
    private func macTransactions(_ snapshot: FinanceSnapshot, period: YearMonth, isEditable: Bool) -> some View {
        let monthTransactions = SpendingSummary.transactions(snapshot.transactions, in: period)
        let shown = cardFilter.map { card in monthTransactions.filter { $0.card == card } } ?? monthTransactions
        return MacTransactionsView(
            transactions: shown,
            isEditable: isEditable,
            edit: { editing = $0 },
            delete: { transaction in
                context.delete(transaction)
                try? context.saveIfNeeded()
            },
            filter: { cardMenu(snapshot, period: period) }
        )
        .overlay {
            if shown.isEmpty {
                ContentUnavailableView("Nothing in \(period.title) yet", systemImage: "creditcard")
            }
        }
    }

    private func cardMenu(_ snapshot: FinanceSnapshot, period: YearMonth) -> some View {
        Picker(selection: $cardFilter) {
            Text("All Cards").tag(SharedFinanceAccount?.none)
            Divider()
            ForEach(snapshot.cards.filter { !$0.isArchived || $0.spend(in: period) != 0 }) { card in
                Text(card.name.isEmpty ? card.displayName : card.name).tag(Optional(card))
            }
        } label: {
            Label("Card", systemImage: "creditcard")
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder
    private func transactionSections(_ snapshot: FinanceSnapshot, period: YearMonth, isEditable: Bool) -> some View {
        let monthTransactions = SpendingSummary.transactions(snapshot.transactions, in: period)
        let shown = cardFilter.map { card in monthTransactions.filter { $0.card == card } } ?? monthTransactions

        if snapshot.cards.isEmpty {
            Section {
                Text("Add a card under Holdings → Accounts first; transactions are charged to a card.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section {
                cardChips(snapshot, period: period, monthTransactions: monthTransactions)

                let categories = SpendingSummary.byCategory(shown)
                if !categories.isEmpty {
                    CategoryBar(totals: categories)
                }
            }
        }

        if shown.isEmpty, !snapshot.cards.isEmpty {
            Section {
                Text("Nothing in \(period.title) yet.")
                    .foregroundStyle(.secondary)
            }
        }

        ForEach(SpendingSummary.byDay(shown)) { day in
            Section {
                ForEach(day.transactions) { transaction in
                    Button {
                        if isEditable { editing = transaction }
                    } label: {
                        TransactionRow(transaction: transaction)
                    }
                    .tint(.primary)
                    .swipeActions(edge: .trailing) {
                        if isEditable {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                context.delete(transaction)
                                try? context.saveIfNeeded()
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text(day.day, format: .dateTime.weekday(.wide).day().month(.abbreviated))
                    Spacer()
                    Text(FinanceFormat.cents(day.total))
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - Budget

    @ViewBuilder
    private func budgetSections(_ snapshot: FinanceSnapshot, period: YearMonth, isEditable: Bool) -> some View {
        if let month = snapshot.household?.month(for: period) {
            let status = BudgetStatus(month: month)
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Left this month")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(FinanceFormat.money(status.left))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(status.left < 0 ? Color.orange : Color.primary)
                    Text("\(FinanceFormat.money(status.totalSpent)) spent of \(FinanceFormat.money(status.totalLimit))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    BudgetBar(fraction: status.totalLimit > 0 ? status.totalSpent / status.totalLimit : 0,
                              pace: status.pace,
                              state: status.overallState)
                    if status.unbudgeted != 0 {
                        Text("\(FinanceFormat.money(status.unbudgeted)) more in categories with no budget.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                if status.lines.isEmpty {
                    Text("No budgets for \(period.monthName). Tap Edit to add one.")
                        .foregroundStyle(.secondary)
                }
                ForEach(status.lines) { line in
                    if editingBudgets, let budget = month.budget(for: line.category) {
                        BudgetLimitRow(budget: budget) { try? context.saveIfNeeded() }
                    } else {
                        BudgetLineRow(line: line, state: status.state(of: line), pace: status.pace)
                    }
                }
                .onDelete { offsets in
                    guard isEditable, editingBudgets else { return }
                    for index in offsets {
                        if let budget = month.budget(for: status.lines[index].category) {
                            context.delete(budget)
                        }
                    }
                    try? context.saveIfNeeded()
                }
                if editingBudgets {
                    Button("Add Budget", systemImage: "plus") {
                        newBudgetCategory = ""
                        addingBudget = true
                    }
                }
            } header: {
                Text("By category")
            } footer: {
                Text("The line on each bar is how far through \(period.monthName) we are. Budgets carry into the next month when it's started.")
            }
        } else {
            Section {
                Text("Start \(period.title) under Months to give it a budget.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func addBudget(in month: SharedFinanceMonth?) {
        let category = newBudgetCategory.trimmingCharacters(in: .whitespaces)
        guard let month, !category.isEmpty, month.budget(for: category) == nil else { return }
        _ = SharedFinanceBudget(category: category, limit: 0, month: month)
        try? context.saveIfNeeded()
    }

    // MARK: - Month

    private func monthMenu(_ snapshot: FinanceSnapshot, selected: YearMonth) -> some View {
        Menu {
            ForEach(Self.periods(snapshot)) { period in
                Button {
                    chosenPeriod = period
                } label: {
                    if period == selected {
                        Label(period.title, systemImage: "checkmark")
                    } else {
                        Text(period.title)
                    }
                }
            }
        } label: {
            Label(selected.shortName, systemImage: "calendar")
                .labelStyle(.titleAndIcon)
        }
    }

    /// Every started month, plus any month with transactions, plus this one —
    /// newest first.
    private static func periods(_ snapshot: FinanceSnapshot) -> [YearMonth] {
        var periods = Set(snapshot.months.compactMap(\.period))
        periods.formUnion(snapshot.transactions.map { YearMonth(containing: $0.date) })
        periods.insert(YearMonth(containing: .now))
        return periods.sorted(by: >)
    }

    /// Today if it's in the month being looked at, else that month's first.
    static func defaultDate(in period: YearMonth, asOf now: Date = .now) -> Date {
        period.contains(now) ? now : period.start
    }
}

struct TransactionRow: View {
    @ObservedObject var transaction: SharedFinanceTransaction

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.merchant.isEmpty ? "Untitled" : transaction.merchant)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if !transaction.detailLine.isEmpty {
                    Text(transaction.detailLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(FinanceFormat.cents(transaction.actualCost))
                    .monospacedDigit()
                    .foregroundStyle(transaction.isRefund ? Color.green : Color.primary)
                if transaction.isSplit {
                    Text("of \(FinanceFormat.cents(transaction.cost))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .contentShape(Rectangle())
    }
}

/// Where the month's money went, as one stacked bar.
struct CategoryBar: View {
    let totals: [SpendingTotal]

    var body: some View {
        let positive = totals.filter { $0.total > 0 }
        let domain = CategoryPalette.domain(totals.map(\.name))
        Chart(positive) { total in
            BarMark(x: .value("Spent", total.total))
                .foregroundStyle(by: .value("Category", total.name))
        }
        .chartForegroundStyleScale(domain: domain, range: CategoryPalette.range(for: domain))
        .chartXAxis(.hidden)
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: positive.count > 4 ? 90 : 64)
    }
}

/// A budget bar: the fill, coloured by state, and a tick at the pace.
private struct BudgetBar: View {
    let fraction: Double
    let pace: Double
    let state: BudgetState

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(state.color)
                    .frame(width: width * min(max(fraction, 0), 1))
                Rectangle()
                    .fill(Color.primary.opacity(0.6))
                    .frame(width: 2, height: 12)
                    .offset(x: width * min(max(pace, 0), 1) - 1)
            }
        }
        .frame(height: 8)
        .padding(.vertical, 2)
        .accessibilityElement()
        .accessibilityLabel("\(Int((fraction * 100).rounded())) percent spent, \(Int((pace * 100).rounded())) percent of the month gone")
    }
}

private struct BudgetLineRow: View {
    let line: BudgetLine
    let state: BudgetState
    let pace: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(line.category)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(FinanceFormat.money(line.spent)) of \(FinanceFormat.money(line.limit))")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            BudgetBar(fraction: line.fractionSpent, pace: pace, state: state)
            Text(caption)
                .font(.caption)
                .foregroundStyle(state == .onTrack ? Color.secondary : state.color)
        }
        .padding(.vertical, 2)
    }

    private var caption: String {
        switch state {
        case .onTrack: "\(FinanceFormat.money(line.remaining)) left"
        case .aheadOfPace: "\(FinanceFormat.money(line.remaining)) left · ahead of pace"
        case .over: "\(FinanceFormat.money(-line.remaining)) over"
        }
    }
}

private struct BudgetLimitRow: View {
    @ObservedObject var budget: SharedFinanceBudget
    let save: () -> Void

    var body: some View {
        HStack {
            Text(budget.category)
            Spacer()
            AmountField(title: "Limit", value: budget.limit, commit: { budget.limit = $0 }, endEditing: save)
                .frame(maxWidth: 140)
        }
    }
}

extension BudgetState {
    /// Green on track, amber ahead of pace, orange over.
    var color: Color {
        switch self {
        case .onTrack: .green
        case .aheadOfPace: Color(red: 0.95, green: 0.70, blue: 0.10)
        case .over: .orange
        }
    }
}
