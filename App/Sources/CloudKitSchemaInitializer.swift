#if DEBUG
import CloudKit
import CoreData
import ExploreTracker
import FinanceTracker
import FuelTracker
import PointsTracker
import SwiftData
import SwiftUI
import TripTracker
import TVTracker

/// Pushes the app's whole SwiftData schema to CloudKit's Development
/// environment, ready to be deployed to Production from the CloudKit Console.
///
/// CloudKit only learns a record type when something creates it, and it never
/// creates schema in Production — so a new model silently fails to sync on
/// TestFlight until its schema is deployed. This used to be done by seeding one
/// throwaway record of every model, waiting for the upload, deploying, then
/// purging them again, on the stated grounds that SwiftData had no bridge to
/// Core Data's `initializeCloudKitSchema()`. It has one:
/// `NSManagedObjectModel.makeManagedObjectModel(for:)` (iOS 17+), which is how
/// Apple's own documentation does it. So no fake records, no purge, no waiting
/// on a background upload, and no hand-written seed code that had to wire
/// every relationship or leave it out of the schema without a word.
///
/// Trips, Fuel and Explore don't live in that SwiftData schema any more: each
/// has its own hand-built Core Data model (`TripModel`, `FuelModel`,
/// `GuideModel`). Those were first left out of this run, so their `CD_Shared*`
/// record types never reached Development, never got deployed, and Production
/// — which never creates a record type on its own — refused every export from
/// those three modules on TestFlight. Each now gets its own pass below, as
/// do Points (`PointsModel`) and Finance (`FinanceModel`), which were built
/// on Core Data from the start, and TV's watch lists (`TVListModel`), the
/// one Core Data store in an otherwise SwiftData module.
///
/// It works on throwaway stores in a temporary folder, and on a launch that
/// asks for it the app opens an in-memory database instead of the real one (see
/// `BhavikApp.init`) — so running it never touches what's on the device.
///
///     -InitializeCloudKitSchema YES
///
/// Needs a device or simulator signed in to the iCloud account that owns the
/// data. A debug build always talks to the Development environment.
enum CloudKitSchemaInitializer {
    static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "InitializeCloudKitSchema")
    }

    /// `-SchemaPass <name>` runs that one pass and no other; `-SchemaPass list`
    /// only prints the passes. `scripts/cloudkit/init-schema.sh` runs every
    /// pass in a process of its own this way — see `keptOpen` for why.
    static var requestedPass: String? {
        UserDefaults.standard.string(forKey: "SchemaPass")
    }

    /// The pass that makes and removes a test share (`createShareRecordType`).
    static let sharePassName = "ShareProbe"

    enum Failure: LocalizedError {
        case modelConversion
        case storeLoad(String)
        case unknownPass(String)

        var errorDescription: String? {
            switch self {
            case .modelConversion:
                "SwiftData couldn't convert the models to a Core Data model."
            case .storeLoad(let detail):
                "The throwaway store wouldn't load: \(detail)"
            case .unknownPass(let name):
                "There's no schema pass called \(name)."
            }
        }
    }

    /// A sentence for the screen. Core Data wraps the real cause two levels
    /// down, and its own description is just "A Core Data error occurred." —
    /// which is what the first run on a signed-out simulator showed.
    static func explain(_ error: any Error) -> String {
        let text = String(describing: error)
        if text.contains("CKAccountStatusNoAccount") {
            return "This device isn't signed in to iCloud. Sign in with your Apple Account in Settings, then run it again."
        }
        if text.contains("CKAccountStatusRestricted") || text.contains("CKAccountStatusTemporarilyUnavailable") {
            return "iCloud isn't available on this device right now. Check Settings, then run it again."
        }
        let nested = (error as NSError).userInfo["encounteredErrors"] as? [NSError]
        return nested?.first?.localizedFailureReason ?? error.localizedDescription
    }

    /// One Core Data model to push, with the name its throwaway store gets.
    ///
    /// `@unchecked` because `NSManagedObjectModel` isn't `Sendable`, yet the
    /// models have to be built on the main actor (the modules' `make()` are
    /// `@MainActor`) and used off it (`run` blocks on CloudKit). Safe here: each
    /// is fully built before it crosses, and nothing mutates it afterwards.
    struct CoreDataModel: @unchecked Sendable {
        let name: String
        let model: NSManagedObjectModel
    }

    /// The modules on Core Data — the three that moved off SwiftData, plus
    /// Points, Finance and TV's watch lists — built fresh, never the instances the app's own containers hold.
    @MainActor
    static func coreDataModels() -> [CoreDataModel] {
        [
            CoreDataModel(name: "TripSchema", model: TripModel.make()),
            CoreDataModel(name: "FuelSchema", model: FuelModel.make()),
            CoreDataModel(name: "ExploreSchema", model: GuideModel.make()),
            CoreDataModel(name: "PointsSchema", model: PointsModel.make()),
            CoreDataModel(name: "FinanceSchema", model: FinanceModel.make()),
            CoreDataModel(name: "TVListSchema", model: TVListModel.make()),
        ]
    }

    /// Every throwaway container, held open until the process ends.
    ///
    /// Each pass used to detach its store as soon as its schema was sent, but
    /// mirroring had already queued an import for it, which then ran against a
    /// coordinator with no store and threw — "This NSPersistentStoreCoordinator
    /// has no persistent stores (unknown). It cannot perform a save
    /// operation." from `-[NSCloudKitMirroringDelegate _performImportWithRequest:]`
    /// — killing the run after its first pass (October 2026, sending TV's
    /// watch lists). Earlier runs had only been lucky with the timing. A
    /// schema launch does nothing else and quits once it's done, so the stores
    /// can simply stay open; each mirrors into its own file.
    ///
    /// Open, though, every store goes on downloading all of Development's
    /// records, and the next pass's own CloudKit operations queued behind
    /// those downloads: the fifth pass's schema save started and never
    /// finished, so `initializeCloudKitSchema` gave up after its 30 s wait,
    /// three runs in a row. That's why the script runs each pass in a process
    /// of its own (`-SchemaPass`): quitting ends its store and its mirroring
    /// together, with nothing left to race and nothing for the next pass to
    /// wait behind. A launch running every pass (on a device) still keeps them
    /// all open, and retries a pass once if it times out.
    ///
    /// `run` is called once, from one task, so a plain static is enough.
    private nonisolated(unsafe) static var keptOpen: [NSPersistentCloudKitContainer] = []

    private static func keepOpen(_ container: NSPersistentCloudKitContainer) {
        keptOpen.append(container)
    }

    /// Blocks while CloudKit is contacted, so call it off the main thread.
    /// Returns every record type sent, sorted.
    static func run(containerID: String, coreDataModels: [CoreDataModel]) throws -> [String] {
        guard let swiftDataModel = NSManagedObjectModel.makeManagedObjectModel(for: AppSchema.models) else {
            throw Failure.modelConversion
        }
        let names = ["CloudKitSchema"] + coreDataModels.map(\.name) + (coreDataModels.isEmpty ? [] : [sharePassName])
        print("[CloudKitSchemaInitializer] Passes: \(names.joined(separator: " "))")
        let only = requestedPass
        if only == "list" { return [] }
        if let only, !names.contains(only) { throw Failure.unknownPass(only) }

        // The folder outlives this run: its stores stay open until the process
        // ends (see `keptOpen`), so it can't be deleted under them. An earlier
        // run's goes instead, now that nothing has it open.
        let temporary = FileManager.default.temporaryDirectory
        for leftover in (try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)) ?? []
        where leftover.lastPathComponent.hasPrefix("cloudkit-schema-") {
            try? FileManager.default.removeItem(at: leftover)
        }
        let folder = temporary.appendingPathComponent("cloudkit-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let passes = [CoreDataModel(name: "CloudKitSchema", model: swiftDataModel)] + coreDataModels
        var recordTypes: [String] = []
        for pass in passes where only == nil || pass.name == only {
            recordTypes += try initialize(pass, in: folder, containerID: containerID)
        }
        if let sharable = coreDataModels.first, only == nil || only == sharePassName {
            recordTypes.append(try createShareRecordType(using: sharable, in: folder, containerID: containerID))
        }
        return recordTypes.sorted()
    }

    /// A share is saved as a record of CloudKit's own `cloudkit.share` type,
    /// and like any other record type Production won't create it: it only
    /// exists there once a share has been made in Development and the schema
    /// deployed. The first deploy happened before anything had ever been
    /// shared, so on TestFlight every Share button failed at the moment the
    /// link was being made. Sharing one throwaway object here, then deleting
    /// its zone, puts the type into Development for the next deploy.
    private static func createShareRecordType(using pass: CoreDataModel, in folder: URL, containerID: String) throws -> String {
        let description = NSPersistentStoreDescription(url: folder.appendingPathComponent("ShareProbe.sqlite"))
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: containerID)
        description.shouldAddStoreAsynchronously = false
        // Unlike the schema passes, this one saves and shares, and mirroring
        // needs history for that: without it the save failed with SQLite
        // error 1, "ShareProbe.sqlite couldn't be opened".
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        let container = NSPersistentCloudKitContainer(name: "ShareProbe", managedObjectModel: pass.model)
        container.persistentStoreDescriptions = [description]

        // Mirroring builds its bookkeeping tables in the background after the
        // store loads; sharing straight away failed with "no such table:
        // ANSCKRECORDMETADATA". Subscribed before loading so a fast setup
        // isn't missed.
        let setUp = DispatchSemaphore(value: 0)
        let observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: container, queue: nil
        ) { note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  event.type == .setup, event.endDate != nil else { return }
            setUp.signal()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw Failure.storeLoad("ShareProbe: \(loadError.localizedDescription)") }
        if setUp.wait(timeout: .now() + 60) == .timedOut {
            throw Failure.storeLoad("ShareProbe: CloudKit setup didn't finish within a minute")
        }
        keepOpen(container)

        guard let entity = pass.model.entities.sorted(by: { ($0.name ?? "") < ($1.name ?? "") }).first,
              let store = container.persistentStoreCoordinator.persistentStores.first else {
            throw Failure.storeLoad("ShareProbe: no entity to share")
        }
        let context = container.newBackgroundContext()
        // performAndWait's block is `@Sendable`, and neither
        // `NSEntityDescription` nor `NSManagedObject` is: the entity goes in
        // by name and the object comes out as the block's return value,
        // rather than being captured and assigned to a local `var`.
        let entityName = entity.name ?? ""
        let object = try context.performAndWait {
            let probe = NSEntityDescription.insertNewObject(forEntityName: entityName, into: context)
            try context.save()
            return probe
        }

        let (share, shareError): (CKShare?, Error?) = waitForCompletion { finish in
            container.share([object], to: nil) { _, result, _, error in finish((result, error)) }
        }
        if let shareError { throw shareError }

        // The app saves every share with a title and a stamp saying which
        // tracker it's for (ShareAcceptRouter.stamp). Saving them here too
        // puts those fields into the schema along with the type.
        if let share, let store = container.persistentStoreCoordinator.persistentStores.first {
            share[CKShare.SystemFieldKey.title] = "Schema probe" as CKRecordValue
            share[CKShare.SystemFieldKey.shareType] = "CD_\(entity.name ?? "")" as CKRecordValue
            let saveShareError: Error? = waitForCompletion { finish in
                container.persistUpdatedShare(share, in: store) { _, error in finish(error) }
            }
            if let saveShareError { throw saveShareError }
        }

        // The type is what's wanted, not the share: remove the zone the share
        // was made in, record and all.
        if let zoneID = share?.recordID.zoneID {
            let purged = DispatchSemaphore(value: 0)
            container.purgeObjectsAndRecordsInZone(with: zoneID, in: store) { _, _ in purged.signal() }
            purged.wait()
        }
        print("[CloudKitSchemaInitializer] ShareProbe: made and removed a test share, so cloudkit.share exists")
        return "cloudkit.share"
    }

    /// Runs `start`, blocks until the completion it hands CloudKit fires, and
    /// returns what that completion was called with. Those completions are
    /// `@Sendable` and run on CloudKit's own queues, so assigning a local
    /// `var` from inside them — as this file first did — is a data race Swift
    /// 6 flags ("mutation of captured var in concurrently-executing code").
    /// The result rides back in a locked box instead, and the semaphore
    /// orders the hand-off exactly as the per-call semaphores did before.
    private static func waitForCompletion<Value>(_ start: (@escaping @Sendable (Value) -> Void) -> Void) -> Value {
        let box = CompletionBox<Value>()
        let done = DispatchSemaphore(value: 0)
        start { value in
            box.store(value)
            done.signal()
        }
        done.wait()
        return box.take()
    }

    /// Written once from CloudKit's queue, read once after the semaphore; the
    /// lock is what makes the unchecked `Sendable` true.
    private final class CompletionBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?

        func store(_ newValue: Value) { lock.withLock { value = newValue } }
        func take() -> Value { lock.withLock { value! } }
    }

    /// One model on its own throwaway container: a private-scope store only.
    /// The shared database has no schema of its own — a share's records use
    /// the owner's record types — so there's nothing to send through one.
    private static func initialize(_ pass: CoreDataModel, in folder: URL, containerID: String) throws -> [String] {
        let description = NSPersistentStoreDescription(url: folder.appendingPathComponent("\(pass.name).sqlite"))
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: containerID)
        description.shouldAddStoreAsynchronously = false

        let container = NSPersistentCloudKitContainer(name: pass.name, managedObjectModel: pass.model)
        container.persistentStoreDescriptions = [description]
        // Before loading, so the setup and first import aren't missed.
        let mirroring = MirroringWatch(container)

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw Failure.storeLoad("\(pass.name): \(loadError.localizedDescription)") }

        // The names the Console shows: Core Data's mirroring prefixes every
        // entity with CD_. Logged before CloudKit is contacted, so the model
        // conversion can be checked even when the upload can't happen.
        let recordTypes = pass.model.entities.compactMap(\.name).map { "CD_\($0)" }.sorted()
        print("[CloudKitSchemaInitializer] \(pass.name): \(recordTypes.count) record types: \(recordTypes.joined(separator: ", "))")

        keepOpen(container)
        // A store that's just opened sets up its mirroring and imports
        // straight away, and those hold the container's executor: on the
        // Points pass, with four passes' stores still importing beside it,
        // `initializeCloudKitSchema` queued behind them and gave up with "the
        // requests timed out (a 30s wait failed)". Waiting for every pass's
        // import first was no better: each throwaway store downloads all of
        // Development's records (Debug builds once synced real data there), and
        // seven of those overran the script's limit. So it goes at once, as it
        // always did, and only waits for its own import before trying again.
        do {
            try container.initializeCloudKitSchema(options: [])
        } catch {
            print("[CloudKitSchemaInitializer] \(pass.name): trying again once its sync settles (\(error.localizedDescription))")
            mirroring.waitUntilSettled(timeout: 240)
            try container.initializeCloudKitSchema(options: [])
        }

        return recordTypes
    }
}

