import SwiftData
import SwiftUI

struct ParcelRootView: View {
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
    }
}
