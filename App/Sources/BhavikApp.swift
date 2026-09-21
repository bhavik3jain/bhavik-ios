import Core
import ExploreTracker
import FuelTracker
import GymTracker
import ParcelTracker
import SwiftData
import SwiftUI
import TripTracker
import TVTracker

@main
struct BhavikApp: App {
    /// Named once so the settings screen can ask CloudKit about the same
    /// container the store actually syncs through.
    static let cloudContainerID = "iCloud.com.bhavikjain.trackers"

    let container: ModelContainer
    @AppStorage(Appearance.defaultsKey) private var appearanceRaw = Appearance.system.rawValue

    init() {
        do {
            let schema = Schema(
                GymTrackerModule.models + FuelTrackerModule.models + TVTrackerModule.models
                    + ParcelTrackerModule.models + TripTrackerModule.models + ExploreTrackerModule.models
            )
            let configuration = ModelConfiguration(
                schema: schema,
                cloudKitDatabase: .private(Self.cloudContainerID)
            )
            container = try ModelContainer(for: schema, configurations: [configuration])
            #if DEBUG
            CloudKitSchemaSeeder.runIfRequested(in: ModelContext(container))
            #endif
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .preferredColorScheme(Appearance.stored(appearanceRaw).colorScheme)
                #if DEBUG
                .modifier(WeatherStub())
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
