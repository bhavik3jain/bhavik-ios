import Core
import CoreData
import SwiftUI

struct PointsRootView: View {
    /// The module's own Core Data context — set by `PointsTrackerModule.rootView(context:container:)`.
    @Environment(\.managedObjectContext) private var context
    @Environment(\.pointsPersistentContainer) private var container

    @State private var selection = "accounts"

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: ModuleTab.home) {
                Color.clear
            }
            Tab("Accounts", systemImage: "star.circle", value: "accounts") {
                AccountsListView()
            }
            Tab("People", systemImage: "person.2", value: "people") {
                OwnersListView()
            }
        }
        .tint(PointsTrackerModule.accent.color)
        .minimizesTabBarOnScroll()
        .dismissesOnHomeTab($selection, restoringTo: "accounts")
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
