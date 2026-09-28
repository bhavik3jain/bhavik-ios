import Combine
import Core // Only reached on macOS, where Core stands in for the iOS-only SwiftUI API below.
import SwiftData
import SwiftUI

struct ActiveWorkoutView: View {
    @Bindable var session: WorkoutSession
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var elapsed: TimeInterval = 0
    @State private var showingExercisePicker = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var groupedSets: [(exercise: Exercise, sets: [WorkoutSet])] {
        let sets = session.sets ?? []
        var seen = [Exercise: [WorkoutSet]]()
        var order = [Exercise]()
        for set in sets.sorted(by: { $0.order < $1.order }) {
            guard let exercise = set.exercise else { continue }
            if seen[exercise] == nil { order.append(exercise) }
            seen[exercise, default: []].append(set)
        }
        return order.map { (exercise: $0, sets: seen[$0] ?? []) }
    }

    var body: some View {
        SheetStack {
            List {
                ForEach(groupedSets, id: \.exercise.persistentModelID) { group in
                    Section {
                        ExerciseSetGroup(exercise: group.exercise, sets: group.sets, session: session)
                    } header: {
                        Text(group.exercise.name)
                            .foregroundStyle(GymTrackerModule.accent.color)
                            .font(.headline)
                    }
                }

                Button {
                    showingExercisePicker = true
                } label: {
                    Label("Add Exercise", systemImage: "plus")
                }
            }
            .navigationTitle(session.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        modelContext.delete(session)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(elapsed.formattedDuration)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Finish") {
                        session.finishedAt = .now
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .tint(GymTrackerModule.accent.color)
                }
            }
            .sheet(isPresented: $showingExercisePicker) {
                ExercisePickerView { exercise in
                    addExercise(exercise)
                }
            }
            .onReceive(timer) { _ in
                elapsed = Date.now.timeIntervalSince(session.startedAt)
            }
        }
    }

    private func addExercise(_ exercise: Exercise) {
        let nextOrder = (session.sets ?? []).map(\.order).max().map { $0 + 1 } ?? 0
        let set = WorkoutSet(weight: 0, reps: 0, order: nextOrder)
        set.exercise = exercise
        set.session = session
        modelContext.insert(set)
    }
}

private struct ExerciseSetGroup: View {
    let exercise: Exercise
    let sets: [WorkoutSet]
    let session: WorkoutSession
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ForEach(Array(sets.enumerated()), id: \.element.persistentModelID) { index, set in
            SetRow(setNumber: index + 1, set: set)
        }

        Button {
            addSet()
        } label: {
            Label("Add Set", systemImage: "plus")
                .font(.subheadline)
        }
        .foregroundStyle(GymTrackerModule.accent.color)
    }

    private func addSet() {
        let nextOrder = (session.sets ?? []).map(\.order).max().map { $0 + 1 } ?? 0
        let newSet = WorkoutSet(weight: sets.last?.weight ?? 0, reps: sets.last?.reps ?? 0, order: nextOrder)
        newSet.exercise = exercise
        newSet.session = session
        modelContext.insert(newSet)
    }
}

private struct SetRow: View {
    let setNumber: Int
    @Bindable var set: WorkoutSet

    private enum Field: Hashable {
        case weight
        case reps
    }

    @FocusState private var focusedField: Field?
    @State private var weightText = ""
    @State private var repsText = ""

    var body: some View {
        HStack(spacing: 8) {
            Text("\(setNumber)")
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .leading)

            TextField("0", text: $weightText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .focused($focusedField, equals: .weight)
                .frame(width: 70)
                .padding(.vertical, 6)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))

            Text("×")
                .foregroundStyle(.secondary)

            TextField("0", text: $repsText)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .focused($focusedField, equals: .reps)
                .frame(width: 60)
                .padding(.vertical, 6)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))

            Spacer(minLength: 0)

            Button {
                focusedField = nil
                commitWeight()
                commitReps()
                set.isCompleted.toggle()
            } label: {
                Image(systemName: set.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(set.isCompleted ? GymTrackerModule.accent.color : .secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
        }
        .toolbar {
            if focusedField != nil {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                        .fontWeight(.semibold)
                }
            }
        }
        .onAppear(perform: syncFromModel)
        .onChange(of: focusedField) { previous, current in
            // Starting to edit a field clears it, so typing replaces rather than appends.
            switch current {
            case .weight: weightText = ""
            case .reps: repsText = ""
            case .none: break
            }
            // Leaving a field commits whatever was typed, falling back to the stored value.
            switch previous {
            case .weight: commitWeight()
            case .reps: commitReps()
            case .none: break
            }
        }
    }

    private func syncFromModel() {
        weightText = set.weight == 0 ? "" : set.weight.formatted()
        repsText = set.reps == 0 ? "" : "\(set.reps)"
    }

    private func commitWeight() {
        if let value = Double(weightText) {
            set.weight = value
        }
        weightText = set.weight == 0 ? "" : set.weight.formatted()
    }

    private func commitReps() {
        if let value = Int(repsText) {
            set.reps = value
        }
        repsText = set.reps == 0 ? "" : "\(set.reps)"
    }
}

private extension TimeInterval {
    var formattedDuration: String {
        let totalSeconds = Int(self)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
