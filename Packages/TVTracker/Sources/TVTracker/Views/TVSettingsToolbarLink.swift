import Core
import SwiftUI

/// TV's settings on the phone: a gear at the leading edge of a library
/// screen's navigation bar, pushing `TVSettingsView` onto that screen's stack.
///
/// They used to be a tab, until the Lists tab made the bar six wide and iOS
/// hid Lists and Settings behind "More" (see `TVTrackerModule.sections`). In
/// the Mac's sidebar layout there's no gear: TV's settings are a tab of the
/// Settings window (⌘,) there, and a second way in beside the toolbar's
/// section switcher would only crowd it.
struct TVSettingsToolbarLink: ToolbarContent {
    let layout: ModuleLayout

    var body: some ToolbarContent {
        if layout == .tabs {
            ToolbarItem(placement: .navigation) {
                NavigationLink {
                    TVSettingsView()
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("TV Settings")
            }
        }
    }
}
