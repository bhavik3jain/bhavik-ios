import Core // Only reached on macOS, where Core stands in for the iOS-only SwiftUI API below.
import SwiftData
import SwiftUI

struct ExercisesListView: View {
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    @State private var showingNewExercise = false

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
                            NavigationLink {
                                ExerciseProgressView(exercise: exercise)
                            } label: {
                                HStack {
                                    Text(exercise.name)
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
            .navigationTitle("Exercises")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNewExercise = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNewExercise) {
                NewExerciseView()
            }
        }
    }
}

private struct NewExerciseView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var name = ""
    @State private var muscleGroup: MuscleGroup = .fullBody
    @State private var equipment = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Muscle Group", selection: $muscleGroup) {
                    ForEach(MuscleGroup.allCases, id: \.self) { group in
                        Text(group.displayName).tag(group)
                    }
                }
                TextField("Equipment", text: $equipment)
            }
            .navigationTitle("New Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let exercise = Exercise(name: name, muscleGroup: muscleGroup, equipment: equipment, isCustom: true)
                        modelContext.insert(exercise)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
