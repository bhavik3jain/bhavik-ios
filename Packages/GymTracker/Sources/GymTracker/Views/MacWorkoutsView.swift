import Core
import SwiftData
import SwiftUI

/// Workouts on the Mac: how training's going as three figures, the routines as
/// cards you start from, and the history as a sortable table. Starting an
/// empty workout is the toolbar's prominent button — on the phone's layout it
/// was an orange bar the width of the window.
struct MacWorkoutsView: View {
    let routines: [Routine]
    let sessions: [WorkoutSession]
    let start: (Routine) -> Void
    let open: (WorkoutSession) -> Void
    let deleteRoutine: (Routine) -> Void

    @State private var sortOrder = [KeyPathComparator(\WorkoutSession.startedAt, order: .reverse)]
    @State private var selection: PersistentIdentifier?

    private var accent: Color { GymTrackerModule.accent.color }

    var body: some View {
        let calendar = Calendar.current
        let now = Date.now
        let thisWeek = sessions.count { calendar.isDate($0.startedAt, equalTo: now, toGranularity: .weekOfYear) }
        let thisMonth = sessions.count { calendar.isDate($0.startedAt, equalTo: now, toGranularity: .month) }
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                MacStatCard(title: "This week", value: String(thisWeek), detail: counted(thisWeek, "workout"), symbol: "flame.fill", tint: accent)
                MacStatCard(title: "This month", value: String(thisMonth), detail: counted(thisMonth, "workout"), symbol: "calendar", tint: accent)
                MacStatCard(
                    title: "Last workout",
                    value: sessions.first.map { $0.startedAt.formatted(.dateTime.month(.abbreviated).day()) } ?? "—",
                    detail: sessions.first.map { "\($0.name) · \($0.startedAt.formatted(.relative(presentation: .named)))" } ?? "Nothing logged yet",
                    symbol: "clock.fill",
                    tint: accent
                )
            }

            if !routines.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Routines")
                        .font(.title3.weight(.semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                        ForEach(routines) { routine in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(routine.name)
                                        .font(.headline)
                                    Text(counted(routine.orderedExercises.count, "exercise"))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Start") { start(routine) }
                                    .buttonStyle(.borderedProminent)
                                    .tint(accent)
                            }
                            .padding(14)
                            .background(.background.secondary, in: .rect(cornerRadius: 14))
                            .contextMenu {
                                Button("Delete Routine", systemImage: "trash", role: .destructive) { deleteRoutine(routine) }
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("History")
                    .font(.title3.weight(.semibold))
                Table(sessions.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Workout", value: \.name)
                    TableColumn("Date", value: \.startedAt) { session in
                        Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    TableColumn("Duration") { session in
                        Text(WorkoutStats.durationText(for: session) ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .alignment(.numeric)
                    TableColumn("Sets") { session in
                        Text(String(WorkoutStats.completedSetCount(for: session)))
                            .monospacedDigit()
                    }
                    .alignment(.numeric)
                }
                // No blank striped rows filling the space under the last one.
            .alternatingRowBackgrounds(.disabled)
            .contextMenu(forSelectionType: PersistentIdentifier.self) { _ in
                } primaryAction: { ids in
                    if let id = ids.first, let session = sessions.first(where: { $0.id == id }) { open(session) }
                }
                .frame(minHeight: 240)
            }
        }
        .padding(20)
    }
}
