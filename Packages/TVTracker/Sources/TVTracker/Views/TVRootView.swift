import Core
import SwiftData
import SwiftUI

struct TVRootView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(TVTrackerModule.apiKeyDefaultsKey) private var apiKey = ""

    @State private var selection = "watching"

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: ModuleTab.home) {
                Color.clear
            }
            Tab("Watching", systemImage: "tv", value: "watching") {
                WatchingListView()
            }
            Tab("Movies", systemImage: "film", value: "movies") {
                MoviesListView()
            }
            Tab("Up Next", systemImage: "calendar", value: "upnext") {
                ScheduleView()
            }
            Tab("Settings", systemImage: "gear", value: "settings") {
                NavigationStack { TVSettingsView() }
            }
        }
        .tint(TVTrackerModule.accent.color)
        .dismissesOnHomeTab($selection, restoringTo: "watching")
        #if DEBUG
        .task {
            guard DebugSeed.isRequested else { return }
            await DebugSeed.run(context: modelContext, apiKey: apiKey)
        }
        #endif
    }
}
