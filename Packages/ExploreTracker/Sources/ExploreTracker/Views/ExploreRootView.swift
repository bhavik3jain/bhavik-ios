import Core
import CoreData
import SwiftData
import SwiftUI

struct ExploreRootView: View {
    /// The module's own Core Data context — set by `ExploreTrackerModule.rootView(context:)`
    /// just above this view, so every descendant reading this same key gets it too.
    @Environment(\.managedObjectContext) private var context
    /// The app-wide SwiftData context, still attached at the WindowGroup level
    /// for Gym/TV/Orders — read here only so `ExploreLegacyMigration` has
    /// something to copy real guides out of.
    @Environment(\.modelContext) private var legacyContext

    @State private var selection = "guides"

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: ModuleTab.home) {
                Color.clear
            }
            Tab("Guides", systemImage: "map", value: "guides") {
                GuideListView()
            }
        }
        .tint(ExploreTrackerModule.accent.color)
        .minimizesTabBarOnScroll()
        .dismissesOnHomeTab($selection, restoringTo: "guides")
        .task {
            ExploreLegacyMigration.runIfNeeded(from: legacyContext, into: context)
            #if DEBUG
            guard ExploreDebugSeed.isRequested else { return }
            ExploreDebugSeed.run(context: context)
            #endif
        }
    }
}
