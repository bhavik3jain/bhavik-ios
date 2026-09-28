import Foundation

/// A total for one category, one card or one day.
public struct SpendingTotal: Identifiable, Equatable, Sendable {
    public let name: String
    public let total: Double

    public init(name: String, total: Double) {
        self.name = name
        self.total = total
    }

    public var id: String { name }
}

/// One category's slice of a month: its total, how many transactions made
/// it, its share of everything spent, and the same split by expense (the
/// sub-category typed under it: "Groceries · Weekly").
public struct CategoryBreakdown: Identifiable, Equatable, Sendable {
    public let name: String
    public let total: Double
    public let count: Int
    /// Of the month's positive spending, 0...1. A category that nets to a
    /// refund has none.
    public let share: Double
    /// Biggest first; "Other" for transactions with no expense typed.
    public let expenses: [SpendingTotal]

    public var id: String { name }
}

/// One day's transactions, for the list's sections.
public struct SpendingDay: Identifiable {
    public let day: Date
    public let transactions: [SharedFinanceTransaction]

    public var id: Date { day }
    public var total: Double { transactions.reduce(0) { $0 + $1.actualCost } }
}

/// The arithmetic behind the Transactions screen. Every total uses
/// `actualCost` — our share — never the statement figure.
public enum SpendingSummary {
    /// What the category chips offer before anything has been typed.
    public static let suggestedCategories = [
        "Food", "Health", "Travel", "Car", "Home", "Groceries",
        "Entertainment", "Personal", "Clothes", "Work", "Subscriptions", "Parking",
    ]

    /// Label for a transaction with no category typed.
    public static let uncategorised = "Other"

    /// How categories are compared: "food " and "Food" are one budget.
    public static func key(_ category: String) -> String {
        category.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// `period`'s transactions, optionally on one card, newest first.
    public static func transactions(
        _ all: [SharedFinanceTransaction],
        in period: YearMonth,
        card: SharedFinanceAccount? = nil
    ) -> [SharedFinanceTransaction] {
        all
            .filter { period.contains($0.date) && (card == nil || $0.card == card) }
            .sorted { $0.date != $1.date ? $0.date > $1.date : $0.createdAt > $1.createdAt }
    }

    public static func total(_ transactions: [SharedFinanceTransaction]) -> Double {
        transactions.reduce(0) { $0 + $1.actualCost }
    }

    /// Spend per category key, for matching against budgets.
    static func totalsByKey(_ transactions: [SharedFinanceTransaction]) -> [String: Double] {
        var totals: [String: Double] = [:]
        for transaction in transactions {
            totals[key(transaction.category), default: 0] += transaction.actualCost
        }
        return totals
    }

    /// Biggest first, each named as it was first typed.
    public static func byCategory(_ transactions: [SharedFinanceTransaction]) -> [SpendingTotal] {
        var totals: [String: Double] = [:]
        var names: [String: String] = [:]
        for transaction in transactions {
            let trimmed = transaction.category.trimmingCharacters(in: .whitespaces)
            let categoryKey = key(trimmed)
            totals[categoryKey, default: 0] += transaction.actualCost
            if names[categoryKey] == nil { names[categoryKey] = trimmed.isEmpty ? uncategorised : trimmed }
        }
        return totals
            .map { SpendingTotal(name: names[$0.key] ?? $0.key, total: $0.value) }
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.name < $1.name }
    }

    /// Every category of `transactions`, biggest first, with its share and
    /// its split by expense. Categories and expenses group the way budgets do
    /// ("food " and "Food" are one), each named as it was first typed.
    public static func breakdown(_ transactions: [SharedFinanceTransaction]) -> [CategoryBreakdown] {
        let categories = byCategory(transactions)
        let spent = categories.reduce(0) { $0 + max($1.total, 0) }
        return categories.map { category in
            let members = self.transactions(transactions, inCategory: category.name)
            var totals: [String: Double] = [:]
            var names: [String: String] = [:]
            for transaction in members {
                let trimmed = transaction.expense.trimmingCharacters(in: .whitespaces)
                let expenseKey = key(trimmed)
                totals[expenseKey, default: 0] += transaction.actualCost
                if names[expenseKey] == nil { names[expenseKey] = trimmed.isEmpty ? uncategorised : trimmed }
            }
            let expenses = totals
                .map { SpendingTotal(name: names[$0.key] ?? $0.key, total: $0.value) }
                .sorted { $0.total != $1.total ? $0.total > $1.total : $0.name < $1.name }
            return CategoryBreakdown(
                name: category.name,
                total: category.total,
                count: members.count,
                share: spent > 0 ? max(category.total, 0) / spent : 0,
                expenses: expenses
            )
        }
    }

    /// The transactions filed under `category`, compared the way budgets are;
    /// "Other" also takes those with no category typed.
    public static func transactions(_ transactions: [SharedFinanceTransaction], inCategory category: String) -> [SharedFinanceTransaction] {
        let wanted = category == uncategorised ? "" : key(category)
        return transactions.filter { transaction in
            let own = key(transaction.category)
            return own == wanted || (category == uncategorised && own == key(uncategorised))
        }
    }

    /// Newest day first; within a day, newest first.
    public static func byDay(_ transactions: [SharedFinanceTransaction]) -> [SpendingDay] {
        let grouped = Dictionary(grouping: transactions) { FinanceCalendar.startOfDay($0.date) }
        return grouped
            .map { day, items in
                SpendingDay(day: day, transactions: items.sorted { $0.date != $1.date ? $0.date > $1.date : $0.createdAt > $1.createdAt })
            }
            .sorted { $0.day > $1.day }
    }

    /// Categories for the chips: those already used, most-used first, then
    /// the suggestions not yet used.
    public static func knownCategories(_ transactions: [SharedFinanceTransaction]) -> [String] {
        var counts: [String: Int] = [:]
        var names: [String: String] = [:]
        for transaction in transactions {
            let trimmed = transaction.category.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let categoryKey = key(trimmed)
            counts[categoryKey, default: 0] += 1
            if names[categoryKey] == nil { names[categoryKey] = trimmed }
        }
        let used = counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .compactMap { names[$0.key] }
        let rest = suggestedCategories.filter { counts[key($0)] == nil }
        return used + rest
    }

    /// Cards for the editor's picker, the most recently used first; cards
    /// never used follow in their usual order. Archived cards are left out.
    public static func cardsByRecentUse(_ cards: [SharedFinanceAccount]) -> [SharedFinanceAccount] {
        let open = cards.filter { $0.category == .card && !$0.isArchived }
        func lastUsed(_ card: SharedFinanceAccount) -> Date? {
            (card.transactions ?? []).map(\.createdAt).max()
        }
        return open.sorted { lhs, rhs in
            switch (lastUsed(lhs), lastUsed(rhs)) {
            case let (left?, right?): return left > right
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return SharedFinanceAccount.displayOrder(lhs, rhs)
            }
        }
    }
}
