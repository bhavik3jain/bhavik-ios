import Charts
import Core // Only reached on macOS, where Core stands in for the iOS-only SwiftUI API below.
import SwiftData
import SwiftUI

struct ExerciseProgressView: View {
    let exercise: Exercise

    private var completedSets: [WorkoutSet] {
        (exercise.sets ?? [])
            .filter { $0.isCompleted && $0.session?.finishedAt != nil }
            .sorted { ($0.session?.startedAt ?? .distantPast) < ($1.session?.startedAt ?? .distantPast) }
    }

    private var sessionGroups: [(date: Date, sets: [WorkoutSet])] {
        let grouped = Dictionary(grouping: completedSets) { set in
            Calendar.current.startOfDay(for: set.session?.startedAt ?? .now)
        }
        return grouped
            .map { (date: $0.key, sets: $0.value) }
            .sorted { $0.date > $1.date }
    }

    private var bestSet: WorkoutSet? {
        completedSets.max { $0.weight < $1.weight }
    }

    var body: some View {
        List {
            if let bestSet {
                Section {
                    HStack {
                        Text("Best set")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(bestSet.weight.formatted()) × \(bestSet.reps)")
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }

                    if completedSets.count > 1 {
                        Chart(sessionGroups.reversed(), id: \.date) { group in
                            let topSet = group.sets.max { $0.weight < $1.weight }
                            LineMark(
                                x: .value("Date", group.date),
                                y: .value("Weight", topSet?.weight ?? 0)
                            )
                            .foregroundStyle(GymTrackerModule.accent.color)
                            .symbol(Circle())
                        }
                        .frame(height: 140)
                        .padding(.vertical, 8)
                    }
                }
            }

            Section("History") {
                if sessionGroups.isEmpty {
                    Text("No completed sets yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sessionGroups, id: \.date) { group in
                        HStack(alignment: .top) {
                            Text(group.date, format: .dateTime.month().day())
                                .foregroundStyle(.secondary)
                                .frame(width: 50, alignment: .leading)
                            Text(group.sets.map { "\($0.weight.formatted())×\($0.reps)" }.joined(separator: ", "))
                                .font(.subheadline)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
