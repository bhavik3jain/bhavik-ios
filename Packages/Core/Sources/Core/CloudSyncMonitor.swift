import CoreData
import Foundation
import Observation
import os
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Watches CloudKit mirroring for every store in the app and offers an honest
/// "refresh from iCloud".
///
/// One instance, built first thing in `BhavikApp.init()` and injected at the
/// app root with `.environment(_:)`. Read it with
/// `@Environment(CloudSyncMonitor.self) private var sync: CloudSyncMonitor?`
/// (optional, so previews and tests without one still build).
///
/// ## API
///
/// - `lastSyncedAt: Date?` — end of the latest successful import or export
///   in any store this session. Format it with
///   `CloudSyncStatusText.lastSynced(_:isRefreshing:)`, never by hand.
/// - `isRefreshing: Bool` — a `refresh()` is waiting. Disable a refresh
///   control and show progress while it's true.
/// - `isSyncing: Bool` — mirroring is doing *something* right now (including
///   the automatic imports and exports nobody asked for).
/// - `lastOutcome: CloudRefreshOutcome?` — how the latest `refresh()` ended;
///   `CloudSyncStatusText.message(for:)` turns it into a sentence, or `nil`
///   when the freshness label already says it all. Cleared again once a
///   successful import lands after it, so it never outlives the news.
/// - `refresh(storesOf:) async -> CloudRefreshOutcome` — nudge mirroring to
///   import, then wait (at most `refreshTimeout`) for every store in scope to
///   finish one. Pass a module's `NSPersistentStoreCoordinator` to wait on
///   that module only; pass nothing to wait on everything. A call while one is
///   already running joins it rather than starting another.
/// - `track(_:)` — register a Core Data container, so a scoped refresh knows
///   its stores and a finished refresh re-reads its view context.
///
/// A `.refreshable` list uses `.refreshesFromCloud()` (see
/// `CloudSyncRefreshable.swift`) rather than calling `refresh` itself.
///
/// ## Why it can't simply "sync now"
///
/// `NSPersistentCloudKitContainer` has no sync-now API; Apple's own engineers
/// answer "No" to asking for one. It imports at launch, whenever the app
/// becomes active, and when a CloudKit push says the database changed — and
/// until the `aps-environment` entitlement was added there were no pushes, so
/// a partner's new itinerary item or fuel-up only appeared at the next
/// foreground. `refresh` re-posts the app's own did-become-active
/// notification — mirroring observes it to schedule its foreground import, and
/// it's the only trigger reachable through public API — then waits for the
/// import itself and reports whether one landed. That mirroring reacts to it
/// is observed behaviour, not a documented promise, which is exactly why the
/// wait is for a real import event rather than a timer: if a future OS stops
/// reacting, a refresh honestly reports "nothing new yet" instead of lying.
/// Nothing else in the app observes the notification (SwiftUI's `scenePhase`
/// is driven by the scene, not by it).
///
/// Rejected: removing and re-adding the persistent stores, which does force a
/// fresh import but invalidates every managed object a view is holding — the
/// next property read on one crashes the app.
@MainActor
@Observable
public final class CloudSyncMonitor {
    public private(set) var ledger = CloudSyncLedger()
    public private(set) var isRefreshing = false
    public private(set) var lastOutcome: CloudRefreshOutcome?

    public var lastSyncedAt: Date? { ledger.lastSyncedAt }
    public var isSyncing: Bool { ledger.isSyncing }

    /// How long a refresh waits for imports before admitting none came.
    /// Imports normally finish in a second or two; this only bounds the wait,
    /// not the sync — a late import still lands and updates the screen.
    public let refreshTimeout: Duration

    /// Nudges are spaced at least this far apart. Asking the system to run
    /// mirroring activities too often trips `dasd`'s ActivityRateLimitPolicy,
    /// which stops *all* of the app's syncing for hours (TN3163).
    public nonisolated static let nudgeCooldown: TimeInterval = 60

