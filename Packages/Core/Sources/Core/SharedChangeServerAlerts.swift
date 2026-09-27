import CloudKit
import CoreData
import Foundation
import os
import UserNotifications

/// Keeps this account's iCloud alert subscriptions in step with what it
/// shares — the thin CloudKit half of `SharedChangeServerAlertPlan`, which
/// explains what these alerts are and what CloudKit does and doesn't allow.
///
/// Each pass reads the locally cached `CKShare`s (no network), builds the
/// plan's inputs, and only then asks the server: one fetch of each
/// database's subscriptions, and one modify call per database if anything
/// differs. An automatic pass (launch, foreground) with the same inputs as
/// the last successful one within `recheckInterval` skips the server
/// entirely. Passes never overlap; a request made during one runs once
/// after it.
@MainActor
public final class SharedChangeServerAlerts {
    public static let shared = SharedChangeServerAlerts()
    private init() {}

    /// One sharing module: its container, and how to name its roots.
    public struct Source: @unchecked Sendable {
        let container: NSPersistentCloudKitContainer
        let moduleID: String
        let moduleName: String
        /// The share root's entity — "SharedTrip". Every object of it in the
        /// private store with a `CKShare` is a zone this user shares.
        let rootEntityName: String
        let describe: SharedChangeDescriber

        public init(
            container: NSPersistentCloudKitContainer,
            moduleID: String,
            moduleName: String,
            rootEntityName: String,
            describe: @escaping SharedChangeDescriber
        ) {
            self.container = container
            self.moduleID = moduleID
            self.moduleName = moduleName
            self.rootEntityName = rootEntityName
            self.describe = describe
        }
    }

    private enum Job: Equatable {
        case sync(force: Bool)
        case removeAll
    }

    private nonisolated static let log = Logger(subsystem: "com.bhavikjain.trackers", category: "SharedChangeAlerts")
    private static let recheckInterval: TimeInterval = 6 * 60 * 60
    /// Where the modules this user participates in are remembered, so a tap
    /// on the participant's alert that launches the app can still be routed.
    nonisolated static let participatingDefaultsKey = "sharedChangeServerAlerts.participatingModules"

    private var containerID: String?
    private var sources: [Source] = []
    private var queued: Job?
    private var running: Task<Void, Never>?
    private var lastApplied: (mode: SharedChangeServerAlertPlan.Mode, inputs: SharedChangeServerAlertInputs, at: Date)?

