#if DEBUG
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
        return recordTypes.sorted()
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
