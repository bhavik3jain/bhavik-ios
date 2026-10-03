import Core
import CoreData
import Foundation
import ObjectiveC
import Testing
@testable import FinanceTracker

// Live metal prices (MetalPriceFeed, MetalQuoteClient) and the Mac's Numbers
// fill spec (FinanceNumbersSpec). Nothing here touches the network.

private nonisolated(unsafe) var associatedContainerKey: UInt8 = 0

@MainActor
private func makeHousehold() -> SharedFinanceHousehold {
    let container = CloudSharedStore.makeContainer(
        name: "FinancePriceTests-\(UUID().uuidString)",
        model: FinanceModel.make(),
        containerID: "iCloud.com.bhavikjain.trackers.tests",
        inMemory: true
    )
    let context = container.viewContext
    objc_setAssociatedObject(context, &associatedContainerKey, container, .OBJC_ASSOCIATION_RETAIN)
    return FinanceHouseholdResolver.forWriting(in: context, container: container)
}

private let live = MetalPrices(gold: 4_300, silver: 65)

@MainActor
private func twoMonths() -> (august: SharedFinanceMonth, september: SharedFinanceMonth) {
    let household = makeHousehold()
    let august = SharedFinanceMonth(period: YearMonth(year: 2026, month: 8), household: household)
    august.goldPricePerOz = 4_000
    august.silverPricePerOz = 50
    let september = SharedFinanceMonth(period: YearMonth(year: 2026, month: 9), household: household)
    september.goldPricePerOz = 4_000
    september.silverPricePerOz = 50
    _ = SharedFinanceMetalItem(name: "Bar", metal: .gold, grams: MetalValuation.gramsPerOunce, household: household, owner: nil)
    return (august, september)
}

@MainActor
@Test func theOpenLatestMonthIsValuedAtLivePrices() {
    let (_, september) = twoMonths()
    #expect(MetalPriceFeed.effectivePrices(for: september, live: live) == live)
    #expect(abs(MonthSummary(month: september, live: live).metals - 4_300) < 0.01)
    #expect(abs(MonthSummary(month: september).metals - 4_000) < 0.01, "No live prices: the stored ones")
}

@MainActor
@Test func closedAndEarlierMonthsKeepTheirOwnPrices() {
    let (august, september) = twoMonths()
    #expect(MetalPriceFeed.effectivePrices(for: august, live: live) == august.metalPrices,
            "Only the latest month follows the market")
    september.close()
    #expect(MetalPriceFeed.effectivePrices(for: september, live: live) == september.metalPrices,
            "Closing freezes a month at its stored prices")
}

@MainActor
@Test func livePricesCountAsUpdatedInAMonthsProgress() {
    let (_, september) = twoMonths()
    // September's prices are copied from August's, so on their own they're
    // still waiting to be updated.
    #expect(MonthRollover.progress(of: september).updated == 0)
    #expect(MonthRollover.progress(of: september, live: live).updated == 2)
}

@Test func aQuoteIsReadFromTheChartsLastPrice() throws {
    let json = #"{"chart":{"result":[{"meta":{"symbol":"GC=F","currency":"USD","regularMarketPrice":4321.2}}],"error":null}}"#
    #expect(try MetalQuoteClient.parsePrice(Data(json.utf8)) == 4_321.2)
    let empty = #"{"chart":{"result":null,"error":{"code":"Not Found"}}}"#
    #expect(throws: MetalQuoteClient.QuoteError.noPrice) { try MetalQuoteClient.parsePrice(Data(empty.utf8)) }
}

// MARK: - Numbers spec

private func document() -> FinanceMonthDocument {
    typealias D = FinanceMonthDocument
    return D(
        month: "2026-09",
        metalPrices: D.Prices(gold: 4_300.004, silver: 65),
        accounts: [
            D.AccountEntry(category: "cash", institution: "Bank", name: "Checking", owner: "", balance: 10.006),
            D.AccountEntry(category: "loan", institution: "", name: "Car Loan", owner: "Alex", balance: 3_000),
        ],
        cards: [D.CardEntry(institution: "Card Co", name: "Rewards", owner: "Alex", limit: 1_000, annualFee: 95)],
        metals: [
            D.MetalEntry(name: "Bar", metal: "gold", grams: 31.10351, pricePaidPerOz: 0, purchaseValue: 0,
                         manualValue: nil, location: "Safe", owner: ""),
            D.MetalEntry(name: "Ring", metal: "gold", grams: 5, pricePaidPerOz: 2_000, purchaseValue: 0,
                         manualValue: 800, location: "", owner: ""),
        ],
        transactions: [
            D.TransactionEntry(date: "2026-09-03", cost: 30, actualCost: 30, merchant: "76", category: "Car",
                               expense: "Gas", breakDown: "", card: "Card Co - Rewards"),
            D.TransactionEntry(date: "2026-09-04", cost: 40, actualCost: 20, merchant: "Dinner", category: "Food",
                               expense: "Out", breakDown: "Split", card: "Card Co - Rewards"),
        ]
    )
}

