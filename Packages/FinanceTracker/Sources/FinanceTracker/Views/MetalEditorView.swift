import Core
import CoreData
import SwiftUI

/// Adds a piece of gold or silver, or edits one. Weight can be typed in grams
/// or regular ounces (the ones `MetalValuation` values in); it's always stored
/// in grams.
struct MetalEditorView: View {
    let item: SharedFinanceMetalItem?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @Environment(\.financePersistentContainer) private var container
    var data = FinanceFetches()

    private enum WeightUnit: String, CaseIterable, Identifiable {
        case grams = "g"
        case ounces = "oz"
        var id: String { rawValue }
    }

    @State private var metal = MetalKind.gold
    @State private var name = ""
    @State private var weightText = ""
    @State private var unit = WeightUnit.grams
    @State private var pricePaidText = ""
    @State private var purchaseValueText = ""
    @State private var hasManualValue = false
    @State private var manualValueText = ""
    @State private var location = ""
    @State private var owner: SharedFinanceOwner?
    @State private var loaded = false

    private var isNew: Bool { item == nil }

    /// Whatever was typed, in grams.
    private var grams: Double? {
        guard let weight = FinanceInput.parse(weightText) else { return nil }
        return unit == .grams ? weight : MetalValuation.grams(ounces: weight)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && grams != nil && canEdit(item, in: container)
    }

    var body: some View {
        let snapshot = data.snapshot
        let prices = snapshot.currentPrices
        NavigationStack {
            Form {
                Section {
                    Picker("Metal", selection: $metal) {
                        ForEach(MetalKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("Name, e.g. Gold - Bar 1", text: $name)
                        .textInputAutocapitalization(.words)
                }

                Section {
                    HStack {
                        TextField("Weight", text: $weightText)
                            .keyboardType(.decimalPad)
                        Picker("Unit", selection: $unit) {
                            ForEach(WeightUnit.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 120)
                    }
                } header: {
                    Text("Weight")
                } footer: {
                    if let grams {
                        Text(unit == .grams
                             ? "= \(FinanceFormat.ounces(MetalValuation.ounces(grams: grams)))"
                             : "= \(FinanceFormat.grams(grams))")
                    }
                }

                Section {
                    LabeledContent("Price paid per oz") {
                        TextField("Unknown", text: $pricePaidText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Purchase value") {
                        TextField(purchasePlaceholder, text: $purchaseValueText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Cost")
                } footer: {
                    Text("Leave both empty if the cost isn't known; the item then shows no gain.")
                }

                Section {
                    Toggle("Set current value by hand", isOn: $hasManualValue.animation())
                    if hasManualValue {
                        LabeledContent("Current value") {
                            TextField("0", text: $manualValueText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                    } else {
                        LabeledContent("Current value", value: FinanceFormat.money(automaticValue(prices: prices)))
                    }
                } footer: {
                    Text(hasManualValue
                         ? "For a piece worth more than its metal — a ring with stones."
                         : "Weight at \(snapshot.latestMonth?.monthName ?? "the latest month")'s \(metal.displayName.lowercased()) price, \(FinanceFormat.cents(prices.price(for: metal))) per oz.")
                }

                Section("Where") {
                    TextField("Location, e.g. Locker", text: $location)
                        .textInputAutocapitalization(.words)
                    if !snapshot.metalLocations.isEmpty {
                        ChipRow {
                            ForEach(snapshot.metalLocations, id: \.self) { option in
                                FinanceChip(
                                    title: option,
                                    isSelected: option.caseInsensitiveCompare(location.trimmingCharacters(in: .whitespaces)) == .orderedSame
                                ) {
                                    location = option
                                }
                            }
                        }
                    }
                    Picker("Owner", selection: $owner) {
                        Text("No one").tag(SharedFinanceOwner?.none)
                        ForEach(snapshot.owners) { person in
                            Text(person.name).tag(SharedFinanceOwner?.some(person))
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Add Gold or Silver" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .onAppear(perform: load)
            // Switching the unit converts what's typed rather than
            // reinterpreting it: 28.35 g must not become 28.35 oz.
            .onChange(of: unit) { oldUnit, newUnit in
                guard let weight = FinanceInput.parse(weightText), oldUnit != newUnit else { return }
                let converted = newUnit == .grams
                    ? MetalValuation.grams(ounces: weight)
                    : MetalValuation.ounces(grams: weight)
                weightText = converted.formatted(
                    .number.grouping(.never).precision(.fractionLength(0...4)).locale(Locale(identifier: "en_US_POSIX"))
                )
            }
        }
    }

    /// Weight × price paid, shown as the purchase value's placeholder.
    private var purchasePlaceholder: String {
        guard let grams, let price = FinanceInput.parse(pricePaidText), price > 0 else { return "Unknown" }
        return FinanceFormat.money(MetalValuation.ounces(grams: grams) * price)
    }

    private func automaticValue(prices: MetalPrices) -> Double {
        MetalValuation.value(grams: grams ?? 0, metal: metal, manualValue: nil, prices: prices)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let item else { return }
        metal = item.metal
        name = item.name
        weightText = FinanceFormat.editable(item.grams)
        pricePaidText = FinanceFormat.editable(item.pricePaidPerOz)
        purchaseValueText = FinanceFormat.editable(item.purchaseValue)
        hasManualValue = item.hasManualValue
        manualValueText = FinanceFormat.editable(item.manualValue)
        location = item.location
        owner = item.owner
    }

    private func save() {
        guard let grams else { return }
        let household = item?.household ?? FinanceHouseholdResolver.forWriting(in: context, container: container)
        let target = item ?? SharedFinanceMetalItem(name: "", metal: metal, grams: grams, household: household)
        target.metal = metal
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.grams = grams
        target.pricePaidPerOz = FinanceInput.parse(pricePaidText) ?? 0
        target.purchaseValue = FinanceInput.parse(purchaseValueText) ?? 0
        target.hasManualValue = hasManualValue
        target.manualValue = hasManualValue ? (FinanceInput.parse(manualValueText) ?? 0) : 0
        target.location = location.trimmingCharacters(in: .whitespaces)
        // Cross-store relationships can't be saved; see AccountEditorView.
        target.owner = owner?.household == household ? owner : nil
        try? context.saveIfNeeded()
        dismiss()
    }
}
