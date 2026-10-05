import CloudKit
import CoreData
import Foundation
import Observation
import os

/// Makes (or finds) the share for one object and gets its link, in the app's
/// own UI, before any sharing sheet sees it — `SharePreparationPlan` decides
/// each step, this carries them out. The iOS host then hands the finished
/// share to `UICloudSharingController(share:container:)`, and the Mac's sheet
/// shows its people and link.
///
/// It replaced handing `share(_:to:)` to `UICloudSharingController`'s
/// preparation handler, and the Mac sheet's bare wait on it: both spun until
/// Core Data gave up on its own, or forever — see the plan's doc comment for
/// what that did to Fuel. Every container call here is one of the
/// `…InBackground` forms (CloudShareCalls.swift), and every wait is bounded.
///
/// Each step is logged under "Sharing" (subsystem com.bhavikjain.trackers):
/// store, step, timings, zone and CloudKit's codes — never a title, name or
/// address — so the next stuck share can be read with
/// `log show --predicate 'category == "Sharing"'`.
@MainActor
@Observable
public final class SharePreparer: Identifiable {
    public let id = UUID()
    public private(set) var step: SharePreparationPlan.Step = .lookingUp
    /// Set once `step` is `.ready`: a saved share with a link.
    public private(set) var share: CKShare?
    /// How long this container's oldest unfinished sync had been running when
    /// a preparation failed, if one was.
    public private(set) var busyFor: TimeInterval?
    /// Whether this preparation made a new share (rather than finding one).
    public private(set) var madeShare = false

    @ObservationIgnored public let container: NSPersistentCloudKitContainer
    @ObservationIgnored private let object: NSManagedObject
    @ObservationIgnored private let monitor: CloudSyncMonitor?
    @ObservationIgnored private let limits: SharePreparationPlan.Limits
    @ObservationIgnored private let title: String?
    @ObservationIgnored private let tag: String
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The share the steps so far have in hand, saved or not.
    @ObservationIgnored private var current: CKShare?

    public init(
        request: ShareSheetRequest,
        monitor: CloudSyncMonitor?,
        limits: SharePreparationPlan.Limits = .standard
    ) {
        object = request.object
        container = request.container
        self.monitor = monitor
        self.limits = limits
        title = Self.displayTitle(of: request.object)
        // The store and entity, never anything the person typed.
        tag = "\(request.container.name)/\(request.object.entity.name ?? "?")"
    }

    public var failure: SharePreparationPlan.Failure? {
        if case .failed(let failure) = step { return failure }
        return nil
    }

    /// Starts, or after a failure starts again from the lookup. Never a
    /// second `share()` for the same object: see `ShareCreations`.
    /// `ignoringEarlierTries` is Share Anyway, after being told an earlier
    /// try left copies in iCloud (`SharePreparationPlan.Failure`).
    public func start(ignoringEarlierTries: Bool = false) {
        task?.cancel()
        share = nil
        busyFor = nil
        task = Task { await run(ignoringEarlierTries: ignoringEarlierTries) }
    }

    /// Stops waiting. A call already handed to Core Data carries on, and the
    /// next preparation finds what it did.
    public func cancel() {
        guard let task else { return }
        task.cancel()
        self.task = nil
    }

    // MARK: - Steps