    /// Modules with a share someone else owns, as of the last pass.
    public nonisolated static var participatingModuleIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: participatingDefaultsKey) ?? [])
    }

    /// Called once from `BhavikApp.init()` on the real stores — never on the
    /// schema-initialising launch, so every later call there is a no-op.
    public func configure(containerID: String, sources: [Source]) {
        self.containerID = containerID
        self.sources = sources.filter {
            $0.container.persistentStoreDescriptions.contains { $0.cloudKitContainerOptions != nil }
        }
    }

    /// Brings the subscriptions in line with this device's settings: all of
    /// them when the switch is on and permission granted, otherwise only
    /// renames and removals (see `SharedChangeServerAlertPlan.Mode`).
    /// `force` goes to the server even when nothing seems to have changed —
    /// for a settings change or a share that was just made or stopped.
    public func sync(force: Bool = false) {
        enqueue(.sync(force: force))
    }

    /// Deletes every alert subscription of ours — the Settings switch going
    /// off. Account-wide: every device of this iCloud account stops getting
    /// iCloud's alerts, until one with the switch on puts them back.
    public func removeAll() {
        enqueue(.removeAll)
    }

    private func enqueue(_ job: Job) {
        switch (queued, job) {
        // An automatic pass never displaces an explicit one waiting its turn:
        // the switch going off must still delete, and a settings change must
        // still reach the server.
        case (.sync(true)?, .sync(false)), (.removeAll?, .sync(false)):
            break
        default:
            queued = job
        }
        guard running == nil else { return }
        running = Task {
            while let job = queued {
                queued = nil
                await perform(job)
            }
            running = nil
        }
    }

    private func perform(_ job: Job) async {
        guard let containerID, !sources.isEmpty else { return }

        let mode: SharedChangeServerAlertPlan.Mode
        if job == .removeAll {
            mode = .removeAll
        } else {
            let enabled = UserDefaults.standard.object(forKey: SharedChangeNotifications.enabledKey) as? Bool ?? true
            let authorized = await SharedChangeNotifications.isAuthorized()
            mode = enabled && authorized ? .reconcile : .maintain
        }

        let inputs = await Self.gatherInputs(from: sources)
        UserDefaults.standard.set(inputs.participatingModuleIDs.sorted(), forKey: Self.participatingDefaultsKey)

        if job == .sync(force: false), let lastApplied, lastApplied.mode == mode, lastApplied.inputs == inputs,
           Date.now.timeIntervalSince(lastApplied.at) < Self.recheckInterval {
            return
        }

        // Until every store has imported once this launch, the local cache
        // may simply not have the shares yet — a new device, a reinstall —
        // and deleting on that basis would take the alerts away from every
        // device on the account. So nothing is deleted until then, and the
        // pass runs again a minute later.
        let settled = sources.allSatisfy { source in
            source.container.persistentStoreCoordinator.persistentStores.allSatisfy { store in
                store.identifier.map { CloudKitImportGate.hasImported(source.container, storeIdentifier: $0) } ?? true
            }
        }

        let container = CKContainer(identifier: containerID)
        do {
            let existing = try await Self.existingAlerts(in: container.privateCloudDatabase, as: .owned)
                + Self.existingAlerts(in: container.sharedCloudDatabase, as: .participating)
            var plan = SharedChangeServerAlertPlan.make(mode: mode, inputs: inputs, existing: existing)
            if !settled && mode != .removeAll {
                plan.delete = []
            }
            var complete = true
            if !plan.isEmpty {
                complete = try await Self.apply(plan, to: container.privateCloudDatabase, database: .owned)
                complete = try await Self.apply(plan, to: container.sharedCloudDatabase, database: .participating) && complete
                Self.log.info("Saved \(plan.save.count) and deleted \(plan.delete.count) alert subscriptions")
            }
            if !complete {
                // One subscription was refused; the next foreground retries.
                lastApplied = nil
            } else if settled || mode == .removeAll {
                lastApplied = (mode, inputs, .now)
            } else {
                lastApplied = nil
                retryOnceImported()
            }
        } catch {
            // No iCloud account, offline, or throttled: the next foreground
            // tries again.
            Self.log.error("Alert subscriptions not updated: \(error.localizedDescription)")
            lastApplied = nil
        }
    }

    private var retryScheduled = false
    /// A store that never reports an import (offline all along) would
    /// otherwise have this asking the server every minute for as long as the
    /// app stays open.
    private var retriesLeft = 5

    private func retryOnceImported() {
        guard !retryScheduled, retriesLeft > 0 else { return }
        retryScheduled = true
        retriesLeft -= 1
        Task {
            try? await Task.sleep(for: .seconds(60))
            retryScheduled = false
            sync()
        }
    }

    // MARK: - Reading the local cache

    private nonisolated static func gatherInputs(from sources: [Source]) async -> SharedChangeServerAlertInputs {
        var inputs = SharedChangeServerAlertInputs()
        let defaults = UserDefaults.standard
        for source in sources {
            if defaults.object(forKey: SharedChangeNotifications.moduleEnabledKey(source.moduleID)) as? Bool == false {
                inputs.mutedModuleIDs.insert(source.moduleID)
            }
            let (zones, participates) = await ownedZones(of: source)
            inputs.ownedZones += zones
            if participates { inputs.participatingModuleIDs.insert(source.moduleID) }
        }
        return inputs
    }

    /// The zones behind this user's own shares of `source`'s roots, and
    /// whether they participate in anyone else's. `fetchShares` reads the
    /// mirroring delegate's cache; nothing here waits on the network.
    private nonisolated static func ownedZones(of source: Source) async -> ([SharedZoneAlertSource], Bool) {
        let container = source.container
        let context = container.newBackgroundContext()
        return await context.perform {
            let sharedStore = container.persistentStoreDescriptions
                .first { $0.cloudKitContainerOptions?.databaseScope == .shared }
                .flatMap { $0.url }
                .flatMap { container.persistentStoreCoordinator.persistentStore(for: $0) }
            let participates = sharedStore.map { !((try? container.fetchShares(in: $0)) ?? []).isEmpty } ?? false

            guard let privateStore = container.privatePersistentStore else { return ([], participates) }
            let request = NSFetchRequest<NSManagedObject>(entityName: source.rootEntityName)
            request.affectedStores = [privateStore]
            let roots = (try? context.fetch(request)) ?? []
            guard !roots.isEmpty,
                  let shares = try? container.fetchShares(matching: roots.map(\.objectID))
            else { return ([], participates) }

            var zones: [SharedZoneAlertSource] = []
            for root in roots {
                guard let share = shares[root.objectID] else { continue }
                // Asked as though the root had just arrived: every module's
                // describer answers that with the root's title.
                let title = source.describe(root, SharedObjectChange(kind: .inserted))?.rootTitle ?? ""
                let hasOthers = share.publicPermission != .none || share.participants.contains {
                    $0.role != .owner && $0.acceptanceStatus != .removed
                }
                let zoneID = share.recordID.zoneID
                zones.append(SharedZoneAlertSource(
                    moduleID: source.moduleID,
                    moduleName: source.moduleName,
                    zoneName: zoneID.zoneName,
                    zoneOwnerName: zoneID.ownerName,
                    rootTitle: title,
                    hasOthers: hasOthers
                ))
            }
            context.reset()
            return (zones, participates)
        }
    }

    // MARK: - Talking to CloudKit

    private nonisolated static func existingAlerts(
        in database: CKDatabase,
        as scope: SharedChangeServerAlert.Database
    ) async throws -> [SharedChangeServerAlert] {
        try await database.allSubscriptions().compactMap { subscription in
            // Never so much as read another subscription — Core Data's own
            // silent ones live alongside these.
            guard subscription.subscriptionID.hasPrefix(SharedChangeServerAlertID.prefix) else { return nil }
            let info = subscription.notificationInfo
            let zoneID = (subscription as? CKRecordZoneSubscription)?.zoneID
            return SharedChangeServerAlert(
                id: subscription.subscriptionID,
                database: scope,
                zoneName: zoneID?.zoneName,
                zoneOwnerName: zoneID?.ownerName,
                title: info?.title,
                subtitle: info?.subtitle,
                body: info?.alertBody,
                category: info?.category
            )
        }
    }

    private nonisolated static func apply(
        _ plan: SharedChangeServerAlertPlan,
        to database: CKDatabase,
        database scope: SharedChangeServerAlert.Database
    ) async throws -> Bool {
        let saving = plan.save.filter { $0.database == scope }.compactMap(subscription(for:))
        let deleting = plan.delete.filter { $0.database == scope }.map(\.id)
        guard !saving.isEmpty || !deleting.isEmpty else { return true }
        let (saved, deleted) = try await database.modifySubscriptions(saving: saving, deleting: deleting)
        var complete = true
        for case (let id, .failure(let error)) in saved {
            log.error("Couldn't save alert subscription \(id): \(error.localizedDescription)")
            complete = false
        }
        for case (let id, .failure(let error)) in deleted {
            // Already gone is as good as deleted.
            if (error as? CKError)?.code == .unknownItem { continue }
            log.error("Couldn't delete alert subscription \(id): \(error.localizedDescription)")
            complete = false
        }
        return complete
    }

    /// A zone subscription for an owned zone, a database subscription for the
    /// shared database — the only kind it accepts. Saving over an existing
    /// ID replaces that subscription, which is how a rename is carried over.
    private nonisolated static func subscription(for alert: SharedChangeServerAlert) -> CKSubscription? {
        let subscription: CKSubscription
        switch alert.database {
        case .owned:
            guard let zoneName = alert.zoneName else { return nil }
            let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: alert.zoneOwnerName ?? CKCurrentUserDefaultName)
            subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: alert.id)
        case .participating:
            subscription = CKDatabaseSubscription(subscriptionID: alert.id)
        }
        let info = CKSubscription.NotificationInfo()
        info.title = alert.title
        info.subtitle = alert.subtitle
        info.alertBody = alert.body
        info.category = alert.category
        info.soundName = "default"
        // A visible alert only. Core Data's own subscriptions already send
        // the silent push that wakes the app to import.
        info.shouldSendContentAvailable = false
        // Sent as apns-collapse-id: an unseen alert about the same share is
        // replaced rather than stacked.
        info.collapseIDKey = SharedChangeServerAlertID.collapseID(for: alert.id)
        subscription.notificationInfo = info
        return subscription
    }
}

/// The alerts iCloud has already delivered, on this device.
public enum SharedChangeServerAlertInbox {
    /// The subscription a delivered or tapped notification came from — nil
    /// for the app's own local notifications.
    public static func subscriptionID(of content: UNNotificationContent) -> String? {
        guard content.categoryIdentifier == SharedChangeServerAlertText.category else { return nil }
        return CKNotification(fromRemoteNotificationDictionary: content.userInfo)?.subscriptionID
    }

    /// Removes delivered iCloud alerts from these subscriptions: the app has
    /// posted something better about the same change, or the change was the
    /// user's own.
    public static func removeDelivered(subscriptionIDs: Set<String>) {
        guard !subscriptionIDs.isEmpty else { return }
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let identifiers = notifications.compactMap { notification -> String? in
                guard let id = subscriptionID(of: notification.request.content), subscriptionIDs.contains(id) else { return nil }
                return notification.request.identifier
            }
            if !identifiers.isEmpty {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
            }
        }
    }
}
