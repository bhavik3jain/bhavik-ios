import Core
import SwiftData
import SwiftUI

struct ParcelRootView: View {
    @Environment(\.modelContext) private var modelContext

    /// The Mac sidebar's own selection when it picks the section; nil on the
    /// phone, where the tab bar's selection below does.
    var section: Binding<String>?
    @State private var ownSection = ParcelTrackerModule.sections[0].id

    var body: some View {
        ModuleTabView(selection: section ?? $ownSection, sections: ParcelTrackerModule.sections) { section in
            switch section.id {
            case "settings": ParcelSettingsView()
            default: ParcelListView()
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
