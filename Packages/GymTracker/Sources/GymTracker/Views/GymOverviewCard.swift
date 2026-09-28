import Core
import SwiftUI

public extension GymTrackerModule {
    /// The Mac Overview's Gym card: how long since the last workout, and this
    /// week's training days as a row of dots. Expects finished sessions,
    /// newest first — the order `HomeView` already queries them in.
    @MainActor
    static func overviewCard(sessions: [WorkoutSession], asOf now: Date = .now, open: @escaping () -> Void) -> some View {
        GymOverviewCard(sessions: sessions, now: now, open: open)
    }
}

struct GymOverviewCard: View {
    let sessions: [WorkoutSession]
    let now: Date
    let open: () -> Void

    var body: some View {
        OverviewCard(accent: GymTrackerModule.accent, icon: GymTrackerModule.symbolName, open: open) {
            if let last = sessions.first {
                let days = WorkoutStats.weekTrained(sessions, asOf: now)
                let trained = days.count { $0.trained }
                let lastWorkout = last.startedAt.formatted(.relative(presentation: .named, unitsStyle: .wide))
                VStack(alignment: .leading, spacing: 4) {
                    // This week's count once there is one; before that, a
                    // bold "0" said less than how long it has been.
                    if trained > 0 {
                        OverviewValue(String(trained), unit: trained == 1 ? "day this week" : "days this week")
                        OverviewCaption("Last workout \(lastWorkout)")
                    } else {
                        OverviewValue(lastWorkout)
                        OverviewCaption("Last workout · none yet this week")
                    }
                    Spacer(minLength: 10)
                    week(days)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    OverviewEmptyState("No workouts yet", message: "Start one from Workouts.")
                    Spacer(minLength: 10)
                    week(WorkoutStats.weekTrained(sessions, asOf: now))
                }
            }
        }
    }

    private func week(_ days: [(day: Date, trained: Bool)]) -> some View {
        HStack(spacing: 6) {
            ForEach(days, id: \.day) { entry in
                VStack(spacing: 4) {
                    Circle()
                        .fill(entry.trained ? AnyShapeStyle(GymTrackerModule.accent.color) : AnyShapeStyle(.fill.secondary))
                        .frame(width: 14, height: 14)
                    Text(entry.day, format: .dateTime.weekday(.narrow))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(entry.day.formatted(.dateTime.weekday(.wide))), \(entry.trained ? "trained" : "rest")")
            }
        }
    }
}
