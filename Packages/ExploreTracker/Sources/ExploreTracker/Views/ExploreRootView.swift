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
    @Environment(\.explorePersistentContainer) private var container

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
            let pins = GuidePins(context: context, container: container)
            // Both steps only look at this device's store, so both wait until
            // it has caught up with iCloud: the importer so it can't re-copy
            // guides another device already exported, and the pin migration
            // so it can't re-pin a guide another device already migrated and
            // then unpinned. See CloudKitImportGate.
            if !ExploreLegacyMigration.hasRun || pins.hasRetiredPinsToMigrate() {
                guard await CloudKitImportGate.waitForFirstImport(of: container) else { return }
            }
            ExploreLegacyMigration.runIfNeeded(from: legacyContext, into: context)
            pins.migrateRetiredPinnedAt()
            #if DEBUG
            guard ExploreDebugSeed.isRequested else { return }
            ExploreDebugSeed.run(context: context)
            #endif
        }
    }
}
