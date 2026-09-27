import Core
import SwiftData
import SwiftUI

struct GymRootView: View {
    @Environment(\.modelContext) private var modelContext

    /// The Mac sidebar's own selection when it picks the section; nil on the
    /// phone, where the tab bar's selection below does.
    var section: Binding<String>?
    @State private var ownSection = GymTrackerModule.sections[0].id

    var body: some View {
        ModuleTabView(selection: section ?? $ownSection, sections: GymTrackerModule.sections) { section in
            switch section.id {
            case "exercises": ExercisesListView()
            case "progress": ProgressOverviewView()
            default: WorkoutsListView()
            }
        }
        .tint(GymTrackerModule.accent.color)
        .task {
            ExerciseSeed.seedIfNeeded(context: modelContext)
        }
    }
}
