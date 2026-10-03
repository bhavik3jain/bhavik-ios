import Charts
import Core
import CoreData
import SwiftUI

/// A month's transactions — on cards and from cash accounts — and how they
/// sit against its budgets.
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
    @State private var categoryEditor: CategoryBudgetEditorView.Target?

    var body: some View {
        let snapshot = data.snapshot
        let isEditable = snapshot.canEdit
        let period = chosenPeriod ?? snapshot.latestMonth?.period ?? YearMonth(containing: .now)
        NavigationStack {
            Group {
                if layout == .sidebar, mode == .transactions, !snapshot.paymentAccounts.isEmpty {
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
                        addButton(snapshot, month: snapshot.household?.month(for: period))
                    }
                }
            }
            .sheet(isPresented: $adding) {
                TransactionEditorView(transaction: nil, defaultDate: Self.defaultDate(in: period))
            }
            .sheet(item: $editing) { transaction in
                TransactionEditorView(transaction: transaction, defaultDate: transaction.date)
            }
            .sheet(item: $categoryEditor) { target in
                CategoryBudgetEditorView(target: target)
            }
            .onChange(of: snapshot.paymentAccounts) { _, accounts in
                if let cardFilter, !accounts.contains(cardFilter) { self.cardFilter = nil }
            }
        }
    }

    /// Transactions adds a transaction, Budget a category, and Categories
    /// offers both.
    @ViewBuilder
    private func addButton(_ snapshot: FinanceSnapshot, month: SharedFinanceMonth?) -> some View {
        let addTransaction = Button("Add Transaction", systemImage: "creditcard") { adding = true }
            .disabled(snapshot.paymentAccounts.isEmpty)
        let addCategory = Button("Add Category", systemImage: "tag") {
            if let month { categoryEditor = .init(month: month, category: nil) }
        }
        .disabled(month == nil)
        switch mode {
        case .transactions:
            Button {
                adding = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add Transaction")
            .disabled(snapshot.paymentAccounts.isEmpty)
        case .categories:
            Menu {
                addTransaction
                addCategory
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add")
        case .budget:
            Button {
                if let month { categoryEditor = .init(month: month, category: nil) }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add Category")
            .disabled(month == nil)
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
                categorySections(snapshot, period: period, isEditable: isEditable)
            case .budget:
                budgetSections(snapshot, period: period, isEditable: isEditable)
            }
        }
        // Categories on the Mac: a donut and a bar per category read better
        // held to a width than stretched across the window.
        .frame(maxWidth: layout == .sidebar && mode == .categories ? 900 : .infinity)
        .frame(maxWidth: .infinity)
    }

    /// A chip per card, and per cash account paid from this month, filtering
    /// Transactions and Categories alike.
    private func cardChips(_ snapshot: FinanceSnapshot, period: YearMonth, monthTransactions: [SharedFinanceTransaction]) -> some View {
        ChipRow {
            FinanceChip(
                title: "All",
                detail: FinanceFormat.money(SpendingSummary.total(monthTransactions)),
                isSelected: cardFilter == nil
            ) { cardFilter = nil }
            ForEach(Self.filterAccounts(snapshot, period: period)) { card in
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

    /// What the filter offers: every card still open, and any account —
    /// cash ones included — with spending in `period`. A checking account
    /// nobody paid from this month would only be a chip reading $0.
    static func filterAccounts(_ snapshot: FinanceSnapshot, period: YearMonth) -> [SharedFinanceAccount] {
        snapshot.paymentAccounts.filter { account in
            account.spend(in: period) != 0 || (account.category == .card && !account.isArchived)
        }
    }

    // MARK: - Categories

    @ViewBuilder
    private func categorySections(_ snapshot: FinanceSnapshot, period: YearMonth, isEditable: Bool) -> some View {
        let monthTransactions = SpendingSummary.transactions(snapshot.transactions, in: period)
        let shown = cardFilter.map { card in monthTransactions.filter { $0.card == card } } ?? monthTransactions
        if Self.filterAccounts(snapshot, period: period).count > 1 {
            Section {
                cardChips(snapshot, period: period, monthTransactions: monthTransactions)
            }
        }
        CategoryBreakdownSections(transactions: shown, periodTitle: period.title)

        // The month's own categories with nothing spent yet: otherwise one
        // just added here would appear nowhere on this screen.
        if cardFilter == nil, let month = snapshot.household?.month(for: period) {
            let spentKeys = Set(monthTransactions.map { SpendingSummary.key($0.category) })
            let unspent = month.sortedBudgets.filter { !spentKeys.contains(SpendingSummary.key($0.category)) }
            if !unspent.isEmpty {
                Section("Nothing spent yet") {
                    ForEach(unspent) { budget in
                        Button {
                            if isEditable { categoryEditor = .init(month: month, category: budget.category) }
                        } label: {
                            LabeledContent(budget.category) {
                                Text(budget.hasLimit ? "\(FinanceFormat.money(budget.limit)) budget" : "No budget")
                                    .monospacedDigit()
                            }
                            .contentShape(Rectangle())
                        }
                        .tint(.primary)
                    }
                }
            }
        }
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
            Text("All Accounts").tag(SharedFinanceAccount?.none)
            Divider()
            ForEach(Self.filterAccounts(snapshot, period: period)) { card in
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

        if snapshot.paymentAccounts.isEmpty {
            Section {
                Text("Add a card or a cash account under Holdings → Accounts first; every transaction is paid with one.")
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

        if shown.isEmpty, !snapshot.paymentAccounts.isEmpty {
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

            if status.lines.isEmpty, status.unbudgetedLines.isEmpty {
                Section {
                    Text(isEditable
                         ? "No categories in \(period.monthName) yet. Tap + to add one, or add a transaction."
                         : "No categories in \(period.monthName) yet.")
                        .foregroundStyle(.secondary)
                }
            }

            if !status.lines.isEmpty {
                Section {
                    ForEach(status.lines) { line in
                        budgetRow(month: month, category: line.category, isEditable: isEditable) {
                            BudgetLineRow(line: line, state: status.state(of: line), pace: status.pace)
                        }
                    }
                } header: {
                    Text("Budgeted")
                } footer: {
                    Text("The line on each bar is how far through \(period.monthName) we are. Budgets carry into the next month when it's started.")
                }
            }

            if !status.unbudgetedLines.isEmpty {
                Section {
                    ForEach(status.unbudgetedLines) { line in
                        budgetRow(month: month, category: line.isUncategorised ? nil : line.category, isEditable: isEditable) {
                            UnbudgetedLineRow(line: line)
                        }
                    }
                } header: {
                    Text("No budget")
                } footer: {
                    if isEditable {
                        Text("Tap a category to give it a budget.")
                    }
                }
            }
        } else {
            Section {
                Text("Start \(period.title) under Months to give it a budget.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A Budget line that opens its category's editor, with a swipe to take
    /// the category off the month. `category` is nil for "Other", which no
    /// budget can match.
    @ViewBuilder
    private func budgetRow(
        month: SharedFinanceMonth,
        category: String?,
        isEditable: Bool,
        @ViewBuilder label: () -> some View
    ) -> some View {
        let budget = category.flatMap { month.budget(for: $0) }
        Button {
            if isEditable, let category { categoryEditor = .init(month: month, category: category) }
        } label: {
            label()
                .contentShape(Rectangle())
        }
        .tint(.primary)
        .swipeActions(edge: .trailing) {
            if isEditable, let budget {
                Button("Remove", systemImage: "trash", role: .destructive) {
                    context.delete(budget)
                    try? context.saveIfNeeded()
                }
            }
        }
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

/// A category with no budget: what's gone on it, in grey — never a bar
/// that can turn orange.
private struct UnbudgetedLineRow: View {
    let line: UnbudgetedLine

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(line.category)
                .fontWeight(.semibold)
            Spacer()
            Text(line.spent == 0 ? "Nothing spent" : "\(FinanceFormat.money(line.spent)) spent")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
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
