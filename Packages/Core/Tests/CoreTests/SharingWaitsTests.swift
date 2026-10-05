import CloudKit
import Foundation
import Testing
@testable import Core

// Three places that waited on a container's request executor, which iCloud's
// imports hold: a view's edit check, Share's wait for a sync whose end never
// came, and the shared-change notifier's lookups.

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

// MARK: - Editing a shared object, without asking iCloud

@Test func aLookedUpShareDecidesWhetherItsObjectsCanBeEdited() {
    let readWrite = SharingStatus.sharedWithMe(role: .privateUser, permission: .readWrite)
    let readOnly = SharingStatus.sharedWithMe(role: .privateUser, permission: .readOnly)
    #expect(SharingStatusCache.editability(lookedUp: readWrite, storeDefault: false))
    #expect(!SharingStatusCache.editability(lookedUp: readOnly, storeDefault: true), "The share's own answer beats the store's")
}

@Test func beforeItsLookupLandsAnObjectTakesItsStoresLastAnswer() {
    // The first redraws after launch are when iCloud's import holds the
    // executor longest; a partner who could edit yesterday can edit now.
    #expect(SharingStatusCache.editability(lookedUp: nil, storeDefault: true))
    #expect(!SharingStatusCache.editability(lookedUp: nil, storeDefault: false))
}

@Test func withNothingKnownAnObjectInTheSharedStoreWaitsToBeEditable() {
    // An edit control a moment late, rather than a view-only participant
    // saving something iCloud will refuse.
    #expect(!SharingStatusCache.editability(lookedUp: nil, storeDefault: nil))
    // Everything in the shared store is in someone's share, so a lookup
    // without one (fetchShares failed, or hasn't caught up) is not knowing.
    #expect(!SharingStatusCache.editability(lookedUp: .notShared, storeDefault: nil))
    #expect(SharingStatusCache.editability(lookedUp: .notShared, storeDefault: true))
}

// MARK: - A sync whose end never came

private func event(
    _ id: UUID = UUID(),
    _ store: String,
    _ kind: CloudSyncEvent.Kind,
    at start: Date,
    endingAt end: Date? = nil
) -> CloudSyncEvent {
    CloudSyncEvent(id: id, storeIdentifier: store, kind: kind, startDate: start, endDate: end, succeeded: end != nil)
}

@Test func aLaterEventInTheSameStoreEndsAnEarlierOneThatNeverReportedItsEnd() {
    var ledger = CloudSyncLedger()
    ledger.record(event(.init(), "fuel", .setup, at: t0))
    #expect(ledger.isSyncing(in: ["fuel"]))
    // The setup's end never arrives; the mirroring delegate goes on to an
    // export, which it can only do once the setup is over.
    let export = UUID()
    ledger.record(event(export, "fuel", .export, at: t0 + 600))
    #expect(ledger.oldestInFlightStart(in: ["fuel"]) == t0 + 600)
    ledger.record(event(export, "fuel", .export, at: t0 + 600, endingAt: t0 + 602))
    #expect(!ledger.isSyncing(in: ["fuel"]), "Not 'syncing' until relaunch")
}

@Test func anotherStoresEventsLeaveAnUnfinishedSyncAlone() {
    var ledger = CloudSyncLedger()
    ledger.record(event(.init(), "fuel", .import, at: t0))
    ledger.record(event(.init(), "trips", .export, at: t0 + 10, endingAt: t0 + 11))
    #expect(ledger.isSyncing(in: ["fuel"]))
}

@Test func anOlderEventsLateNoticeLeavesTheNewerSyncRunning() {
    var ledger = CloudSyncLedger()
    let importID = UUID()
    ledger.record(event(importID, "fuel", .import, at: t0 + 100))
    ledger.record(event(.init(), "fuel", .export, at: t0, endingAt: t0 + 50))
    #expect(ledger.oldestInFlightStart(in: ["fuel"]) == t0 + 100)
    ledger.record(event(importID, "fuel", .import, at: t0 + 100, endingAt: t0 + 140))
    #expect(!ledger.isSyncing(in: ["fuel"]))
}

@Test func shareWaitsForARecentSyncButNotForOneThatIsStuck() {
    #expect(!SharePreparationPlan.isWorthWaiting(forSyncSince: nil, asOf: t0))
    #expect(SharePreparationPlan.isWorthWaiting(forSyncSince: t0, asOf: t0 + 20))
    // Waiting out the whole limit for a sync running this long only delayed
    // every Share by that much before it went on anyway.
    #expect(!SharePreparationPlan.isWorthWaiting(forSyncSince: t0, asOf: t0 + SharePreparationPlan.longSync))
    #expect(!SharePreparationPlan.isWorthWaiting(forSyncSince: t0, asOf: t0 + 11 * 3_600))
}

// MARK: - The notifier reads history once the import is over

@Test func anImportIsUnderWayFromItsStartToItsEnd() {
    var current = SharedChangeImportWatch.importStart(current: nil, eventIsImport: true, eventStarted: t0, eventEnded: false)
    #expect(current == t0)
    // Its start posted again changes nothing.
    current = SharedChangeImportWatch.importStart(current: current, eventIsImport: true, eventStarted: t0, eventEnded: false)
    #expect(current == t0)
    current = SharedChangeImportWatch.importStart(current: current, eventIsImport: true, eventStarted: t0, eventEnded: true)
    #expect(current == nil)
}

@Test func anyLaterEventShowsTheImportIsOverEvenWithoutItsEnd() {
    let after = SharedChangeImportWatch.importStart(current: t0, eventIsImport: false, eventStarted: t0 + 30, eventEnded: false)
    #expect(after == nil)
    let nextImport = SharedChangeImportWatch.importStart(current: t0, eventIsImport: true, eventStarted: t0 + 30, eventEnded: false)
    #expect(nextImport == t0 + 30)
}

@Test func anOlderEventsLateNoticeLeavesTheImportUnderWay() {
    #expect(SharedChangeImportWatch.importStart(current: t0 + 60, eventIsImport: false, eventStarted: t0, eventEnded: true) == t0 + 60)
    #expect(SharedChangeImportWatch.importStart(current: t0 + 60, eventIsImport: true, eventStarted: t0, eventEnded: true) == t0 + 60)
}

@Test func otherEventsWithNoImportUnderWayStartNothing() {
    #expect(SharedChangeImportWatch.importStart(current: nil, eventIsImport: false, eventStarted: t0, eventEnded: false) == nil)
    #expect(SharedChangeImportWatch.importStart(current: nil, eventIsImport: true, eventStarted: t0, eventEnded: true) == nil)
}

@Test func historyWaitsForAnImportButNotForOneThatIsStuck() {
    #expect(!SharedChangeImportWatch.defers(importStartedAt: nil, asOf: t0))
    #expect(SharedChangeImportWatch.defers(importStartedAt: t0, asOf: t0 + 30))
    #expect(!SharedChangeImportWatch.defers(importStartedAt: t0, asOf: t0 + SharedChangeImportWatch.maximumDeferral))
}