    private func run(ignoringEarlierTries: Bool) async {
        let began = ContinuousClock.now
        let objectID = object.objectID
        guard !objectID.isTemporaryID, objectID.persistentStore != nil else {
            // Unreachable from a Share button, which only shows saved objects.
            step = .failed(.lookupFailed(ShareError(domain: "Sharing", code: 0, message: "Save this item before sharing it.")))
            return
        }
        let cached = SharingStatusCache.shared.cachedShare(for: objectID).flatMap { $0.url == nil ? nil : $0 }
        var plan = SharePreparationPlan(hasCachedLink: cached != nil, ignoresEarlierTries: ignoringEarlierTries)
        var action = plan.start()
        step = plan.step
        current = nil
        log("start\(cached == nil ? "" : ", cached link")\(ignoringEarlierTries ? ", share anyway" : "")")

        while !Task.isCancelled {
            let event: SharePreparationPlan.Event
            switch action {
            case .lookUp: event = await lookUp()
            case .waitForSync: event = await waitForSync()
            case .checkEarlierTries: event = await checkEarlierTries()
            case .create: event = await create()
            case .save: event = await save()
            case .waitForUpload: event = await waitForUpload()
            case .fetchLink: event = await fetchLink()
            case .present:
                let ready = current?.url != nil ? current : cached
                share = ready
                step = .ready
                if madeShare { SharingStatusCache.shared.invalidateAll() }
                log("ready in \(Self.ms(ContinuousClock.now - began)) ms\(ready === cached ? " (cached share; lookup failed)" : ""), zone \(ready?.recordID.zoneID.zoneName ?? "?"), participants \(ready?.participants.count ?? 0)")
                task = nil
                return
            case .fail(let failure):
                let stores = container.cloudKitStoreIdentifiers
                busyFor = monitor?.syncingSince(stores).map { Date.now.timeIntervalSince($0) }
                step = .failed(failure)
                logError("failed after \(Self.ms(ContinuousClock.now - began)) ms: \(failure.title), \(failure.error?.codeLabel ?? "no error")\(busyFor.map { ", syncing for \(Int($0)) s" } ?? "")")
                task = nil
                return
            }
            guard !Task.isCancelled else { break }
            action = plan.handle(event)
            step = plan.step
        }
        log("cancelled while \(String(describing: plan.step)) after \(Self.ms(ContinuousClock.now - began)) ms")
    }

    private func lookUp() async -> SharePreparationPlan.Event {
        let began = ContinuousClock.now
        let objectID = object.objectID
        let container = container
        let result: Result<CKShare?, ShareError>? = await Bounded.wait(limits.lookup) { done in
            container.lookUpShareInBackground(for: objectID) { done($0.mapError(ShareError.init)) }
        }
        let took = Self.ms(ContinuousClock.now - began)
        switch result {
        case nil:
            logError("lookup: no answer in \(took) ms")
            return .lookedUp(.failed(.timedOut(after: limits.lookup)))
        case .failure(let error)?:
            logError("lookup failed in \(took) ms: \(error.codeLabel)")
            return .lookedUp(.failed(error))
        case .success(let found?)?:
            current = found
            // Only the owner can save a share; a participant's try only
            // waited out the save's limit before the sheet opened.
            let needsSave = Self.isOwner(of: found) && applyTitleAndStamp(to: found)
            log("lookup: shared in \(took) ms, zone \(found.recordID.zoneID.zoneName), link \(found.url != nil), needs save \(needsSave)")
            return .lookedUp(.shared(hasLink: found.url != nil, needsSave: needsSave))
        case .success(nil)?:
            let syncing = monitor?.isSyncing(container.cloudKitStoreIdentifiers) ?? false
            log("lookup: not shared in \(took) ms, syncing \(syncing)")
            return .lookedUp(.notShared(isSyncing: syncing))
        }
    }

    private func waitForSync() async -> SharePreparationPlan.Event {
        let began = ContinuousClock.now
        let stores = container.cloudKitStoreIdentifiers
        let since = monitor?.syncingSince(stores)
        let settled = await monitor?.waitUntilIdle(stores, timeout: limits.sync) ?? true
        log("sync wait: \(settled ? "settled" : "still syncing") after \(Self.ms(ContinuousClock.now - began)) ms\(since.map { ", oldest started \(Int(Date.now.timeIntervalSince($0))) s ago" } ?? "")")
        return .syncSettled(timedOut: !settled)
    }

