import Foundation

/// One month of Finance as JSON — the hand-off to and from the Numbers sheet.
///
/// `scripts/finance/export_numbers.py` turns this into Numbers rows on a Mac,
/// and `import_numbers.py` produces it from the Numbers file. The keys are
/// shared with those scripts: **never rename one**. Schema version 1:
///
///     { "version": 1, "month": "2026-09",
///       "metalPrices": { "gold": 4500.0, "silver": 52.0 },
///       "owners": ["Bhavik", "Saloni", "Joint"],
///       "accounts": [ { "category", "institution", "name", "owner", "balance" } ],
///       "cards": [ { "institution", "name", "owner", "limit", "annualFee" } ],
///       "metals": [ { "name", "metal", "grams", "pricePaidPerOz", "purchaseValue",
///                     "manualValue" (null when automatic), "location", "owner" } ],
///       "transactions": [ { "date" (yyyy-MM-dd), "cost", "actualCost", "merchant",
///                           "category", "expense", "breakDown", "card" (its displayName) } ],
///       "budgets": [ { "category", "limit" } ] }
///
/// Decoding is lenient — a missing array or string reads as empty — so a
/// hand-trimmed file still imports; encoding always writes every key.
public struct FinanceMonthDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var month: String
    public var metalPrices: Prices
    public var owners: [String]
    public var accounts: [AccountEntry]
    public var cards: [CardEntry]
    public var metals: [MetalEntry]
    public var transactions: [TransactionEntry]
    public var budgets: [BudgetEntry]

    public init(
        version: Int = FinanceMonthDocument.currentVersion,
        month: String,
        metalPrices: Prices = Prices(),
        owners: [String] = [],
        accounts: [AccountEntry] = [],
        cards: [CardEntry] = [],
        metals: [MetalEntry] = [],
        transactions: [TransactionEntry] = [],
        budgets: [BudgetEntry] = []
    ) {
        self.version = version
        self.month = month
        self.metalPrices = metalPrices
        self.owners = owners
        self.accounts = accounts
        self.cards = cards
        self.metals = metals
        self.transactions = transactions
        self.budgets = budgets
    }

    /// "Finance 2026-09" — the exporter adds ".json" from the content type.
    public static func fileStem(for month: String) -> String { "Finance \(month)" }

    /// "Finance 2026-09.json".
    public static func fileName(for month: String) -> String { "\(fileStem(for: month)).json" }

    public struct Prices: Codable, Equatable, Sendable {
        public var gold: Double
        public var silver: Double

        public init(gold: Double = 0, silver: Double = 0) {
            self.gold = gold
            self.silver = silver
        }
    }

    public struct AccountEntry: Codable, Equatable, Sendable {
        /// An `AccountCategory` raw value other than "card".
        public var category: String
        public var institution: String
        public var name: String
        /// An owner's name; empty for no one.
        public var owner: String
        public var balance: Double

        public init(category: String, institution: String, name: String, owner: String, balance: Double) {
            self.category = category
            self.institution = institution
            self.name = name
            self.owner = owner
            self.balance = balance
        }
    }

    public struct CardEntry: Codable, Equatable, Sendable {
        public var institution: String
        public var name: String
        public var owner: String
        public var limit: Double
        public var annualFee: Double

        public init(institution: String, name: String, owner: String, limit: Double, annualFee: Double) {
            self.institution = institution
            self.name = name
            self.owner = owner
            self.limit = limit
            self.annualFee = annualFee
        }
    }

    public struct MetalEntry: Codable, Equatable, Sendable {
        public var name: String
        /// "gold" or "silver".
        public var metal: String
        public var grams: Double
        public var pricePaidPerOz: Double
        public var purchaseValue: Double
        /// nil means valued automatically from the month's price. Written as
        /// an explicit `null`, not left out.
        public var manualValue: Double?
        public var location: String
        public var owner: String

        // Spelled out: both `init(from:)` and `encode(to:)` are hand-written
        // below, and nothing guarantees keys get synthesized with neither.
        enum CodingKeys: String, CodingKey {
            case name, metal, grams, pricePaidPerOz, purchaseValue, manualValue, location, owner
        }

        public init(
            name: String,
            metal: String,
            grams: Double,
            pricePaidPerOz: Double,
            purchaseValue: Double,
            manualValue: Double?,
            location: String,
            owner: String
        ) {
            self.name = name
            self.metal = metal
            self.grams = grams
            self.pricePaidPerOz = pricePaidPerOz
            self.purchaseValue = purchaseValue
            self.manualValue = manualValue
            self.location = location
            self.owner = owner
        }
    }

    public struct TransactionEntry: Codable, Equatable, Sendable {
        /// yyyy-MM-dd.
        public var date: String
        public var cost: Double
        public var actualCost: Double
        public var merchant: String
        public var category: String
        public var expense: String
        public var breakDown: String
        /// The card's `displayName`, "Chase - Sapphire Preferred".
        public var card: String

        public init(
            date: String,
            cost: Double,
            actualCost: Double,
            merchant: String,
            category: String,
            expense: String,
            breakDown: String,
            card: String
        ) {
            self.date = date
            self.cost = cost
            self.actualCost = actualCost
            self.merchant = merchant
            self.category = category
            self.expense = expense
            self.breakDown = breakDown
            self.card = card
        }
    }

    public struct BudgetEntry: Codable, Equatable, Sendable {
        public var category: String
        public var limit: Double

        public init(category: String, limit: Double) {
            self.category = category
            self.limit = limit
        }
    }
}

