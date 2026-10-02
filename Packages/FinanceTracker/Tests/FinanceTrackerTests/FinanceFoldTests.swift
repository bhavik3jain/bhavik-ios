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
    addPeople(to: household)
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
    addPeople(to: mine)
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
    addPeople(to: mine)
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
    addPeople(to: household)
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
    addPeople(to: household)
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

// MARK: - Merging into a partner's share

@MainActor
@Test func mergingIntoAnEditableShareCopiesEverythingAcross() throws {
    let container = makeContainer()
    let context = container.viewContext
    let privateStore = try #require(container.privatePersistentStore)
    let shared = try sharedStore(of: container)

    let mine = FinanceHouseholdResolver.forWriting(in: context, container: container)

    addPeople(to: mine)
    let myJoint = try owner("Joint", in: mine)
    let myChecking = SharedFinanceAccount(institution: "Bank", name: "Checking", category: .cash, household: mine, owner: myJoint)
    let myBrokerage = SharedFinanceAccount(institution: "Broker", name: "Taxable", category: .investments, household: mine, owner: try owner("Bhavik", in: mine))
    let myCard = SharedFinanceAccount(institution: "Chase", name: "Sapphire", category: .card, household: mine)
    myCard.limit = 10_000
    let mySeptember = SharedFinanceMonth(period: september, household: mine)
    mySeptember.goldPricePerOz = 4_000
    mySeptember.setBalance(1_000, for: myChecking)
    mySeptember.setBalance(20_000, for: myBrokerage)
    _ = SharedFinanceBudget(category: "Travel", limit: 300, month: mySeptember)
    let myOctober = SharedFinanceMonth(period: october, household: mine)
    myOctober.setBalance(21_000, for: myBrokerage)
    let ring = SharedFinanceMetalItem(name: "Ring", metal: .gold, grams: 5, household: mine)
    ring.hasManualValue = true
    ring.manualValue = 800
    let charge = SharedFinanceTransaction(date: day(2026, 9, 3), cost: 30, merchant: "Cafe", household: mine, card: myCard)
    charge.actualCost = 15
    charge.category = "Food"
    try context.save()

    let partners = household("Household", in: context, store: shared, createdAt: mine.createdAt.addingTimeInterval(60))
    let theirChecking = SharedFinanceAccount(institution: "Bank", name: "Checking", category: .cash, household: partners, owner: try owner("Joint", in: partners))
    let theirSeptember = SharedFinanceMonth(period: september, household: partners)
    theirSeptember.setBalance(1_200, for: theirChecking)
    _ = SharedFinanceBudget(category: "Food", limit: 500, month: theirSeptember)
    try context.save()

    let households = try context.fetch(SharedFinanceHousehold.fetchRequest())
    let offer = try #require(FinanceHouseholdResolver.mergeOffer(among: households, privateStore: privateStore, canEdit: { _ in true }))
    #expect(offer.own == mine)
    #expect(offer.shared == partners)
    #expect(offer.message.contains("3 accounts") && offer.message.contains("2 months") && offer.message.contains("1 transaction"))

    offer.merge()
    try context.save()

    #expect(try context.fetch(SharedFinanceHousehold.fetchRequest()) == [partners], "The emptied private household is gone")
    #expect(partners.sortedOwners.map(\.name) == ["Bhavik", "Saloni", "Joint"])
    #expect(partners.sortedAccounts.map(\.displayName) == ["Bank - Checking", "Broker - Taxable", "Chase - Sapphire"])
    #expect(partners.sortedMonths.map(\.yearMonth) == ["2026-09", "2026-10"])

    let merged = try #require(partners.month(for: september))
    let brokerage = try #require(partners.sortedAccounts.first { $0.category == .investments })
    let card = try #require(partners.sortedAccounts.first { $0.category == .card })
    #expect(merged.balance(for: theirChecking)?.amount == 1_200, "Both typed in: the share's figure is kept")
    #expect(merged.balance(for: brokerage)?.amount == 20_000)
    #expect(partners.month(for: october)?.balance(for: brokerage)?.amount == 21_000)
    #expect(merged.goldPricePerOz == 4_000)
    #expect(merged.sortedBudgets.map(\.category) == ["Food", "Travel"])
    #expect(brokerage.owner?.name == "Bhavik" && brokerage.owner?.household == partners)
    #expect(card.limit == 10_000)
    #expect(partners.sortedMetals.first?.value(at: merged.metalPrices) == 800)
    let copied = try #require(card.transactions?.first)
    #expect(copied.actualCost == 15 && copied.category == "Food")

    // Everything now lives where the partner can see it.
    for entity in ["SharedFinanceOwner", "SharedFinanceAccount", "SharedFinanceMonth", "SharedFinanceBalance",
                   "SharedFinanceBudget", "SharedFinanceMetalItem", "SharedFinanceTransaction"] {
        let objects = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: entity))
        #expect(!objects.isEmpty)
        #expect(objects.allSatisfy { $0.objectID.persistentStore == shared }, "\(entity) left behind in the private store")
    }

    let remaining = try context.fetch(SharedFinanceHousehold.fetchRequest())
    #expect(FinanceHouseholdResolver.mergeOffer(among: remaining, privateStore: privateStore, canEdit: { _ in true }) == nil)
}

