import CloudKit
import CoreData
import Foundation
import Synchronization

/// Holds a module's legacy SwiftData importer back until its Core Data store
/// has caught up with iCloud at least once since launch.
///
/// The importers (`TripLegacyMigration`, `FuelLegacyMigration`,
/// `ExploreLegacyMigration`) de-duplicate only against the *local* store. The
/// legacy SwiftData data is itself synced, so every device holds the same
/// legacy rows. Install the Core Data build on the phone and it copies them
/// and exports the copies; install it on the Mac next, and if the Mac's
/// importer runs before the phone's copies have been imported there, it finds
/// nothing to match against, copies everything again, exports that too — and
/// the account ends up holding every record twice (the same shape of damage as
/// the 4-cars-instead-of-2 Fuel incident, from a different cause). Waiting for
/// one successful import of the private store means whatever another device
/// already exported is local before the importer looks, so its per-record
/// match skips it.
///
/// ## When it doesn't wait
///
/// - **No CloudKit at all** (in-memory test and schema-probing containers):
///   there is nothing to import, so nothing to wait for.
/// - **`.noAccount` / `.restricted`**: this device can't receive another
///   device's export at all, so waiting can only ever time out, and the legacy
///   store here holds nothing another device exported either (with no account
///   it has had nothing to sync with). The residual risk — the user signs in
///   later and this device's copies meet another device's — needs this device
///   to have been signed out through its whole first launch of the build, and
///   is accepted over showing an empty module indefinitely.
/// - **Timeout** (default 60 s) for the undecidable cases: offline with an
///   account, `.temporarilyUnavailable`, `.couldNotDetermine`. Mirroring
///   doesn't reliably report *anything* while offline, so there's no event to
///   wait on. Waiting costs little — the legacy rows stay safe in SwiftData
///   and the module is fully usable meanwhile — but it can't be forever: a
///   device that's offline on its first launch of the build would otherwise
///   never show its data. Duplicates after a timeout need that device to be
///   offline for the whole minute *and* another device to have exported first.
///
/// Only launches that still have migration work pending call this, so once an
/// importer has recorded completion a later offline launch never waits.
public enum CloudKitImportGate {
    /// One tracker per CloudKit-backed container, installed by
    /// `CloudSharedStore.makeContainer` before its stores load. Never removed:
    /// the containers it's keyed on live for the whole process.
    private static let trackers = Mutex<[ObjectIdentifier: ImportTracker]>([:])

