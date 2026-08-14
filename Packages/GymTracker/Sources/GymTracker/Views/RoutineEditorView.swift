import SwiftData
import SwiftUI

struct RoutineEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var selectedExercises: [Exercise] = []
    @State private var showingExercisePicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Routine Name", text: $name)
                }

                Section("Exercises") {
                    ForEach(selectedExercises) { exercise in
                        Text(exercise.name)
                    }
                    .onDelete { offsets in
                        selectedExercises.remove(atOffsets: offsets)
                    }
                    .onMove { source, destination in
                        selectedExercises.move(fromOffsets: source, toOffset: destination)
                    }

                    Button {
                        showingExercisePicker = true
                    } label: {
                        Label("Add Exercise", systemImage: "plus")
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    EditButton()
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveRoutine()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || selectedExercises.isEmpty)
                }
            }
            .navigationTitle("New Routine")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingExercisePicker) {
                ExercisePickerView { exercise in
                    if !selectedExercises.contains(exercise) {
                        selectedExercises.append(exercise)
                    }
                }
            }
        }
    }

    private func saveRoutine() {
        let routine = Routine(name: name)
        modelContext.insert(routine)
        for (index, exercise) in selectedExercises.enumerated() {
            let routineExercise = RoutineExercise(order: index, exercise: exercise)
            routineExercise.routine = routine
            modelContext.insert(routineExercise)
        }
    }
}
