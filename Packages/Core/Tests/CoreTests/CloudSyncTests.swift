import CoreData
import Foundation
import Testing
@testable import Core

// MARK: - CloudSyncLedger

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func started(_ id: UUID, _ store: String, _ kind: CloudSyncEvent.Kind, at start: Date) -> CloudSyncEvent {
    CloudSyncEvent(id: id, storeIdentifier: store, kind: kind, startDate: start)
}

private func ended(
    _ id: UUID,
    _ store: String,
    _ kind: CloudSyncEvent.Kind,
    from start: Date,
    to end: Date,
    succeeded: Bool = true,
    error: String? = nil
) -> CloudSyncEvent {
    CloudSyncEvent(
        id: id, storeIdentifier: store, kind: kind, startDate: start,
        endDate: end, succeeded: succeeded, errorDescription: error
    )
}

@Test func ledgerIsSyncingOnlyBetweenAnEventsStartAndEnd() {
    var ledger = CloudSyncLedger()
    let id = UUID()
    #expect(!ledger.isSyncing)
    ledger.record(started(id, "A", .import, at: t0))
    #expect(ledger.isSyncing)
    ledger.record(ended(id, "A", .import, from: t0, to: t0 + 2))
    #expect(!ledger.isSyncing)
}

@Test func ledgerLastSyncedIsTheLatestSuccessAcrossStoresAndKinds() {
    var ledger = CloudSyncLedger()
    ledger.record(ended(UUID(), "A", .import, from: t0, to: t0 + 10))
    ledger.record(ended(UUID(), "B", .export, from: t0, to: t0 + 30))
    ledger.record(ended(UUID(), "A", .setup, from: t0, to: t0 + 99))
    ledger.record(ended(UUID(), "B", .import, from: t0, to: t0 + 50, succeeded: false, error: "nope"))
    // Setup and a failed import don't count as the device agreeing with iCloud.
    #expect(ledger.lastSyncedAt == t0 + 30)
    #expect(ledger.knownStores == ["A", "B"])
}

@Test func ledgerKeepsTheLatestTimestampWhenEventsFinishOutOfOrder() {
    var ledger = CloudSyncLedger()
    ledger.record(ended(UUID(), "A", .import, from: t0, to: t0 + 20))
    ledger.record(ended(UUID(), "A", .import, from: t0, to: t0 + 5))
    #expect(ledger.stores["A"]?.lastImportAt == t0 + 20)
}

@Test func ledgerFailureIsRememberedUntilTheNextSuccess() {
    var ledger = CloudSyncLedger()
    ledger.record(ended(UUID(), "A", .export, from: t0, to: t0 + 1, succeeded: false, error: "quota"))
    #expect(ledger.stores["A"]?.lastError == "quota")
    ledger.record(ended(UUID(), "A", .export, from: t0, to: t0 + 2))
    #expect(ledger.stores["A"]?.lastError == nil)
}

@Test func progressWaitsWithoutAnImportSinceTheRequest() {
    var ledger = CloudSyncLedger()
    ledger.record(ended(UUID(), "A", .import, from: t0, to: t0 + 1))
    #expect(ledger.progress(since: t0 + 5, in: ["A"]) == .waiting)
    // An export after the request brings nothing in.
    ledger.record(ended(UUID(), "A", .export, from: t0 + 6, to: t0 + 7))
    #expect(ledger.progress(since: t0 + 5, in: ["A"]) == .waiting)
}

@Test func progressFinishesOnlyOnceEveryStoreInScopeHasImported() {
    var ledger = CloudSyncLedger()
    ledger.record(ended(UUID(), "A", .import, from: t0 + 6, to: t0 + 7))
    #expect(ledger.progress(since: t0 + 5, in: ["A", "B"]) == .waiting)
    #expect(ledger.progress(since: t0 + 5, in: ["A"]) == .finished)
    ledger.record(ended(UUID(), "B", .import, from: t0 + 6, to: t0 + 8))
    #expect(ledger.progress(since: t0 + 5, in: ["A", "B"]) == .finished)
}