@MainActor
@Test func aMergeIsOfferedOnlyForAnEditableShareAndAnOwnHouseholdWithSomethingInIt() throws {
    let container = makeContainer()
    let context = container.viewContext
    let privateStore = try #require(container.privatePersistentStore)
    let shared = try sharedStore(of: container)

    let mine = FinanceHouseholdResolver.forWriting(in: context, container: container)

    addPeople(to: mine)
    try context.save()
    #expect(FinanceHouseholdResolver.mergeOffer(among: [mine], privateStore: privateStore, canEdit: { _ in true }) == nil, "No share")

    let partners = household("Household", in: context, store: shared, createdAt: mine.createdAt.addingTimeInterval(60))
    try context.save()
    #expect(FinanceHouseholdResolver.mergeOffer(among: [mine, partners], privateStore: privateStore, canEdit: { _ in true }) == nil,
            "Nothing of my own but the default people")

    _ = SharedFinanceAccount(institution: "Bank", name: "Checking", category: .cash, household: mine)
    try context.save()
    #expect(FinanceHouseholdResolver.mergeOffer(among: [mine, partners], privateStore: privateStore, canEdit: { _ in true }) != nil)

    let viewOnly: (SharedFinanceHousehold) -> Bool = { $0.objectID.persistentStore == privateStore }
    #expect(FinanceHouseholdResolver.mergeOffer(among: [mine, partners], privateStore: privateStore, canEdit: viewOnly) == nil,
            "A view-only share is never offered a merge")
    #expect(FinanceHouseholdResolver.mergeOffer(among: [mine, partners], privateStore: nil, canEdit: { _ in true }) == nil)
}

// MARK: - Home

