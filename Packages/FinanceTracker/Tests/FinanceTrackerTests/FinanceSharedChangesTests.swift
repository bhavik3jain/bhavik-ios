import Core
import CoreData
import Foundation
import Testing
@testable import FinanceTracker

@MainActor
private func withHousehold(_ body: (SharedFinanceHousehold) throws -> Void) throws {
    let container = CloudSharedStore.makeContainer(
        name: "FinanceSharedChangeTests-\(UUID().uuidString)",
        model: FinanceModel.make(),
        containerID: "iCloud.com.bhavikjain.trackers.tests",
        inMemory: true
    )
    try withExtendedLifetime(container) {
        try body(FinanceHouseholdResolver.forWriting(in: container.viewContext, container: container))
    }
}

@MainActor
private func describe(_ object: NSManagedObject, _ kind: SharedChangeKind, _ properties: Set<String> = []) -> SharedChangeDescription? {
    FinanceTrackerModule.describeSharedChange(object, SharedObjectChange(kind: kind, updatedProperties: properties))
}

@MainActor
@Test func financeNotificationsNeverCarryAnAmount() throws {
    try withHousehold { household in
        let card = SharedFinanceAccount(institution: "Chase", name: "Sapphire", category: .card, household: household)
        let charge = SharedFinanceTransaction(date: .now, cost: 84.12, merchant: "Whole Foods", household: household, card: card)
        let month = SharedFinanceMonth(period: YearMonth(year: 2026, month: 9), household: household)
        let balance = SharedFinanceBalance(account: card, month: month, amount: 12_345, edited: true)

        let added = try #require(describe(charge, .inserted))
        #expect(added.rootID == household.objectID)
        #expect(added.action == "added a transaction at Whole Foods")
        let updated = try #require(describe(balance, .updated, ["amount"]))
        #expect(updated.action == "updated Sapphire for September 2026")
        for text in [added.action, updated.action] {
            #expect(!text.contains("84"), "No amount on a lock screen")
            #expect(!text.contains("12,345") && !text.contains("12345"))
        }
    }
}

@MainActor
@Test func closingAMonthIsNamed() throws {
    try withHousehold { household in
        let month = SharedFinanceMonth(period: YearMonth(year: 2026, month: 9), household: household)
        #expect(describe(month, .inserted)?.action == "started September 2026")
        month.closedAt = .now
        #expect(describe(month, .updated, ["closedAt"])?.action == "closed September 2026")
    }
}

/// A hard-coded "a" in front of typed text read "added a Amazon transaction"
/// and "set a Entertainment budget"; the wording keeps articles off it.
@MainActor
@Test func typedNamesStartingWithAVowelNeverFollowAnArticle() throws {
    try withHousehold { household in
        let card = SharedFinanceAccount(institution: "Chase", name: "Sapphire", category: .card, household: household)
        let charge = SharedFinanceTransaction(date: .now, cost: 20, merchant: "Amazon", household: household, card: card)
        let blank = SharedFinanceTransaction(date: .now, cost: 5, merchant: "  ", household: household, card: card)
        let month = SharedFinanceMonth(period: YearMonth(year: 2026, month: 9), household: household)
        let budget = SharedFinanceBudget(category: "Entertainment", limit: 100, month: month)
        let uncategorised = SharedFinanceBudget(category: "", limit: 50, month: month)

        #expect(describe(charge, .inserted)?.action == "added a transaction at Amazon")
        #expect(describe(charge, .updated, ["merchant"])?.action == "changed a transaction at Amazon")
        #expect(describe(blank, .inserted)?.action == "added a transaction")
        #expect(describe(budget, .inserted)?.action == "set the Entertainment budget for September 2026")
        #expect(describe(budget, .updated, ["limit"])?.action == "changed the Entertainment budget for September 2026")
        #expect(describe(uncategorised, .inserted)?.action == "set the budget for September 2026")
    }
}