@Test func progressCountsAnImportAlreadyRunningWhenTheRequestCame() {
    var ledger = CloudSyncLedger()
    let id = UUID()
    ledger.record(started(id, "A", .import, at: t0))
    ledger.record(ended(id, "A", .import, from: t0, to: t0 + 9))
    #expect(ledger.progress(since: t0 + 5, in: ["A"]) == .finished)
}

@Test func progressReportsAFailedImportWithItsMessage() {
    var ledger = CloudSyncLedger()
    ledger.record(ended(UUID(), "A", .import, from: t0 + 6, to: t0 + 7))
    ledger.record(ended(UUID(), "B", .import, from: t0 + 6, to: t0 + 7, succeeded: false, error: "offline"))
    #expect(ledger.progress(since: t0 + 5, in: ["A", "B"]) == .failed("offline"))
}

@Test func progressOverAnEmptyScopeNeverFinishes() {
    #expect(CloudSyncLedger().progress(since: t0, in: []) == .waiting)
}

// MARK: - CloudSyncMonitor

/// Lets a test's nudge reach the monitor it was passed to.
@MainActor
private final class MonitorBox {
    var monitor: CloudSyncMonitor?
    var nudges = 0
}

/// A monitor that never hears the real notification center (no test may touch
/// CloudKit) and skips the account check.
@MainActor
private func makeMonitor(
    timeout: Duration = .seconds(5),
    onNudge: @escaping @MainActor (CloudSyncMonitor) -> Void = { _ in }
) -> (CloudSyncMonitor, MonitorBox) {
    let box = MonitorBox()
    let monitor = CloudSyncMonitor(
        containerID: nil,
        refreshTimeout: timeout,
        nudge: {
            box.nudges += 1
            if let monitor = box.monitor { onNudge(monitor) }
        },
        center: NotificationCenter()
    )
    box.monitor = monitor
    return (monitor, box)
}

/// The container posts its events from its own CloudKit queue, sometimes while
/// holding the request executor that the main thread may be waiting on. When the
/// monitor observed with `queue: .main`, that post waited for the main thread,
/// and TestFlight build 16 deadlocked on Share. The main thread here is blocked
/// the same way, and the post must still return.
@MainActor
@Test func aCloudKitEventPostedInTheBackgroundNeverWaitsForTheMainThread() {
    let center = NotificationCenter()
    let monitor = CloudSyncMonitor(containerID: nil, nudge: {}, center: center)
    let posted = DispatchSemaphore(value: 0)
    // Its own thread, not `DispatchQueue.global()`: that pool is only as wide
    // as the CPU count, and on a 3-core CI runner running every suite at once
    // the post sometimes never got a thread within the bound. It failed main
    // at two seconds and then this branch at ten, with the observer unchanged
    // and correct, and never locally.
    Thread {
        center.post(name: NSPersistentCloudKitContainer.eventChangedNotification, object: nil)
        posted.signal()
    }.start()
    #expect(posted.wait(timeout: .now() + 10) == .success)
    withExtendedLifetime(monitor) {}
}

@MainActor
@Test func refreshWithNoCloudStoresSaysSoWithoutNudging() async {
    let (monitor, box) = makeMonitor()
    #expect(await monitor.refresh() == .notSyncing)
    #expect(box.nudges == 0)
    #expect(!monitor.isRefreshing)
}

@MainActor
@Test func refreshEndsAsSoonAsAFreshImportLands() async {
    let (monitor, box) = makeMonitor { monitor in
        monitor.ingest(ended(UUID(), "A", .import, from: .now, to: .now))
    }
    monitor.ingest(ended(UUID(), "A", .import, from: t0, to: t0 + 1))

    let outcome = await monitor.refresh()
    guard case .updated = outcome else {
        Issue.record("expected .updated, got \(outcome)")
        return
    }
    #expect(box.nudges == 1)
    #expect(monitor.lastOutcome == outcome)
    #expect(monitor.lastSyncedAt.map { $0 > t0 + 1 } == true)
}

