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
    /// When the CloudKit import under way in each store started; see
    /// `SharedChangeImportWatch`.
    private var importing: [String: Date] = [:]
    /// Stores whose history `process` held back until their import is over.
    private var deferred: Set<String> = []
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
                    as? NSPersistentCloudKitContainer.Event else { return }
            let storeID = event.storeIdentifier
            let type = event.type
            let started = event.startDate
            let ended = event.endDate != nil
            let succeeded = event.succeeded
            self.context.perform {
                self.cloudKitEvent(type: type, storeID: storeID, started: started, ended: ended, succeeded: succeeded)
            }
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

    /// Every CloudKit event, started or finished: keeps `importing` up to
    /// date, reads history held back by an import once it's over, and passes
    /// successful ends on.
    private func cloudKitEvent(
        type: NSPersistentCloudKitContainer.EventType,
        storeID: String,
        started: Date,
        ended: Bool,
        succeeded: Bool
    ) {
        importing[storeID] = SharedChangeImportWatch.importStart(
            current: importing[storeID],
            eventIsImport: type == .import,
            eventStarted: started,
            eventEnded: ended
        )
        if ended, succeeded {
            cloudKitEventFinished(type: type, storeID: storeID, started: started)
        }
        if importing[storeID] == nil, deferred.remove(storeID) != nil {
            process(storeID: storeID)
        }
    }

    private func cloudKitEventFinished(type: NSPersistentCloudKitContainer.EventType, storeID: String, started: Date) {
        if type == .import {
            SharedChangeActivityLog.noteImport(moduleID: moduleID)
        }
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
        // Remote-change notifications arrive while the import that caused
        // them is still running and holding the container's executor, and
        // reading who changed what (`fetchShares`, `records(for:)`) waits on
        // that executor: after a sync reset the Mac logged "Wait timed out
        // during call to recordForManagedObjectID" every ten minutes for three
        // and a half hours, one wait per changed object. Read once it's over.
        if SharedChangeImportWatch.defers(importStartedAt: importing[storeID]) {
            deferred.insert(storeID)
            return
        }

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
            let (events, unsharedTitles) = events(from: transactions, in: store)
            // iCloud's own alert about an edit this account made on another
            // device — see SharedChangeServerAlertCleanup.
            let ownEditAlerts = SharedChangeServerAlertCleanup.ownEditAlertIDs(in: events)
            if !ownEditAlerts.isEmpty {
                SharedChangeServerAlertInbox.removeDelivered(subscriptionIDs: ownEditAlerts)
            }
            let now = Date.now
            let admitted = arrivals.admit(events, asOf: now)
            for event in admitted {
                coalescer.add(event, at: now)
            }
            logSkipped(events: events, admitted: admitted, unsharedTitles: unsharedTitles)
            saveToken(last.token, for: storeID)
            scheduleFlush()
        }
        processedThrough[storeID] = readStarted
        purgeIfSafe(storeID: storeID)
    }

    /// What the Status page's activity log shows for a batch that produced
    /// no notification, or only part of one. See `SharedChangeActivityLog`.
    private func logSkipped(events: [SharedChangeEvent], admitted: [SharedChangeEvent], unsharedTitles: Set<String>) {
        for title in unsharedTitles.sorted() {
            SharedChangeActivityLog.record(SharedChangeLogEntry(moduleID: moduleID, outcome: .notShared, detail: title))
        }
        let admittedKeys = Set(admitted.map(\.objectKey))
        let skipped = events.filter { !admittedKeys.contains($0.objectKey) }
        for title in Set(skipped.filter { $0.author == .currentUser }.map(\.rootTitle)).sorted() {
            SharedChangeActivityLog.record(SharedChangeLogEntry(moduleID: moduleID, outcome: .ownEdit, detail: title))
        }
        for title in Set(skipped.filter { $0.author != .currentUser }.map(\.rootTitle)).sorted() {
            SharedChangeActivityLog.record(SharedChangeLogEntry(moduleID: moduleID, outcome: .justJoined, detail: title))
        }
    }

    /// The batch's events, and the titles of roots it changed that aren't
    /// shared at all — logged, never notified.
    private func events(
        from transactions: [NSPersistentHistoryTransaction],
        in store: NSPersistentStore
    ) -> (events: [SharedChangeEvent], unsharedTitles: Set<String>) {
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

        var described: [(change: HistoryChangeRecord, objectID: NSManagedObjectID, description: SharedChangeDescription)] = []
        for change in SharedChangeFilter.relevantChanges(in: records, entityNames: entityNames) {
            guard let objectID = objectIDs[change.objectKey],
                  let object = try? context.existingObject(with: objectID),
                  let description = describe(object, SharedObjectChange(kind: change.kind, updatedProperties: change.updatedProperties))
            else { continue }
            described.append((change, objectID, description))
        }

        // One lookup of each kind for the whole batch, never one per object:
        // each call waits its turn on the container's executor, and behind a
        // sync that held it, each waited ten minutes before giving up.
        let roots = Array(Set(described.map(\.description.rootID)))
        let shares = roots.isEmpty ? [:] : (try? container.fetchShares(matching: roots)) ?? [:]
        var events: [SharedChangeEvent] = []
        var unsharedTitles: Set<String> = []
        // Everything in the shared store is someone else's share; in the
        // private store only a zone with a CKShare is shared at all.
        let kept = described.filter { entry in
            guard shares[entry.description.rootID] != nil || isSharedStore else {
                unsharedTitles.insert(entry.description.rootTitle)
                return false
            }
            return true
        }
        let changedRecords = kept.isEmpty ? [:] : container.records(for: kept.map(\.objectID))
        let alertIDs = serverAlertIDs(for: Array(Set(kept.map(\.description.rootID))), isSharedStore: isSharedStore)

        for (change, objectID, description) in kept {
            let root = description.rootID
            let share = shares[root]
            let modifiedBy = changedRecords[objectID]?.lastModifiedUserRecordID?.recordName
            let participants = share.map(SharedChangeAuthorResolver.participants(of:)) ?? []
            let author = SharedChangeAuthorResolver.author(lastModifiedBy: modifiedBy, participants: participants)
            if let reason = SharedChangeAuthorResolver.unnamedReason(
                lastModifiedBy: modifiedBy,
                participants: participants,
                hasShare: share != nil
            ) {
                SharedChangeActivityLog.record(SharedChangeLogEntry(
                    moduleID: moduleID,
                    outcome: .unnamed,
                    detail: "\(description.rootTitle) — \(reason)"
                ))
            }
            events.append(SharedChangeEvent(
                moduleID: moduleID,
                rootKey: root.uriRepresentation().absoluteString,
                rootTitle: description.rootTitle,
                objectKey: change.objectKey,
                kind: change.kind,
                action: description.action,
                author: author,
                serverAlertID: alertIDs[root]
            ))
        }
        // Don't keep every object from every batch registered and snapshotted
        // for the life of the app.
        context.reset()
        return (events, unsharedTitles)
    }

    /// The iCloud alert subscription that would cover each root: the one on
    /// its zone when this user owns it, the shared database's one when
    /// someone else does. Read from the mirroring delegate's local metadata,
    /// every root in one `recordIDs(for:)` — see `events(from:in:)`.
    private func serverAlertIDs(for roots: [NSManagedObjectID], isSharedStore: Bool) -> [NSManagedObjectID: String] {
        if isSharedStore {
            return Dictionary(uniqueKeysWithValues: roots.map { ($0, SharedChangeServerAlertID.shared) })
        }
        guard !roots.isEmpty else { return [:] }
        return container.recordIDs(for: roots).mapValues {
            SharedChangeServerAlertID.zone(moduleID: moduleID, zoneName: $0.zoneID.zoneName)
        }
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
