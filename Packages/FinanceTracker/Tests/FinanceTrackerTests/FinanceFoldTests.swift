import Core
import CoreData
import Foundation
import Testing
@testable import FinanceTracker

// Folding duplicate households and months, and merging this person's own
// household into a partner's share. The shared store is simulated the same
// way as FinanceTrackerTests' sharing test: an in-memory container's second
// store, which `canUpdateRecord` treats as editable.

/// A fresh, uniquely-named in-memory container per test: Swift Testing runs
/// tests in parallel, and two containers under one name share a store URL.
@MainActor
private func makeContainer() -> NSPersistentCloudKitContainer {
    CloudSharedStore.makeContainer(
        name: "FinanceFoldTests-\(UUID().uuidString)",
        model: FinanceModel.make(),
        containerID: "iCloud.com.bhavikjain.trackers.tests",
        inMemory: true
    )
}

@MainActor
private func sharedStore(of container: NSPersistentCloudKitContainer) throws -> NSPersistentStore {
    try #require(container.persistentStoreCoordinator.persistentStores.first { $0 != container.privatePersistentStore })
}

/// A household in `store`, with the default people, made at `createdAt` —
/// standing in for one another device made, or a partner's.
@MainActor
private func household(
    _ name: String,
    in context: NSManagedObjectContext,
    store: NSPersistentStore,
    createdAt: Date
) -> SharedFinanceHousehold {
    let household = SharedFinanceHousehold(context: context, name: name)
    context.assign(household, to: store)
    household.createdAt = createdAt
    household.addDefaultOwners()
    return household
}

@MainActor
private func owner(_ name: String, in household: SharedFinanceHousehold) throws -> SharedFinanceOwner {
    try #require(household.sortedOwners.first { $0.name == name })
}

private let september = YearMonth(year: 2026, month: 9)
private let october = YearMonth(year: 2026, month: 10)

private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    FinanceCalendar.date(year, month, day).addingTimeInterval(12 * 3_600)
}

@MainActor
private func count<T: NSManagedObject>(_ type: T.Type, in context: NSManagedObjectContext) throws -> Int {
    try context.count(for: NSFetchRequest<T>(entityName: String(describing: type)))
}

// MARK: - Households

@MainActor
@Test func aNewerPrivateHouseholdFoldsIntoTheOldest() throws {
    let container = makeContainer()
    let context = container.viewContext
    let privateStore = try #require(container.privatePersistentStore)

    // This device's household, with September typed in.
    let mine = FinanceHouseholdResolver.forWriting(in: context, container: container)
    let checking = SharedFinanceAccount(institution: "Bank", name: "Checking", category: .cash, household: mine, owner: try owner("Bhavik", in: mine))
    let mySeptember = SharedFinanceMonth(period: september, household: mine)
    mySeptember.setBalance(100, for: checking)
    let myCard = SharedFinanceAccount(institution: "Chase", name: "Sapphire", category: .card, household: mine)
    _ = SharedFinanceTransaction(date: day(2026, 9, 3), cost: 12, merchant: "Cafe", household: mine, card: myCard)
    try context.save()

    // One a second device made before its first sync: the same checking
    // account with a copied-forward figure, plus things only it has.
    let theirs = household("Household", in: context, store: privateStore, createdAt: mine.createdAt.addingTimeInterval(60))
    let theirChecking = SharedFinanceAccount(institution: "Bank", name: "Checking", category: .cash, household: theirs, owner: try owner("Bhavik", in: theirs))
    let theirSeptember = SharedFinanceMonth(period: september, household: theirs)
    _ = SharedFinanceBalance(account: theirChecking, month: theirSeptember, amount: 90, edited: false)
    let savings = SharedFinanceAccount(institution: "Bank", name: "Savings", category: .cash, household: theirs, owner: try owner("Saloni", in: theirs))
    theirSeptember.setBalance(5_000, for: savings)
    let theirOctober = SharedFinanceMonth(period: october, household: theirs)
    theirOctober.setBalance(5_100, for: savings)
    _ = SharedFinanceOwner(name: "Grandma", household: theirs)
    _ = SharedFinanceMetalItem(name: "Coin", metal: .gold, grams: 31.1, household: theirs)
    let theirCard = SharedFinanceAccount(institution: "Chase", name: "Sapphire", category: .card, household: theirs)
    _ = SharedFinanceTransaction(date: day(2026, 9, 3), cost: 12, merchant: "Cafe", household: theirs, card: theirCard)
    _ = SharedFinanceTransaction(date: day(2026, 9, 5), cost: 40, merchant: "Grocer", household: theirs, card: theirCard)
    try context.save()

    let households = try context.fetch(SharedFinanceHousehold.fetchRequest())
    #expect(FinanceHouseholdResolver.forDisplay(among: households, container: container) == mine, "The newer one was hidden")
    #expect(FinanceFold.needsTidying(households: households, privateStore: privateStore))

    #expect(FinanceFold.tidy(in: context, privateStore: privateStore))
    try context.save()

    #expect(try context.fetch(SharedFinanceHousehold.fetchRequest()) == [mine])
    #expect(mine.sortedOwners.map(\.name) == ["Bhavik", "Saloni", "Joint", "Grandma"], "People matched by name, the new one added")
    #expect(mine.sortedAccounts.map(\.displayName) == ["Bank - Checking", "Bank - Savings", "Chase - Sapphire"])
    #expect(mine.sortedMonths.map(\.yearMonth) == ["2026-09", "2026-10"])
    #expect(mine.month(for: september)?.balance(for: checking)?.amount == 100, "The typed-in figure beats the copied one")
    #expect(mine.month(for: september)?.balance(for: savings)?.amount == 5_000)
    #expect(mine.month(for: october)?.balance(for: savings)?.amount == 5_100)
    #expect(mine.sortedMetals.map(\.name) == ["Coin"])
    #expect(myCard.transactionCount == 2, "The shared charge is kept once, the other moved onto the matching card")
    #expect(try count(SharedFinanceBalance.self, in: context) == 3)
    #expect(try count(SharedFinanceTransaction.self, in: context) == 2)

    let after = try context.fetch(SharedFinanceHousehold.fetchRequest())
    #expect(!FinanceFold.needsTidying(households: after, privateStore: privateStore))
    #expect(!FinanceFold.tidy(in: context, privateStore: privateStore), "Folding again changes nothing")
}

