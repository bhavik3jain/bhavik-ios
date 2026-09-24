#if DEBUG
import CloudKit
import CoreData
import ExploreTracker
import FuelTracker
import PointsTracker
import SwiftData
import SwiftUI
import TripTracker

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
/// does Points (`PointsModel`), which was built on Core Data from the start.
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

    enum Failure: LocalizedError {
        case modelConversion
        case storeLoad(String)

        var errorDescription: String? {
            switch self {
            case .modelConversion:
                "SwiftData couldn't convert the models to a Core Data model."
            case .storeLoad(let detail):
                "The throwaway store wouldn't load: \(detail)"
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
    /// Points — built fresh, never the instances the app's own containers hold.
    @MainActor
    static func coreDataModels() -> [CoreDataModel] {
        [
            CoreDataModel(name: "TripSchema", model: TripModel.make()),
            CoreDataModel(name: "FuelSchema", model: FuelModel.make()),
            CoreDataModel(name: "ExploreSchema", model: GuideModel.make()),
            CoreDataModel(name: "PointsSchema", model: PointsModel.make()),
        ]
    }

    /// Blocks while CloudKit is contacted, so call it off the main thread.
    /// Returns every record type sent, sorted.
    static func run(containerID: String, coreDataModels: [CoreDataModel]) throws -> [String] {
        guard let swiftDataModel = NSManagedObjectModel.makeManagedObjectModel(for: AppSchema.models) else {
            throw Failure.modelConversion
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudkit-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let passes = [CoreDataModel(name: "CloudKitSchema", model: swiftDataModel)] + coreDataModels
        var recordTypes: [String] = []
        for pass in passes {
            recordTypes += try initialize(pass, in: folder, containerID: containerID)
        }
        if let sharable = coreDataModels.first {
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
        defer {
            let coordinator = container.persistentStoreCoordinator
            for store in coordinator.persistentStores {
                try? coordinator.remove(store)
            }
        }

        guard let entity = pass.model.entities.sorted(by: { ($0.name ?? "") < ($1.name ?? "") }).first,
              let store = container.persistentStoreCoordinator.persistentStores.first else {
            throw Failure.storeLoad("ShareProbe: no entity to share")
        }
        let context = container.newBackgroundContext()
        var object: NSManagedObject?
        var saveError: Error?
        context.performAndWait {
            let probe = NSManagedObject(entity: entity, insertInto: context)
            do { try context.save() } catch { saveError = error }
            object = probe
        }
        if let saveError { throw saveError }
        guard let object else { throw Failure.storeLoad("ShareProbe: nothing inserted") }

        let shared = DispatchSemaphore(value: 0)
        var share: CKShare?
        var shareError: Error?
        container.share([object], to: nil) { _, result, _, error in
            share = result
            shareError = error
            shared.signal()
        }
        shared.wait()
        if let shareError { throw shareError }

        // The app saves every share with a title and a stamp saying which
        // tracker it's for (ShareAcceptRouter.stamp). Saving them here too
        // puts those fields into the schema along with the type.
        if let share, let store = container.persistentStoreCoordinator.persistentStores.first {
            share[CKShare.SystemFieldKey.title] = "Schema probe" as CKRecordValue
            share[CKShare.SystemFieldKey.shareType] = "CD_\(entity.name ?? "")" as CKRecordValue
            let saved = DispatchSemaphore(value: 0)
            var saveShareError: Error?
            container.persistUpdatedShare(share, in: store) { _, error in
                saveShareError = error
                saved.signal()
            }
            saved.wait()
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

    /// One model on its own throwaway container: a private-scope store only.
    /// The shared database has no schema of its own — a share's records use
    /// the owner's record types — so there's nothing to send through one.
    private static func initialize(_ pass: CoreDataModel, in folder: URL, containerID: String) throws -> [String] {
        let description = NSPersistentStoreDescription(url: folder.appendingPathComponent("\(pass.name).sqlite"))
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: containerID)
        description.shouldAddStoreAsynchronously = false

        let container = NSPersistentCloudKitContainer(name: pass.name, managedObjectModel: pass.model)
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw Failure.storeLoad("\(pass.name): \(loadError.localizedDescription)") }

        // The names the Console shows: Core Data's mirroring prefixes every
        // entity with CD_. Logged before CloudKit is contacted, so the model
        // conversion can be checked even when the upload can't happen.
        let recordTypes = pass.model.entities.compactMap(\.name).map { "CD_\($0)" }.sorted()
        print("[CloudKitSchemaInitializer] \(pass.name): \(recordTypes.count) record types: \(recordTypes.joined(separator: ", "))")

        // Detach the throwaway store so mirroring stops before the folder
        // goes — on failure too, or the next pass shares the process with a
        // store still mirroring into a deleted file.
        defer {
            let coordinator = container.persistentStoreCoordinator
            for store in coordinator.persistentStores {
                try? coordinator.remove(store)
            }
        }
        try container.initializeCloudKitSchema(options: [])

        return recordTypes
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
