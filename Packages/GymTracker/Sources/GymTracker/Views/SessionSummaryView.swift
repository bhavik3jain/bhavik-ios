import Core // Only reached on macOS, where Core stands in for the iOS-only SwiftUI API below.
import SwiftData
import SwiftUI

struct SessionSummaryView: View {
    let session: WorkoutSession

    private var groupedSets: [(exercise: Exercise, sets: [WorkoutSet])] {
        let sets = (session.sets ?? []).sorted { $0.order < $1.order }
        var seen = [Exercise: [WorkoutSet]]()
        var order = [Exercise]()
        for set in sets {
            guard let exercise = set.exercise else { continue }
            if seen[exercise] == nil { order.append(exercise) }
            seen[exercise, default: []].append(set)
        }
        return order.map { (exercise: $0, sets: seen[$0] ?? []) }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text(session.startedAt, format: .dateTime.month().day().year())
                    Spacer()
                    if let finishedAt = session.finishedAt {
                        Text(finishedAt.timeIntervalSince(session.startedAt).formattedDuration)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            }

            ForEach(groupedSets, id: \.exercise.persistentModelID) { group in
                Section(group.exercise.name) {
                    ForEach(Array(group.sets.enumerated()), id: \.element.persistentModelID) { index, set in
                        HStack {
                            Text("\(index + 1)")
                                .foregroundStyle(.secondary)
                                .frame(width: 20, alignment: .leading)
                            Text("\(set.weight.formatted()) × \(set.reps)")
                                .monospacedDigit()
                            Spacer()
                            if set.isCompleted {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(GymTrackerModule.accent.color)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension TimeInterval {
    var formattedDuration: String {
        let totalMinutes = Int(self) / 60
        return "\(totalMinutes) min"
    }
}
