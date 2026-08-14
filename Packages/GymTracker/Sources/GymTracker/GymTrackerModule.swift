import SwiftData
import SwiftUI
import Core

public enum GymTrackerModule {
    public static let accent = ModuleAccent(name: "Gym", color: Color(red: 1.0, green: 0.42, blue: 0.21))

    /// The SwiftData model types owned by this module, for registering into the app's shared container.
    public static var models: [any PersistentModel.Type] {
        [Exercise.self, WorkoutSet.self, WorkoutSession.self, Routine.self, RoutineExercise.self]
    }

    @MainActor
    public static func rootView() -> some View {
        GymRootView()
    }
}