// MARK: - Lenient decoding

// In extensions so each struct keeps its synthesized `encode(to:)` and
// `CodingKeys`; only MetalEntry needs a hand-written encoder, for the null.

private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, or fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

public extension FinanceMonthDocument {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            version: try container.value(.version, or: FinanceMonthDocument.currentVersion),
            month: try container.value(.month, or: ""),
            metalPrices: try container.value(.metalPrices, or: Prices()),
            owners: try container.value(.owners, or: []),
            accounts: try container.value(.accounts, or: []),
            cards: try container.value(.cards, or: []),
            metals: try container.value(.metals, or: []),
            transactions: try container.value(.transactions, or: []),
            budgets: try container.value(.budgets, or: [])
        )
    }
}

public extension FinanceMonthDocument.Prices {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(gold: try container.value(.gold, or: 0), silver: try container.value(.silver, or: 0))
    }
}

public extension FinanceMonthDocument.AccountEntry {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            category: try container.value(.category, or: AccountCategory.cash.rawValue),
            institution: try container.value(.institution, or: ""),
            name: try container.value(.name, or: ""),
            owner: try container.value(.owner, or: ""),
            balance: try container.value(.balance, or: 0)
        )
    }
}

public extension FinanceMonthDocument.CardEntry {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            institution: try container.value(.institution, or: ""),
            name: try container.value(.name, or: ""),
            owner: try container.value(.owner, or: ""),
            limit: try container.value(.limit, or: 0),
            annualFee: try container.value(.annualFee, or: 0)
        )
    }
}

public extension FinanceMonthDocument.MetalEntry {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.value(.name, or: ""),
            metal: try container.value(.metal, or: MetalKind.gold.rawValue),
            grams: try container.value(.grams, or: 0),
            pricePaidPerOz: try container.value(.pricePaidPerOz, or: 0),
            purchaseValue: try container.value(.purchaseValue, or: 0),
            manualValue: try container.decodeIfPresent(Double.self, forKey: .manualValue),
            location: try container.value(.location, or: ""),
            owner: try container.value(.owner, or: "")
        )
    }

    /// Synthesized encoding leaves a nil `manualValue` out altogether; the
    /// scripts expect the key, as `null`.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(metal, forKey: .metal)
        try container.encode(grams, forKey: .grams)
        try container.encode(pricePaidPerOz, forKey: .pricePaidPerOz)
        try container.encode(purchaseValue, forKey: .purchaseValue)
        if let manualValue {
            try container.encode(manualValue, forKey: .manualValue)
        } else {
            try container.encodeNil(forKey: .manualValue)
        }
        try container.encode(location, forKey: .location)
        try container.encode(owner, forKey: .owner)
    }
}

public extension FinanceMonthDocument.TransactionEntry {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let cost: Double = try container.value(.cost, or: 0)
        self.init(
            date: try container.value(.date, or: ""),
            cost: cost,
            // Missing means "all ours" — the same default the editor uses.
            actualCost: try container.value(.actualCost, or: cost),
            merchant: try container.value(.merchant, or: ""),
            category: try container.value(.category, or: ""),
            expense: try container.value(.expense, or: ""),
            breakDown: try container.value(.breakDown, or: ""),
            card: try container.value(.card, or: "")
        )
    }
}

public extension FinanceMonthDocument.BudgetEntry {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(category: try container.value(.category, or: ""), limit: try container.value(.limit, or: 0))
    }
}
