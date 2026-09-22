import Core
import ExploreTracker
import FuelTracker
import GymTracker
import ParcelTracker
import SwiftData
import SwiftUI
import TripTracker
import TVTracker

/// Every module's models: the one list both the real container and the
/// CloudKit schema initializer are built from, so the two can't drift apart.
/// Outside `BhavikApp` because an `App` is main-actor isolated and the
/// initializer reads this from a background task.
enum AppSchema {
    static var models: [any PersistentModel.Type] {
        GymTrackerModule.models + FuelTrackerModule.models + TVTrackerModule.models
            + ParcelTrackerModule.models + TripTrackerModule.models + ExploreTrackerModule.models
    }
}

@main
struct BhavikApp: App {
    /// Named once so the settings screen can ask CloudKit about the same
    /// container the store actually syncs through.
    static let cloudContainerID = "iCloud.com.bhavikjain.trackers"

    let container: ModelContainer
    @AppStorage(Appearance.defaultsKey) private var appearanceRaw = Appearance.system.rawValue

    init() {
        do {
            let schema = Schema(AppSchema.models)
            #if DEBUG
            // A schema-initialising launch must never open the real store: the
            // point is that it's safe to run on a phone holding real data. An
            // empty in-memory container keeps SwiftUI's environment satisfied.
            if CloudKitSchemaInitializer.isRequested {
                let scratch = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
                container = try ModelContainer(for: schema, configurations: [scratch])
                return
            }
            #endif
            let configuration = ModelConfiguration(
                schema: schema,
                cloudKitDatabase: .private(Self.cloudContainerID)
            )
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if CloudKitSchemaInitializer.isRequested {
                CloudKitSchemaInitializerView(containerID: Self.cloudContainerID)
            } else {
                HomeView()
                    .preferredColorScheme(Appearance.stored(appearanceRaw).colorScheme)
                    .modifier(WeatherStub())
            }
            #else
            HomeView()
                .preferredColorScheme(Appearance.stored(appearanceRaw).colorScheme)
            #endif
        }
        .modelContainer(container)
    }
}

#if DEBUG
/// `-WeatherStub YES` swaps in made-up weather for the whole app.
///
/// The live WeatherKit provider throws until the WeatherKit capability is
/// enabled for the app ID and the entitlement is added, and Trips and Explore
/// then quietly show no weather at all — so without this there is no way to
/// see a day strip or a weather card on a simulator. Set at the root so it
/// reaches the modules' full-screen covers too.
private struct WeatherStub: ViewModifier {
    func body(content: Content) -> some View {
        if UserDefaults.standard.bool(forKey: "WeatherStub") {
            content.environment(\.weatherProvider, StubWeatherProvider())
        } else {
            content
        }
    }
}
#endif
