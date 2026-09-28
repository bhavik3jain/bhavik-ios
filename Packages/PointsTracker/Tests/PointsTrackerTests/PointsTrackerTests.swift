import Core
import CoreData
import Foundation
import ObjectiveC
import Testing
@testable import PointsTracker

/// Ties a returned context's lifetime to its container — see Fuel's tests.
private nonisolated(unsafe) var associatedContainerKey: UInt8 = 0

/// A fresh, uniquely-named in-memory container per test: Swift Testing runs
/// tests in parallel, and two containers under one name share a store URL.
@MainActor
private func makeContainer() -> NSPersistentCloudKitContainer {
    CloudSharedStore.makeContainer(
        name: "PointsTests-\(UUID().uuidString)",
        model: PointsModel.make(),
        containerID: "iCloud.com.bhavikjain.trackers.tests",
        inMemory: true
    )
}

@MainActor
private func makeHousehold() -> SharedPointsHousehold {
    let container = makeContainer()
    let context = container.viewContext
    objc_setAssociatedObject(context, &associatedContainerKey, container, .OBJC_ASSOCIATION_RETAIN)
    return HouseholdResolver.forWriting(in: context, container: container)
}

private let start = Date(timeIntervalSince1970: 1_750_000_000)

@MainActor
@Test func recordingABalanceLogsTheChange() throws {
    let account = SharedPointsAccount(name: "Bonvoy", kind: .hotel, household: makeHousehold())

    account.recordBalance(50_000, note: "Opening balance", asOf: start)
    account.recordBalance(62_500, asOf: start.addingTimeInterval(86_400))

    #expect(account.balance == 62_500)
    let history = account.orderedHistory
    #expect(history.map(\.balance) == [62_500, 50_000], "Newest first")
    #expect(history.first?.delta == 12_500)
    try account.managedObjectContext?.save()
}

@MainActor
@Test func anUnchangedBalanceConfirmsWithoutAddingHistory() {
    let account = SharedPointsAccount(name: "United", kind: .airline, household: makeHousehold())
    account.recordBalance(10_000, asOf: start)

    let later = start.addingTimeInterval(7 * 86_400)
    account.recordBalance(10_000, asOf: later)

    #expect(account.entries?.count == 1)
    #expect(account.balanceUpdatedAt == later, "Re-confirming still refreshes when the figure was checked")
}

@MainActor
@Test func aZeroOpeningBalanceIsStillLogged() {
    let account = SharedPointsAccount(name: "New card", kind: .creditCard, household: makeHousehold())
    account.recordBalance(0, asOf: start)
    #expect(account.entries?.count == 1, "An empty history would read as never checked")
}

@MainActor
@Test func deletingAPersonKeepsTheirAccounts() throws {
    let household = makeHousehold()
    let context = try #require(household.managedObjectContext)
    let alex = SharedPointsOwner(name: "Alex", household: household)
    _ = SharedPointsAccount(name: "Sapphire", kind: .creditCard, household: household, owner: alex)
    try context.save()

    context.delete(alex)
    try context.save()

    let accounts = try context.fetch(SharedPointsAccount.fetchRequest())
    #expect(accounts.count == 1)
    #expect(accounts.first?.owner == nil)
}

@MainActor
@Test func deletingAnAccountTakesItsHistory() throws {
    let household = makeHousehold()
    let context = try #require(household.managedObjectContext)
    let account = SharedPointsAccount(name: "Delta", kind: .airline, household: household)
    account.recordBalance(1_000, asOf: start)
    account.recordBalance(2_000, asOf: start.addingTimeInterval(60))
    try context.save()

    context.delete(account)
    try context.save()

    #expect(try context.count(for: SharedPointsEntry.fetchRequest()) == 0)
}

@MainActor
@Test func theHouseholdIsCreatedOnceAndReused() throws {
    let container = makeContainer()
    let context = container.viewContext
    let first = HouseholdResolver.forWriting(in: context, container: container)
    try context.save()

    let second = HouseholdResolver.forWriting(in: context, container: container)

    #expect(first == second)
    #expect(first.objectID.persistentStore == container.privatePersistentStore, "A new household is this device's own")
}

