import Core
import SwiftData
import SwiftUI

struct ExploreRootView: View {
    @Environment(\.modelContext) private var modelContext

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
        #if DEBUG
        .task {
            guard ExploreDebugSeed.isRequested else { return }
            ExploreDebugSeed.run(context: modelContext)
        }
        #endif
    }
}
