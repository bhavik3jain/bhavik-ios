import Core
import FuelTracker
import GymTracker
import ParcelTracker
import SwiftData
import SwiftUI
import TVTracker

@main
struct BhavikApp: App {
    let container: ModelContainer
    @AppStorage(Appearance.defaultsKey) private var appearanceRaw = Appearance.system.rawValue

    init() {
        do {
            let schema = Schema(GymTrackerModule.models + FuelTrackerModule.models + TVTrackerModule.models + ParcelTrackerModule.models)
            let configuration = ModelConfiguration(
                schema: schema,
                cloudKitDatabase: .private("iCloud.com.bhavikjain.trackers")
            )
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .preferredColorScheme(Appearance.stored(appearanceRaw).colorScheme)
        }
        .modelContainer(container)
    }
}
