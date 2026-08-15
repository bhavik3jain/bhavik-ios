import SwiftData
import SwiftUI

struct ParcelRootView: View {
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        TabView {
            Tab("Parcels", systemImage: "shippingbox") {
                ParcelListView()
            }
            Tab("Settings", systemImage: "gear") {
                ParcelSettingsView()
            }
        }
        .tint(ParcelTrackerModule.accent.color)
        #if DEBUG
        .task {
            guard ParcelDebugSeed.isRequested else { return }
            ParcelDebugSeed.run(context: modelContext)
        }
        #endif
    }
}
