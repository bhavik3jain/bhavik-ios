import Core // Only reached on macOS, where Core stands in for the iOS-only SwiftUI API below.
import CoreData
import SwiftUI

struct AddFillUpView: View {
    let vehicle: Vehicle

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var modelContext

    @State private var date = Date.now
    @State private var odometerText = ""
    @State private var gallonsText = ""
    @State private var priceText = ""
    @State private var totalText = ""
    @State private var isFullTank = true
    @State private var station = ""
    @FocusState private var isFieldFocused: Bool

    private var odometer: Int? { Int(odometerText.filter(\.isNumber)) }
    private var gallons: Double? { Double(gallonsText) }
    private var pricePerGallon: Double? { Double(priceText) }
    private var total: Double? { Double(totalText) }

    private var lastOdometer: Int? {
        vehicle.orderedFillUps.last?.odometer
    }

    private var canSave: Bool {
        guard let odometer, odometer > 0 else { return false }
        return gallons != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: [.date, .hourAndMinute])

                    LabeledContent("Odometer") {
                        TextField(lastOdometer.map { "\($0)" } ?? "Miles", text: $odometerText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .focused($isFieldFocused)
                    }

                    LabeledContent("Gallons") {
                        TextField("0.00", text: $gallonsText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .focused($isFieldFocused)
                            .onChange(of: gallonsText) { _, _ in recalculateTotal() }
                    }

                    LabeledContent("Price / gal") {
                        TextField("0.000", text: $priceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .focused($isFieldFocused)
                            .onChange(of: priceText) { _, _ in recalculateTotal() }
                    }

                    LabeledContent("Total") {
                        TextField("0.00", text: $totalText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .focused($isFieldFocused)
                    }
                } footer: {
                    if let odometer, let previous = lastOdometer, odometer <= previous {
                        Label(
                            "That reading is at or below the previous fill-up at \(previous.formatted()) mi.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                    }
                }

                Section {
                    Toggle("Filled the tank", isOn: $isFullTank)
                    TextField("Station", text: $station)
                        .focused($isFieldFocused)
                } footer: {
                    if !isFullTank {
                        Text("Partial fills don't get their own MPG — the fuel counts toward the next full tank.")
                    }
                }
            }
            .navigationTitle("New Fill-up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
                if isFieldFocused {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { isFieldFocused = false }
                            .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    /// Keeps total in step with gallons × price until the total is edited directly.
    private func recalculateTotal() {
        guard let gallons, let pricePerGallon else { return }
        totalText = (gallons * pricePerGallon).formatted(.number.precision(.fractionLength(2)))
    }

    private func save() {
        guard let odometer else { return }
        let entry = FuelEntry(
            context: modelContext,
            date: date,
            odometer: odometer,
            gallons: gallons ?? 0,
            pricePerGallon: pricePerGallon ?? 0,
            totalCost: total ?? 0,
            isFullTank: isFullTank,
            station: station
        )
        entry.vehicle = vehicle
        try? modelContext.saveIfNeeded()
        dismiss()
    }
}