@MainActor
@Test func accountsOfTheSameNameStaySeparateForDifferentPeople() throws {
    let container = makeContainer()
    let context = container.viewContext
    let privateStore = try #require(container.privatePersistentStore)
    let mine = FinanceHouseholdResolver.forWriting(in: context, container: container)
    let theirs = household("Household", in: context, store: privateStore, createdAt: mine.createdAt.addingTimeInterval(60))
    for household in [mine, theirs] {
        for name in ["Bhavik", "Saloni"] {
            _ = SharedFinanceAccount(institution: "Online Brokerage", name: "Taxable", category: .investments, household: household, owner: try owner(name, in: household))
        }
    }
    try context.save()

    FinanceFold.tidy(in: context, privateStore: privateStore)
    try context.save()

    #expect(mine.sortedAccounts.compactMap(\.owner?.name).sorted() == ["Bhavik", "Saloni"], "Two accounts, not one and not four")
}

@MainActor
@Test func householdsSharedWithThisDeviceAreNeverFoldedTogether() throws {
    let container = makeContainer()
    let context = container.viewContext
    let privateStore = try #require(container.privatePersistentStore)
    let shared = try sharedStore(of: container)
    let base = Date(timeIntervalSince1970: 1_780_000_000)
    let first = household("Partner's", in: context, store: shared, createdAt: base)
    let second = household("Someone else's", in: context, store: shared, createdAt: base.addingTimeInterval(60))
    _ = SharedFinanceMonth(period: september, household: second)
    try context.save()

    let households = try context.fetch(SharedFinanceHousehold.fetchRequest())
    #expect(!FinanceFold.needsTidying(households: households, privateStore: privateStore))
    #expect(!FinanceFold.tidy(in: context, privateStore: privateStore))
    #expect(try context.count(for: SharedFinanceHousehold.fetchRequest()) == 2)
    #expect(!first.isDeleted && !second.isDeleted)
}

// MARK: - Months