@MainActor
@Test func refreshReportsAFailedImport() async {
    let (monitor, _) = makeMonitor { monitor in
        monitor.ingest(ended(UUID(), "A", .import, from: .now, to: .now, succeeded: false, error: "offline"))
    }
    monitor.ingest(ended(UUID(), "A", .import, from: t0, to: t0 + 1))
    #expect(await monitor.refresh() == .failed("offline"))
}

@MainActor
@Test func refreshGivesUpHonestlyWhenNoImportComes() async {
    let (monitor, _) = makeMonitor(timeout: .milliseconds(300))
    monitor.ingest(ended(UUID(), "A", .import, from: t0, to: t0 + 1))
    #expect(await monitor.refresh() == .timedOut(lastSyncedAt: t0 + 1))
    #expect(!monitor.isRefreshing)
}

@MainActor
@Test func overlappingRefreshesShareOneWaitAndOneNudge() async {
    let (monitor, box) = makeMonitor(timeout: .milliseconds(300))
    monitor.ingest(ended(UUID(), "A", .import, from: t0, to: t0 + 1))

    async let first = monitor.refresh()
    async let second = monitor.refresh()
    let outcomes = await [first, second]
    #expect(outcomes.allSatisfy { $0 == .timedOut(lastSyncedAt: t0 + 1) })
    #expect(box.nudges == 1)
}

@MainActor
@Test func aSecondRefreshInsideTheCooldownCountsTheFirstNudgesImport() async {
    let (monitor, box) = makeMonitor(timeout: .seconds(5)) { monitor in
        monitor.ingest(ended(UUID(), "A", .import, from: .now, to: .now))
    }
    monitor.ingest(ended(UUID(), "A", .import, from: t0, to: t0 + 1))
    guard case .updated = await monitor.refresh() else {
        Issue.record("first refresh should have landed")
        return
    }

    // No second nudge, and no waiting out the 5 s timeout for an import
    // nothing asked for: the one the first nudge caused already counts.
    // `.updated` is the proof — a refresh that waited for a fresh import
    // would get none and end `.timedOut`. It used to time the call as well,
    // and that wall-clock bound failed on starved CI runners at 1 s (PR #11)
    // and again at 4 s (PR #28) though the refresh never waited at all.
    let second = await monitor.refresh()
    guard case .updated = second else {
        Issue.record("expected .updated, got \(second)")
        return
    }
    #expect(box.nudges == 1)
}

@MainActor
@Test func aSecondRefreshInsideTheCooldownStillWaitsForAnImportNotYetLanded() async {
    let (monitor, box) = makeMonitor(timeout: .milliseconds(200))
    monitor.ingest(ended(UUID(), "A", .import, from: t0, to: t0 + 1))
    await monitor.refresh()
    #expect(await monitor.refresh() == .timedOut(lastSyncedAt: t0 + 1))
    #expect(box.nudges == 1)
}

@MainActor
@Test func aLaterSuccessfulImportClearsAStaleRefreshMessage() async {
    let (monitor, _) = makeMonitor(timeout: .milliseconds(200))
    monitor.ingest(ended(UUID(), "A", .import, from: t0, to: t0 + 1))
    await monitor.refresh()
    #expect(monitor.lastOutcome == .timedOut(lastSyncedAt: t0 + 1))

    // A failure, or an import that finished before the outcome, is no news.
    monitor.ingest(ended(UUID(), "A", .import, from: .now, to: .now + 1, succeeded: false, error: "offline"))
    monitor.ingest(ended(UUID(), "A", .import, from: t0, to: t0 + 2))
    monitor.ingest(ended(UUID(), "A", .export, from: .now, to: .now + 1))
    #expect(monitor.lastOutcome != nil)

    monitor.ingest(ended(UUID(), "A", .import, from: .now, to: .now + 1))
    #expect(monitor.lastOutcome == nil)
}

@Test func nudgesAreSpacedByTheCooldown() {
    #expect(CloudSyncMonitor.shouldNudge(lastNudgeAt: nil, asOf: t0))
    #expect(!CloudSyncMonitor.shouldNudge(lastNudgeAt: t0, asOf: t0 + 59))
    #expect(CloudSyncMonitor.shouldNudge(lastNudgeAt: t0, asOf: t0 + CloudSyncMonitor.nudgeCooldown))
}

