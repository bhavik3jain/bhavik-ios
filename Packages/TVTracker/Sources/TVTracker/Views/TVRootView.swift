import SwiftData
import SwiftUI

struct TVRootView: View {
    var body: some View {
        TabView {
            Tab("Watching", systemImage: "tv") {
                WatchingListView()
            }
            Tab("Up Next", systemImage: "calendar") {
                ScheduleView()
            }
            Tab("Stats", systemImage: "chart.bar") {
                TVStatsView()
            }
        }
        .tint(TVTrackerModule.accent.color)
    }
}
