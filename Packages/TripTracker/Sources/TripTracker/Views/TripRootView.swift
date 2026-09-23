import Core
import SwiftData
import SwiftUI

/// One tab of the module's own. Everything else — a trip's days, map and codes —
/// lives inside a trip, so nothing here ever has to ask which trip you mean.
struct TripRootView: View {
    /// The module's own Core Data context — set by `TripTrackerModule.rootView(context:)`
    /// just above this view, so every descendant reading this same key gets it too.
    @Environment(\.managedObjectContext) private var context
    /// The app-wide SwiftData context, still attached at the WindowGroup level
    /// for Gym/TV/Orders — read here only so `TripLegacyMigration` has
    /// something to copy real trips out of.
    @Environment(\.modelContext) private var legacyContext
    @Environment(\.tripPersistentContainer) private var container

    @State private var selection = "trips"

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: ModuleTab.home) {
                Color.clear
            }
            Tab("Trips", systemImage: "suitcase", value: "trips") {
                TripListView()
            }
        }
        .tint(TripTrackerModule.accent.color)
        .minimizesTabBarOnScroll()
        .dismissesOnHomeTab($selection, restoringTo: "trips")
        .task {
            // The importer de-duplicates against this device's store only, so
            // it waits until that store has caught up with iCloud — otherwise
            // a second device re-copies what the first already exported. See
            // CloudKitImportGate.
            if !TripLegacyMigration.hasRun {
                guard await CloudKitImportGate.waitForFirstImport(of: container) else { return }
            }
            TripLegacyMigration.runIfNeeded(from: legacyContext, into: context)
            #if DEBUG
            guard TripDebugSeed.isRequested else { return }
            TripDebugSeed.run(context: context)
            #endif
        }
    }
}