@MainActor
@Test func aHouseholdSharedWithThisDeviceWinsAndKeepsNewThingsInItsStore() throws {
    let container = makeContainer()
    let context = container.viewContext
    _ = HouseholdResolver.forWriting(in: context, container: container)
    // Stands in for a partner's household arriving through an accepted share:
    // same entity, but in the shared-scope store.
    let sharedStore = try #require(container.persistentStoreCoordinator.persistentStores.first {
        $0 != container.privatePersistentStore
    })
    let partners = SharedPointsHousehold(context: context, name: "Partner's")
    context.assign(partners, to: sharedStore)
    try context.save()

    let chosen = HouseholdResolver.forWriting(in: context, container: container)
    #expect(chosen == partners, "New things go where the partner can see them")

    let person = SharedPointsOwner(name: "Sam", household: chosen)
    let account = SharedPointsAccount(name: "Hyatt", kind: .hotel, household: chosen, owner: person)
    account.recordBalance(5_000)
    try context.save()

    let entry = try #require(account.entries?.first)
    #expect(person.objectID.persistentStore == sharedStore)
    #expect(account.objectID.persistentStore == sharedStore)
    #expect(entry.objectID.persistentStore == sharedStore, "History follows its account, not the default store")
}

@MainActor
@Test func groupingByPersonPutsUnassignedLast() {
    let household = makeHousehold()
    let sam = SharedPointsOwner(name: "Sam", household: household)
    let alex = SharedPointsOwner(name: "Alex", household: household)
    let accounts = [
        SharedPointsAccount(name: "Hyatt", kind: .hotel, household: household, owner: sam),
        SharedPointsAccount(name: "Amex", kind: .creditCard, household: household, owner: alex),
        SharedPointsAccount(name: "Delta", kind: .airline, household: household),
        SharedPointsAccount(name: "Chase", kind: .creditCard, household: household, owner: alex)
    ]
    accounts[1].balance = 10
    accounts[3].balance = 20

    let sections = PointsSummary.sections(accounts, by: .owner)

    #expect(sections.map(\.title) == ["Alex", "Sam", "Unassigned"])
    #expect(sections[0].accounts.map(\.name) == ["Chase", "Amex"], "Biggest balance first")
}

@MainActor
@Test func groupingByTypeFollowsTheKindOrderAndSkipsEmptyOnes() {
    let household = makeHousehold()
    let accounts = [
        SharedPointsAccount(name: "Delta", kind: .airline, household: household),
        SharedPointsAccount(name: "Chase", kind: .creditCard, household: household)
    ]

    #expect(PointsSummary.sections(accounts, by: .kind).map(\.title) == ["Credit Cards", "Airlines"])
}

@MainActor
@Test func sectionsByTypeCarryTheirKindForItsColourAndPeopleDoNot() {
    let household = makeHousehold()
    let accounts = [
        SharedPointsAccount(name: "United", kind: .airline, household: household),
        SharedPointsAccount(name: "Hyatt", kind: .hotel, household: household),
    ]
    #expect(PointsSummary.sections(accounts, by: .kind).map(\.kind) == [.hotel, .airline])
    #expect(PointsSummary.sections(accounts, by: .owner).allSatisfy { $0.kind == nil })
    #expect(Set(PointsKind.allCases.map { "\($0.color)" }).count == PointsKind.allCases.count, "Every kind has its own colour")
}

