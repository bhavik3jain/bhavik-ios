import Foundation

/// A merchant paid before, and what was filed under it last time: what the
/// transaction editor offers under the Merchant field, and fills in when
/// one is picked.
struct MerchantSuggestion: Identifiable, Equatable {
    /// As it was typed the latest time.
    let name: String
    /// From the latest transaction there with a category or an expense —
    /// taken together, because an expense is typed under its category
    /// ("Groceries · Weekly").
    let category: String
    let expense: String
    /// The account paid with there the latest time, while it's still open
    /// to pay with: the editor's "Paid with" never offers an archived one.
    let account: SharedFinanceAccount?
    let uses: Int
    let lastUsed: Date

    var id: String { MerchantSuggestions.key(name) }
}

/// The arithmetic behind the editor's merchant suggestions.
enum MerchantSuggestions {
    /// How many the editor shows at once.
    static let limit = 6

    /// How merchants are compared: "costco ", "Costco" and "COSTCO" are one,
    /// and so are "Café" and "Cafe".
    static func key(_ merchant: String) -> String {
        merchant
            .trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Every merchant in `transactions`, one per key, each named as it was
    /// typed the latest time.
    static func merchants(_ transactions: [SharedFinanceTransaction]) -> [MerchantSuggestion] {
        let latestFirst = transactions.sorted {
            $0.date != $1.date ? $0.date > $1.date : $0.createdAt > $1.createdAt
        }
        var order: [String] = []
        var seen: [String: Seen] = [:]
        for transaction in latestFirst {
            let name = transaction.merchant.trimmingCharacters(in: .whitespaces)
            let merchantKey = key(name)
            guard !merchantKey.isEmpty else { continue }
            if seen[merchantKey] == nil {
                order.append(merchantKey)
                seen[merchantKey] = Seen(name: name, lastUsed: transaction.date)
            }
            seen[merchantKey]?.add(transaction)
        }
        return order.compactMap { seen[$0]?.suggestion }
    }

    /// The merchants `typed` could be, best first: those it starts, then
    /// those with a word it starts ("joe" finds "Trader Joe's"), then any it
    /// appears in — each run the most used first, then the latest. Nothing
    /// typed yet offers the most used.
    static func matching(
        _ typed: String,
        in merchants: [MerchantSuggestion],
        limit: Int = MerchantSuggestions.limit
    ) -> [MerchantSuggestion] {
        let query = key(typed)
        let ranked = merchants.compactMap { merchant in
            rank(of: query, in: key(merchant.name)).map { (merchant, $0) }
        }
        return ranked
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.0.uses != rhs.0.uses { return lhs.0.uses > rhs.0.uses }
                if lhs.0.lastUsed != rhs.0.lastUsed { return lhs.0.lastUsed > rhs.0.lastUsed }
                return lhs.0.name < rhs.0.name
            }
            .prefix(limit)
            .map { $0.0 }
    }

    /// 0 for a merchant `query` starts, 1 for one with a word it starts, 2
    /// for one it's anywhere in, nil for no match. Both already `key`ed.
    private static func rank(of query: String, in merchant: String) -> Int? {
        if query.isEmpty || merchant.hasPrefix(query) { return 0 }
        let words = merchant.split { $0.isWhitespace || $0 == "-" || $0 == "/" || $0 == "&" }
        if words.contains(where: { $0.hasPrefix(query) }) { return 1 }
        if merchant.contains(query) { return 2 }
        return nil
    }

    /// One merchant's transactions, read latest first.
    private struct Seen {
        let name: String
        let lastUsed: Date
        var uses = 0
        var filed: (category: String, expense: String)?
        var account: SharedFinanceAccount?

        init(name: String, lastUsed: Date) {
            self.name = name
            self.lastUsed = lastUsed
        }

        mutating func add(_ transaction: SharedFinanceTransaction) {
            uses += 1
            if filed == nil {
                let category = transaction.category.trimmingCharacters(in: .whitespaces)
                let expense = transaction.expense.trimmingCharacters(in: .whitespaces)
                if !category.isEmpty || !expense.isEmpty { filed = (category, expense) }
            }
            if account == nil, let card = transaction.card, card.category.takesTransactions, !card.isArchived {
                account = card
            }
        }

        var suggestion: MerchantSuggestion {
            MerchantSuggestion(
                name: name,
                category: filed?.category ?? "",
                expense: filed?.expense ?? "",
                account: account,
                uses: uses,
                lastUsed: lastUsed
            )
        }
    }
}

/// The editor's fields a picked merchant fills in.
struct MerchantFill: Equatable {
    var merchant: String
    var category: String
    var expense: String
    var account: SharedFinanceAccount?

    /// Takes `suggestion`'s name, and what was filed under it last time
    /// wherever nothing is typed yet — never over something typed. Its
    /// expense comes only with its own category, so "Weekly" isn't put under
    /// a category it was never typed for. The account changes only when
    /// `mayChangeAccount`: a new transaction whose account nobody has picked.
    mutating func apply(_ suggestion: MerchantSuggestion, mayChangeAccount: Bool) {
        merchant = suggestion.name
        if category.trimmingCharacters(in: .whitespaces).isEmpty {
            category = suggestion.category
        }
        if expense.trimmingCharacters(in: .whitespaces).isEmpty,
           SpendingSummary.key(category) == SpendingSummary.key(suggestion.category) {
            expense = suggestion.expense
        }
        if mayChangeAccount, let suggested = suggestion.account {
            account = suggested
        }
    }
}
