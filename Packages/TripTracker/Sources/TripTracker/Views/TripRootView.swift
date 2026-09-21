import Core
import SwiftData
import SwiftUI

/// One tab of the module's own. Everything else — a trip's days, map and codes —
/// lives inside a trip, so nothing here ever has to ask which trip you mean.
struct TripRootView: View {
    @Environment(\.modelContext) private var modelContext

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
        #if DEBUG
        .task {
            guard TripDebugSeed.isRequested else { return }
            TripDebugSeed.run(context: modelContext)
        }
        #endif
    }
}
