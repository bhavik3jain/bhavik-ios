import Foundation
import SwiftData

@Model
public final class WorkoutSet {
    public var weight: Double = 0
    public var reps: Int = 0
    public var order: Int = 0
    public var isCompleted: Bool = false

    public var exercise: Exercise?
    public var session: WorkoutSession?

    public init(weight: Double, reps: Int, order: Int, isCompleted: Bool = false) {
        self.weight = weight
        self.reps = reps
        self.order = order
        self.isCompleted = isCompleted
    }
}
