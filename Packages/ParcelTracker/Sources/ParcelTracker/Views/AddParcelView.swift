import Core // Only reached on macOS, where Core stands in for the iOS-only SwiftUI API below.
import SwiftData
import SwiftUI

struct AddParcelView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var trackingNumber = ""
    @State private var name = ""
    @State private var choice = CarrierChoice()
    @FocusState private var isNumberFocused: Bool

    private var normalized: String { CarrierDetector.normalize(trackingNumber) }
    private var guess: CarrierDetector.Guess { CarrierDetector.detect(trackingNumber) }
    private var carrier: Carrier { choice.resolved(for: trackingNumber) }
    private var canSave: Bool { !normalized.isEmpty }

    private var carrierSelection: Binding<String> {
        Binding(
            get: { carrier.rawValue },
            set: { choice.choose(Carrier(rawValue: $0) ?? .other, whileShowing: carrier) }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Tracking number", text: $trackingNumber, axis: .vertical)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($isNumberFocused)

                    TextField("What is it? (optional)", text: $name)
                } footer: {
                    if !normalized.isEmpty {
                        if choice.isManual {
                            Text("Set to \(carrier.displayName).")
                        } else if guess.carrier == .other {
                            Text("That number isn't a format this app recognises. Pick a carrier below if you know it.")
                        } else if guess.isCertain {
                            Text("Looks like \(guess.carrier.displayName).")
                        } else {
                            Text("Best guess is \(guess.carrier.displayName) — change it below if that's wrong.")
                        }
                    }
                }

                Section {
                    Picker("Carrier", selection: carrierSelection) {
                        ForEach(Carrier.allCases, id: \.rawValue) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                } footer: {
                    if let reason = carrier.manualTrackingReason {
                        Text(reason)
                    }
                }
            }
            .navigationTitle("Add Order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: save)
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
                if isNumberFocused {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { isNumberFocused = false }
                            .fontWeight(.semibold)
                    }
                }
            }
            .onAppear { isNumberFocused = true }
        }
    }

    private func save() {
        let parcel = Parcel(
            trackingNumber: normalized,
            name: name.trimmingCharacters(in: .whitespaces),
            carrier: carrier
        )
        parcel.status = .pending
        modelContext.insert(parcel)
        dismiss()
    }
}
