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

    /// One entry per day of the calendar week containing `now`, first weekday
    /// first, saying whether a finished workout started on it — the Mac
    /// Overview's row of dots. The week follows the calendar's own first
    /// weekday, so it reads M…S or S…S the way the person's calendar does.
    @MainActor
    public static func weekTrained(
        _ sessions: [WorkoutSession],
        asOf now: Date = .now,
        calendar: Calendar = .current
    ) -> [(day: Date, trained: Bool)] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return [] }
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: week.start) else { return nil }
            let trained = sessions.contains {
                $0.finishedAt != nil && calendar.isDate($0.startedAt, inSameDayAs: day)
            }
            return (day, trained)
        }
    }
}
