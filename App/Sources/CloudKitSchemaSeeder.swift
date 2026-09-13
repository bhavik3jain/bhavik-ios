#if DEBUG
import Foundation
import FuelTracker
import GymTracker
import ParcelTracker
import SwiftData
import TVTracker

/// Creates one throwaway record of every model so CloudKit materialises the
/// complete schema.
///
/// CloudKit only creates a record type the first time a record of that type
/// syncs. A development schema built by using the app by hand therefore has
/// gaps: whatever you never got around to creating is simply absent, and it
/// stays absent in production, where nothing is ever created automatically.
/// The failure is quiet — those modules just don't sync.
///
/// Core Data's `initializeCloudKitSchema` exists for exactly this, but
/// SwiftData exposes no bridge to `NSManagedObjectModel`, so the only way to
/// materialise a type is still to sync a record of it. Hence seeding.
///
/// Run after any model change, let it sync, deploy the schema to production,
/// then purge:
///
///     -SeedCloudKitSchema YES     creates one record of every model
///     -PurgeCloudKitSchema YES    deletes them again
///
/// Debug-only, and inert unless one of those arguments is passed, so ordinary
/// debug runs are unaffected.
enum CloudKitSchemaSeeder {
    /// Written into a string field on every seeded record so the purge can find
    /// them again without going near anything real.
    static let marker = "__cloudkit-schema-seed__"

    static func runIfRequested(in context: ModelContext) {
        let defaults = UserDefaults.standard
        do {
            if defaults.bool(forKey: "SeedCloudKitSchema") {
                try seed(in: context)
                print("[CloudKitSchemaSeeder] Seeded every model. Let it sync, then deploy the schema to production.")
            } else if defaults.bool(forKey: "PurgeCloudKitSchema") {
                try purge(in: context)
                print("[CloudKitSchemaSeeder] Purged seeded records.")
            }
        } catch {
            print("[CloudKitSchemaSeeder] Failed: \(error)")
        }
    }

    /// One record per model, with every relationship wired, because a
    /// relationship only appears in the schema once a record actually carries
    /// it.
    private static func seed(in context: ModelContext) throws {
        // TV
        let show = Show(name: marker)
        let episode = Episode(name: marker, seasonNumber: 0, episodeNumber: 0)
        episode.show = show
        let movie = Movie(title: marker)

        // Gym
        let exercise = Exercise(name: marker, muscleGroup: .chest, equipment: marker, isCustom: true)
        let routine = Routine(name: marker)
        let routineExercise = RoutineExercise(order: 0, exercise: exercise)
        routineExercise.routine = routine
        let session = WorkoutSession(name: marker, routine: routine)
        let set = WorkoutSet(weight: 0, reps: 0, order: 0)
        set.session = session
        set.exercise = exercise

        // Fuel
        let vehicle = Vehicle(name: marker)
        let fuelEntry = FuelEntry(date: .now, odometer: 0, notes: marker)
        fuelEntry.vehicle = vehicle

        // Parcels
        let parcel = Parcel(trackingNumber: marker, name: marker, carrier: .other)
        let event = ParcelEvent(occurredAt: .now, detail: marker)
        event.parcel = parcel

        context.insert(show)
        context.insert(episode)
        context.insert(movie)
        context.insert(exercise)
        context.insert(routine)
        context.insert(routineExercise)
        context.insert(session)
        context.insert(set)
        context.insert(vehicle)
        context.insert(fuelEntry)
        context.insert(parcel)
        context.insert(event)

        try context.save()
    }

    private static func purge(in context: ModelContext) throws {
        let marker = Self.marker

        // WorkoutSet and RoutineExercise carry no string field to match on, so
        // they're reached through the marked parent that owns them. Deleting
        // them explicitly rather than leaning on the cascade rules keeps this
        // correct even if those rules change.
        for session in try context.fetch(
            FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.name == marker })
        ) {
            for set in session.sets ?? [] { context.delete(set) }
        }
        for routine in try context.fetch(
            FetchDescriptor<Routine>(predicate: #Predicate { $0.name == marker })
        ) {
            for link in routine.exercises ?? [] { context.delete(link) }
        }

        for episode in try context.fetch(
            FetchDescriptor<Episode>(predicate: #Predicate { $0.name == marker })
        ) { context.delete(episode) }
        for show in try context.fetch(
            FetchDescriptor<Show>(predicate: #Predicate { $0.name == marker })
        ) { context.delete(show) }
        for movie in try context.fetch(
            FetchDescriptor<Movie>(predicate: #Predicate { $0.title == marker })
        ) { context.delete(movie) }

        for session in try context.fetch(
            FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.name == marker })
        ) { context.delete(session) }
        for routine in try context.fetch(
            FetchDescriptor<Routine>(predicate: #Predicate { $0.name == marker })
        ) { context.delete(routine) }
        for exercise in try context.fetch(
            FetchDescriptor<Exercise>(predicate: #Predicate { $0.name == marker })
        ) { context.delete(exercise) }

        for entry in try context.fetch(
            FetchDescriptor<FuelEntry>(predicate: #Predicate { $0.notes == marker })
        ) { context.delete(entry) }
        for vehicle in try context.fetch(
            FetchDescriptor<Vehicle>(predicate: #Predicate { $0.name == marker })
        ) { context.delete(vehicle) }

        for event in try context.fetch(
            FetchDescriptor<ParcelEvent>(predicate: #Predicate { $0.detail == marker })
        ) { context.delete(event) }
        for parcel in try context.fetch(
            FetchDescriptor<Parcel>(predicate: #Predicate { $0.name == marker })
        ) { context.delete(parcel) }

        try context.save()
    }
}
#endif
