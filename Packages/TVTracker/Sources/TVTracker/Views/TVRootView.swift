import SwiftData
import SwiftUI

struct TVRootView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(TVTrackerModule.apiKeyDefaultsKey) private var apiKey = ""

    var body: some View {
        TabView {
            Tab("Watching", systemImage: "tv") {
                WatchingListView()
            }
            Tab("Movies", systemImage: "film") {
                MoviesListView()
            }
            Tab("Up Next", systemImage: "calendar") {
                ScheduleView()
            }
            Tab("Stats", systemImage: "chart.bar") {
                TVStatsView()
            }
        }
        .tint(TVTrackerModule.accent.color)
        #if DEBUG
        .task {
            guard DebugSeed.isRequested else { return }
            await DebugSeed.run(context: modelContext, apiKey: apiKey)
        }
        #endif
    }
}
