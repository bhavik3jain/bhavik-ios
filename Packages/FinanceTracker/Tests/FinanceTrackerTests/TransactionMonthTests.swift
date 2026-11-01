import Core
import CoreData
import Foundation
import ObjectiveC
import Testing
@testable import FinanceTracker

// A transaction can count toward a month other than its date's, for a card
// statement that runs past the month's end. On Nov 1 the user's October ran to
// a statement closing Nov 7 or 8.

private nonisolated(unsafe) var associatedContainerKey: UInt8 = 0

@MainActor
private func makeHousehold() -> SharedFinanceHousehold {
    let container = CloudSharedStore.makeContainer(
        name: "FinanceTransactionMonthTests-\(UUID().uuidString)",
        model: FinanceModel.make(),
        containerID: "iCloud.com.bhavikjain.trackers.tests",
        inMemory: true
    )
    let context = container.viewContext
    objc_setAssociatedObject(context, &associatedContainerKey, container, .OBJC_ASSOCIATION_RETAIN)
    return FinanceHouseholdResolver.forWriting(in: context, container: container)
}

private let september = YearMonth(year: 2026, month: 9)
private let october = YearMonth(year: 2026, month: 10)
private let november = YearMonth(year: 2026, month: 11)
private let december = YearMonth(year: 2026, month: 12)
private let nov5 = FinanceCalendar.date(2026, 11, 5)
private let oct30 = FinanceCalendar.date(2026, 10, 30)

@Test func aChargeAfterTheMonthEndsCountsTowardItWhileItIsOpen() {
    #expect(TransactionMonthRule.automatic(for: nov5, closedByPeriod: [october: false]) == october)
    #expect(TransactionMonthRule.automatic(for: nov5, closedByPeriod: [october: false, november: false]) == october,
            "Starting November early doesn't end October's statement")
}

@Test func onceTheMonthClosesAChargeCountsTowardTheNext() {
    #expect(TransactionMonthRule.automatic(for: nov5, closedByPeriod: [october: true, november: false]) == november)
    #expect(TransactionMonthRule.automatic(for: nov5, closedByPeriod: [october: true]) == november,
            "November needn't have been started yet")
}

@Test func aLateChargeForAClosedMonthGoesOnTheNextLikeTheSheet() {
    #expect(TransactionMonthRule.automatic(for: oct30, closedByPeriod: [september: true, october: true, november: false]) == november)
    #expect(TransactionMonthRule.automatic(for: oct30, closedByPeriod: [september: true, october: true]) == november)
    #expect(TransactionMonthRule.automatic(for: oct30, closedByPeriod: [september: true, october: true, november: true]) == december)
}

@Test func aMonthForgottenLongAgoDoesNotCatchNewCharges() {
    #expect(TransactionMonthRule.automatic(for: nov5, closedByPeriod: [september: false, october: true, november: false]) == november)
}

@Test func withNoMonthsAChargeCountsTowardItsDate() {
    #expect(TransactionMonthRule.automatic(for: nov5, closedByPeriod: [:]) == november)
}

@Test func choicesKeepWhatIsAlreadyChosen() {
    let choices = TransactionMonthRule.choices(for: nov5, automatic: october, selected: YearMonth(year: 2026, month: 3))
    #expect(choices == [YearMonth(year: 2026, month: 3), october, november, december])
}

@Test func savingAssignsNewTransactionsButNotOldOnes() {
    #expect(TransactionMonthRule.stored(selected: nil, automatic: october, isUnassignedExisting: false) == "2026-10")
    #expect(TransactionMonthRule.stored(selected: nil, automatic: november, isUnassignedExisting: true) == nil,
            "An old transaction keeps following its date, on screen and on the sheet")
    #expect(TransactionMonthRule.stored(selected: october, automatic: november, isUnassignedExisting: true) == "2026-10")
}

@Test func theEditorExplainsOnlyAMonthThatIsNotTheDates() {
    #expect(TransactionMonthRule.explanation(counted: november, date: nov5, isAutomatic: true) == nil)
    #expect(TransactionMonthRule.explanation(counted: october, date: nov5, isAutomatic: true)?.contains("October is still open") == true)
    #expect(TransactionMonthRule.explanation(counted: november, date: oct30, isAutomatic: true)?.contains("October is closed") == true)
    #expect(TransactionMonthRule.explanation(counted: october, date: nov5, isAutomatic: false)?.contains("Dated in November") == true)
}

@MainActor
@Test func anUnassignedTransactionStillGoesByDate() {
    let household = makeHousehold()
    let transaction = SharedFinanceTransaction(date: nov5, cost: 10, merchant: "Shop", household: household)
    #expect(transaction.assignedMonth == nil)
    #expect(transaction.counts(in: november))
    #expect(!transaction.counts(in: october))
    #expect(!transaction.isCountedOutsideItsDate)
}

@MainActor
@Test func everyTotalFollowsTheAssignedMonth() {
    let household = makeHousehold()
    let card = SharedFinanceAccount(institution: "Bank", name: "Card", category: .card, household: household)
    let octoberMonth = SharedFinanceMonth(period: october, household: household)
    let novemberMonth = SharedFinanceMonth(period: november, household: household)
    let transaction = SharedFinanceTransaction(date: nov5, cost: 80, merchant: "Shop", household: household, card: card)
    transaction.category = "Food"
    transaction.assignedMonth = october.rawValue

    #expect(transaction.isCountedOutsideItsDate)
    #expect(transaction.countedPeriod == october)
    #expect(card.spend(in: october) == 80)
    #expect(card.spend(in: november) == 0)
    #expect(MonthSummary(month: octoberMonth).cardSpend == 80)
    #expect(MonthSummary(month: novemberMonth).cardSpend == 0)
    #expect(octoberMonth.transactionsInMonth == [transaction])
    #expect(novemberMonth.transactionsInMonth.isEmpty)
    #expect(SpendingSummary.transactions([transaction], in: october) == [transaction])
    #expect(SpendingSummary.transactions([transaction], in: november).isEmpty)

    let status = BudgetStatus(period: october, budgets: [(category: "Food", limit: 100)], transactions: [transaction])
    #expect(status.lines.first?.spent == 80)
    let other = BudgetStatus(period: november, budgets: [(category: "Food", limit: 100)], transactions: [transaction])
    #expect(other.lines.first?.spent == 0)
}

@MainActor
@Test func theSheetFollowsTheAssignedMonthAndOldTransactionsKeepTheirRule() {
    let household = makeHousehold()
    let octoberMonth = SharedFinanceMonth(period: october, household: household)
    let novemberMonth = SharedFinanceMonth(period: november, household: household)

    let assigned = SharedFinanceTransaction(date: nov5, cost: 1, merchant: "Assigned", household: household)
    assigned.assignedMonth = october.rawValue
    assigned.createdAt = FinanceCalendar.date(2026, 11, 20)
    let legacy = SharedFinanceTransaction(date: oct30, cost: 2, merchant: "Legacy", household: household)
    legacy.createdAt = FinanceCalendar.date(2026, 11, 2)

    #expect(FinanceMonthDocument(month: octoberMonth).transactions.map(\.merchant) == ["Assigned"])
    #expect(FinanceMonthDocument(month: novemberMonth).transactions.map(\.merchant) == ["Legacy"],
            "Unassigned, it's on the sheet it was entered during")
}
