import Foundation
import SwiftData

public enum ExerciseSeed {
    /// (name, muscle group, equipment)
    public static let library: [(String, MuscleGroup, String)] = [
        // Chest
        ("Barbell Bench Press", .chest, "Barbell"),
        ("Incline Barbell Bench Press", .chest, "Barbell"),
        ("Decline Barbell Bench Press", .chest, "Barbell"),
        ("Dumbbell Bench Press", .chest, "Dumbbell"),
        ("Incline Dumbbell Press", .chest, "Dumbbell"),
        ("Dumbbell Fly", .chest, "Dumbbell"),
        ("Cable Crossover", .chest, "Cable"),
        ("Chest Dip", .chest, "Bodyweight"),
        ("Push-Up", .chest, "Bodyweight"),
        ("Machine Chest Press", .chest, "Machine"),
        ("Pec Deck", .chest, "Machine"),

        // Back
        ("Deadlift", .back, "Barbell"),
        ("Barbell Row", .back, "Barbell"),
        ("Pull-Up", .back, "Bodyweight"),
        ("Chin-Up", .back, "Bodyweight"),
        ("Lat Pulldown", .back, "Cable"),
        ("Seated Cable Row", .back, "Cable"),
        ("One-Arm Dumbbell Row", .back, "Dumbbell"),
        ("T-Bar Row", .back, "Barbell"),
        ("Face Pull", .back, "Cable"),
        ("Straight-Arm Pulldown", .back, "Cable"),
        ("Rack Pull", .back, "Barbell"),

        // Shoulders
        ("Overhead Press", .shoulders, "Barbell"),
        ("Seated Dumbbell Shoulder Press", .shoulders, "Dumbbell"),
        ("Arnold Press", .shoulders, "Dumbbell"),
        ("Lateral Raise", .shoulders, "Dumbbell"),
        ("Front Raise", .shoulders, "Dumbbell"),
        ("Rear Delt Fly", .shoulders, "Dumbbell"),
        ("Cable Lateral Raise", .shoulders, "Cable"),
        ("Upright Row", .shoulders, "Barbell"),
        ("Shrug", .shoulders, "Dumbbell"),
        ("Machine Shoulder Press", .shoulders, "Machine"),

        // Biceps
        ("Barbell Curl", .biceps, "Barbell"),
        ("Dumbbell Curl", .biceps, "Dumbbell"),
        ("Hammer Curl", .biceps, "Dumbbell"),
        ("Preacher Curl", .biceps, "Barbell"),
        ("Cable Curl", .biceps, "Cable"),
        ("Concentration Curl", .biceps, "Dumbbell"),
        ("Incline Dumbbell Curl", .biceps, "Dumbbell"),

        // Triceps
        ("Close-Grip Bench Press", .triceps, "Barbell"),
        ("Triceps Pushdown", .triceps, "Cable"),
        ("Overhead Triceps Extension", .triceps, "Dumbbell"),
        ("Skull Crusher", .triceps, "Barbell"),
        ("Triceps Dip", .triceps, "Bodyweight"),
        ("Cable Overhead Extension", .triceps, "Cable"),
        ("Diamond Push-Up", .triceps, "Bodyweight"),

        // Legs
        ("Barbell Back Squat", .legs, "Barbell"),
        ("Barbell Front Squat", .legs, "Barbell"),
        ("Leg Press", .legs, "Machine"),
        ("Romanian Deadlift", .legs, "Barbell"),
        ("Bulgarian Split Squat", .legs, "Dumbbell"),
        ("Walking Lunge", .legs, "Dumbbell"),
        ("Leg Extension", .legs, "Machine"),
        ("Leg Curl", .legs, "Machine"),
        ("Standing Calf Raise", .legs, "Machine"),
        ("Seated Calf Raise", .legs, "Machine"),
        ("Goblet Squat", .legs, "Dumbbell"),
        ("Hack Squat", .legs, "Machine"),

        // Glutes
        ("Hip Thrust", .glutes, "Barbell"),
        ("Glute Bridge", .glutes, "Barbell"),
        ("Cable Kickback", .glutes, "Cable"),
        ("Sumo Deadlift", .glutes, "Barbell"),
        ("Glute Machine", .glutes, "Machine"),

        // Core
        ("Plank", .core, "Bodyweight"),
        ("Hanging Leg Raise", .core, "Bodyweight"),
        ("Cable Crunch", .core, "Cable"),
        ("Russian Twist", .core, "Bodyweight"),
        ("Ab Wheel Rollout", .core, "Bodyweight"),
        ("Sit-Up", .core, "Bodyweight"),
        ("Weighted Crunch", .core, "Dumbbell"),

        // Full Body
        ("Clean and Jerk", .fullBody, "Barbell"),
        ("Snatch", .fullBody, "Barbell"),
        ("Kettlebell Swing", .fullBody, "Kettlebell"),
        ("Burpee", .fullBody, "Bodyweight"),
        ("Farmer's Carry", .fullBody, "Dumbbell"),
        ("Thruster", .fullBody, "Barbell")
    ]

    /// Inserts the seed exercises into the given context if no exercises exist yet.
    /// Safe to call on every launch — it's a no-op once seeding has happened.
    @MainActor
    public static func seedIfNeeded(context: ModelContext) {
        let descriptor = FetchDescriptor<Exercise>()
        let existingCount = (try? context.fetchCount(descriptor)) ?? 0
        guard existingCount == 0 else { return }

        for (name, muscleGroup, equipment) in library {
            let exercise = Exercise(name: name, muscleGroup: muscleGroup, equipment: equipment, isCustom: false)
            context.insert(exercise)
        }
    }
}
