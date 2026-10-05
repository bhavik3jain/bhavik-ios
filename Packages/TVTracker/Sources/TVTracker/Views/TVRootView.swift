import Core
import CoreData
import SwiftData
import SwiftUI

struct TVRootView: View {
    @Environment(\.modelContext) private var modelContext
    /// The watch-list store's — see `TVTrackerModule.rootView(context:container:section:)`.
    @Environment(\.managedObjectContext) private var listContext
    @Environment(\.tvListPersistentContainer) private var listContainer
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
            case "lists": WatchListsView()
            default: WatchingListView()
            }
        }
        .tint(TVTrackerModule.accent.color)
        .modifier(EpisodeAlertsRoot(section: section ?? $ownSection))
        #if DEBUG
        .task {
            guard DebugSeed.isRequested else { return }
            await DebugSeed.run(context: modelContext, apiKey: apiKey)
        }
        .task {
            guard WatchListDebugSeed.isRequested else { return }
            // Waits for iCloud like Points' seed, so a seeded second device
            // doesn't start lists of its own before the first one's arrive.
            guard await CloudKitImportGate.waitForFirstImport(of: listContainer) else { return }
            WatchListDebugSeed.run(context: listContext)
        }
        #endif
    }
}
