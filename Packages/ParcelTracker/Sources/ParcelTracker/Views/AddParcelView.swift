import SwiftData
import SwiftUI

struct AddParcelView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var trackingNumber = ""
    @State private var name = ""
    @State private var carrier: Carrier = .other
    @State private var hasEditedCarrier = false
    @FocusState private var isNumberFocused: Bool

    private var normalized: String { CarrierDetector.normalize(trackingNumber) }
    private var guess: CarrierDetector.Guess { CarrierDetector.detect(trackingNumber) }
    private var canSave: Bool { !normalized.isEmpty }

    /// Picking a carrier by hand stops detection from overriding the choice.
    /// Writing through a binding keeps that decision here, rather than trying
    /// to tell the reader's edits apart from ours inside an onChange.
    private var carrierSelection: Binding<String> {
        Binding(
            get: { carrier.rawValue },
            set: { newValue in
                carrier = Carrier(rawValue: newValue) ?? .other
                hasEditedCarrier = true
            }
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
                        .onChange(of: trackingNumber) { _, newValue in
                            // Follow the number until the reader picks a carrier
                            // themselves. Read the incoming value rather than the
                            // computed guess, which still reflects the old text.
                            guard !hasEditedCarrier else { return }
                            carrier = CarrierDetector.detect(newValue).carrier
                        }

                    TextField("What is it? (optional)", text: $name)
                } footer: {
                    if !normalized.isEmpty {
                        if guess.carrier == .other {
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
                    if !carrier.supportsAutomaticTracking, carrier != .other {
                        Text("\(carrier.displayName) stopped letting apps look up parcels they didn't ship, so this one won't refresh on its own. You can still keep it here and open \(carrier.displayName) to check on it.")
                    }
                }
            }
            .navigationTitle("Add Parcel")
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
