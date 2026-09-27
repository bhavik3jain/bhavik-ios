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

    @State private var selection = ExploreTrackerModule.sections[0].id

    var body: some View {
        // One section, so the Mac sidebar never nests anything under Explore
        // and nobody outside needs to hold the selection.
        ModuleTabView(selection: $selection, sections: ExploreTrackerModule.sections) { _ in
            GuideListView()
        }
        .tint(ExploreTrackerModule.accent.color)
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