    /// Asks iCloud whether an earlier `share()` left a share zone holding this
    /// object's record. Core Data names each share's zone
    /// `com.apple.coredata.cloudkit.share.<UUID>` and keeps the record's name
    /// when it moves it there, so a copy is that name in a share zone other
    /// than the one Core Data says the object is in.
    private func checkEarlierTries() async -> SharePreparationPlan.Event {
        let began = ContinuousClock.now
        // A `share()` this process is still running for it (Try Again after
        // the create step ran out of time) may have made its zone already:
        // the check would call that an earlier try that didn't finish, and
        // Share Anyway would only join the same call. Join it straight away.
        if ShareCreations.shared.isRunning(object.objectID) {
            log("earlier tries: skipped, share() for this object is still running here")
            return .earlierTriesChecked(.none)
        }
        guard let identifier = container.cloudKitContainerIdentifier,
              let store = object.objectID.persistentStore,
              container.databaseScope(of: store) == .private else {
            // Someone else's share (the shared store) is always found by the
            // lookup; and an in-memory container has no iCloud to ask.
            return .earlierTriesChecked(.none)
        }
        let objectID = object.objectID
        let container = container
        let limit = limits.earlierTries
        let result: Result<[String], ShareError>? = await Bounded.wait(limit) { done in
            // Where Core Data says the object lives: the same local metadata
            // the lookup read, behind the same executor.
            container.recordIDInBackground(for: objectID) { recordID in
                // Never uploaded (a car added a moment ago): no `share()`
                // can have carried a record that doesn't exist yet.
                guard let recordID else {
                    done(.success([]))
                    return
                }
                let database = CKContainer(identifier: identifier).privateCloudDatabase
                Task { done(await LeftoverShareZones.find(recordID, in: database)) }
            }
        }
        let took = Self.ms(ContinuousClock.now - began)
        switch result {
        case nil:
            logError("earlier tries: no answer in \(took) ms")
            return .earlierTriesChecked(.failed(.timedOut(after: limit)))
        case .failure(let error)?:
            logError("earlier tries: check failed in \(took) ms: \(error.codeLabel)")
            return .earlierTriesChecked(.failed(error))
        case .success(let zones)? where zones.isEmpty:
            log("earlier tries: none (\(took) ms)")
            return .earlierTriesChecked(.none)
        case .success(let zones)?:
            // Zone names are Core Data's UUIDs, nothing the person typed.
            logError("earlier tries: \(zones.count) share zone(s) already hold this record: \(zones.joined(separator: ", ")) (\(took) ms)")
            return .earlierTriesChecked(.found(zones))
        }
    }

    private func create() async -> SharePreparationPlan.Event {
        let began = ContinuousClock.now
        // The export `share()` queues runs on its own schedule; keep the app
        // alive for it, as for a save.
        CloudExportKeeper.keepAlive(for: container)
        let result = await ShareCreations.shared.create(object, in: container, limit: limits.create, tag: tag)
        let took = Self.ms(ContinuousClock.now - began)
        switch result {
        case nil:
            logError("share(): no answer in \(took) ms")
            return .created(.failed(.timedOut(after: limits.create)))
        case .failure(let error)?:
            logError("share() failed in \(took) ms: \(error.codeLabel)")
            return .created(.failed(error))
        case .success(let made)?:
            current = made
            madeShare = true
            _ = applyTitleAndStamp(to: made)
            log("share(): made in \(took) ms, zone \(made.recordID.zoneID.zoneName), link \(made.url != nil)")
            return .created(.share(hasLink: made.url != nil))
        }
    }

    /// Saves the title and the tracker stamp `applyTitleAndStamp` set.
    private func save() async -> SharePreparationPlan.Event {
        let began = ContinuousClock.now
        guard let share = current, let store = object.objectID.persistentStore else {
            return .saved(.failed(.noResult))
        }
        let container = container
        let result: Result<CKShare, ShareError>? = await Bounded.wait(limits.save) { done in
            container.persistUpdatedShareInBackground(share, in: store) { saved, error in
                done(saved.map { .success($0) } ?? .failure(error.map(ShareError.init) ?? .noResult))
            }
        }
        let took = Self.ms(ContinuousClock.now - began)
        switch result {
        case nil:
            logError("save: no answer in \(took) ms")
            return .saved(.failed(.timedOut(after: limits.save)))
        case .failure(let error)?:
            logError("save failed in \(took) ms: \(error.codeLabel)")
            return .saved(.failed(error))
        case .success(let saved)?:
            if saved.url != nil || current?.url == nil { current = saved }
            log("save: done in \(took) ms, link \(current?.url != nil)")
            return .saved(.share(hasLink: current?.url != nil))
        }
    }

