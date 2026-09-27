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
            VStack(alignment: .leading, spacing: 4) {
                if let last = sessions.first {
                    OverviewValue(last.startedAt.formatted(.relative(presentation: .named, unitsStyle: .wide)))
                    Text("Last workout")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else {
                    OverviewValue("No workouts")
                    Text("Start one from Workouts")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                week
            }
        }
    }

    private var week: some View {
        let days = WorkoutStats.weekTrained(sessions, asOf: now)
        return HStack(spacing: 6) {
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