// MARK: - CloudSyncStatusText

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private let enUS = Locale(identifier: "en_US")

/// 2026-09-26 15:12 UTC.
private let now = utc.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 15, minute: 12))!

private func label(_ date: Date?, refreshing: Bool = false) -> String {
    CloudSyncStatusText.lastSynced(date, isRefreshing: refreshing, asOf: now, calendar: utc, locale: enUS)
}

@Test func statusTextCoversEachAge() {
    #expect(label(nil) == "Not synced yet")
    #expect(label(now, refreshing: true) == "Checking iCloud…")
    #expect(label(now - 30) == "Updated just now")
    // A timestamp a moment ahead of this device's clock isn't "in the future".
    #expect(label(now + 2) == "Updated just now")
    #expect(label(now - 5 * 60) == "Last synced 5 min ago")

    let earlierToday = label(now - 3 * 60 * 60)
    #expect(earlierToday.hasPrefix("Last synced today at "))
    #expect(earlierToday.contains("12:12"))

    let yesterday = label(now - 20 * 60 * 60)
    #expect(yesterday.hasPrefix("Last synced yesterday at "))
    #expect(yesterday.contains("7:12"))

    #expect(label(utc.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 9))!) == "Last synced Sep 3")
}

@Test func refreshMessagesStayQuietOnlyWhenSomethingLanded() {
    #expect(CloudSyncStatusText.message(for: .updated(at: now)) == nil)
    #expect(CloudSyncStatusText.message(for: .timedOut(lastSyncedAt: nil)) != nil)
    #expect(CloudSyncStatusText.message(for: .failed("offline"))?.contains("offline") == true)
    #expect(CloudSyncStatusText.message(for: .unavailable(.signedOut)) == CloudSyncState.signedOut.explanation)
    #expect(CloudSyncStatusText.message(for: .notSyncing) != nil)
}

private func footer(_ date: Date?, refreshing: Bool = false) -> String {
    CloudSyncStatusText.synced(date, isRefreshing: refreshing, asOf: now, calendar: utc, locale: enUS)
}

@Test func sidebarFooterUsesTheShortForm() {
    #expect(footer(nil) == "Not synced yet")
    #expect(footer(now, refreshing: true) == "Checking iCloud…")
    #expect(footer(now - 30) == "Synced just now")
    #expect(footer(now + 2) == "Synced just now")
    #expect(footer(now - 5 * 60) == "Synced 5 min ago")
    let earlierToday = footer(now - 3 * 60 * 60)
    #expect(earlierToday.hasPrefix("Synced at "))
    #expect(earlierToday.contains("12:12"))
    #expect(footer(now - 20 * 60 * 60) == "Synced yesterday")
    #expect(footer(utc.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 9))!) == "Synced Sep 3")
}

@Test func sidebarHeadlineOwnsUpToAFailure() {
    #expect(CloudSyncStatusText.headline(lastSyncedAt: nil, isRefreshing: false, lastOutcome: nil) == "iCloud")
    #expect(CloudSyncStatusText.headline(lastSyncedAt: now, isRefreshing: false, lastOutcome: nil) == "iCloud up to date")
    #expect(CloudSyncStatusText.headline(lastSyncedAt: now, isRefreshing: true, lastOutcome: nil) == "Syncing with iCloud")
    // A timed-out wait isn't a failure: the last good sync still stands.
    #expect(CloudSyncStatusText.headline(lastSyncedAt: now, isRefreshing: false, lastOutcome: .timedOut(lastSyncedAt: now)) == "iCloud up to date")
    #expect(CloudSyncStatusText.headline(lastSyncedAt: now, isRefreshing: false, lastOutcome: .failed("offline")) == "iCloud couldn't sync")
    #expect(CloudSyncStatusText.headline(lastSyncedAt: now, isRefreshing: false, lastOutcome: .unavailable(.signedOut)) == "iCloud unavailable")
}