    /// Starts recording successful imports for `container`. Must run before
    /// `loadPersistentStores`, or a fast first import is missed.
    static func track(_ container: NSPersistentCloudKitContainer) {
        guard container.persistentStoreDescriptions.contains(where: { $0.cloudKitContainerOptions != nil }) else { return }
        let tracker = ImportTracker()
        trackers.withLock { $0[ObjectIdentifier(container)] = tracker }
        // The token is dropped on purpose: the observer lives as long as the
        // container, which is the whole process.
        _ = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container,
            queue: nil
        ) { notification in
            // The notification fires at start *and* end of every event; only a
            // finished, successful import means the store has caught up.
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  event.type == .import,
                  event.endDate != nil,
                  event.succeeded else { return }
            tracker.markImported(storeIdentifier: event.storeIdentifier)
        }
    }

    /// Whether `storeIdentifier` has finished a successful import since
    /// launch — for `SharedChangeNotifier`, which starts after the stores
    /// load and so may have missed that event itself.
    static func hasImported(_ container: NSPersistentCloudKitContainer, storeIdentifier: String) -> Bool {
        trackers.withLock { $0[ObjectIdentifier(container)] }?.hasImported(storeIdentifier: storeIdentifier) ?? false
    }

    /// Returns once `container`'s private store has finished a successful
    /// CloudKit import since launch, or once one of the fallbacks in the type's
    /// doc comment applies. Returns `false` only when the calling task was
    /// cancelled (the module was closed) — the caller must then *not* import,
    /// or closing the module mid-wait would bypass the gate entirely.
    @MainActor
    public static func waitForFirstImport(
        of container: NSPersistentCloudKitContainer?,
        timeout: Duration = .seconds(60)
    ) async -> Bool {
        await waitForFirstImportOutcome(of: container, timeout: timeout) != .cancelled
    }

    /// Why a wait ended — for the legacy importers, which may copy only when
    /// the store has really caught up (`mayCopyLegacyData`).
    public enum Outcome: Equatable, Sendable {
        /// A successful import landed: the store holds what iCloud does.
        case imported
        /// Nothing to wait for: no CloudKit on this container, or no account.
        case nothingToImport
        /// The minute ran out, iCloud's state unknown.
        case timedOut
        /// The calling task was cancelled (the module was closed).
        case cancelled

        /// Whether a legacy importer may copy anything now. Not after a
        /// timeout: then this device can't tell "iCloud has none of these"
        /// from "iCloud hasn't sent them yet", and copying on the second
        /// re-created every car a fresh install hadn't downloaded in time —
        /// cars duplicated on every reinstall. The importer tries again on the
        /// next launch instead.
        public var mayCopyLegacyData: Bool {
            self == .imported || self == .nothingToImport
        }
    }

    @MainActor
    public static func waitForFirstImportOutcome(
        of container: NSPersistentCloudKitContainer?,
        timeout: Duration = .seconds(60)
    ) async -> Outcome {
        guard let container,
              let description = container.persistentStoreDescriptions.first(where: {
                  $0.cloudKitContainerOptions?.databaseScope == .private
              }),
              let containerID = description.cloudKitContainerOptions?.containerIdentifier,
              let url = description.url,
              let storeID = container.persistentStoreCoordinator.persistentStore(for: url)?.identifier,
              let tracker = trackers.withLock({ $0[ObjectIdentifier(container)] })
        else {
            return Task.isCancelled ? .cancelled : .nothingToImport
        }

        if tracker.hasImported(storeIdentifier: storeID) { return .imported }

        switch try? await CKContainer(identifier: containerID).accountStatus() {
        case .noAccount, .restricted:
            return Task.isCancelled ? .cancelled : .nothingToImport
        default:
            break
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await tracker.waitForImport(storeIdentifier: storeID) }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
        if Task.isCancelled { return .cancelled }
        return tracker.hasImported(storeIdentifier: storeID) ? .imported : .timedOut
    }
}

/// The per-container bookkeeping behind `CloudKitImportGate`: which stores have
/// completed an import, and who is waiting on which. Internal rather than
/// private so the waiting logic is testable without CloudKit (an
/// `NSPersistentCloudKitContainer.Event` can't be constructed outside Core
/// Data).
final class ImportTracker: Sendable {
    private struct State {
        var imported: Set<String> = []
        var waiters: [UUID: (store: String, continuation: CheckedContinuation<Void, Never>)] = [:]
        /// Waits cancelled before they managed to register — without this, a
        /// cancel that lands first would leave the later registration hanging.
        var cancelledEarly: Set<UUID> = []
    }

    private let state = Mutex(State())

    func hasImported(storeIdentifier: String) -> Bool {
        state.withLock { $0.imported.contains(storeIdentifier) }
    }

    func markImported(storeIdentifier: String) {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.imported.insert(storeIdentifier)
            let ids = state.waiters.filter { $0.value.store == storeIdentifier }.map(\.key)
            return ids.compactMap { state.waiters.removeValue(forKey: $0)?.continuation }
        }
        for continuation in ready { continuation.resume() }
    }

    /// Returns when `storeIdentifier` has imported, or when the calling task is
    /// cancelled — whichever comes first.
    func waitForImport(storeIdentifier: String) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state -> Bool in
                    if state.cancelledEarly.remove(id) != nil || state.imported.contains(storeIdentifier) {
                        return true
                    }
                    state.waiters[id] = (storeIdentifier, continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
                if let waiter = state.waiters.removeValue(forKey: id) { return waiter.continuation }
                state.cancelledEarly.insert(id)
                return nil
            }
            waiting?.resume()
        }
    }
}