    @ObservationIgnored private let containerID: String?
    @ObservationIgnored private let nudge: @MainActor () -> Void
    @ObservationIgnored private var containers: [NSPersistentCloudKitContainer] = []
    @ObservationIgnored private var lastNudgeAt: Date?
    @ObservationIgnored private var lastOutcomeAt: Date?
    @ObservationIgnored private var running: Task<CloudRefreshOutcome, Never>?

    private static let log = Logger(subsystem: "com.bhavikjain.trackers", category: "CloudSync")

    /// - Parameters:
    ///   - containerID: the iCloud container, for checking the account before
    ///     waiting on imports that can't come. `nil` skips the check (tests,
    ///     which must never touch CloudKit).
    ///   - nudge: what `refresh` does to prompt an import. Tests pass a
    ///     counter; the app uses the default.
    ///   - center: where `eventChangedNotification` is observed.
    public init(
        containerID: String?,
        refreshTimeout: Duration = .seconds(15),
        nudge: @escaping @MainActor () -> Void = CloudSyncMonitor.postDidBecomeActive,
        center: NotificationCenter = .default
    ) {
        self.containerID = containerID
        self.refreshTimeout = refreshTimeout
        self.nudge = nudge
        // Every container's events, not one container's: the SwiftData store
        // (Gym, TV, Orders) mirrors through an NSPersistentCloudKitContainer
        // SwiftData never exposes, so it can only be heard this way. Built
        // before any container, so no store's launch import goes unseen. The
        // token is dropped on purpose — the monitor lives as long as the app.
        //
        // Observed on the posting queue and handed to the main queue
        // *asynchronously*, never with `queue: .main`. Posted from a
        // background thread, a `queue: .main` observer makes the post wait
        // until the main thread has run it, so the container's CloudKit queue
        // sat inside its export, holding the request executor, waiting on the
        // main thread. With the main thread waiting on that same executor (a
        // Share button's `persistUpdatedShare`), neither moved: TestFlight
        // build 16 froze on Share and was killed by the watchdog (0x8BADF00D,
        // "Failed to terminate gracefully after 5.0s") with thread
        // `com.apple.coredata.cloudkit.queue` parked in
        // `-[NSOperation waitUntilFinished]` under `eventUpdated:`. The share
        // calls moved off the main thread too (CloudShareCalls.swift); this
        // takes the other half of the cycle away, so the main thread's
        // remaining synchronous container calls (`fetchShares(matching:)`
        // for a "Shared" badge, `canUpdateRecord`) can wait, but never
        // deadlock. `DispatchQueue.main` runs the blocks in the order they
        // were posted, which the ledger relies on.
        _ = center.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            let snapshot = CloudSyncEvent(event)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.ingest(snapshot) }
            }
        }
    }

    public func track(_ container: NSPersistentCloudKitContainer) {
        guard !containers.contains(where: { $0 === container }) else { return }
        containers.append(container)
    }

    func ingest(_ event: CloudSyncEvent) {
        ledger.record(event)
        // Without this, one pull that timed out or failed left "iCloud hasn't
        // sent anything new yet" under Settings' "Updated just now" for the
        // rest of the session, after later automatic imports had succeeded.
        if lastOutcome != nil, Self.supersedes(event, outcomeAt: lastOutcomeAt) {
            lastOutcome = nil
            lastOutcomeAt = nil
        }
        Self.log.debug("""
            \(String(describing: event.kind), privacy: .public) \
            \(event.endDate == nil ? "started" : (event.succeeded ? "succeeded" : "failed"), privacy: .public) \
            store \(event.storeIdentifier, privacy: .public)\
            \(event.errorDescription.map { ": " + $0 } ?? "", privacy: .public)
            """)
    }

    @discardableResult
    public func refresh(storesOf coordinator: NSPersistentStoreCoordinator? = nil) async -> CloudRefreshOutcome {
        if let running { return await running.value }
        let scope = cloudStores(of: coordinator)
        let task = Task { await perform(scope: scope) }
        running = task
        isRefreshing = true
        let outcome = await task.value
        running = nil
        isRefreshing = false
        lastOutcome = outcome
        lastOutcomeAt = .now
        Self.log.debug("refresh ended: \(String(describing: outcome), privacy: .public)")
        return outcome
    }

    private func perform(scope: Set<String>) async -> CloudRefreshOutcome {
        guard !scope.isEmpty else { return .notSyncing }
        let requestedAt = Date.now

        if let containerID {
            let state = await CloudSync.state(containerID: containerID)
            // An account that can't sync would only ever time out.
            if state != .syncing { return .unavailable(state) }
        }

        // Inside the cooldown there is no new nudge, so waiting for an import
        // that ends after *this* request waited on one nothing had asked for:
        // pulling again seconds after a refresh that had just said "updated"
        // spun for the whole timeout and then claimed nothing new had come.
        // Measure from the nudge that is still in effect instead, so the
        // import it caused counts — or is still awaited if it hasn't landed.
        let since: Date
        if Self.shouldNudge(lastNudgeAt: lastNudgeAt, asOf: requestedAt) {
            lastNudgeAt = requestedAt
            since = requestedAt
            nudge()
        } else {
            since = lastNudgeAt ?? requestedAt
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: refreshTimeout)
        while clock.now < deadline {
            switch ledger.progress(since: since, in: scope) {
            case .finished:
                refreshViewContexts(in: scope)
                return .updated(at: .now)
            case .failed(let message):
                return .failed(message)
            case .waiting:
                // Polling a value the main actor already holds is cheap, and
                // unlike a stored continuation it can't be left hanging by an
                // event that never comes.
                try? await clock.sleep(for: .milliseconds(200))
            }
        }
        return .timedOut(lastSyncedAt: lastSyncedAt)
    }

    /// The iCloud-backed stores a refresh waits on. Stores the ledger has
    /// heard from but nobody tracked — SwiftData's — join an app-wide refresh.
    private func cloudStores(of coordinator: NSPersistentStoreCoordinator?) -> Set<String> {
        var stores = Set<String>()
        for container in containers where coordinator == nil || container.persistentStoreCoordinator === coordinator {
            for description in container.persistentStoreDescriptions where description.cloudKitContainerOptions != nil {
                if let url = description.url, let store = container.persistentStoreCoordinator.persistentStore(for: url) {
                    stores.insert(store.identifier)
                }
            }
        }
        if coordinator == nil { stores.formUnion(ledger.knownStores) }
        return stores
    }

    /// `automaticallyMergesChangesFromParent` already merges an import into
    /// each view context; this re-reads what those contexts had cached, so an
    /// object a view is holding shows the imported values too. Unsaved edits
    /// survive: `refreshAllObjects` merges rather than discards them.
    private func refreshViewContexts(in scope: Set<String>) {
        for container in containers
        where container.persistentStoreCoordinator.persistentStores.contains(where: { scope.contains($0.identifier) }) {
            container.viewContext.refreshAllObjects()
        }
    }

    /// Whether `event` makes a refresh outcome reached at `outcomeAt` old
    /// news: a successful import that finished after it.
    nonisolated static func supersedes(_ event: CloudSyncEvent, outcomeAt: Date?) -> Bool {
        guard event.kind == .import, event.succeeded, let end = event.endDate else { return false }
        guard let outcomeAt else { return true }
        return end > outcomeAt
    }

    nonisolated static func shouldNudge(lastNudgeAt: Date?, asOf now: Date) -> Bool {
        guard let lastNudgeAt else { return true }
        return now.timeIntervalSince(lastNudgeAt) >= nudgeCooldown
    }

    /// Tells mirroring the app just became active, which is what schedules its
    /// activation import. Only while the app really is active, so nothing
    /// that observes the same notification is told something untrue.
    public static func postDidBecomeActive() {
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else { return }
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: UIApplication.shared)
        #elseif os(macOS)
        guard let app = NSApp, app.isActive else { return }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: app)
        #endif
    }
}
