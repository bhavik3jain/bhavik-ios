import SwiftData
import SwiftUI

struct ProgressOverviewView: View {
    @Query(filter: #Predicate<WorkoutSession> { $0.finishedAt != nil }, sort: \WorkoutSession.startedAt, order: .reverse)
    private var sessions: [WorkoutSession]

    private var thisWeekCount: Int {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        return sessions.filter { $0.startedAt >= weekAgo }.count
    }

    private var mostTrainedExercises: [(Exercise, Int)] {
        var counts = [Exercise: Int]()
        for session in sessions {
            for set in session.sets ?? [] where set.isCompleted {
                guard let exercise = set.exercise else { continue }
                counts[exercise, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        StatTile(value: "\(sessions.count)", label: "Total workouts")
                        StatTile(value: "\(thisWeekCount)", label: "This week")
                    }
                    .listRowInsets(EdgeInsets())
                    .padding(.vertical, 8)
                }

                if !mostTrainedExercises.isEmpty {
                    Section("Most Trained") {
                        ForEach(mostTrainedExercises, id: \.0.persistentModelID) { exercise, count in
                            NavigationLink {
                                ExerciseProgressView(exercise: exercise)
                            } label: {
                                HStack {
                                    Text(exercise.name)
                                    Spacer()
                                    Text("^[\(count) set](inflect: true)")
                                        .foregroundStyle(.secondary)
                                        .font(.footnote)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Progress")
        }
    }
}

private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(GymTrackerModule.accent.color)
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 14))
    }
}
