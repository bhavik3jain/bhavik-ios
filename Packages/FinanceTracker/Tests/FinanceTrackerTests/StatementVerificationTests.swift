import Core
import CoreData
import Foundation
import ObjectiveC
import Testing
@testable import FinanceTracker

// Ticking a card's charges off against its statement, and what that carries to
// the sheet: a verified row gets the same teal fill as the user's own.

private nonisolated(unsafe) var associatedContainerKey: UInt8 = 0

@MainActor
private func makeHousehold() -> SharedFinanceHousehold {
    let container = CloudSharedStore.makeContainer(
        name: "FinanceStatementVerificationTests-\(UUID().uuidString)",
        model: FinanceModel.make(),
        containerID: "iCloud.com.bhavikjain.trackers.tests",
        inMemory: true
    )
    let context = container.viewContext
    objc_setAssociatedObject(context, &associatedContainerKey, container, .OBJC_ASSOCIATION_RETAIN)
    return FinanceHouseholdResolver.forWriting(in: context, container: container)
}

private let october = YearMonth(year: 2026, month: 10)
private let oct4 = FinanceCalendar.date(2026, 10, 4)
private let oct9 = FinanceCalendar.date(2026, 10, 9)
private let nov2 = FinanceCalendar.date(2026, 11, 2)

@MainActor
@Test func chargesCountByTheirMonthNotTheirDateOldestFirst() {
    let household = makeHousehold()
    let card = SharedFinanceAccount(institution: "Big Bank", name: "Rewards", category: .card, household: household)
    let other = SharedFinanceAccount(institution: "Big Bank", name: "Cash Back", category: .card, household: household)
    let later = SharedFinanceTransaction(date: oct9, cost: 20, merchant: "Later", household: household, card: card)
    let earlier = SharedFinanceTransaction(date: oct4, cost: 10, merchant: "Earlier", household: household, card: card)
    let runsPastMonthEnd = SharedFinanceTransaction(date: nov2, cost: 30, merchant: "Past the end", household: household, card: card)
    runsPastMonthEnd.assignedMonth = october.rawValue
    let movedOut = SharedFinanceTransaction(date: oct4, cost: 40, merchant: "Moved out", household: household, card: card)
    movedOut.assignedMonth = "2026-11"
    let otherCard = SharedFinanceTransaction(date: oct4, cost: 50, merchant: "Other card", household: household, card: other)

    let all = [later, earlier, runsPastMonthEnd, movedOut, otherCard]
    #expect(StatementVerification.charges(of: card, among: all, in: october) == [earlier, later, runsPastMonthEnd])
}

@MainActor
@Test func onlyCardsWithChargesThatMonthAreOffered() {
    let household = makeHousehold()
    let charged = SharedFinanceAccount(institution: "Big Bank", name: "Rewards", category: .card, household: household)
    let idle = SharedFinanceAccount(institution: "Big Bank", name: "Idle", category: .card, household: household)
    let chequing = SharedFinanceAccount(institution: "Big Bank", name: "Checking", category: .cash, household: household)
    let onCard = SharedFinanceTransaction(date: oct4, cost: 10, merchant: "Shop", household: household, card: charged)
    let fromCash = SharedFinanceTransaction(date: oct4, cost: 10, merchant: "Landlord", household: household, card: chequing)

    let offered = StatementVerification.cards(among: [charged, idle, chequing], transactions: [onCard, fromCash], in: october)
    #expect(offered == [charged], "Cash has no statement, and an idle card has nothing to tick")
}

@MainActor
@Test func progressGoesByWhatTheStatementSaysNotOurShare() {
    let household = makeHousehold()
    let card = SharedFinanceAccount(institution: "Big Bank", name: "Rewards", category: .card, household: household)
    let split = SharedFinanceTransaction(date: oct4, cost: 100, merchant: "Dinner", household: household, card: card)
    split.actualCost = 50
    split.setVerified(true)
    let refund = SharedFinanceTransaction(date: oct4, cost: -20, merchant: "Refund", household: household, card: card)

    let progress = StatementProgress([split, refund])
    #expect(progress.total == 2)
    #expect(progress.verified == 1)
    #expect(progress.verifiedCost == 100, "On the statement in full, whoever owes what")
    #expect(progress.totalCost == 80)
    #expect(!progress.isComplete)
    #expect(progress.fraction == 0.5)

    refund.setVerified(true)
    #expect(StatementProgress([split, refund]).isComplete)
    #expect(!StatementProgress([]).isComplete, "Nothing to check isn't finished")
}