@MainActor
@Test func totalsKeepPointsAndMilesApart() {
    let household = makeHousehold()
    let card = SharedPointsAccount(name: "Chase", kind: .creditCard, household: household)
    let hotel = SharedPointsAccount(name: "Hyatt", kind: .hotel, household: household)
    let airline = SharedPointsAccount(name: "United", kind: .airline, household: household)
    card.balance = 100_000
    hotel.balance = 20_000
    airline.balance = 45_000

    #expect(PointsTotal([card, hotel, airline]) == PointsTotal(points: 120_000, miles: 45_000))
    #expect(PointsTotal(points: 0, miles: 5).summary.hasSuffix("mi"))
    #expect(!PointsTotal(points: 5, miles: 0).summary.contains("mi"))
    #expect(PointsTotal().summary == "0 pts")
}

@MainActor
@Test func expiryCountsAnAlreadyPassedDateAsSoon() {
    let household = makeHousehold()
    let passed = SharedPointsAccount(name: "Old", kind: .hotel, household: household)
    let soon = SharedPointsAccount(name: "Soon", kind: .hotel, household: household)
    let later = SharedPointsAccount(name: "Later", kind: .hotel, household: household)
    let never = SharedPointsAccount(name: "Never", kind: .hotel, household: household)
    passed.expiresAt = start.addingTimeInterval(-86_400)
    soon.expiresAt = start.addingTimeInterval(30 * 86_400)
    later.expiresAt = start.addingTimeInterval(200 * 86_400)

    let expiring = PointsSummary.expiringSoon([later, soon, never, passed], asOf: start)

    #expect(expiring.map(\.name) == ["Old", "Soon"])
}

@MainActor
@Test func homeDetailLeadsWithExpiry() {
    #expect(PointsSummary.homeDetail(for: [], asOf: start) == "No accounts yet")

    let account = SharedPointsAccount(name: "Bonvoy", kind: .hotel, household: makeHousehold())
    account.balance = 1_000
    #expect(PointsSummary.homeDetail(for: [account], asOf: start) == PointsTotal(points: 1_000).summary)

    account.expiresAt = start.addingTimeInterval(86_400)
    #expect(PointsSummary.homeDetail(for: [account], asOf: start) == "1 account expiring soon")
}

@MainActor
@Test func anUnknownKindFallsBackToCreditCard() {
    let account = SharedPointsAccount(name: "x", kind: .hotel, household: makeHousehold())
    account.kindRaw = "cruise"
    #expect(account.kind == .creditCard)
    #expect(PointsKind.airline.unit == .miles)
    #expect(PointsKind.hotel.unit == .points)
}

@Test func typedFiguresReadWithSeparatorsAndNothingElse() {
    #expect(PointsInput.parse("184250") == 184_250)
    #expect(PointsInput.parse("184,250") == 184_250)
    #expect(PointsInput.parse(" 184 250 ") == 184_250)
    #expect(PointsInput.parse("") == nil)
    #expect(PointsInput.parse("abc") == nil)
}

@MainActor
@Test func deletingTheNewestEntryUndoesItsBalance() throws {
    let account = SharedPointsAccount(name: "Chase", kind: .creditCard, household: makeHousehold())
    account.recordBalance(50_000, asOf: start)
    account.recordBalance(500_000, asOf: start.addingTimeInterval(60))  // Mistyped.

    account.deleteEntries([try #require(account.orderedHistory.first)])

    #expect(account.balance == 50_000, "The header must not keep showing the deleted figure")
    account.recordBalance(52_000, asOf: start.addingTimeInterval(120))
    #expect(account.orderedHistory.first?.delta == 2_000)
}

@MainActor
@Test func shareWithPartnerSharesYourOwnHouseholdEvenAfterJoiningTheirs() throws {
    let container = makeContainer()
    let context = container.viewContext
    let mine = HouseholdResolver.forWriting(in: context, container: container)
    let sharedStore = try #require(container.persistentStoreCoordinator.persistentStores.first {
        $0 != container.privatePersistentStore
    })
    let partners = SharedPointsHousehold(context: context, name: "Partner's")
    context.assign(partners, to: sharedStore)
    try context.save()

    #expect(HouseholdResolver.forWriting(in: context, container: container) == partners)
    #expect(HouseholdResolver.own(in: context, container: container) == mine)
}
