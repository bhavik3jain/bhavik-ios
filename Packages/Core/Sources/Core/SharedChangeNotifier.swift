import CloudKit
import CoreData
import Foundation
import Synchronization

/// Tells the user when someone they share with changes something: a partner
/// adds a stop to a shared trip, logs a fill-up on a shared car, adds a place
/// to a shared guide, updates a shared Points or Finance household.
///
/// One per `CloudSharedStore` container, started by `BhavikApp.init()` with
/// that module's describer. It reads the container's persistent history —
/// both stores already track it, because CloudKit mirroring requires it —
/// every time a store reports a remote change, the way Apple's "Sharing Core
/// Data objects between iCloud users" sample does, and keeps a token per store
/// so each transaction is looked at once, across launches.
///
/// What gets through, in order (`SharedChangeFilter`, `SharedRootArrivals`):
/// transactions the CloudKit mirroring delegate imported, never this
/// device's own saves; inserts and updates, never deletions; objects that are
/// actually shared — in the shared store, or in a private-store zone that has
/// a `CKShare`; changes whose record says someone other than this iCloud
/// account made them; nothing under a root that just arrived by accepting a
/// share. Then `SharedChangeCoalescer` turns each root's burst into one
/// notification.
///
/// Nothing is notified for the first download after install or after this
/// feature first ships: until a store has a saved token, it waits for its
/// first successful CloudKit import (`CloudKitImportGate` tracks those) and
/// then starts from wherever history stands at that moment.
///
/// All mutable state is confined to `context`'s private queue — every entry
/// point hops onto it with `perform` — which is what the `@unchecked
/// Sendable` below relies on. CloudKit is only ever read from its local
/// cache (`fetchShares(matching:)`, `record(for:)`), never waited on over the
/// network, and never on the main thread.
public final class SharedChangeNotifier: @unchecked Sendable {
    /// Notifiers live for the whole process, like the containers they watch.
    private static let running = Mutex<[SharedChangeNotifier]>([])

    private let container: NSPersistentCloudKitContainer
    private let context: NSManagedObjectContext
    private let moduleID: String
    private let moduleName: String
    private let describe: SharedChangeDescriber
    private let entityNames: Set<String>
    private let tokenDirectory: URL?

    // Confined to `context`'s queue.
    private var tokens: [String: NSPersistentHistoryToken] = [:]
    private var bootstrapping: Set<String> = []
    private var arrivals = SharedRootArrivals()
    private var coalescer = SharedChangeCoalescer()
    /// Start of the latest successful CloudKit export per store: every
    /// transaction before it has been exported, so the mirroring delegate no
    /// longer needs it. See `purgeIfSafe`.
    private var lastExportStart: [String: Date] = [:]
    /// When history was last read to the end, per store.
    private var processedThrough: [String: Date] = [:]
    private var purged: Set<String> = []
    private var flushScheduled = false
    /// Signalled when the pending notifications have posted, releasing the
    /// expiring activity that is keeping the process awake. A fresh one per
    /// activity: a signal that lands after its wait timed out would otherwise
    /// linger and let the next activity end at once.
    private var activityFinished: DispatchSemaphore?
    /// The Mac's equivalent — see `holdProcessAlive`.
    private var macActivity: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []

    /// Starts watching `container`. Returns nil for a container with no
    /// CloudKit mirroring (tests, the schema-initialising launch): nothing
    /// there is ever imported, so there's nothing to tell anyone.
    ///
    /// `moduleID` is what a tap on the notification opens (`HomeView`'s
    /// `SelectedModule` raw value); `moduleName` is the notification's
    /// subtitle.
    @MainActor
    @discardableResult
    public static func start(
        container: NSPersistentCloudKitContainer,
        moduleID: String,
        moduleName: String,
        describe: @escaping SharedChangeDescriber
    ) -> SharedChangeNotifier? {
        guard container.persistentStoreDescriptions.contains(where: { $0.cloudKitContainerOptions != nil }) else {
            return nil
        }
        let notifier = SharedChangeNotifier(container: container, moduleID: moduleID, moduleName: moduleName, describe: describe)
        running.withLock { $0.append(notifier) }
        notifier.begin()
        return notifier
    }

    private init(
        container: NSPersistentCloudKitContainer,
        moduleID: String,
        moduleName: String,
        describe: @escaping SharedChangeDescriber
    ) {
        self.container = container
        self.context = container.newBackgroundContext()
        self.moduleID = moduleID
        self.moduleName = moduleName
        self.describe = describe
        self.entityNames = Set(container.managedObjectModel.entities.compactMap(\.name))
        // Application Support, not UserDefaults: a token is an archived
        // object per store, and UserDefaults is for small settings.
        self.tokenDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SharedChangeHistory", isDirectory: true)
            .appendingPathComponent(container.name, isDirectory: true)
    }

    // MARK: - Wiring

