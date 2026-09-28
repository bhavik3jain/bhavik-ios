#if os(macOS)
import SwiftUI

/// The Settings window (⌘,): the phone's Settings screen, and Customize
/// Trackers as a tab of its own rather than a row that pushes it — a Mac
/// settings window switches panes from its toolbar and has no back button.
/// General is the phone's screen itself, so "Apple Intelligence in Trips"
/// (`TripsIntelligenceSection`) is here with no Mac-only copy to keep in step.
struct MacSettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                NavigationStack {
                    AppSettingsView()
                }
            }
            Tab("Trackers", systemImage: "square.grid.2x2") {
                NavigationStack {
                    CustomizeTrackersView()
                }
            }
        }
        .formStyle(.grouped)
        // A settings window sizes to its content, and a scrolling Form has
        // none of its own to offer: without a frame it opens a sliver tall.
        .frame(width: 540, height: 640)
    }
}
#endif
