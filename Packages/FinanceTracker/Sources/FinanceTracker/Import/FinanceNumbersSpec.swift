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
/// `{COL:k}` column k's header, `{PRICE:gold}` the Metal Price cell).
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

    /// One cell write, encoded as the script's `[column, op, value]`.
    public struct Op: Encodable, Equatable, Sendable {
        public var column: Int
        public var op: String
        public var value: Value

        public enum Value: Equatable, Sendable {
            case number(Double)
            case text(String)
        }

        public init(_ column: Int, _ op: String, _ value: Value) {
            self.column = column
            self.op = op
            self.value = value
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(column)
            try container.encode(op)
            switch value {
            case .number(let number): try container.encode(number)
            case .text(let text): try container.encode(text)
            }
        }
    }

    // The template's table names; `finance_numbers.py` has the same list.
    public static let accountTables: [(table: String, category: String)] = [
        ("Cash", "cash"), ("Investments", "investments"), ("Retirement", "retirement"),
    ]
    public static let fixedTable = "Large and Fixed Assets"
    public static let loanTable = "Long-Term Liabilities"
    public static let cardTable = "Credit Card Details"
    public static let metalTable = "Gold + Silver"
    public static let priceTableName = "Metal Price"
    public static let transactionTable = "Transactions"
    public static let budgetTable = "Budget"
    public static let joint = "Joint"

    public init(document: FinanceMonthDocument, outputPath: String, opened: Bool = true) {
        path = outputPath
        self.opened = opened
        priceTable = PriceTable(values: [
            "gold": Self.money(document.metalPrices.gold),
            "silver": Self.money(document.metalPrices.silver),
        ])

        var tables: [Table] = []
        for (table, category) in Self.accountTables {
            let rows = document.accounts.filter { $0.category == category }.map { account in
                [Op(2, "keep", .number(Self.money(account.balance))),
                 Op(0, "text", .text(Self.displayName(account.institution, account.name))),
                 Op(1, "text", .text(account.owner.isEmpty ? Self.joint : account.owner))]
            }
            tables.append(Self.table(table, tokenCol: 0, rows: rows, width: 3, groupCol: 1))
        }

        for (table, category) in [(Self.fixedTable, "fixed"), (Self.loanTable, "loan")] {
            let rows = document.accounts.filter { $0.category == category }.map { account in
                [Op(1, "keep", .number(Self.money(account.balance))),
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
            return [Op(2, "set", .number(Self.money(card.limit))),
                    Op(3, "set", .number(Self.money(card.annualFee))),
                    Op(4, "keep", .number(Self.money(spend[name] ?? 0))),
                    Op(0, "text", .text(name)),
                    Op(1, "text", .text(card.owner.isEmpty ? Self.joint : card.owner))]
        }
        tables.append(Self.table(Self.cardTable, tokenCol: 0, rows: cardRows, width: 5, groupCol: 1))

        let metalRows = document.metals.map { metal in
            let grams = (metal.grams * 10_000).rounded() / 10_000
            let current = metal.manualValue.map { Op(6, "set", .number(Self.money($0))) }
                ?? Op(6, "formula", .text("=Metal Price::{PRICE:\(metal.metal.lowercased())}×{COL:2} {ROW}"))
            // "ozm" is the regular ounce MetalValuation values in, so the
            // sheet's metals come out equal to the app's (no --troy-fix here).
            return [Op(3, "set", .number(grams)),
                    Op(2, "formula", .text("=CONVERT({COL:3} {ROW},\"g\",\"ozm\")")),
                    Op(4, "set", metal.pricePaidPerOz != 0 ? .number(Self.money(metal.pricePaidPerOz)) : .text("")),
                    Op(5, "set", .number(Self.money(metal.purchaseValue))),
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

        let budgetRows = document.budgets.map { budget in
            [Op(1, "keep", .number(Self.money(budget.limit))), Op(0, "text", .text(budget.category))]
        }
        if !budgetRows.isEmpty {
            tables.append(Self.table(Self.budgetTable, tokenCol: 0, rows: budgetRows, width: 2, optional: true))
        }
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

    static func displayName(_ institution: String, _ name: String) -> String {
        institution.isEmpty ? name : "\(institution) - \(name)"
    }
}