@MainActor
@Test func theHomeScreenShowsTheHouseholdTheModuleShows() throws {
    let container = makeContainer()
    let context = container.viewContext
    let shared = try sharedStore(of: container)

    let mine = FinanceHouseholdResolver.forWriting(in: context, container: container)

    addPeople(to: mine)
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

// MARK: - Review fixes

@MainActor
@Test func aSharedPrivateHouseholdIsKeptEvenWhenNewer() throws {
    let container = makeContainer()
    let context = container.viewContext
    let privateStore = try #require(container.privatePersistentStore)
    let base = Date(timeIntervalSince1970: 1_780_000_000)

    // An offline Mac made one first; the iPhone then made its own and
    // shared it. Folding the shared one away would end the share.
    let macs = household("Household", in: context, store: privateStore, createdAt: base)
    let checking = SharedFinanceAccount(institution: "Bank", name: "Checking", category: .cash, household: macs, owner: try owner("Bhavik", in: macs))
    SharedFinanceMonth(period: september, household: macs).setBalance(100, for: checking)
    let phones = household("Household", in: context, store: privateStore, createdAt: base.addingTimeInterval(60))
    try context.save()

    let households = try context.fetch(SharedFinanceHousehold.fetchRequest())
    let isShared: (SharedFinanceHousehold) -> Bool = { $0 == phones }
    #expect(FinanceFold.needsTidying(households: households, privateStore: privateStore, isShared: isShared))
    #expect(FinanceFold.tidy(in: context, privateStore: privateStore, isShared: isShared))
    try context.save()

    #expect(try context.fetch(SharedFinanceHousehold.fetchRequest()) == [phones], "The shared one survives")
    #expect(phones.sortedAccounts.map(\.displayName) == ["Bank - Checking"])
    #expect(phones.month(for: september)?.balance(for: checking)?.amount == 100)
    #expect(!FinanceFold.tidy(in: context, privateStore: privateStore, isShared: isShared))
}

@MainActor
@Test func twoSharedPrivateHouseholdsAreNeitherFolded() throws {
    let container = makeContainer()
    let context = container.viewContext
    let privateStore = try #require(container.privatePersistentStore)
    let base = Date(timeIntervalSince1970: 1_780_000_000)
    let first = household("Household", in: context, store: privateStore, createdAt: base)
    let second = household("Household", in: context, store: privateStore, createdAt: base.addingTimeInterval(60))
    try context.save()

    let households = try context.fetch(SharedFinanceHousehold.fetchRequest())
    #expect(!FinanceFold.needsTidying(households: households, privateStore: privateStore, isShared: { _ in true }))
    #expect(!FinanceFold.tidy(in: context, privateStore: privateStore, isShared: { _ in true }))
    #expect(!first.isDeleted && !second.isDeleted)
}

@MainActor
@Test func copiesFromASecondMergeFoldButHandTypedTwinsStay() throws {
    let container = makeContainer()
    let context = container.viewContext
    let shared = try sharedStore(of: container)
    let base = Date(timeIntervalSince1970: 1_780_000_000)
    let partners = household("Household", in: context, store: shared, createdAt: base)
    let bhavik = try owner("Bhavik", in: partners)

    // What two merges of one household leave, each device's copies made
    // before the other's arrived: the same stamps, a CloudKit millisecond
    // apart at most.
    let copied = base.addingTimeInterval(3_600)
    let secondBhavik = SharedFinanceOwner(name: "Bhavik", household: partners)
    secondBhavik.createdAt = bhavik.createdAt.addingTimeInterval(60)
    let checking = SharedFinanceAccount(institution: "Chase", name: "Checking", category: .cash, household: partners, owner: bhavik)
    checking.createdAt = copied
    let checkingCopy = SharedFinanceAccount(institution: "Chase", name: "Checking", category: .cash, household: partners, owner: secondBhavik)
    checkingCopy.createdAt = copied.addingTimeInterval(0.0004)
    let card = SharedFinanceAccount(institution: "Amex", name: "Gold", category: .card, household: partners)
    card.createdAt = copied
    let month = SharedFinanceMonth(period: september, household: partners)
    month.setBalance(1_000, for: checking)
    month.setBalance(1_000, for: checkingCopy)
    for offset in [0, 0.0004] {
        let coin = SharedFinanceMetalItem(name: "Coin", metal: .gold, grams: 31.1, household: partners, owner: bhavik)
        coin.createdAt = copied.addingTimeInterval(offset)
        let charge = SharedFinanceTransaction(date: day(2026, 9, 3), cost: 12, merchant: "Cafe", household: partners, card: card)
        charge.createdAt = copied.addingTimeInterval(offset)
    }
    // Two identical coins and two identical coffees typed in by hand.
    for seconds in [10.0, 20.0] {
        let coin = SharedFinanceMetalItem(name: "Bar", metal: .silver, grams: 50, household: partners, owner: bhavik)
        coin.createdAt = base.addingTimeInterval(seconds)
        let coffee = SharedFinanceTransaction(date: day(2026, 9, 4), cost: 5, merchant: "Kiosk", household: partners, card: card)
        coffee.createdAt = base.addingTimeInterval(seconds)
    }
    try context.save()

    #expect(MonthSummary(month: month).cash == 2_000, "Net worth counted the account twice")
    let households = try context.fetch(SharedFinanceHousehold.fetchRequest())
    #expect(FinanceFold.needsTidying(households: households, privateStore: container.privatePersistentStore))

    #expect(FinanceFold.tidy(in: context, privateStore: container.privatePersistentStore))
    try context.save()

    #expect(partners.sortedOwners.map(\.name) == ["Bhavik", "Saloni", "Joint"])
    // Which copy is kept is the record-name tiebreak's call; one is.
    let cash = partners.sortedAccounts.filter { $0.category == .cash }
    #expect(cash.count == 1 && cash.first?.owner == bhavik)
    #expect(partners.sortedAccounts.count == 2)
    #expect(MonthSummary(month: month).cash == 1_000)
    #expect(partners.sortedMetals.map(\.name).sorted() == ["Bar", "Bar", "Coin"], "Hand-typed twins stay")
    #expect(card.transactionCount == 3)
    let after = try context.fetch(SharedFinanceHousehold.fetchRequest())
    #expect(!FinanceFold.needsTidying(households: after, privateStore: container.privatePersistentStore))
    #expect(!FinanceFold.tidy(in: context, privateStore: container.privatePersistentStore))
}

@MainActor
@Test func screensUseTheDuplicateMonthTheFoldKeeps() throws {
    let container = makeContainer()
    let context = container.viewContext
    let household = FinanceHouseholdResolver.forWriting(in: context, container: container)
    addPeople(to: household)
    let base = Date(timeIntervalSince1970: 1_780_000_000)
    // Inserted newest first, so the set's order can't be what decides.
    let newer = SharedFinanceMonth(period: september, household: household)
    newer.createdAt = base.addingTimeInterval(60)
    let older = SharedFinanceMonth(period: september, household: household)
    older.createdAt = base
    let next = SharedFinanceMonth(period: october, household: household)
    try context.save()

    #expect(household.month(for: september) == older)
    #expect(next.previousMonth == older)
    #expect(FinanceFold.distinctMonths(Array(household.months ?? [])).first == older)
}
