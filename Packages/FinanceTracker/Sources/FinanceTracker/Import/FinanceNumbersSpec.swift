import Foundation

/// What `scripts/finance/numbers_fill.js` writes into a copy of the Numbers
/// template: which rows go in which table, cell by cell.
///
/// A port of `build_spec` in `scripts/finance/export_numbers.py`, for the Mac
/// app's Export to Numbers, which runs the same fill script without Python.
/// The two must stay in step: the script's comments explain each rule (why the
/// group column goes last, why Weight (oz) is always a formula, why a metal's
/// Current Value is written rather than kept), and they apply here unchanged.
///
/// Every row is a list of `[column, op, value]`, columns counted without the
/// group column Numbers adds to a grouped table. Ops: "set" writes a value,
/// "text" writes text as text, "date" a yyyy-MM-dd date, "keep" writes unless
/// the cell has a formula, "formula" writes a formula (`{ROW}` is this row,
/// `{COL:k}` column k's header, `{PRICE:gold}` the Metal Price cell). An op
/// may name the format its cell is left in ("currency"): writing a number into
/// a currency cell turns it automatic, so "$20,000" came out "20,000".
public struct FinanceNumbersSpec: Encodable, Equatable, Sendable {
    public var path: String
    /// Whether the caller has already opened `path` in Numbers. The Mac app
    /// has, through Launch Services, because the sandbox won't let the fill
    /// script shell out to `open` itself; the Python script leaves it unset.
    public var opened: Bool
    public var priceTable: PriceTable
    public var tables: [Table]

    public struct PriceTable: Encodable, Equatable, Sendable {
        public var name = FinanceNumbersSpec.priceTableName
        public var keyCol = 0
        public var valueCol = 1
        public var format = FinanceNumbersSpec.currency
        /// The sheet's live quotes, written instead of `values` wherever
        /// Numbers takes them.
        public var formulas = FinanceNumbersSpec.priceFormulas
        public var values: [String: Double]
    }

    public struct Table: Encodable, Equatable, Sendable {
        public var name: String
        public var tokenCol: Int
        /// Encoded as `null` when the table isn't grouped: the script tests
        /// `op[0] === ts.groupCol`, and a missing key would read as undefined.
        public var groupCol: Int?
        public var rows: [[Op]]
        public var blank: [Op]
        public var optional: Bool

        enum CodingKeys: String, CodingKey {
            case name, tokenCol, groupCol, rows, blank, optional
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(tokenCol, forKey: .tokenCol)
            if let groupCol {
                try container.encode(groupCol, forKey: .groupCol)
            } else {
                try container.encodeNil(forKey: .groupCol)
            }
            try container.encode(rows, forKey: .rows)
            try container.encode(blank, forKey: .blank)
            try container.encode(optional, forKey: .optional)
        }
    }

    /// One cell write, encoded as the script's `[column, op, value]`, or
    /// `[column, op, value, format]` when it names a format.
    public struct Op: Encodable, Equatable, Sendable {
        public var column: Int
        public var op: String
        public var value: Value
        public var format: String?

        public enum Value: Equatable, Sendable {
            case number(Double)
            case text(String)
        }

        public init(_ column: Int, _ op: String, _ value: Value, _ format: String? = nil) {
            self.column = column
            self.op = op
            self.value = value
            self.format = format
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(column)
            try container.encode(op)
            switch value {
            case .number(let number): try container.encode(number)
            case .text(let text): try container.encode(text)
            }
            if let format {
                try container.encode(format)
            }
        }
    }