    private func waitForUpload() async -> SharePreparationPlan.Event {
        let began = ContinuousClock.now
        CloudExportKeeper.keepAlive(for: container)
        let finished: Bool
        if let monitor {
            finished = await monitor.waitForExport(container.cloudKitStoreIdentifiers, endingAfter: .now, timeout: limits.upload)
        } else {
            // No monitor (previews): a short pause, then look again.
            try? await Task.sleep(for: .seconds(2))
            finished = false
        }
        log("upload wait: \(finished ? "an export finished" : "no export finished") after \(Self.ms(ContinuousClock.now - began)) ms")
        return .uploadFinished(timedOut: !finished)
    }

    /// The share's own record, straight from CloudKit: it carries the link
    /// once the share has reached the server, whatever Core Data's copy says,
    /// and the fetch doesn't wait on the container's executor.
    private func fetchLink() async -> SharePreparationPlan.Event {
        let began = ContinuousClock.now
        guard let share = current, let identifier = container.cloudKitContainerIdentifier,
              let store = object.objectID.persistentStore else {
            return .linkFetched(.failed(.noResult))
        }
        let ckContainer = CKContainer(identifier: identifier)
        let database = container.databaseScope(of: store) == .shared
            ? ckContainer.sharedCloudDatabase
            : ckContainer.privateCloudDatabase
        let recordID = share.recordID
        let result: Result<CKShare?, ShareError>? = await Bounded.wait(limits.fetchLink) { done in
            database.fetch(withRecordID: recordID) { record, error in
                if let fetched = record as? CKShare {
                    done(.success(fetched))
                } else if let error, (error as? CKError)?.code == .unknownItem {
                    // Not on the server yet: the upload hasn't carried it.
                    done(.success(nil))
                } else {
                    done(.failure(error.map(ShareError.init) ?? .noResult))
                }
            }
        }
        let took = Self.ms(ContinuousClock.now - began)
        switch result {
        case nil:
            logError("link fetch: no answer in \(took) ms")
            return .linkFetched(.failed(.timedOut(after: limits.fetchLink)))
        case .failure(let error)?:
            logError("link fetch failed in \(took) ms: \(error.codeLabel)")
            return .linkFetched(.failed(error))
        case .success(nil)?:
            log("link fetch: share not on the server yet (\(took) ms)")
            return .linkFetched(.share(hasLink: false))
        case .success(let fetched?)?:
            if Self.isOwner(of: fetched) { _ = applyTitleAndStamp(to: fetched) }
            if fetched.url != nil { current = fetched }
            log("link fetch: \(fetched.url != nil ? "got the link" : "no link yet") in \(took) ms")
            return .linkFetched(.share(hasLink: fetched.url != nil))
        }
    }

    // MARK: - Helpers

    /// Sets the share's title and the tracker stamp, in memory. True when
    /// either changed, so the share needs saving. Without a title the
    /// invitation names nothing; without the stamp the other person's app
    /// can't tell which tracker it's for (ShareAcceptRouter.stamp).
    private func applyTitleAndStamp(to share: CKShare) -> Bool {
        var changed = ShareAcceptRouter.stamp(share, for: object)
        if let title, (share[CKShare.SystemFieldKey.title] as? String)?.isEmpty ?? true {
            share[CKShare.SystemFieldKey.title] = title as CKRecordValue
            changed = true
        }
        return changed
    }

