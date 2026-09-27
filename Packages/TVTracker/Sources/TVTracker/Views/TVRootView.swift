import Core
import SwiftData
import SwiftUI

struct TVRootView: View {
    @Environment(\.modelContext) private var modelContext
    @SyncedSecret(TVTrackerModule.apiKeyDefaultsKey) private var apiKey

    /// The Mac sidebar's own selection when it picks the section; nil on the
    /// phone, where the tab bar's selection below does.
    var section: Binding<String>?
    @State private var ownSection = TVTrackerModule.sections[0].id

    var body: some View {
        ModuleTabView(selection: section ?? $ownSection, sections: TVTrackerModule.sections) { section in
            switch section.id {
            case "movies": MoviesListView()
            case "upnext": ScheduleView()
            case "settings": NavigationStack { TVSettingsView() }
            default: WatchingListView()
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