@MainActor
@Test func duplicateMonthsFoldIntoTheOldest() throws {
    let container = makeContainer()
    let context = container.viewContext
    let household = FinanceHouseholdResolver.forWriting(in: context, container: container)
    let checking = SharedFinanceAccount(institution: "Bank", name: "Checking", category: .cash, household: household)
    let savings = SharedFinanceAccount(institution: "Bank", name: "Savings", category: .cash, household: household)

    // The newer one is inserted first, so the fetch order can't be what
    // decides — only `createdAt` may, or two devices could disagree.
    let newer = SharedFinanceMonth(period: september, household: household)
    let older = SharedFinanceMonth(period: september, household: household)
    older.createdAt = newer.createdAt.addingTimeInterval(-60)
    newer.goldPricePerOz = 4_000
    newer.closedAt = day(2026, 10, 1)
    _ = SharedFinanceBalance(account: checking, month: older, amount: 50, edited: false)
    _ = SharedFinanceBalance(account: checking, month: newer, amount: 70, edited: true)
    _ = SharedFinanceBalance(account: savings, month: newer, amount: 900, edited: true)
    _ = SharedFinanceBudget(category: "Food", limit: 100, month: older)
    _ = SharedFinanceBudget(category: "food", limit: 250, month: newer)
    _ = SharedFinanceBudget(category: "Travel", limit: 50, month: newer)
    try context.save()

    #expect(FinanceHistory(months: [older, newer]).points.count == 1, "Listed once before the fold")
    #expect(FinanceFold.distinctMonths([newer, older]) == [older])

    #expect(FinanceFold.foldDuplicateMonths(in: household))
    try context.save()

    #expect(household.sortedMonths == [older])
    #expect(older.balance(for: checking)?.amount == 70, "Only the duplicate's was typed in")
    #expect(older.balance(for: checking)?.edited == true)
    #expect(older.balance(for: savings)?.amount == 900)
    #expect(older.sortedBudgets.map(\.category) == ["Food", "Travel"])
    #expect(older.budget(for: "Food")?.limit == 100, "The kept month's budget wins")
    #expect(older.goldPricePerOz == 4_000, "A price only the duplicate had is kept")
    #expect(older.closedAt == day(2026, 10, 1))
    #expect(try count(SharedFinanceBalance.self, in: context) == 2)
    #expect(try count(SharedFinanceBudget.self, in: context) == 2)
    #expect(!FinanceFold.foldDuplicateMonths(in: household), "Folding again changes nothing")
}

@MainActor
@Test func aMonthWithTwoBalancesForOneAccountKeepsOne() throws {
    let container = makeContainer()
    let context = container.viewContext
    let household = FinanceHouseholdResolver.forWriting(in: context, container: container)
    let checking = SharedFinanceAccount(institution: "Bank", name: "Checking", category: .cash, household: household)
    let month = SharedFinanceMonth(period: september, household: household)
    // What arrives when the kept month's own balance syncs in after a fold
    // moved the duplicate's onto it: net worth counted the account twice.
    _ = SharedFinanceBalance(account: checking, month: month, amount: 10, edited: false)
    _ = SharedFinanceBalance(account: checking, month: month, amount: 20, edited: true)
    _ = SharedFinanceBalance(account: checking, month: month, amount: 30, edited: false)
    _ = SharedFinanceBudget(category: "Food", limit: 100, month: month)
    _ = SharedFinanceBudget(category: "Food", limit: 150, month: month)
    try context.save()

    #expect(MonthSummary(month: month).cash == 60)
    let households = try context.fetch(SharedFinanceHousehold.fetchRequest())
    #expect(FinanceFold.needsTidying(households: households, privateStore: container.privatePersistentStore))

    #expect(FinanceFold.foldDuplicateMonths(in: household))
    try context.save()

    #expect(month.balances?.count == 1)
    #expect(month.balance(for: checking)?.amount == 20, "The typed-in one is kept")
    #expect(month.budgets?.count == 1)
    #expect(month.budget(for: "Food")?.limit == 150)
    #expect(MonthSummary(month: month).cash == 20)
    #expect(!FinanceFold.foldDuplicateMonths(in: household))
}

// MARK: - Home

@MainActor
@Test func theHomeScreenShowsTheHouseholdTheModuleShows() throws {
    let container = makeContainer()
    let context = container.viewContext
    let shared = try sharedStore(of: container)

    let mine = FinanceHouseholdResolver.forWriting(in: context, container: container)
    let myOctober = SharedFinanceMonth(period: october, household: mine)
    let partners = household("Household", in: context, store: shared, createdAt: mine.createdAt.addingTimeInterval(60))
    let theirSeptember = SharedFinanceMonth(period: september, household: partners)
    let account = SharedFinanceAccount(institution: "Bank", name: "Checking", category: .cash, household: partners)
    theirSeptember.setBalance(2_500, for: account)
    try context.save()

    let households = try context.fetch(SharedFinanceHousehold.fetchRequest())
    #expect(FinanceHouseholdResolver.forDisplay(among: households, container: container) == partners)
    // The newest month overall is my own October, which the module hides.
    #expect(FinanceHome.latestMonth([theirSeptember, myOctober], container: container) == theirSeptember)
    #expect(FinanceHome.homeDetail(for: [theirSeptember, myOctober], container: container) == "Net worth \(FinanceFormat.money(2_500))")
}