@MainActor
@Test func aRepeatTickKeepsTheFirstDate() {
    let household = makeHousehold()
    let charge = SharedFinanceTransaction(date: oct4, cost: 10, merchant: "Shop", household: household)
    #expect(!charge.isVerified)
    charge.setVerified(true, asOf: oct4)
    charge.setVerified(true, asOf: oct9)
    #expect(charge.verifiedAt == oct4, "Mark All must not rewrite and re-sync what was already ticked")
    charge.setVerified(false)
    #expect(charge.verifiedAt == nil)
}

@MainActor
@Test func onlyChangingAStatementLineClearsVerification() {
    let household = makeHousehold()
    let card = SharedFinanceAccount(institution: "Big Bank", name: "Rewards", category: .card, household: household)
    let other = SharedFinanceAccount(institution: "Big Bank", name: "Cash Back", category: .card, household: household)
    let charge = SharedFinanceTransaction(date: oct4, cost: 10, merchant: "Shop", household: household, card: card)
    let changes = { (date: Date, cost: Double, merchant: String, account: SharedFinanceAccount?) in
        StatementVerification.editChangesStatementLine(of: charge, date: date, cost: cost, merchant: merchant, card: account)
    }

    #expect(!changes(oct4, 10, "Shop", card))
    #expect(!changes(oct4.addingTimeInterval(3_600), 10, " shop ", card), "Same day, same name")
    #expect(changes(oct9, 10, "Shop", card))
    #expect(changes(oct4, 10.5, "Shop", card))
    #expect(changes(oct4, 10, "Elsewhere", card))
    #expect(changes(oct4, 10, "Shop", other))
}

@MainActor
@Test func tickingAloneSendsNoSharedChangeNotice() throws {
    let household = makeHousehold()
    let charge = SharedFinanceTransaction(date: oct4, cost: 10, merchant: "Shop", household: household)
    let describe = { (properties: Set<String>) in
        FinanceTrackerModule.describeSharedChange(charge, SharedObjectChange(kind: .updated, updatedProperties: properties))
    }
    #expect(describe(["verifiedAt"]) == nil)
    #expect(describe(["verifiedAt", "cost"])?.action == "changed a transaction at Shop", "A real edit still says so")
    #expect(describe([])?.action == "changed a transaction at Shop")
}

@MainActor
@Test func theSheetFillsVerifiedRowsFromCostThroughCardAndNeverDate() throws {
    typealias D = FinanceMonthDocument
    let entry = { (merchant: String, verified: Bool) in
        D.TransactionEntry(date: "2026-10-04", cost: 10, actualCost: 10, merchant: merchant, category: "Food", expense: "", breakDown: "", card: "Big Bank - Rewards", verified: verified)
    }
    let document = D(month: "2026-10", transactions: [entry("Ticked", true), entry("Open", false)])
    let spec = FinanceNumbersSpec(document: document, outputPath: "/x.numbers")
    let table = try #require(spec.tables.first { $0.name == FinanceNumbersSpec.transactionTable })

    let fills = table.rows[0].filter { $0.op == "fill" }
    #expect(fills.map(\.column) == [1, 2, 3, 4, 5, 6, 7], "Date, column 0, stays white as in the user's sheet")
    #expect(fills.allSatisfy { $0.value == .text("verified") })
    #expect(!table.rows[1].contains { $0.op == "fill" })
}

@MainActor
@Test func verifiedRoundTripsThroughTheMonthJSONAndOldFilesReadAsUnverified() throws {
    let household = makeHousehold()
    let context = try #require(household.managedObjectContext)
    let card = SharedFinanceAccount(institution: "Big Bank", name: "Rewards", category: .card, household: household)
    let month = SharedFinanceMonth(period: october, household: household)
    let ticked = SharedFinanceTransaction(date: oct4, cost: 10, merchant: "Ticked", household: household, card: card)
    ticked.assignedMonth = october.rawValue
    ticked.setVerified(true)
    let open = SharedFinanceTransaction(date: oct4, cost: 20, merchant: "Open", household: household, card: card)
    open.assignedMonth = october.rawValue
    try context.save()

    let document = FinanceMonthDocument(month: month)
    #expect(document.transactions.first { $0.merchant == "Ticked" }?.verified == true)
    #expect(document.transactions.first { $0.merchant == "Open" }?.verified == false)

    let data = try FinanceMonthExchange.encode(document)
    let decoded = try FinanceMonthExchange.decode(data)
    #expect(decoded.transactions.first { $0.merchant == "Ticked" }?.verified == true)

    let old = #"{"month":"2026-10","transactions":[{"date":"2026-10-04","cost":1,"merchant":"Old","card":"X"}]}"#
    #expect(try FinanceMonthExchange.decode(Data(old.utf8)).transactions.first?.verified == false)
}
