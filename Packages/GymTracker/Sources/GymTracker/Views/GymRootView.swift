import SwiftData
import SwiftUI

struct GymRootView: View {
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        TabView {
            Tab("Workouts", systemImage: "dumbbell.fill") {
                WorkoutsListView()
            }
            Tab("Exercises", systemImage: "list.bullet") {
                ExercisesListView()
            }
            Tab("Progress", systemImage: "chart.line.uptrend.xyaxis") {
                ProgressOverviewView()
            }
        }
        .tint(GymTrackerModule.accent.color)
        .task {
            ExerciseSeed.seedIfNeeded(context: modelContext)
        }
    }
}
