import Foundation

/// Small facts about finished workouts, for summaries outside the module.
public enum WorkoutStats {
    /// Finished workouts that started within the last `days` days, today included.
    @MainActor
    public static func finishedCount(
        _ sessions: [WorkoutSession],
        inLast days: Int,
        asOf now: Date = .now,
        calendar: Calendar = .current
    ) -> Int {
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) else {
            return 0
        }
        return sessions.count { $0.finishedAt != nil && $0.startedAt >= start && $0.startedAt <= now }
    }

    /// "52 min", or "1 hr 5 min"; nil for a workout that never finished.
    @MainActor
    public static func durationText(for session: WorkoutSession) -> String? {
        guard let finished = session.finishedAt, finished > session.startedAt else { return nil }
        let minutes = Int(finished.timeIntervalSince(session.startedAt) / 60)
        let hours = minutes / 60
        return hours > 0 ? "\(hours) hr \(minutes % 60) min" : "\(minutes) min"
    }

    @MainActor
    public static func completedSetCount(for session: WorkoutSession) -> Int {
        (session.sets ?? []).count { $0.isCompleted }
    }
}
