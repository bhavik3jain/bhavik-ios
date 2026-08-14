import Foundation
import SwiftData

@Model
public final class Routine {
    public var name: String = ""
    public var createdAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \RoutineExercise.routine)
    public var exercises: [RoutineExercise]? = []

    @Relationship(deleteRule: .nullify, inverse: \WorkoutSession.routine)
    public var sessions: [WorkoutSession]? = []

    public init(name: String) {
        self.name = name
        self.createdAt = .now
    }

    public var orderedExercises: [RoutineExercise] {
        (exercises ?? []).sorted { $0.order < $1.order }
    }
}

@Model
public final class RoutineExercise {
    public var order: Int = 0
    public var targetSetCount: Int = 3

    public var routine: Routine?
    public var exercise: Exercise?

    public init(order: Int, targetSetCount: Int = 3, exercise: Exercise? = nil) {
        self.order = order
        self.targetSetCount = targetSetCount
        self.exercise = exercise
    }
}
