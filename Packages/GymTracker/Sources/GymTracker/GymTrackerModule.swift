import SwiftData
import SwiftUI
import Core

public enum GymTrackerModule {
    public static let accent = ModuleAccent(name: "Gym", color: Color(red: 1.0, green: 0.42, blue: 0.21))

    /// The white-on-accent symbol on the hub row, the Mac sidebar tile and
    /// its Overview card.
    public static let symbolName = "dumbbell.fill"

    /// Its tabs on the phone and, in the same order, the rows nested under it
    /// in the Mac sidebar. The first is where the module opens.
    public static let sections = [
        ModuleSection("workouts", title: "Workouts", systemImage: "dumbbell.fill"),
        ModuleSection("exercises", title: "Exercises", systemImage: "list.bullet"),
        ModuleSection("progress", title: "Progress", systemImage: "chart.line.uptrend.xyaxis"),
    ]

    /// The SwiftData model types owned by this module, for registering into the app's shared container.
    public static var models: [any PersistentModel.Type] {
        [Exercise.self, WorkoutSet.self, WorkoutSession.self, Routine.self, RoutineExercise.self]
    }

    /// `section` is the Mac sidebar's selection, which picks the section in
    /// place of a tab bar; leave it nil on the phone.
    @MainActor
    public static func rootView(section: Binding<String>? = nil) -> some View {
        GymRootView(section: section)
    }
}
