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
        metalPrices: D.Prices(gold: 4_300.00004, silver: 60.725_004),
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
        "Credit Card Details", "Gold + Silver", "Transactions", "Credit Card", "Personal Items Pivot",
    ], "No Budget table without budgets")
    #expect(spec.priceTable.values == ["gold": 4_300, "silver": 60.725],
            "Prices to four places: a futures quote's third decimal stays, float noise doesn't")

    let cash = try table("Cash", in: spec)
    #expect(cash.rows == [[.init(2, "keep", .number(10.01), "currency"), .init(0, "text", .text("Bank - Checking")),
                           .init(1, "text", .text("Joint"))]], "No owner is Joint; the group column goes last")
    #expect(try table("Investments", in: spec).rows.isEmpty)
    #expect(try table("Investments", in: spec).blank.last == .init(1, "set", .text("")),
            "An empty table's blank row clears the group column last")
}

@Test func aCategoryWithNoBudgetHasNoRowInTheSheet() throws {
    var month = document()
    month.budgets = [
        FinanceMonthDocument.BudgetEntry(category: "Food", limit: 600),
        FinanceMonthDocument.BudgetEntry(category: "Gifts", limit: SharedFinanceBudget.noLimit),
    ]
    let spec = FinanceNumbersSpec(document: month, outputPath: "/tmp/x.numbers")
    #expect(try table("Budget", in: spec).rows == [[.init(1, "keep", .number(600), "currency"), .init(0, "text", .text("Food"))]])
}

@Test func theNumbersSpecKeepsTheSheetsFormulas() throws {
    let spec = FinanceNumbersSpec(document: document(), outputPath: "/tmp/x.numbers")

    let card = try table("Credit Card Details", in: spec).rows[0]
    #expect(card.contains(.init(4, "keep", .number(50), "currency")), "Outstanding Balance keeps its SUMIFS of Actual Cost")

    let metals = try table("Gold + Silver", in: spec).rows
    #expect(metals[0].contains(.init(3, "set", .number(31.1035))), "Grams to four places")
    #expect(metals[0].contains(.init(2, "formula", .text(#"=CONVERT({COL:3} {ROW},"g","ozm")"#))))
    #expect(metals[0].contains(.init(6, "formula", .text("=Metal Price::{PRICE:gold}×{COL:2} {ROW}"), "currency")))
    #expect(metals[0].contains(.init(4, "set", .text(""), "currency")), "No price paid is left blank, not 0")
    #expect(metals[1].contains(.init(6, "set", .number(800), "currency")), "A set value is written, not priced")
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
            "A cell write is a [column, op, value, format] array")
    #expect(row.count == 4 && row[3] as? String == "currency", "Writing a number loses a currency format; it's put back")
    let transactions = try #require(tables.first { $0["name"] as? String == "Transactions" })
    let merchant = try #require((transactions["rows"] as? [[[Any]]])?.first?.first { $0[0] as? Int == 3 })
    #expect(merchant.count == 3, "An op that names no format is three long, as the script always read it")
    let prices = try #require(json["priceTable"] as? [String: Any])
    #expect(prices["format"] as? String == "currency")
    #expect(prices["formulas"] as? [String: String] == ["gold": #"=STOCK("GC=F")"#, "silver": #"=STOCK("SI=F")"#],
            "Metal Price is the sheet's live quote, as in the user's own sheet; the month's price only as a fallback")
}

// The user's sheet has two pivot tables Numbers' scripting can't refresh: an
// export showed the template's seed data in both. The template has plain
// tables of the same names instead, filled like the rest.
@Test func theCreditCardTableSumsEachCategoryOnce() throws {
    var month = document()
    month.transactions.append(.init(date: "2026-09-05", cost: 5, actualCost: 5, merchant: "Cafe", category: "food",
                                    expense: "Coffee", breakDown: "", card: "Card Co - Rewards"))
    month.transactions.append(.init(date: "2026-09-06", cost: 5, actualCost: 5, merchant: "Shop", category: " ",
                                    expense: "", breakDown: "", card: "Card Co - Rewards"))
    let spending = try table("Credit Card", in: FinanceNumbersSpec(document: month, outputPath: "/tmp/x.numbers"))
    #expect(spending.optional && spending.groupCol == nil && spending.tokenCol == 0)
    #expect(spending.rows.map { $0.last } == [.init(0, "text", .text("Car")), .init(0, "text", .text("Food"))],
            "Sorted; SUMIF ignores case, so food is Food's row; a blank category has none")
    #expect(spending.rows[0].first == .init(1, "formula", .text("=SUMIF(Transactions::Category,{COL:0} {ROW},Transactions::Cost)"), "currency"),
            "Every row writes its own SUMIF: a row Numbers adds to a plain table copies none")
}

