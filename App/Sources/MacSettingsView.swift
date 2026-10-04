#if os(macOS)
import ParcelTracker
import SwiftUI
import TVTracker

/// The Settings window (⌘,): the phone's Settings screen, and Customize
/// Trackers as a tab of its own rather than a row that pushes it — a Mac
/// settings window switches panes from its toolbar and has no back button.
/// General is the phone's screen itself, so the Apple Intelligence switches
/// (`AppleIntelligenceSection`) and Finance reports are here with no Mac-only
/// copy to keep in step.
/// TV and Orders have their settings here too, as tabs: on the phone they're a
/// tab of the tracker, which on the Mac read as one of its screens.
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
            Tab("TV", systemImage: TVTrackerModule.symbolName) {
                TVTrackerModule.settingsView()
            }
            Tab("Orders", systemImage: ParcelTrackerModule.symbolName) {
                ParcelTrackerModule.settingsView()
            }
        }
        .formStyle(.grouped)
        // A settings window sizes to its content, and a scrolling Form has
        // none of its own to offer: without a frame it opens a sliver tall.
        .frame(width: 540, height: 640)
    }
}
#endif
