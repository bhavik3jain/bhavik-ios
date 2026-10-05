#if DEBUG
import CloudKit
import Core
import CoreData
import Foundation
import FuelTracker

/// `-ShareProbe YES`: Share, end to end, against iCloud *Development*, on a
/// throwaway Fuel store, printing how long each step took. On this Mac,
/// `scripts/cloudkit/init-schema.sh --share-probe` builds, signs and runs it.
///
/// Fuel's Share hung on "generating a link" (October 2026) and each try left
/// another share zone in the user's iCloud; nothing could time a share
/// without touching their data. This does it on data of its own: an on-disk
/// Fuel container in Caches with CloudKit mirroring (private and shared
/// stores, like the app's), one car with 150 fill-ups and a control car with
/// 3, each taken through `SharePreparer` — the code a Share button runs — and
/// then opened again, to show the second time finds the share instead of
/// making another.
///
/// Then it removes what it made, and only that: the zones of its own shares
/// (`purgeObjectsAndRecordsInZone` on its own container), any share zone
/// still holding one of its own records (record names are UUIDs Core Data
/// gave its own cars), its cars if they never left the default zone, and its
/// store files. Never the default zone, never anything it didn't create.
///
/// Started from `BhavikApp.init`'s in-memory branch like the other probes,
/// so this launch never opens the app's real stores.
enum ShareProbe {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "ShareProbe") }

    @MainActor
    static func start(containerID: String, monitor: CloudSyncMonitor) {
        Task { @MainActor in
            await run(containerID: containerID, monitor: monitor)
            say("done")
            exit(0)
        }
    }

    @MainActor
    private static func run(containerID: String, monitor: CloudSyncMonitor) async {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let folder = caches.appendingPathComponent("ShareProbe-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            say("removed the probe's store files")
        }
        let events = Events()
        let container: NSPersistentCloudKitContainer
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            container = try makeContainer(in: folder, containerID: containerID, events: events)
        } catch {
            say("FAILED to load the probe's store: \(ShareError(error).codeLabel) \(error.localizedDescription)")
            return
        }
        defer {
            let coordinator = container.persistentStoreCoordinator
            for store in coordinator.persistentStores { try? coordinator.remove(store) }
        }
        let stores = container.cloudKitStoreIdentifiers
        let launched = ContinuousClock.now

        // Mirroring sets itself up and imports Development's default zone
        // before anything can be shared. How long that import takes is half
        // the story: the user's Share waited behind one.
        let ready = await until(.seconds(240)) { events.hasFinished(.setup, in: stores) && events.hasFinished(.import, in: stores) }
        say("setup and first import \(ready ? "finished" : "NOT finished") after \(ms(since: launched)) ms; \(events.summary(in: stores))")
        guard ready else { return }

        let context = container.viewContext
        let control = seed(name: "Share probe control", fillUps: 3, in: context)
        let big = seed(name: "Share probe 150", fillUps: 150, in: context)
        let savedAt = Date.now
        do { try context.save() } catch {
            say("FAILED to save the seed: \(ShareError(error).codeLabel)")
            return
        }
        let seedClock = ContinuousClock.now
        let uploaded = await until(.seconds(180)) { events.exportStarted(after: savedAt, in: stores) != nil && events.exportEnded(startedAfter: savedAt, in: stores) }
        say("seed (2 cars, 153 fill-ups) \(uploaded ? "uploaded" : "NOT uploaded") in \(ms(since: seedClock)) ms")

        var madeZones: [CKRecordZone.ID] = []
        for (label, car) in [("control, 3 fill-ups", control), ("150 fill-ups", big)] {
            for attempt in ["first Share", "Share again"] {
                let outcome = await share(car, label: "\(label), \(attempt)", container: container, monitor: monitor, events: events)
                if let zone = outcome, !madeZones.contains(zone) { madeZones.append(zone) }
            }
        }

        await cleanUp(cars: [control, big], madeZones: madeZones, container: container, containerID: containerID, events: events)
    }

    // MARK: - Steps

    /// Runs one preparation and prints each step as it changes. Returns the
    /// zone of a share it made.
    @MainActor
    private static func share(
        _ car: SharedVehicle,
        label: String,
        container: NSPersistentCloudKitContainer,
        monitor: CloudSyncMonitor,
        events: Events
    ) async -> CKRecordZone.ID? {
        say("— \(label)")
        let preparer = SharePreparer(request: ShareSheetRequest(object: car, container: container), monitor: monitor)
        let began = ContinuousClock.now
        let since = Date.now
        preparer.start()
        let deadline = began + SharePreparationPlan.Limits.standard.worstCase + .seconds(15)
        var shown: SharePreparationPlan.Step?
        while preparer.step.isWorking, ContinuousClock.now < deadline {
            if preparer.step != shown {
                shown = preparer.step
                say("  \(ms(since: began)) ms  \(preparer.step.statusText)")
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let took = ms(since: began)
        let activity = events.summary(in: container.cloudKitStoreIdentifiers, since: since)
        if let failure = preparer.failure {
            say("  \(took) ms  FAILED: \(failure.title), \(failure.error?.codeLabel ?? "no error"): \(failure.message(busyFor: preparer.busyFor))")
            say("  sync meanwhile: \(activity)")
            return nil
        }
        guard preparer.step == .ready, let share = preparer.share else {
            preparer.cancel()
            say("  \(took) ms  STILL WORKING at the probe's own deadline: \(preparer.step.statusText)")
            return nil
        }
        say("  \(took) ms  ready: \(preparer.madeShare ? "made a share" : "found the existing share"), link \(share.url != nil ? "present" : "MISSING"), zone \(share.recordID.zoneID.zoneName)")
        say("  sync meanwhile: \(activity)")
        return preparer.madeShare ? share.recordID.zoneID : nil
    }

    /// Removes the probe's shares, cars and leftovers. Record IDs are read
    /// first: a purge deletes the zone's objects here too, and touching one
    /// afterwards would crash on a fault Core Data can't fulfil.
    @MainActor
    private static func cleanUp(
        cars: [SharedVehicle],
        madeZones: [CKRecordZone.ID],
        container: NSPersistentCloudKitContainer,
        containerID: String,
        events: Events
    ) async {
        say("— cleaning up")
        var records: [(objectID: NSManagedObjectID, recordID: CKRecord.ID?)] = []
        for car in cars {
            let objectID = car.objectID
            let recordID: CKRecord.ID?? = await Bounded.wait(.seconds(60)) { done in
                container.recordIDInBackground(for: objectID) { done($0) }
            }
            records.append((objectID, recordID ?? nil))
        }
        guard let store = container.privatePersistentStore else { return }

        // Purging waits on the container's executor like the sharing calls,
        // so it goes off the main thread the same way (CloudShareCalls.swift).
        nonisolated(unsafe) let purgingStore = store
        for zone in madeZones where zone.zoneName.hasPrefix(LeftoverShareZones.prefix) {
            let purged: (any Error)?? = await Bounded.wait(.seconds(120)) { done in
                DispatchQueue.global(qos: .userInitiated).async {
                    container.purgeObjectsAndRecordsInZone(with: zone, in: purgingStore) { _, error in done(error) }
                }
            }
            switch purged {
            case nil: say("  purge of \(zone.zoneName): no answer in 120 s")
            case .some(nil): say("  purged \(zone.zoneName)")
            case .some(let error?): say("  purge of \(zone.zoneName) FAILED: \(ShareError(error).codeLabel)")
            }
        }

        // A car never shared is still in the default zone: delete it like a
        // person would, and let the delete upload.
        let defaultZone = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone", ownerName: CKCurrentUserDefaultName)
        let unshared = records.filter { $0.recordID?.zoneID == defaultZone }
        if !unshared.isEmpty {
            let context = container.viewContext
            for record in unshared {
                if let car = try? context.existingObject(with: record.objectID) { context.delete(car) }
            }
            let deletedAt = Date.now
            if (try? context.save()) != nil {
                let stores = container.cloudKitStoreIdentifiers
                let uploaded = await until(.seconds(120)) { events.exportEnded(startedAfter: deletedAt, in: stores) }
                say("  deleted \(unshared.count) unshared car(s) from the default zone\(uploaded ? "" : " (upload not confirmed)")")
            }
        }

        // A share that never finished can leave a zone Core Data doesn't
        // know: find any share zone still holding one of the probe's own
        // records and delete it directly.
        let database = CKContainer(identifier: containerID).privateCloudDatabase
        for record in records {
            guard let recordID = record.recordID else { continue }
            let probeID = CKRecord.ID(recordName: recordID.recordName, zoneID: defaultZone)
            let found: Result<[String], ShareError>? = await Bounded.wait(.seconds(60)) { done in
                Task { done(await LeftoverShareZones.find(probeID, in: database)) }
            }
            let zones: [String]
            switch found {
            case nil:
                say("  leftover check for \(recordID.recordName): no answer in 60 s")
                continue
            case .failure(let error)?:
                say("  leftover check for \(recordID.recordName) FAILED: \(error.codeLabel)")
                continue
            case .success(let found)?:
                zones = found
            }
            guard !zones.isEmpty else {
                say("  no leftover share zone holds \(recordID.recordName)")
                continue
            }
            let ids = zones.map { CKRecordZone.ID(zoneName: $0, ownerName: CKCurrentUserDefaultName) }
            do {
                _ = try await database.modifyRecordZones(saving: [], deleting: ids)
                say("  deleted \(zones.count) leftover share zone(s) holding a probe record: \(zones.joined(separator: ", "))")
            } catch {
                say("  deleting leftover zones FAILED: \(ShareError(error).codeLabel)")
            }
        }
    }

    // MARK: - Helpers

    /// The app's two-store shape (`CloudSharedStore.makeContainer`), but on
    /// disk in `folder`, never at the app's own store URLs.
    @MainActor
    private static func makeContainer(in folder: URL, containerID: String, events: Events) throws -> NSPersistentCloudKitContainer {
        let container = NSPersistentCloudKitContainer(name: "ShareProbe", managedObjectModel: FuelModel.make())
        func description(_ file: String, scope: CKDatabase.Scope) -> NSPersistentStoreDescription {
            let description = NSPersistentStoreDescription(url: folder.appendingPathComponent(file))
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            let options = NSPersistentCloudKitContainerOptions(containerIdentifier: containerID)
            options.databaseScope = scope
            description.cloudKitContainerOptions = options
            description.shouldAddStoreAsynchronously = false
            return description
        }
        container.persistentStoreDescriptions = [
            description("ShareProbe.sqlite", scope: .private),
            description("ShareProbe-shared.sqlite", scope: .shared),
        ]
        // Before loading: mirroring's setup starts the moment a store loads.
        events.watch(container)
        var loadError: (any Error)?
        container.loadPersistentStores { _, error in
            if let error { loadError = error }
        }
        if let loadError { throw loadError }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.transactionAuthor = SharedChangeFilter.appAuthor
        return container
    }

    @MainActor
    private static func seed(name: String, fillUps: Int, in context: NSManagedObjectContext) -> SharedVehicle {
        let car = SharedVehicle(context: context, name: name)
        let start = Date.now.addingTimeInterval(-Double(fillUps) * 7 * 86_400)
        for index in 0..<fillUps {
            let entry = SharedFuelEntry(
                context: context,
                date: start.addingTimeInterval(Double(index) * 7 * 86_400),
                odometer: 10_000 + index * 320,
                gallons: 11.4,
                pricePerGallon: 3.49,
                totalCost: 39.79,
                station: "Probe"
            )
            entry.vehicle = car
        }
        return car
    }

    /// Polls `condition` on the main actor until it holds or `timeout` passes.
    @MainActor
    private static func until(_ timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }

    private static func ms(since start: ContinuousClock.Instant) -> Int {
        SharePreparer.ms(ContinuousClock.now - start)
    }

    nonisolated private static func say(_ line: String) {
        print("[ShareProbe] \(line)")
        fflush(stdout)
    }

    /// The probe container's mirroring events, as they finish.
    @MainActor
    private final class Events {
        struct Finished {
            let kind: NSPersistentCloudKitContainer.EventType
            let store: String
            let start: Date
            let end: Date
            let succeeded: Bool
            let error: String?
        }

        private(set) var finished: [Finished] = []
        private var observer: NSObjectProtocol?

        func watch(_ container: NSPersistentCloudKitContainer) {
            observer = NotificationCenter.default.addObserver(
                forName: NSPersistentCloudKitContainer.eventChangedNotification,
                object: container,
                queue: nil
            ) { [weak self] notification in
                guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                        as? NSPersistentCloudKitContainer.Event,
                      let end = event.endDate else { return }
                let item = Finished(
                    kind: event.type,
                    store: event.storeIdentifier,
                    start: event.startDate,
                    end: end,
                    succeeded: event.succeeded,
                    error: event.error.map { ShareError($0).codeLabel }
                )
                // Never `queue: .main`: a synchronous hop to the main thread
                // from mirroring's queue is the deadlock CloudSyncMonitor's
                // init describes.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.finished.append(item) }
                }
            }
        }

        func hasFinished(_ kind: NSPersistentCloudKitContainer.EventType, in stores: Set<String>) -> Bool {
            finished.contains { $0.kind == kind && stores.contains($0.store) }
        }

        func exportStarted(after date: Date, in stores: Set<String>) -> Date? {
            finished.first { $0.kind == .export && stores.contains($0.store) && $0.start >= date }?.start
        }

        func exportEnded(startedAfter date: Date, in stores: Set<String>) -> Bool {
            finished.contains { $0.kind == .export && stores.contains($0.store) && $0.start >= date }
        }

        /// "2 imports (1.2 s, 0.3 s), 1 export (0.8 s, failed: CKError 2)".
        func summary(in stores: Set<String>, since date: Date = .distantPast) -> String {
            let relevant = finished.filter { stores.contains($0.store) && $0.end >= date }
            guard !relevant.isEmpty else { return "no import or export finished" }
            let kinds: [(NSPersistentCloudKitContainer.EventType, String)] = [(.setup, "setup"), (.import, "import"), (.export, "export")]
            return kinds.compactMap { kind, name -> String? in
                let matching = relevant.filter { $0.kind == kind }
                guard !matching.isEmpty else { return nil }
                let each = matching.map { event in
                    let seconds = String(format: "%.1f s", event.end.timeIntervalSince(event.start))
                    return event.succeeded ? seconds : "\(seconds), failed: \(event.error ?? "?")"
                }
                return "\(matching.count) \(name)\(matching.count == 1 ? "" : "s") (\(each.joined(separator: "; ")))"
            }.joined(separator: ", ")
        }
    }
}
#endif
