import CoreData
import Foundation
#if os(iOS)
import UIKit
#endif

/// Keeps the app running after a save until iCloud has the change.
///
/// `NSPersistentCloudKitContainer` uploads ("exports") a save on its own
/// schedule, and there's no API to make it go now. With the app open that's
/// seconds. But leave the app straight after saving — add a transaction,
/// lock the phone — and iOS suspends it before the upload runs, so the
/// change waited in the phone until Multitrack was next opened: a partner
/// heard nothing for minutes, sometimes far longer, and iCloud's own alert
/// (`SharedChangeServerAlerts`), which fires the moment the upload lands,
/// couldn't help because nothing had landed.
///
/// So each save by this app starts a hold — a background task on iOS, an
/// activity on the Mac (App Nap can stretch timers there) — and the first
/// upload that starts after the latest save ends it. A hold never outlasts
/// `limit`: iOS gives a background task about 30 seconds, and an upload that
/// can't run (offline, no iCloud) shouldn't keep the app alive at all.
///
/// One per `CloudSharedStore` container, started by `BhavikApp` beside its
/// `SharedChangeNotifier`. Main-actor only: every observer delivers on the
/// main queue, which `beginBackgroundTask` wants anyway.
@MainActor
public final class CloudExportKeeper {
    private static var running: [CloudExportKeeper] = []

    /// Under iOS's background allowance, with room to end cleanly.
    public static let limit: TimeInterval = 25

    private let container: NSPersistentCloudKitContainer
    private let moduleID: String
    private var hold = CloudExportHold()
    /// Bumped per hold, so a timeout from an earlier one can't end a later one.
    private var generation = 0
    #if os(iOS)
    private var task: UIBackgroundTaskIdentifier = .invalid
    #else
    private var activity: NSObjectProtocol?
    #endif
    private var observers: [NSObjectProtocol] = []

    /// Starts keeping uploads for `container`. Nothing for a container with
    /// no CloudKit mirroring (tests, in-memory launches): it never uploads.
    @discardableResult
    public static func start(container: NSPersistentCloudKitContainer, moduleID: String) -> CloudExportKeeper? {
        guard container.persistentStoreDescriptions.contains(where: { $0.cloudKitContainerOptions != nil }) else {
            return nil
        }
        let keeper = CloudExportKeeper(container: container, moduleID: moduleID)
        running.append(keeper)
        return keeper
    }

    private init(container: NSPersistentCloudKitContainer, moduleID: String) {
        self.container = container
        self.moduleID = moduleID
        let coordinator = container.persistentStoreCoordinator

        observers.append(NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let context = notification.object as? NSManagedObjectContext,
                  context.persistentStoreCoordinator === coordinator,
                  CloudExportHold.isLocalSave(author: context.transactionAuthor)
            else { return }
            MainActor.assumeIsolated { self?.saved() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  event.type == .export,
                  event.endDate != nil
            else { return }
            let started = event.startDate
            let error = event.succeeded ? nil : (event.error?.localizedDescription ?? "unknown error")
            MainActor.assumeIsolated { self?.uploadFinished(started: started, error: error) }
        })
    }

    // MARK: - Events

    private func saved() {
        guard hold.saved(at: .now) else { return }
        generation += 1
        let thisHold = generation
        beginPlatformHold()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.limit) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == thisHold, self.hold.isHolding else { return }
                self.hold.timedOut()
                SharedChangeActivityLog.record(SharedChangeLogEntry(
                    moduleID: self.moduleID,
                    outcome: .uploadSlow,
                    detail: "\(Int(Self.limit)) s"
                ))
                self.endPlatformHold()
            }
        }
    }

    private func uploadFinished(started: Date, error: String?) {
        if let error {
            SharedChangeActivityLog.noteExportFailure(moduleID: moduleID, error: error)
            SharedChangeActivityLog.record(SharedChangeLogEntry(moduleID: moduleID, outcome: .uploadFailed, detail: error))
        } else {
            SharedChangeActivityLog.noteExport(moduleID: moduleID)
        }
        // A failed upload ends the hold too: iCloud said no, and waiting
        // longer won't change that before iOS suspends the app.
        if hold.exportFinished(startedAt: started) {
            endPlatformHold()
        }
    }

    // MARK: - Platform

    private func beginPlatformHold() {
        #if os(iOS)
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "Uploading to iCloud") { [weak self] in
            // iOS is about to suspend the app regardless.
            MainActor.assumeIsolated {
                self?.hold.timedOut()
                self?.endPlatformHold()
            }
        }
        #else
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Uploading a change to iCloud"
        )
        #endif
    }

    private func endPlatformHold() {
        #if os(iOS)
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
        #else
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        #endif
    }
}

/// When a hold starts and ends — `CloudExportKeeper`'s decisions as plain
/// values, so they can be tested without a container.
public struct CloudExportHold: Sendable, Equatable {
    /// The latest save not yet known to be uploaded; nil when there's none.
    public private(set) var latestSave: Date?

    public init() {}

    public var isHolding: Bool { latestSave != nil }

    /// Records a save. True when a hold should begin — none was running.
    public mutating func saved(at date: Date) -> Bool {
        let begins = latestSave == nil
        latestSave = date
        return begins
    }

    /// An upload has ended. True when the hold should end: the upload began
    /// after the latest save, so it carried it. An upload already under way
    /// when the save happened may not have, and the hold waits for the next.
    public mutating func exportFinished(startedAt start: Date) -> Bool {
        guard let latestSave, start >= latestSave else { return false }
        self.latestSave = nil
        return true
    }

    public mutating func timedOut() {
        latestSave = nil
    }

    /// Saves this app made, as opposed to the mirroring delegate's own
    /// imports and bookkeeping, which also save through the coordinator.
    public static func isLocalSave(author: String?) -> Bool {
        !(author ?? "").hasPrefix("NSCloudKitMirroringDelegate")
    }
}
