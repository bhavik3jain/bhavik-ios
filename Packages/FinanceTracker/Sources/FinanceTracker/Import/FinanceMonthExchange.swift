import Core
import CoreData
import Foundation

public enum FinanceImportError: Error, Equatable, LocalizedError {
    case unreadableFile
    case unsupportedVersion(Int)
    case badMonth(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile:
            "The file isn't a Finance month document."
        case .unsupportedVersion(let version):
            "This file is version \(version) of the Finance format; this app reads version \(FinanceMonthDocument.currentVersion)."
        case .badMonth(let month):
            "\"\(month)\" isn't a month. Expected something like 2026-09."
        }
    }
}

/// What an import added, for the alert afterwards.
public struct FinanceImportSummary: Equatable, Sendable {
    public var month = ""
    public var ownersAdded = 0
    public var accountsAdded = 0
    public var cardsAdded = 0
    public var metalsAdded = 0
    public var transactionsAdded = 0
    /// Already there — same date, merchant, cost and card.
    public var transactionsSkipped = 0
    public var budgetsAdded = 0

    public init() {}

    /// "Added 3 accounts and 18 transactions to September 2026. 2 transactions were already there."
    public var message: String {
        var parts: [String] = []
        if ownersAdded > 0 { parts.append(counted(ownersAdded, "person", plural: "people")) }
        if accountsAdded > 0 { parts.append(counted(accountsAdded, "account")) }
        if cardsAdded > 0 { parts.append(counted(cardsAdded, "card")) }
        if metalsAdded > 0 { parts.append(counted(metalsAdded, "metal item")) }
        if transactionsAdded > 0 { parts.append(counted(transactionsAdded, "transaction")) }
        if budgetsAdded > 0 { parts.append(counted(budgetsAdded, "budget")) }
        let title = YearMonth(month)?.title ?? month
        var message = parts.isEmpty
            ? "Updated \(title); nothing new was added."
            : "Added \(parts.joined(separator: ", ")) to \(title)."
        if transactionsSkipped > 0 {
            message += " \(counted(transactionsSkipped, "transaction")) \(transactionsSkipped == 1 ? "was" : "were") already there."
        }
        return message
    }
}

public extension FinanceMonthDocument {
    /// The document for `month`: its balances and prices, its budgets, its
    /// transactions, and the household's owners, cards and metals as they
    /// are now. Everything is sorted, so exporting twice gives the same file.
    init(month: SharedFinanceMonth) {
        let household = month.household
        let period = month.period
        self.init(
            month: month.yearMonth,
            metalPrices: Prices(gold: month.goldPricePerOz, silver: month.silverPricePerOz),
            owners: household?.sortedOwners.map(\.name) ?? [],
            accounts: month.sortedBalances.compactMap { balance in
                guard let account = balance.account, account.category.hasMonthlyBalance else { return nil }
                return AccountEntry(
                    category: account.category.rawValue,
                    institution: account.institution,
                    name: account.name,
                    owner: account.owner?.name ?? "",
                    balance: balance.amount
                )
            },
            cards: (household?.sortedAccounts ?? []).filter { $0.category == .card }.map { card in
                CardEntry(
                    institution: card.institution,
                    name: card.name,
                    owner: card.owner?.name ?? "",
                    limit: card.limit,
                    annualFee: card.annualFee
                )
            },
            metals: (household?.sortedMetals ?? []).map { item in
                MetalEntry(
                    name: item.name,
                    metal: item.metal.rawValue,
                    grams: item.grams,
                    pricePaidPerOz: item.pricePaidPerOz,
                    purchaseValue: item.purchaseValue,
                    manualValue: item.hasManualValue ? item.manualValue : nil,
                    location: item.location,
                    owner: item.owner?.name ?? ""
                )
            },
            transactions: (household?.transactions ?? [])
                .filter { transaction in period.map { $0.contains(transaction.date) } ?? false }
                .sorted(by: FinanceMonthExchange.exportOrder)
                .map { transaction in
                    TransactionEntry(
                        date: FinanceCalendar.dayString(transaction.date),
                        cost: transaction.cost,
                        actualCost: transaction.actualCost,
                        merchant: transaction.merchant,
                        category: transaction.category,
                        expense: transaction.expense,
                        breakDown: transaction.breakDown,
                        card: transaction.card?.displayName ?? ""
                    )
                },
            budgets: month.sortedBudgets.map { BudgetEntry(category: $0.category, limit: $0.limit) }
        )
    }
}

