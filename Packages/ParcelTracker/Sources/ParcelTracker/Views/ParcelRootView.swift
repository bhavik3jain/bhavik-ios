import Core
import SwiftData
import SwiftUI

struct ParcelRootView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var selection = "parcels"

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: ModuleTab.home) {
                Color.clear
            }
            Tab("Orders", systemImage: "shippingbox", value: "parcels") {
                ParcelListView()
            }
            Tab("Settings", systemImage: "gear", value: "settings") {
                ParcelSettingsView()
            }
        }
        .tint(ParcelTrackerModule.accent.color)
        .minimizesTabBarOnScroll()
        .dismissesOnHomeTab($selection, restoringTo: "parcels")
        #if DEBUG
        .task {
            guard ParcelDebugSeed.isRequested else { return }
            ParcelDebugSeed.run(context: modelContext)
        }
        #endif
    }
}
