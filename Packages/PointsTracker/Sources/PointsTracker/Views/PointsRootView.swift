import Core
import CoreData
import SwiftUI

struct PointsRootView: View {
    /// The module's own Core Data context — set by `PointsTrackerModule.rootView(context:container:)`.
    @Environment(\.managedObjectContext) private var context
    @Environment(\.pointsPersistentContainer) private var container

    /// The Mac sidebar's own selection when it picks the section; nil on the
    /// phone, where the tab bar's selection below does.
    var section: Binding<String>?
    @State private var ownSection = PointsTrackerModule.sections[0].id

    var body: some View {
        ModuleTabView(selection: section ?? $ownSection, sections: PointsTrackerModule.sections) { section in
            switch section.id {
            case "people": OwnersListView()
            default: AccountsListView()
            }
        }
        .tint(PointsTrackerModule.accent.color)
        #if DEBUG
        .task {
            guard PointsDebugSeed.isRequested else { return }
            // Waits for iCloud like Fuel's importer does, so a seeded second
            // device doesn't mint a household of its own before the first
            // device's has arrived.
            guard await CloudKitImportGate.waitForFirstImport(of: container) else { return }
            PointsDebugSeed.run(context: context, container: container)
        }
        #endif
    }
}
