import Foundation
import SwiftData
import Testing
@testable import GymTracker

@MainActor
private func makeContext() throws -> ModelContext {
    let schema = Schema(GymTrackerModule.models)
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return ModelContext(container)
}

@MainActor
@Test func seedingPopulatesLibraryOnceOnly() throws {
    let context = try makeContext()

    ExerciseSeed.seedIfNeeded(context: context)
    try context.save()
    let afterFirst = try context.fetchCount(FetchDescriptor<Exercise>())
    #expect(afterFirst == ExerciseSeed.library.count)

    ExerciseSeed.seedIfNeeded(context: context)
    try context.save()
    let afterSecond = try context.fetchCount(FetchDescriptor<Exercise>())
    #expect(afterSecond == afterFirst, "Seeding twice must not duplicate the library")
}

@MainActor
@Test func loggingSetsAttachesThemToSessionAndExercise() throws {
    let context = try makeContext()
    let exercise = Exercise(name: "Deadlift", muscleGroup: .back, equipment: "Barbell")
    let session = WorkoutSession(name: "Pull Day")
    context.insert(exercise)
    context.insert(session)

    for (index, reps) in [5, 5, 3].enumerated() {
        let set = WorkoutSet(weight: 225, reps: reps, order: index, isCompleted: true)
        set.exercise = exercise
        set.session = session
        context.insert(set)
    }
    try context.save()

    #expect(session.sets?.count == 3)
    #expect(exercise.sets?.count == 3)
    #expect(session.sets?.allSatisfy { $0.weight == 225 } == true)
}

@MainActor
@Test func finishingSessionMarksItInactive() throws {
    let context = try makeContext()
    let session = WorkoutSession(name: "Push Day")
    context.insert(session)

    #expect(session.isActive)
    session.finishedAt = .now
    try context.save()
    #expect(!session.isActive)
}

@MainActor
@Test func routineOrdersExercisesByPosition() throws {
    let context = try makeContext()
    let routine = Routine(name: "Push Day")
    context.insert(routine)

    let names = ["Bench Press", "Overhead Press", "Triceps Pushdown"]
    for (index, name) in names.enumerated().reversed() {
        let exercise = Exercise(name: name, muscleGroup: .chest, equipment: "Barbell")
        context.insert(exercise)
        let entry = RoutineExercise(order: index, exercise: exercise)
        entry.routine = routine
        context.insert(entry)
    }
    try context.save()

    #expect(routine.orderedExercises.map { $0.exercise?.name } == names)
}

@MainActor
@Test func deletingRoutineDoesNotDeleteLoggedSessions() throws {
    let context = try makeContext()
    let routine = Routine(name: "Legs")
    let session = WorkoutSession(name: "Legs", routine: routine)
    context.insert(routine)
    context.insert(session)
    try context.save()

    context.delete(routine)
    try context.save()

    let remaining = try context.fetchCount(FetchDescriptor<WorkoutSession>())
    #expect(remaining == 1, "Workout history must survive deleting the routine it came from")
    #expect(session.routine == nil)
}
