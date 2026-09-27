import Core
import CoreData
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
    @Environment(\.moduleLayout) private var layout

    /// The trip the Mac sidebar has open, and on which face. Nil on the phone,
    /// where the list pushes a trip itself.
    var trip: Binding<NSManagedObjectID?>?
    var tripSection: Binding<TripSection>?

    @State private var selection = TripTrackerModule.sections[0].id

    /// The sidebar's trip, while it still exists — one deleted here or on
    /// another device drops back to the list rather than showing a husk.
    private var openTrip: SharedTrip? {
        guard let id = trip?.wrappedValue,
              let object = try? context.existingObject(with: id) as? SharedTrip,
              !object.isDeleted
        else { return nil }
        return object
    }

    var body: some View {
        // One section — the trips themselves nest under Trips in the Mac
        // sidebar instead of sections.
        ModuleTabView(selection: $selection, sections: TripTrackerModule.sections) { _ in
            if layout == .sidebar, let openTrip {
                NavigationStack {
                    TripDetailView(trip: openTrip, section: tripSection)
                }
                // A fresh identity per trip, so its selected day and weather
                // don't carry over into the next one picked in the sidebar.
                .id(openTrip.objectID)
            } else if layout == .sidebar, let trip {
                TripListView { trip.wrappedValue = $0.objectID }
            } else {
                TripListView()
            }
        }
        .tint(TripTrackerModule.accent.color)
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