/// One throwaway container's mirroring: whether its setup and first import
/// have finished and nothing else is running. Fed from CloudKit's own queues,
/// read from the schema run's; the lock is what makes it `Sendable`.
private final class MirroringWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight: Set<UUID> = []
    private var setUp = false
    private var imported = false
    private var observer: NSObjectProtocol?

    init(_ container: NSPersistentCloudKitContainer) {
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container,
            queue: nil
        ) { [weak self] note in
            guard let self,
                  let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            let id = event.identifier, type = event.type, ended = event.endDate != nil
            self.lock.withLock {
                guard ended else {
                    self.inFlight.insert(id)
                    return
                }
                self.inFlight.remove(id)
                if type == .setup { self.setUp = true }
                if type == .import { self.imported = true }
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Blocks until setup and an import have finished with nothing else
    /// running, or `timeout` seconds pass — whichever is first. Going on
    /// after the limit is fine: the schema call then reports its own error.
    func waitUntilSettled(timeout: TimeInterval) {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if lock.withLock({ setUp && imported && inFlight.isEmpty }) { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }
}

/// What a `-InitializeCloudKitSchema YES` launch shows instead of the app.
struct CloudKitSchemaInitializerView: View {
    let containerID: String

    private enum Phase {
        case running
        case done([String])
        case failed(String)
    }

    @State private var phase = Phase.running

    var body: some View {
        NavigationStack {
            List {
                Section {
                    switch phase {
                    case .running:
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Sending the schema to CloudKit…")
                        }
                    case .done(let types):
                        Label("Done — \(types.count) record types are in Development.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("Container \(containerID). Your data on this device wasn't opened.")
                }

                if case .done(let types) = phase {
                    Section("Record types") {
                        ForEach(types, id: \.self) { type in
                            Text(type).font(.body.monospaced())
                        }
                    }
                    Section("Next") {
                        Text("In the CloudKit Console, open this container's Development environment, check these record types are there, then use Deploy Schema Changes to send them to Production.")
                        Text("Then remove -InitializeCloudKitSchema from the scheme so the app opens normally.")
                    }
                }

                if case .failed = phase {
                    Section("If this failed") {
                        Text("Nothing was changed, here or in CloudKit. Fix the cause above and run it again.")
                    }
                }
            }
            .navigationTitle("CloudKit Schema")
        }
        .task {
            let containerID = containerID
            let coreDataModels = CloudKitSchemaInitializer.coreDataModels()
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[String], any Error> in
                Result { try CloudKitSchemaInitializer.run(containerID: containerID, coreDataModels: coreDataModels) }
            }.value
            switch outcome {
            case .success(let types):
                print("[CloudKitSchemaInitializer] Schema sent to Development: \(types.joined(separator: ", "))")
                phase = .done(types)
            case .failure(let error):
                print("[CloudKitSchemaInitializer] Failed: \(error)")
                phase = .failed(CloudKitSchemaInitializer.explain(error))
            }
        }
    }
}
#endif
