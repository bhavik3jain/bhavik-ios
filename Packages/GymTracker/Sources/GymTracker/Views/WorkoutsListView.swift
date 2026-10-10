import SwiftData
import Core
import SwiftUI

struct WorkoutsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Routine.createdAt) private var routines: [Routine]
    @Query(filter: #Predicate<WorkoutSession> { $0.finishedAt != nil }, sort: \WorkoutSession.startedAt, order: .reverse)
    private var pastSessions: [WorkoutSession]

    @State private var activeSession: WorkoutSession?
    @State private var showingNewRoutine = false
    @State private var openedSession: WorkoutSession?
    @Environment(\.moduleLayout) private var layout

    var body: some View {
        NavigationStack {
            // Starting a workout sits above the list rather than in it: it is
            // the reason for the screen, and a list row would put a grouped
            // background behind a control that is meant to float.
            Group {
            if layout == .sidebar {
                MacWorkoutsView(
                    routines: routines,
                    sessions: pastSessions,
                    start: startSession(from:),
                    open: { openedSession = $0 },
                    deleteRoutine: { modelContext.delete($0) },
                    deleteSession: { modelContext.delete($0) }
                )
            } else {
            VStack(spacing: 12) {
                Button {
                    startEmptyWorkout()
                } label: {
                    Label("Start Empty Workout", systemImage: "plus.circle.fill")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .primaryActionStyle(tint: GymTrackerModule.accent.color)
                .padding(.horizontal)

                List {
                Section("Routines") {
                    ForEach(routines) { routine in
                        Button {
                            startSession(from: routine)
                        } label: {
                            HStack {
                                Text(routine.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("^[\(routine.orderedExercises.count) exercise](inflect: true)")
                                    .foregroundStyle(.secondary)
                                    .font(.footnote)
                            }
                        }
                    }
                    .onDelete(perform: deleteRoutines)

                    Button {
                        showingNewRoutine = true
                    } label: {
                        Label("New Routine", systemImage: "plus")
                    }
                }

                if !pastSessions.isEmpty {
                    Section("History") {
                        ForEach(pastSessions.prefix(20)) { session in
                            NavigationLink {
                                SessionSummaryView(session: session)
                            } label: {
                                HStack {
                                    Text(session.name)
                                    Spacer()
                                    Text(session.startedAt, format: .dateTime.month().day())
                                        .foregroundStyle(.secondary)
                                        .font(.footnote)
                                }
                            }
                        }
                        .onDelete(perform: deleteSessions)
                    }
                }
                }
            }
            }
            }
            .navigationTitle("Workouts")
            .navigationDestination(item: $openedSession) { SessionSummaryView(session: $0) }
            .toolbar {
                if layout == .sidebar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New Routine", systemImage: "list.bullet.rectangle") { showingNewRoutine = true }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            startEmptyWorkout()
                        } label: {
                            Label("Start Workout", systemImage: "play.fill")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(GymTrackerModule.accent.color)
                    }
                }
            }
            .sheet(isPresented: $showingNewRoutine) {
                RoutineEditorView()
            }
            .fullScreenCover(item: $activeSession) { session in
                ActiveWorkoutView(session: session)
            }
        }
    }

    private func startEmptyWorkout() {
        let session = WorkoutSession(name: "Workout")
        modelContext.insert(session)
        activeSession = session
    }

    private func startSession(from routine: Routine) {
        let session = WorkoutSession(name: routine.name, routine: routine)
        modelContext.insert(session)

        var order = 0
        for routineExercise in routine.orderedExercises {
            for _ in 0..<routineExercise.targetSetCount {
                let set = WorkoutSet(weight: 0, reps: 0, order: order)
                set.exercise = routineExercise.exercise
                set.session = session
                modelContext.insert(set)
                order += 1
            }
        }
        activeSession = session
    }

    private func deleteRoutines(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(routines[index])
        }
    }

    /// History lists the newest 20, a prefix, so its offsets index `pastSessions`
    /// directly. The cascade takes the workout's sets with it, so Progress and an
    /// exercise's best set stop counting them; its routine stays.
    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(pastSessions[index])
        }
    }
}