    /// A share this person made, or one `share()` just returned (whose
    /// current participant is its owner).
    static func isOwner(of share: CKShare) -> Bool {
        share.currentUserParticipant.map { $0.role == .owner } ?? true
    }

    /// A trip has a `title`; a vehicle and a guide have a `name`; a
    /// household has neither and CloudKit says "Shared item".
    static func displayTitle(of object: NSManagedObject) -> String? {
        let attributes = object.entity.attributesByName
        for key in ["title", "name"] where attributes[key] != nil {
            if let value = object.value(forKey: key) as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private func log(_ message: String) {
        ShareLog.logger.notice("\(self.tag, privacy: .public) \(message, privacy: .public)")
    }

    private func logError(_ message: String) {
        ShareLog.logger.error("\(self.tag, privacy: .public) \(message, privacy: .public)")
    }

    /// Whole milliseconds, for the log and `-ShareProbe`.
    public nonisolated static func ms(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}

/// The "Sharing" log category, for everything Share does.
public enum ShareLog {
    public static let logger = Logger(subsystem: "com.bhavikjain.trackers", category: "Sharing")
}

/// Share zones in the private database that hold a copy of one record.
///
/// What an abandoned `share()` leaves (October 2026, the user's Fuel cars):
/// the share's zone, with the car and its fill-ups under their own record
/// names, while this device still has the car in the default zone and
/// `fetchShares` says it isn't shared. Public for `-ShareProbe`'s cleanup,
/// which removes only zones holding its own records.
public enum LeftoverShareZones {
    public static let prefix = "com.apple.coredata.cloudkit.share."

    /// The zones worth asking about: Core Data's share zones, other than the
    /// one the record is in now (a share that was stopped leaves its objects
    /// in their zone, and sharing again is not a leftover).
    static func candidates(_ zones: [CKRecordZone.ID], besides current: CKRecordZone.ID) -> [CKRecordZone.ID] {
        zones.filter { $0.zoneName.hasPrefix(prefix) && $0 != current }
    }

    /// Names of the share zones holding `recordID`'s record name, sorted.
    public static func find(_ recordID: CKRecord.ID, in database: CKDatabase) async -> Result<[String], ShareError> {
        do {
            let zones = try await database.allRecordZones().map(\.zoneID)
            let ids = candidates(zones, besides: recordID.zoneID).map {
                CKRecord.ID(recordName: recordID.recordName, zoneID: $0)
            }
            guard !ids.isEmpty else { return .success([]) }
            // Only whether each exists: an item error (unknown item, the
            // zone gone since the listing) means not there.
            let results = try await database.records(for: ids, desiredKeys: [])
            let found = results.compactMap { id, result in (try? result.get()) == nil ? nil : id.zoneID.zoneName }
            return .success(found.sorted())
        } catch {
            return .failure(ShareError(error))
        }
    }
}

/// `share(_:to:)` calls still running in this process, one per object.
///
/// A share call doesn't stop when Share stops waiting for it: Core Data
/// queues it behind whatever sync holds the container, and it can still make
/// the zone minutes later. A second call for the same object — Try Again, or
/// Share tapped again after Cancel — used to make a second zone. Now it waits
/// on the first call's answer instead.
@MainActor
final class ShareCreations {
    static let shared = ShareCreations()

    private var ledger = ShareCallLedger<NSManagedObjectID>()
    private var calls: [NSManagedObjectID: Task<Result<CKShare, ShareError>, Never>] = [:]

    /// Whether a `share()` for `id` is still waiting on Core Data.
    func isRunning(_ id: NSManagedObjectID) -> Bool {
        ledger.isRunning(id)
    }

    func create(
        _ object: NSManagedObject,
        in container: NSPersistentCloudKitContainer,
        limit: Duration,
        tag: String
    ) async -> Result<CKShare, ShareError>? {
        let id = object.objectID
        let call: Task<Result<CKShare, ShareError>, Never>
        if ledger.begin(id) == .call {
            call = Task {
                await withCheckedContinuation { continuation in
                    container.shareInBackground(object) { share, _, error in
                        continuation.resume(returning: share.map { .success($0) } ?? .failure(error.map(ShareError.init) ?? .noResult))
                    }
                }
            }
            calls[id] = call
            let began = ContinuousClock.now
            Task {
                let result = await call.value
                self.ledger.end(id)
                self.calls[id] = nil
                // How long Core Data really took, whoever was still waiting.
                ShareLog.logger.notice("\(tag, privacy: .public) share() answered after \(SharePreparer.ms(ContinuousClock.now - began), privacy: .public) ms: \((try? result.get()) == nil ? "failed" : "share", privacy: .public)")
            }
        } else if let running = calls[id] {
            ShareLog.logger.notice("\(tag, privacy: .public) share(): joining the call still running for this object")
            call = running
        } else {
            return .failure(.noResult)
        }
        let answer: Result<CKShare, ShareError>? = await Bounded.wait(limit) { done in
            Task { done(await call.value) }
        }
        return answer
    }
}

/// Whether to call `share()` or wait on the call already running: the
/// bookkeeping of `ShareCreations`, as a value so it can be tested.
struct ShareCallLedger<Key: Hashable & Sendable>: Sendable, Equatable {
    enum Begin: Sendable, Equatable {
        /// Nothing running for this key: make the call.
        case call
        /// A call is running: wait for its answer instead.
        case join
    }

    private(set) var running: Set<Key> = []

    mutating func begin(_ key: Key) -> Begin {
        running.insert(key).inserted ? .call : .join
    }

    mutating func end(_ key: Key) {
        running.remove(key)
    }

    func isRunning(_ key: Key) -> Bool {
        running.contains(key)
    }
}

/// Waiting on a completion handler without waiting forever.
public enum Bounded {
    /// Runs `start`, which hands its answer to the closure it's given, and
    /// waits for that answer at most `limit` — or until the task is
    /// cancelled. nil when the limit or the cancel came first; an answer
    /// after that is dropped. The call itself is never stopped: Core Data's
    /// sharing calls can't be.
    ///
    /// Runs on the caller's actor (`isolation`), so `start` can use the
    /// caller's state without being sent anywhere.
    public static func wait<T: Sendable>(
        _ limit: Duration,
        isolation: isolated (any Actor)? = #isolation,
        _ start: (@escaping @Sendable (T) -> Void) -> Void
    ) async -> T? {
        let gate = AnswerGate<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                guard gate.arm(continuation) else { return }
                start { gate.answer($0) }
                gate.startTimer(limit)
            }
        } onCancel: {
            gate.answer(nil)
        }
    }
}

/// Resumes its continuation exactly once: with the answer, or with nil for
/// the timer or a cancel, whichever comes first. The lock is what makes the
/// unchecked `Sendable` true.
final class AnswerGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var answered = false
    private var timer: Task<Void, Never>?

    /// False when the gate was answered (cancelled) before it was armed; the
    /// continuation has then been resumed already.
    func arm(_ continuation: CheckedContinuation<T?, Never>) -> Bool {
        let early = lock.withLock { () -> Bool in
            if answered { return true }
            self.continuation = continuation
            return false
        }
        if early { continuation.resume(returning: nil) }
        return !early
    }

    func startTimer(_ limit: Duration) {
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: limit) } catch { return }
            self?.answer(nil)
        }
        let isAnswered = lock.withLock { () -> Bool in
            if !answered { self.timer = timer }
            return answered
        }
        if isAnswered { timer.cancel() }
    }

    func answer(_ value: T?) {
        let (continuation, timer) = lock.withLock { () -> (CheckedContinuation<T?, Never>?, Task<Void, Never>?) in
            guard !answered else { return (nil, nil) }
            answered = true
            defer {
                self.continuation = nil
                self.timer = nil
            }
            return (self.continuation, self.timer)
        }
        timer?.cancel()
        continuation?.resume(returning: value)
    }
}