private func table(_ name: String, in spec: FinanceNumbersSpec) throws -> FinanceNumbersSpec.Table {
    try #require(spec.tables.first { $0.name == name })
}

@Test func theNumbersSpecFillsEveryTableTheScriptDoes() throws {
    let spec = FinanceNumbersSpec(document: document(), outputPath: "/tmp/x.numbers")
    #expect(spec.opened)
    #expect(spec.tables.map(\.name) == [
        "Cash", "Investments", "Retirement", "Large and Fixed Assets", "Long-Term Liabilities",
        "Credit Card Details", "Gold + Silver", "Transactions",
    ], "No Budget table without budgets")
    #expect(spec.priceTable.values == ["gold": 4_300, "silver": 65], "Money is written in cents")

    let cash = try table("Cash", in: spec)
    #expect(cash.rows == [[.init(2, "keep", .number(10.01)), .init(0, "text", .text("Bank - Checking")),
                           .init(1, "text", .text("Joint"))]], "No owner is Joint; the group column goes last")
    #expect(try table("Investments", in: spec).rows.isEmpty)
    #expect(try table("Investments", in: spec).blank.last == .init(1, "set", .text("")),
            "An empty table's blank row clears the group column last")
}

@Test func theNumbersSpecKeepsTheSheetsFormulas() throws {
    let spec = FinanceNumbersSpec(document: document(), outputPath: "/tmp/x.numbers")

    let card = try table("Credit Card Details", in: spec).rows[0]
    #expect(card.contains(.init(4, "keep", .number(50))), "Outstanding Balance keeps its SUMIFS of Actual Cost")

    let metals = try table("Gold + Silver", in: spec).rows
    #expect(metals[0].contains(.init(3, "set", .number(31.1035))), "Grams to four places")
    #expect(metals[0].contains(.init(2, "formula", .text(#"=CONVERT({COL:3} {ROW},"g","ozm")"#))))
    #expect(metals[0].contains(.init(6, "formula", .text("=Metal Price::{PRICE:gold}×{COL:2} {ROW}"))))
    #expect(metals[0].contains(.init(4, "set", .text(""))), "No price paid is left blank, not 0")
    #expect(metals[1].contains(.init(6, "set", .number(800))), "A set value is written, not priced")
    #expect(metals[1].last == .init(1, "text", .text("Gold")))

    let transactions = try table("Transactions", in: spec)
    #expect(transactions.tokenCol == 3 && transactions.groupCol == 7)
    #expect(transactions.rows[0].contains(.init(2, "keep", .number(30))), "Actual Cost keeps =Cost unless split")
    #expect(transactions.rows[1].contains(.init(2, "set", .number(20))))
    #expect(transactions.rows[0].contains(.init(3, "text", .text("76"))), "A numeric merchant goes in as text")
}

@Test func theNumbersSpecEncodesAsTheScriptReadsIt() throws {
    let spec = FinanceNumbersSpec(document: document(), outputPath: "/tmp/x.numbers")
    let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as? [String: Any])
    let tables = try #require(json["tables"] as? [[String: Any]])
    let fixed = try #require(tables.first { $0["name"] as? String == "Large and Fixed Assets" })
    #expect(fixed["groupCol"] is NSNull, "An ungrouped table's groupCol is null, not missing")
    let loans = try #require(tables.first { $0["name"] as? String == "Long-Term Liabilities" })
    let row = try #require((loans["rows"] as? [[[Any]]])?.first?.first)
    #expect(row[0] as? Int == 1 && row[1] as? String == "keep" && row[2] as? Double == 3_000,
            "A cell write is a [column, op, value] array")
}

@Test func anFSAOrHSAGoesUnderRetirementInTheSheet() throws {
    var withHealth = document()
    withHealth.accounts.append(.init(category: "health", institution: "Benefits Co", name: "HSA", owner: "", balance: 4_000))
    let spec = FinanceNumbersSpec(document: withHealth, outputPath: "/tmp/x.numbers")
    let retirement = try table("Retirement", in: spec)
    #expect(retirement.rows.count == 1)
    #expect(retirement.rows[0].contains(.init(0, "text", .text("Benefits Co - HSA"))))
    #expect(!spec.tables.contains { $0.name == "Health" }, "The template has no such table")
}