    private func begin() {
        let coordinator = container.persistentStoreCoordinator
        // Observers first, then the initial pass: an import that finishes in
        // between still queues behind that pass on the same context.
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: coordinator,
            queue: nil
        ) { [weak self] notification in
            guard let self, let storeID = notification.userInfo?[NSStoreUUIDKey] as? String else { return }
            self.context.perform { self.process(storeID: storeID) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  event.endDate != nil,
                  event.succeeded else { return }
            let storeID = event.storeIdentifier
            let type = event.type
            let started = event.startDate
            self.context.perform { self.cloudKitEventFinished(type: type, storeID: storeID, started: started) }
        })

        context.perform {
            for store in coordinator.persistentStores {
                guard let storeID = store.identifier else { continue }
                if let token = self.loadToken(for: storeID) {
                    self.tokens[storeID] = token
                    // Whatever arrived while the app wasn't running, or was
                    // suspended before it could be read.
                    self.process(storeID: storeID)
                } else if CloudKitImportGate.hasImported(self.container, storeIdentifier: storeID) {
                    self.startFromNow(storeID: storeID)
                } else {
                    self.bootstrapping.insert(storeID)
                }
            }
        }
    }

    private func cloudKitEventFinished(type: NSPersistentCloudKitContainer.EventType, storeID: String, started: Date) {
        switch type {
        case .import where bootstrapping.contains(storeID):
            // The first download is done; everything in it is history
            // nobody needs telling about.
            bootstrapping.remove(storeID)
            startFromNow(storeID: storeID)
        case .export:
            lastExportStart[storeID] = started
            purgeIfSafe(storeID: storeID)
        default:
            break
        }
    }

    // MARK: - Reading history

    private func process(storeID: String) {
        guard !bootstrapping.contains(storeID),
              let store = container.persistentStoreCoordinator.persistentStores.first(where: { $0.identifier == storeID })
        else { return }

        let readStarted = Date.now
        let request = NSPersistentHistoryChangeRequest.fetchHistory(after: tokens[storeID])
        request.affectedStores = [store]
        let transactions: [NSPersistentHistoryTransaction]
        do {
            transactions = (try context.execute(request) as? NSPersistentHistoryResult)?.result
                as? [NSPersistentHistoryTransaction] ?? []
        } catch {
            // The token outlived its history (purged, or the store was reset
            // after an iCloud account change). Replaying from the start would
            // announce everything ever shared, so start again from now.
            startFromNow(storeID: storeID)
            return
        }

        if let last = transactions.last {
            let events = events(from: transactions, in: store)
            let now = Date.now
            for event in arrivals.admit(events, asOf: now) {
                coalescer.add(event, at: now)
            }
            saveToken(last.token, for: storeID)
            scheduleFlush()
        }
        processedThrough[storeID] = readStarted
        purgeIfSafe(storeID: storeID)
    }

    private func events(from transactions: [NSPersistentHistoryTransaction], in store: NSPersistentStore) -> [SharedChangeEvent] {
        let isSharedStore = store.url == container.persistentStoreDescriptions
            .first(where: { $0.cloudKitContainerOptions?.databaseScope == .shared })?.url

        var objectIDs: [String: NSManagedObjectID] = [:]
        let records = transactions.map { transaction in
            HistoryTransactionRecord(
                author: transaction.author,
                changes: (transaction.changes ?? []).map { change in
                    let key = change.changedObjectID.uriRepresentation().absoluteString
                    objectIDs[key] = change.changedObjectID
                    return HistoryChangeRecord(
                        objectKey: key,
                        entityName: change.changedObjectID.entity.name ?? "",
                        kind: Self.kind(of: change.changeType),
                        updatedProperties: Set((change.updatedProperties ?? []).map(\.name))
                    )
                }
            )
        }

        var shares: [NSManagedObjectID: CKShare] = [:]
        var unshared: Set<NSManagedObjectID> = []
        var events: [SharedChangeEvent] = []
        for change in SharedChangeFilter.relevantChanges(in: records, entityNames: entityNames) {
            guard let objectID = objectIDs[change.objectKey],
                  let object = try? context.existingObject(with: objectID),
                  let description = describe(object, SharedObjectChange(kind: change.kind, updatedProperties: change.updatedProperties))
            else { continue }

            let root = description.rootID
            var share = shares[root]
            if share == nil, !unshared.contains(root) {
                share = (try? container.fetchShares(matching: [root]))?[root]
                if let share { shares[root] = share } else { unshared.insert(root) }
            }
            // Everything in the shared store is someone else's share; in the
            // private store only a zone with a CKShare is shared at all.
            guard share != nil || isSharedStore else { continue }

            let modifiedBy = container.record(for: objectID)?.lastModifiedUserRecordID?.recordName
            let author = SharedChangeAuthorResolver.author(
                lastModifiedBy: modifiedBy,
                participants: share.map(SharedChangeAuthorResolver.participants(of:)) ?? []
            )
            events.append(SharedChangeEvent(
                moduleID: moduleID,
                rootKey: root.uriRepresentation().absoluteString,
                rootTitle: description.rootTitle,
                objectKey: change.objectKey,
                kind: change.kind,
                action: description.action,
                author: author
            ))
        }
        // Don't keep every object from every batch registered and snapshotted
        // for the life of the app.
        context.reset()
        return events
    }

    private static func kind(of type: NSPersistentHistoryChangeType) -> SharedChangeKind {
        switch type {
        case .insert: .inserted
        case .update: .updated
        case .delete: .deleted
        @unknown default: .updated
        }
    }

    // MARK: - Posting

    private func scheduleFlush() {
        guard !coalescer.isEmpty else { return }
        holdProcessAlive()
        guard !flushScheduled, let deadline = coalescer.nextDeadline else { return }
        flushScheduled = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(deadline.timeIntervalSinceNow, 0)) { [weak self] in
            guard let self else { return }
            self.context.perform { self.flush(force: false) }
        }
    }

    private func flush(force: Bool) {
        flushScheduled = false
        for notice in coalescer.due(asOf: .now, force: force) {
            SharedChangeNotifications.post(notice, moduleName: moduleName)
        }
        if coalescer.isEmpty {
            releaseProcess()
        } else {
            scheduleFlush()
        }
    }

    /// A silent push wakes the app for a few seconds, and a burst is held
    /// back longer than that to coalesce. Without an expiring activity the
    /// app could be suspended with notifications still pending and post them
    /// only on the next launch. `performExpiringActivity` holds the process
    /// awake until its block returns, and calls it again with `expired` when
    /// the system won't wait any longer — then everything pending posts at
    /// once.
    ///
    /// That API is iOS-only (it fails the Mac build as unavailable). A Mac app
    /// isn't suspended in the background, but App Nap can stretch the
    /// coalescing timer by minutes, so there a plain `beginActivity` keeps the
    /// timer honest until the burst has posted.
    private func holdProcessAlive() {
        #if os(macOS)
        guard macActivity == nil else { return }
        macActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Posting notifications about shared changes"
        )
        #else
        guard activityFinished == nil else { return }
        let finished = DispatchSemaphore(value: 0)
        activityFinished = finished
        ProcessInfo.processInfo.performExpiringActivity(withReason: "Posting notifications about shared changes") { [weak self] expired in
            guard let self else { return }
            if expired {
                self.context.performAndWait { self.flush(force: true) }
            } else if finished.wait(timeout: .now() + 60) == .timedOut {
                // Gave up holding on; a later burst may take out a new one.
                self.context.perform {
                    if self.activityFinished === finished { self.activityFinished = nil }
                }
            }
        }
        #endif
    }

    private func releaseProcess() {
        if let macActivity {
            ProcessInfo.processInfo.endActivity(macActivity)
            self.macActivity = nil
        }
        activityFinished?.signal()
        activityFinished = nil
    }

    // MARK: - Tokens

    private func startFromNow(storeID: String) {
        guard let store = container.persistentStoreCoordinator.persistentStores.first(where: { $0.identifier == storeID }),
              let token = container.persistentStoreCoordinator.currentPersistentHistoryToken(fromStores: [store])
        else { return }
        saveToken(token, for: storeID)
        processedThrough[storeID] = .now
    }

    private func tokenURL(for storeID: String) -> URL? {
        tokenDirectory?.appendingPathComponent("\(storeID).token")
    }

    private func loadToken(for storeID: String) -> NSPersistentHistoryToken? {
        guard let url = tokenURL(for: storeID), let data = try? Data(contentsOf: url) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: data)
    }

    private func saveToken(_ token: NSPersistentHistoryToken, for storeID: String) {
        tokens[storeID] = token
        guard let directory = tokenDirectory, let url = tokenURL(for: storeID),
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Purging

    /// Deletes history nothing needs any more, at most once per store per
    /// launch.
    ///
    /// History has two readers: this notifier, and the CloudKit mirroring
    /// delegate, which exports local saves by reading history since its own
    /// last export. Deleting history it hasn't exported yet makes it lose
    /// track and fall back to a full re-export, so the cutoff is the earliest
    /// of: the start of an export that finished successfully this launch,
    /// what this notifier has read, and a week ago as a margin. Nothing is
    /// purged until an export has been seen to succeed. Anything new that
    /// reads persistent history must be added to this cutoff.
    private func purgeIfSafe(storeID: String) {
        guard !purged.contains(storeID),
              let exported = lastExportStart[storeID],
              let processed = processedThrough[storeID],
              let store = container.persistentStoreCoordinator.persistentStores.first(where: { $0.identifier == storeID })
        else { return }
        let cutoff = min(exported, processed, Date.now.addingTimeInterval(-7 * 24 * 60 * 60))
        let request = NSPersistentHistoryChangeRequest.deleteHistory(before: cutoff)
        request.affectedStores = [store]
        _ = try? context.execute(request)
        purged.insert(storeID)
    }
}