/// JSON in and out of a household.
public enum FinanceMonthExchange {
    public static func encode(_ document: FinanceMonthDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    public static func decode(_ data: Data) throws -> FinanceMonthDocument {
        do {
            return try JSONDecoder().decode(FinanceMonthDocument.self, from: data)
        } catch {
            throw FinanceImportError.unreadableFile
        }
    }

    /// Reads a file picked with `.fileImporter` and merges it into `household`.
    /// Doesn't save — the caller does, like every other mutation.
    @MainActor
    public static func importFile(at url: URL, into household: SharedFinanceHousehold) throws -> FinanceImportSummary {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw FinanceImportError.unreadableFile }
        return try apply(try decode(data), to: household)
    }

    /// Merges `document` into `household`, matching what's already there:
    /// owners by name, accounts and cards by display name + category, metals
    /// by name, budgets by category, and transactions by date + merchant +
    /// cost + card, which are skipped when they match. Importing the same file
    /// twice changes nothing the second time.
    ///
    /// Matched accounts, cards and metals take the file's figures; the
    /// month's balances are marked edited, since they came from somewhere
    /// real rather than being copied forward.
    @discardableResult
    public static func apply(_ document: FinanceMonthDocument, to household: SharedFinanceHousehold) throws -> FinanceImportSummary {
        guard document.version == FinanceMonthDocument.currentVersion else {
            throw FinanceImportError.unsupportedVersion(document.version)
        }
        guard let period = YearMonth(document.month) else {
            throw FinanceImportError.badMonth(document.month)
        }

        var summary = FinanceImportSummary()
        summary.month = period.rawValue

        // Owners.
        var ownersByKey: [String: SharedFinanceOwner] = [:]
        for owner in household.sortedOwners {
            ownersByKey[nameKey(owner.name)] = ownersByKey[nameKey(owner.name)] ?? owner
        }
        func owner(named name: String) -> SharedFinanceOwner? {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            if let existing = ownersByKey[nameKey(trimmed)] { return existing }
            let kind: OwnerKind = nameKey(trimmed) == "joint" ? .joint : .person
            let created = SharedFinanceOwner(name: trimmed, kind: kind, household: household)
            ownersByKey[nameKey(trimmed)] = created
            summary.ownersAdded += 1
            return created
        }
        for name in document.owners {
            _ = owner(named: name)
        }

        // The month.
        let month = household.month(for: period) ?? SharedFinanceMonth(period: period, household: household)
        // A hand-trimmed file with no metalPrices decodes them as 0; writing
        // that would value every gold and silver item at $0.
        if document.metalPrices.gold > 0 { month.goldPricePerOz = document.metalPrices.gold }
        if document.metalPrices.silver > 0 { month.silverPricePerOz = document.metalPrices.silver }

        // Accounts and cards, one lookup for both.
        var accountsByKey: [String: SharedFinanceAccount] = [:]
        for account in household.sortedAccounts {
            let key = accountKey(account.displayName, account.category)
            accountsByKey[key] = accountsByKey[key] ?? account
        }
        func account(institution: String, name: String, category: AccountCategory, owner ownerName: String) -> SharedFinanceAccount {
            let institution = institution.trimmingCharacters(in: .whitespaces)
            let name = name.trimmingCharacters(in: .whitespaces)
            let key = accountKey(SharedFinanceAccount.displayName(institution: institution, name: name), category)
            if let existing = accountsByKey[key] {
                existing.owner = owner(named: ownerName) ?? existing.owner
                return existing
            }
            let created = SharedFinanceAccount(
                institution: institution,
                name: name,
                category: category,
                household: household,
                owner: owner(named: ownerName)
            )
            accountsByKey[key] = created
            if category == .card { summary.cardsAdded += 1 } else { summary.accountsAdded += 1 }
            return created
        }

        for entry in document.accounts {
            var category = AccountCategory(rawValue: entry.category) ?? .cash
            // A card has no typed balance; one filed under accounts is a
            // mistake in the file, so keep the balance as cash rather than drop it.
            if category == .card { category = .cash }
            let target = account(institution: entry.institution, name: entry.name, category: category, owner: entry.owner)
            month.setBalance(entry.balance, for: target)
        }

        for entry in document.cards {
            let card = account(institution: entry.institution, name: entry.name, category: .card, owner: entry.owner)
            card.limit = entry.limit
            card.annualFee = entry.annualFee
        }

        // Metals.
        var metalsByKey: [String: SharedFinanceMetalItem] = [:]
        for item in household.sortedMetals {
            metalsByKey[nameKey(item.name)] = metalsByKey[nameKey(item.name)] ?? item
        }
        for entry in document.metals {
            let name = entry.name.trimmingCharacters(in: .whitespaces)
            let metal = MetalKind(rawValue: entry.metal) ?? .gold
            let item: SharedFinanceMetalItem
            if let existing = metalsByKey[nameKey(name)] {
                item = existing
            } else {
                item = SharedFinanceMetalItem(name: name, metal: metal, grams: entry.grams, household: household)
                metalsByKey[nameKey(name)] = item
                summary.metalsAdded += 1
            }
            item.metal = metal
            item.grams = entry.grams
            item.pricePaidPerOz = entry.pricePaidPerOz
            item.purchaseValue = entry.purchaseValue
            item.hasManualValue = entry.manualValue != nil
            item.manualValue = entry.manualValue ?? 0
            item.location = entry.location.trimmingCharacters(in: .whitespaces)
            item.owner = owner(named: entry.owner) ?? item.owner
        }

        // Transactions.
        var cardsByName: [String: SharedFinanceAccount] = [:]
        for card in household.sortedAccounts where card.category == .card {
            cardsByName[nameKey(card.displayName)] = cardsByName[nameKey(card.displayName)] ?? card
        }
        var seen = Set((household.transactions ?? []).map {
            transactionKey(day: FinanceCalendar.dayString($0.date), merchant: $0.merchant, cost: $0.cost, card: $0.card?.displayName ?? "")
        })
        for entry in document.transactions {
            guard let date = FinanceCalendar.date(fromDayString: entry.date) else { continue }
            let key = transactionKey(day: FinanceCalendar.dayString(date), merchant: entry.merchant, cost: entry.cost, card: entry.card)
            guard !seen.contains(key) else {
                summary.transactionsSkipped += 1
                continue
            }
            seen.insert(key)

            var card: SharedFinanceAccount?
            let cardName = entry.card.trimmingCharacters(in: .whitespaces)
            if !cardName.isEmpty {
                if let existing = cardsByName[nameKey(cardName)] {
                    card = existing
                } else {
                    // A card only named by its transactions: split the
                    // display name back into institution and name so it
                    // exports under the same name.
                    let (institution, name) = splitDisplayName(cardName)
                    let created = account(institution: institution, name: name, category: .card, owner: "")
                    cardsByName[nameKey(cardName)] = created
                    card = created
                }
            }

            let transaction = SharedFinanceTransaction(
                date: date,
                cost: entry.cost,
                merchant: entry.merchant.trimmingCharacters(in: .whitespaces),
                household: household,
                card: card
            )
            transaction.actualCost = entry.actualCost
            transaction.category = entry.category.trimmingCharacters(in: .whitespaces)
            transaction.expense = entry.expense.trimmingCharacters(in: .whitespaces)
            transaction.breakDown = entry.breakDown.trimmingCharacters(in: .whitespaces)
            summary.transactionsAdded += 1
        }

        // Budgets.
        for entry in document.budgets {
            let category = entry.category.trimmingCharacters(in: .whitespaces)
            guard !category.isEmpty else { continue }
            if let existing = month.budget(for: category) {
                existing.limit = entry.limit
            } else {
                _ = SharedFinanceBudget(category: category, limit: entry.limit, month: month)
                summary.budgetsAdded += 1
            }
        }

        return summary
    }

