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

// MARK: - "September's report is ready"

@MainActor
private func notice(_ object: NSManagedObject, _ kind: SharedChangeKind, _ properties: Set<String> = [], asOf now: Date = .now) -> FinanceReportReady.Notice? {
    FinanceReportReady.notice(for: object, SharedObjectChange(kind: kind, updatedProperties: properties), asOf: now)
}

@MainActor
@Test func aMonthFinishedOnAnotherDeviceIsAReportReady() throws {
    try withHousehold { household in
        household.name = "Jain Family"
        let now = FinanceCalendar.date(2026, 10, 2)
        let month = SharedFinanceMonth(period: YearMonth(year: 2026, month: 9), household: household)
        month.closedAt = now.addingTimeInterval(-60)

        let ready = try #require(notice(month, .updated, ["closedAt"], asOf: now))
        #expect(ready.scope == .month(YearMonth(year: 2026, month: 9)))
        #expect(ready.title == "September's report is ready")
        #expect(ready.body.contains("September 2026"))
        #expect(ready.body.contains("Jain Family"))
        #expect(ready.identifier == "finance.reportReady.2026-09")
        #expect(ready.destination == "finance.report:2026-09")
        #expect(FinanceReportRouter.scope(fromDestination: ready.destination) == ready.scope)
    }
}

@MainActor
@Test func onlyFinishingAMonthIsAReportReady() throws {
    try withHousehold { household in
        let now = FinanceCalendar.date(2026, 10, 2)
        let month = SharedFinanceMonth(period: YearMonth(year: 2026, month: 9), household: household)
        month.closedAt = now

        // Arriving already closed: an old month imported, or the download
        // after joining a share — nobody just finished it.
        #expect(notice(month, .inserted, asOf: now) == nil)
        // Some other edit to a closed month.
        #expect(notice(month, .updated, ["note"], asOf: now) == nil)

        // Reopened: closedAt touched, but cleared.
        month.closedAt = nil
        #expect(notice(month, .updated, ["closedAt"], asOf: now) == nil)

        // Anything that isn't a month.
        let account = SharedFinanceAccount(institution: "Chase", name: "Checking", category: .cash, household: household)
        #expect(notice(account, .updated, ["closedAt"], asOf: now) == nil)
    }
}

/// A re-import of a month closed long ago can mark `closedAt` as updated
/// without anyone closing anything; that's history, not news.
@MainActor
@Test func aLongClosedMonthIsNotNewsAgain() throws {
    try withHousehold { household in
        let now = FinanceCalendar.date(2026, 10, 20)
        let month = SharedFinanceMonth(period: YearMonth(year: 2026, month: 9), household: household)
        month.closedAt = FinanceCalendar.date(2026, 10, 1)
        #expect(notice(month, .updated, ["closedAt"], asOf: now) == nil)
    }
}

@Test func lastYearsMonthIsNamedWithItsYear() {
    let ready = FinanceReportReady.notice(
        period: YearMonth(year: 2025, month: 12),
        closedAt: FinanceCalendar.date(2026, 1, 2),
        householdTitle: "Household",
        asOf: FinanceCalendar.date(2026, 1, 2)
    )
    #expect(ready.title == "December 2025's report is ready")
}

@Test func aReportReadyNeverCarriesAnAmount() {
    let ready = FinanceReportReady.notice(
        period: YearMonth(year: 2026, month: 9),
        closedAt: .now,
        householdTitle: "Household"
    )
    #expect(!ready.title.contains("$") && !ready.body.contains("$"))
}

/// One close is told once, however often its record is imported again; a
/// reopen and a fresh close is news again.
@Test func eachCloseIsToldOnce() throws {
    let suite = "FinanceReportReadyTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let period = YearMonth(year: 2026, month: 9)
    let first = FinanceReportReady.notice(period: period, closedAt: FinanceCalendar.date(2026, 10, 1), householdTitle: "Household")
    #expect(FinanceReportReady.claim(first, defaults: defaults))
    #expect(!FinanceReportReady.claim(first, defaults: defaults))

    let again = FinanceReportReady.notice(period: period, closedAt: FinanceCalendar.date(2026, 10, 2), householdTitle: "Household")
    #expect(FinanceReportReady.claim(again, defaults: defaults))
}

@Test func reportDestinationsRoundTrip() {
    #expect(FinanceReportRouter.destination(for: .month(YearMonth(year: 2026, month: 9))) == "finance.report:2026-09")
    #expect(FinanceReportRouter.scope(fromDestination: "finance.report:2026") == .year(2026))
    #expect(FinanceReportRouter.scope(fromDestination: "trips.trip:abc") == nil, "Another module's destination isn't ours")
    #expect(FinanceReportRouter.scope(fromDestination: "finance.report:soon") == nil)
}

@MainActor
@Test func openingADestinationSetsThePendingReport() {
    let router = FinanceReportRouter.shared
    let before = router.pending
    defer { router.pending = before }
    #expect(!router.open(destination: "trips.trip:abc"))
    #expect(router.open(destination: "finance.report:2026-09"))
    #expect(router.pending == .month(YearMonth(year: 2026, month: 9)))
}
