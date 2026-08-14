import FuelTracker
import GymTracker
import SwiftData
import SwiftUI

@main
struct BhavikApp: App {
    let container: ModelContainer

    init() {
        do {
            let schema = Schema(GymTrackerModule.models + FuelTrackerModule.models)
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
        }
        .modelContainer(container)
    }
}