    // MARK: - Keys

    /// Collapses inner runs of spaces too: the sheet names a card
    /// "Bank of America -  Cash Rewards" (two spaces), import_numbers.py keeps
    /// that byte for byte, and the card it becomes is rebuilt from trimmed
    /// parts with one. Keyed on the raw text, a second import of the same file
    /// matched none of that card's transactions and added them all again.
    static func nameKey(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    static func accountKey(_ displayName: String, _ category: AccountCategory) -> String {
        "\(category.rawValue)|\(nameKey(displayName))"
    }

    /// Date, merchant, cost to the cent, and card: two coffees at the same
    /// place on the same day for the same price on the same card read as one,
    /// which is the price of making re-imports safe.
    static func transactionKey(day: String, merchant: String, cost: Double, card: String) -> String {
        let cents = Int((cost * 100).rounded())
        return "\(day)|\(nameKey(merchant))|\(cents)|\(nameKey(card))"
    }

    /// "Chase - Sapphire Preferred" → ("Chase", "Sapphire Preferred"); no
    /// separator → ("", whole thing).
    static func splitDisplayName(_ displayName: String) -> (institution: String, name: String) {
        guard let range = displayName.range(of: " - ") else { return ("", displayName) }
        return (String(displayName[..<range.lowerBound]), String(displayName[range.upperBound...]))
    }

    /// Oldest first, so the file reads like a statement.
    static func exportOrder(_ lhs: SharedFinanceTransaction, _ rhs: SharedFinanceTransaction) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        if lhs.merchant != rhs.merchant { return lhs.merchant < rhs.merchant }
        if lhs.cost != rhs.cost { return lhs.cost < rhs.cost }
        return (lhs.card?.displayName ?? "") < (rhs.card?.displayName ?? "")
    }
}
