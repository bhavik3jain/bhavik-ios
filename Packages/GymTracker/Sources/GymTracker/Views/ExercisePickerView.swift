import Core // Only reached on macOS, where Core stands in for the iOS-only SwiftUI API below.
import SwiftData
import SwiftUI

struct ExercisePickerView: View {
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    let onPick: (Exercise) -> Void

    private var filtered: [Exercise] {
        guard !searchText.isEmpty else { return exercises }
        return exercises.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var grouped: [(MuscleGroup, [Exercise])] {
        Dictionary(grouping: filtered, by: \.muscleGroup)
            .sorted { $0.key.displayName < $1.key.displayName }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(grouped, id: \.0) { group, groupExercises in
                    Section(group.displayName) {
                        ForEach(groupExercises) { exercise in
                            Button {
                                onPick(exercise)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(exercise.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(exercise.equipment)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search exercises")
            .navigationTitle("Add Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
    }
}
