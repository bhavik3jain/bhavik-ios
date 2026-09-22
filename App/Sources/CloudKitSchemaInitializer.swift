#if DEBUG
import CoreData
import SwiftData
import SwiftUI

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
/// It works on a throwaway store in a temporary folder, and on a launch that
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

    /// Blocks while CloudKit is contacted, so call it off the main thread.
    static func run(containerID: String) throws -> [String] {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: AppSchema.models) else {
            throw Failure.modelConversion
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudkit-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let description = NSPersistentStoreDescription(url: folder.appendingPathComponent("Schema.sqlite"))
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: containerID)
        description.shouldAddStoreAsynchronously = false

        let container = NSPersistentCloudKitContainer(name: "CloudKitSchema", managedObjectModel: model)
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw Failure.storeLoad(loadError.localizedDescription) }

        // The names the Console shows: Core Data's mirroring prefixes every
        // entity with CD_. Logged before CloudKit is contacted, so the model
        // conversion can be checked even when the upload can't happen.
        let recordTypes = model.entities.compactMap(\.name).map { "CD_\($0)" }.sorted()
        print("[CloudKitSchemaInitializer] \(recordTypes.count) record types: \(recordTypes.joined(separator: ", "))")

        try container.initializeCloudKitSchema(options: [])

        // Detach the throwaway store so mirroring stops before the folder goes.
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try? coordinator.remove(store)
        }

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
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[String], any Error> in
                Result { try CloudKitSchemaInitializer.run(containerID: containerID) }
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
