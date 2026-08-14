import Foundation
import SwiftData

@Model
public final class Exercise {
    public var name: String = ""
    public var muscleGroupRaw: String = MuscleGroup.fullBody.rawValue
    public var equipment: String = ""
    public var isCustom: Bool = false
    public var createdAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \WorkoutSet.exercise)
    public var sets: [WorkoutSet]? = []

    @Relationship(deleteRule: .cascade, inverse: \RoutineExercise.exercise)
    public var routineAppearances: [RoutineExercise]? = []

    public var muscleGroup: MuscleGroup {
        get { MuscleGroup(rawValue: muscleGroupRaw) ?? .fullBody }
        set { muscleGroupRaw = newValue.rawValue }
    }

    public init(name: String, muscleGroup: MuscleGroup, equipment: String, isCustom: Bool = false) {
        self.name = name
        self.muscleGroupRaw = muscleGroup.rawValue
        self.equipment = equipment
        self.isCustom = isCustom
        self.createdAt = .now
    }
}
