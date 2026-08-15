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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        startEmptyWorkout()
                    } label: {
                        Label("Start Empty Workout", systemImage: "plus.circle.fill")
                            .fontWeight(.semibold)
                    }
                    .listRowBackground(GymTrackerModule.accent.color)
                    .foregroundStyle(.white)
                }

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
                    }
                }
            }
            .navigationTitle("Workouts")
            .moduleChrome(accent: GymTrackerModule.accent)
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
}
