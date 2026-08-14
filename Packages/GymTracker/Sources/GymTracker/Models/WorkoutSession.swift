import Foundation
import SwiftData

@Model
public final class WorkoutSession {
    public var name: String = ""
    public var startedAt: Date = Date.now
    public var finishedAt: Date?
    public var routine: Routine?

    @Relationship(deleteRule: .cascade, inverse: \WorkoutSet.session)
    public var sets: [WorkoutSet]? = []

    public var isActive: Bool { finishedAt == nil }

    public init(name: String, startedAt: Date = .now, routine: Routine? = nil) {
        self.name = name
        self.startedAt = startedAt
        self.routine = routine
    }
}