@Test func personalItemsAreListedUnderTheirLocation() throws {
    var month = document()
    month.metals.append(.init(name: "Coin", metal: "silver", grams: 31, pricePaidPerOz: 0, purchaseValue: 0,
                              manualValue: nil, location: "Safe", owner: ""))
    month.metals.append(.init(name: "Coin", metal: "silver", grams: 31, pricePaidPerOz: 0, purchaseValue: 0,
                              manualValue: nil, location: "Safe", owner: ""))
    let items = try table("Personal Items Pivot", in: FinanceNumbersSpec(document: month, outputPath: "/tmp/x.numbers"))
    #expect(items.tokenCol == 1 && items.optional)
    #expect(items.rows == [
        [.init(0, "text", .text("Safe")), .init(1, "text", .text("Bar"))],
        [.init(0, "text", .text("")), .init(1, "text", .text("Coin"))],
        [.init(0, "text", .text("(blank)")), .init(1, "text", .text("Ring"))],
    ], "The location on each group's first row, no location last, one row per name as the pivot had")
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

// MARK: - Sheet period

private func at(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
    FinanceCalendar.date(2026, month, day).addingTimeInterval(Double(hour) * 3_600)
}

// The user's September sheet began with charges from Aug 23 and grew into
// October until the next one was started: by calendar month, 19 of its 116
// charges were left out and every card balance came out low.
@Test func aMonthsSheetRunsFromTheLastCloseToItsOwn() {
    let september = YearMonth(year: 2026, month: 9)
    let sheet = SheetPeriod(period: september, closedAt: at(10, 5),
                            previous: (YearMonth(year: 2026, month: 8), at(8, 22)), hasLaterMonth: true)
    #expect(!sheet.contains(entered: at(8, 22)), "Entered before August closed: August's sheet")
    #expect(sheet.contains(entered: at(8, 23)), "Entered after August closed, though dated in August")
    #expect(sheet.contains(entered: at(10, 4)), "Entered in October, before September closed")
    #expect(!sheet.contains(entered: at(10, 6)), "Entered after September closed: October's sheet")
}

@Test func anOpenMonthsSheetRunsToNowAndAMonthNeverClosedEndsWithItsCalendarMonth() {
    let october = SheetPeriod(period: YearMonth(year: 2026, month: 10), closedAt: nil,
                              previous: (YearMonth(year: 2026, month: 9), nil), hasLaterMonth: false)
    #expect(october.after == at(10, 1, hour: 0), "September was never closed, so it ends where October starts")
    #expect(october.through == nil, "The latest open month runs to now")
    let first = SheetPeriod(period: YearMonth(year: 2026, month: 8), closedAt: nil, previous: nil, hasLaterMonth: true)
    #expect(first.after == nil && first.through == at(9, 1, hour: 0), "The first month starts with the first charge")
}

@MainActor
@Test func theExportFollowsTheSheetNotTheCalendar() throws {
    let household = makeHousehold()
    let august = SharedFinanceMonth(period: YearMonth(year: 2026, month: 8), household: household)
    let september = SharedFinanceMonth(period: YearMonth(year: 2026, month: 9), household: household)
    _ = SharedFinanceMonth(period: YearMonth(year: 2026, month: 10), household: household)
    august.close(asOf: at(8, 22))
    september.close(asOf: at(10, 5))
    func charge(_ merchant: String, dated: Date, entered: Date) {
        let transaction = SharedFinanceTransaction(date: dated, cost: 10, merchant: merchant, household: household)
        transaction.createdAt = entered
    }
    charge("Dated August", dated: at(8, 23), entered: at(8, 23))
    charge("Dated October", dated: at(10, 2), entered: at(10, 2))
    charge("Typed in late", dated: at(9, 30), entered: at(10, 7))
    try #require(household.managedObjectContext).processPendingChanges()

    #expect(FinanceMonthDocument(month: september).transactions.map(\.merchant) == ["Dated August", "Dated October"])
}

@MainActor
@Test func anImportedMonthsChargesLandOnItsOwnSheet() throws {
    let household = makeHousehold()
    let document = FinanceMonthDocument(
        month: "2026-08",
        metalPrices: .init(gold: 4_000, silver: 50),
        transactions: [.init(date: "2026-08-03", cost: 5, actualCost: 5, merchant: "Cafe", category: "Food",
                             expense: "", breakDown: "", card: "")]
    )
    try FinanceMonthExchange.apply(document, to: household)
    _ = SharedFinanceMonth(period: YearMonth(year: 2026, month: 10), household: household)
    try #require(household.managedObjectContext).processPendingChanges()
    let august = try #require(household.month(for: YearMonth(year: 2026, month: 8)))
    #expect(FinanceMonthDocument(month: august).transactions.count == 1,
            "Imported after August ended, it still counts as entered in August, not on October's sheet")
}