    // The template's table names; `finance_numbers.py` has the same list.
    public static let accountTables: [(table: String, category: String)] = [
        ("Cash", "cash"), ("Investments", "investments"), ("Retirement", "retirement"),
    ]
    /// Categories the template has no table for, and the table they go
    /// under: an FSA/HSA counts toward the sheet's assets as retirement.
    /// `finance_numbers.SHEET_CATEGORY` has the same map.
    public static let sheetCategory = ["health": "retirement"]
    public static let fixedTable = "Large and Fixed Assets"
    public static let loanTable = "Long-Term Liabilities"
    public static let cardTable = "Credit Card Details"
    public static let metalTable = "Gold + Silver"
    public static let priceTableName = "Metal Price"
    public static let transactionTable = "Transactions"
    public static let budgetTable = "Budget"
    /// Plain tables where the user's sheet has pivots: Cost summed by category
    /// beside Transactions, and every metal item under its location. Numbers'
    /// scripting can't refresh a pivot, so an export showed the template's
    /// "Seed Data" in both until someone refreshed them by hand.
    public static let spendingTable = "Credit Card"
    public static let spendingFormula = "=SUMIF(Transactions::Category,{COL:0} {ROW},Transactions::Cost)"
    public static let itemsTable = "Personal Items Pivot"
    /// What Numbers' own pivot called an item with no location.
    public static let noLocation = "(blank)"
    public static let currency = "currency"
    /// Metal Price is the user's live STOCK() quote of the futures
    /// `MetalPriceFeed` reads, so an exported sheet's metals follow the market
    /// as their own sheet does; the month's price only if Numbers refuses it.
    public static let priceFormulas = ["gold": #"=STOCK("GC=F")"#, "silver": #"=STOCK("SI=F")"#]
    public static let joint = "Joint"

    public init(document: FinanceMonthDocument, outputPath: String, opened: Bool = true) {
        path = outputPath
        self.opened = opened
        priceTable = PriceTable(values: [
            "gold": Self.price(document.metalPrices.gold),
            "silver": Self.price(document.metalPrices.silver),
        ])

        var tables: [Table] = []
        for (table, category) in Self.accountTables {
            let rows = document.accounts.filter { (Self.sheetCategory[$0.category] ?? $0.category) == category }.map { account in
                [Op(2, "keep", .number(Self.money(account.balance)), Self.currency),
                 Op(0, "text", .text(Self.displayName(account.institution, account.name))),
                 Op(1, "text", .text(account.owner.isEmpty ? Self.joint : account.owner))]
            }
            tables.append(Self.table(table, tokenCol: 0, rows: rows, width: 3, groupCol: 1))
        }

        for (table, category) in [(Self.fixedTable, "fixed"), (Self.loanTable, "loan")] {
            let rows = document.accounts.filter { $0.category == category }.map { account in
                [Op(1, "keep", .number(Self.money(account.balance)), Self.currency),
                 Op(0, "text", .text(Self.displayName(account.institution, account.name)))]
            }
            tables.append(Self.table(table, tokenCol: 0, rows: rows, width: 2))
        }

        var spend: [String: Double] = [:]
        for transaction in document.transactions {
            spend[transaction.card, default: 0] += transaction.actualCost
        }
        let cardRows = document.cards.map { card in
            let name = Self.displayName(card.institution, card.name)
            return [Op(2, "set", .number(Self.money(card.limit)), Self.currency),
                    Op(3, "set", .number(Self.money(card.annualFee)), Self.currency),
                    Op(4, "keep", .number(Self.money(spend[name] ?? 0)), Self.currency),
                    Op(0, "text", .text(name)),
                    Op(1, "text", .text(card.owner.isEmpty ? Self.joint : card.owner))]
        }
        tables.append(Self.table(Self.cardTable, tokenCol: 0, rows: cardRows, width: 5, groupCol: 1))

        let metalRows = document.metals.map { metal in
            let grams = (metal.grams * 10_000).rounded() / 10_000
            let current = metal.manualValue.map { Op(6, "set", .number(Self.money($0)), Self.currency) }
                ?? Op(6, "formula", .text("=Metal Price::{PRICE:\(metal.metal.lowercased())}×{COL:2} {ROW}"), Self.currency)
            // "ozm" is the regular ounce MetalValuation values in, so the
            // sheet's metals come out equal to the app's (no --troy-fix here).
            return [Op(3, "set", .number(grams)),
                    Op(2, "formula", .text("=CONVERT({COL:3} {ROW},\"g\",\"ozm\")")),
                    Op(4, "set", metal.pricePaidPerOz != 0 ? .number(Self.money(metal.pricePaidPerOz)) : .text(""), Self.currency),
                    Op(5, "set", .number(Self.money(metal.purchaseValue)), Self.currency),
                    current,
                    Op(7, "text", .text(metal.location)),
                    Op(0, "text", .text(metal.name)),
                    Op(1, "text", .text(metal.metal.capitalized))]
        }
        tables.append(Self.table(Self.metalTable, tokenCol: 0, rows: metalRows, width: 8, groupCol: 1))

        let transactionRows = document.transactions.map { transaction in
            let actual = Self.money(transaction.actualCost)
            let cost = Self.money(transaction.cost)
            return [Op(0, "date", .text(String(transaction.date.prefix(10)))),
                    Op(1, "set", .number(cost)),
                    Op(2, actual == cost ? "keep" : "set", .number(actual)),
                    Op(4, "text", .text(transaction.category)),
                    Op(5, "text", .text(transaction.expense)),
                    Op(6, "text", .text(transaction.breakDown)),
                    Op(3, "text", .text(transaction.merchant)),
                    Op(7, "text", .text(transaction.card))]
        }
        tables.append(Self.table(Self.transactionTable, tokenCol: 3, rows: transactionRows, width: 8, groupCol: 7))

        // A category kept with no budget (a negative limit) has no row:
        // the sheet would read it as a budget of -$1.
        let budgetRows = document.budgets.filter { $0.limit >= 0 }.map { budget in
            [Op(1, "keep", .number(Self.money(budget.limit)), Self.currency), Op(0, "text", .text(budget.category))]
        }
        if !budgetRows.isEmpty {
            tables.append(Self.table(Self.budgetTable, tokenCol: 0, rows: budgetRows, width: 2, optional: true))
        }

        // Credit Card: one row per category, its sum a SUMIF over Transactions
        // written into every row (a row Numbers adds to a plain table copies no
        // formula). SUMIF matches without case, so "Food" and "food" are one
        // row, or that spend would count twice.
        var seen: Set<String> = []
        let categories = Set(document.transactions.map(\.category))
            .sorted { ($0.lowercased(), $0) < ($1.lowercased(), $1) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0.lowercased()).inserted }
        let spendingRows = categories.map { category in
            [Op(1, "formula", .text(Self.spendingFormula), Self.currency), Op(0, "text", .text(category))]
        }
        tables.append(Self.table(Self.spendingTable, tokenCol: 0, rows: spendingRows, width: 2, optional: true))

        // Personal Items: every metal item under its location, the location on
        // its group's first row only, sorted and de-duplicated as the pivot was.
        struct Item: Hashable { var location: String; var name: String }
        let items = Set(document.metals.map { Item(location: $0.location, name: $0.name) }).sorted {
            ($0.location.isEmpty ? 1 : 0, $0.location.lowercased(), $0.location, $0.name.lowercased(), $0.name)
                < ($1.location.isEmpty ? 1 : 0, $1.location.lowercased(), $1.location, $1.name.lowercased(), $1.name)
        }
        var previous: String?
        let itemRows = items.map { item in
            let label = item.location == previous ? "" : (item.location.isEmpty ? Self.noLocation : item.location)
            previous = item.location
            return [Op(0, "text", .text(label)), Op(1, "text", .text(item.name))]
        }
        tables.append(Self.table(Self.itemsTable, tokenCol: 1, rows: itemRows, width: 2, optional: true))
        self.tables = tables
    }

    /// With no rows the table keeps one, emptied: its formulas stay,
    /// everything else is cleared, token then group column last.
    private static func table(
        _ name: String, tokenCol: Int, rows: [[Op]], width: Int, groupCol: Int? = nil, optional: Bool = false
    ) -> Table {
        var blank = (0..<width).filter { $0 != tokenCol && $0 != groupCol }.map { Op($0, "keep", .text("")) }
        blank.append(Op(tokenCol, "set", .text("")))
        if let groupCol {
            blank.append(Op(groupCol, "set", .text("")))
        }
        return Table(name: name, tokenCol: tokenCol, groupCol: groupCol, rows: rows, blank: blank, optional: optional)
    }

    /// Cents: a sheet of money doesn't want float noise.
    static func money(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    /// A metal price per ounce keeps a futures quote's third decimal: the
    /// sheet's STOCK("SI=F") read 60.725, which went out in cents as 60.73.
    static func price(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }

    static func displayName(_ institution: String, _ name: String) -> String {
        institution.isEmpty ? name : "\(institution) - \(name)"
    }
}
