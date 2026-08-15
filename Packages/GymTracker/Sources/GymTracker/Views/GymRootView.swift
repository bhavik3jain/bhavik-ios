import Core
import SwiftData
import SwiftUI

struct GymRootView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var selection = "workouts"

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: ModuleTab.home) {
                Color.clear
            }
            Tab("Workouts", systemImage: "dumbbell.fill", value: "workouts") {
                WorkoutsListView()
            }
            Tab("Exercises", systemImage: "list.bullet", value: "exercises") {
                ExercisesListView()
            }
            Tab("Progress", systemImage: "chart.line.uptrend.xyaxis", value: "progress") {
                ProgressOverviewView()
            }
        }
        .tint(GymTrackerModule.accent.color)
        .dismissesOnHomeTab($selection, restoringTo: "workouts")
        .task {
            ExerciseSeed.seedIfNeeded(context: modelContext)
        }
    }
}
