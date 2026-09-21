import Core
import SwiftUI

public extension GymTrackerModule {
    /// What long-pressing Gym on the home screen shows: the week so far and the
    /// last few workouts. Expects finished sessions, newest first — the order
    /// `HomeView` already queries them in.
    @MainActor
    static func homePeek(sessions: [WorkoutSession]) -> some View {
        GymHomePeek(sessions: sessions)
    }
}

struct GymHomePeek: View {
    let sessions: [WorkoutSession]

    var body: some View {
        ModulePeekCard(
            accent: GymTrackerModule.accent,
            icon: "dumbbell.fill",
            subtitle: sessions.isEmpty ? "" : "\(counted(WorkoutStats.finishedCount(sessions, inLast: 7), "workout")) in the last 7 days"
        ) {
            if sessions.isEmpty {
                PeekEmpty("No workouts yet.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(sessions.prefix(3)) { session in
                        PeekRow(
                            session.name.isEmpty ? "Workout" : session.name,
                            detail: detail(for: session),
                            value: counted(WorkoutStats.completedSetCount(for: session), "set"),
                            tint: GymTrackerModule.accent.color
                        )
                    }
                }
            }
        }
    }

    private func detail(for session: WorkoutSession) -> String {
        let when = session.startedAt.formatted(.relative(presentation: .named))
        guard let duration = WorkoutStats.durationText(for: session) else { return when }
        return "\(when) · \(duration)"
    }
}
