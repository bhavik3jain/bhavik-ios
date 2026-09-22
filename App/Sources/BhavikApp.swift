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
                    #if os(macOS)
                    .frame(minWidth: 860, minHeight: 560)
                    #endif
            }
            #else
            HomeView()
                .preferredColorScheme(Appearance.stored(appearanceRaw).colorScheme)
                #if os(macOS)
                .frame(minWidth: 860, minHeight: 560)
                #endif
            #endif
        }
        .modelContainer(container)
        #if os(macOS)
        // A left-over default-sized window reads as an unfinished iPhone app
        // squeezed onto a Mac; a sidebar layout wants the width to show it.
        .defaultSize(width: 1100, height: 700)
        .commands { TrackerCommands() }
        #endif
    }
}

#if os(macOS)
/// The Trackers menu: ⌘1–⌘6 jump straight to a tracker. A Scene's `.commands`
/// sits outside the WindowGroup's view hierarchy, so it can't reach into
/// HomeView's own `@State` — it posts a notification instead, which
/// `HomeView.macBody` listens for.
private struct TrackerCommands: Commands {
    var body: some Commands {
        CommandMenu("Trackers") {
            item("Trips", .trips, "1")
            item("Explore", .explore, "2")
            item("Gym", .gym, "3")
            item("TV", .tv, "4")
            item("Orders", .parcels, "5")
            item("Fuel", .fuel, "6")
        }
    }

    private func item(_ name: String, _ module: SelectedModule, _ key: KeyEquivalent) -> some View {
        Button(name) {
            NotificationCenter.default.post(name: .selectTracker, object: nil, userInfo: ["module": module.rawValue])
        }
        .keyboardShortcut(key, modifiers: .command)
    }
}
#endif

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
