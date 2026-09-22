import Core
import SwiftUI

struct VehicleLogView: View {
    let vehicle: Vehicle?
    let summary: VehicleSummary?
    let summaries: [VehicleSummary]
    @Binding var showingAddEntry: Bool
    let perform: (VehicleChipAction, VehicleSummary) -> Void

    private var fillUps: [FuelEntry] {
        (vehicle?.orderedFillUps ?? []).reversed()
    }

    private var mpgByOdometer: [Int: Double] {
        Dictionary(
            FuelStatistics.mpgPoints(for: vehicle?.orderedFillUps ?? [])
                .map { ($0.odometer, $0.mpg) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VehicleChipStrip(
                    summaries: summaries,
                    selectedID: summary?.id,
                    perform: perform
                )

                Group {
                    if let vehicle, let summary {
                        List {
                            Section {
                                SummaryTiles(summary: summary)
                                    .listRowInsets(EdgeInsets())
                                    .listRowBackground(Color.clear)
                            }

                            Section("Fill-ups") {
                                if fillUps.isEmpty {
                                    ContentUnavailableView(
                                        "No fill-ups yet",
                                        systemImage: "fuelpump",
                                        description: Text("Add one with the + button, or import a Fuelly export from the Garage tab.")
                                    )
                                } else {
                                    ForEach(fillUps) { entry in
                                        FillUpRow(entry: entry, mpg: mpgByOdometer[entry.odometer])
                                    }
                                }
                            }

                            if !vehicle.orderedServices.isEmpty {
                                Section("Service") {
                                    ForEach(vehicle.orderedServices) { entry in
                                        ServiceRow(entry: entry)
                                    }
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView(
                            "No vehicles",
                            systemImage: "car",
                            description: Text("Add a vehicle in the Garage tab, or import a Fuelly export.")
                        )
                    }
                }
            }
            .navigationTitle(summary?.name ?? "Fuel")
            .toolbar {
                if vehicle != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingAddEntry = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add fill-up")
                    }
                }
            }
            .sheet(isPresented: $showingAddEntry) {
                if let vehicle {
                    AddFillUpView(vehicle: vehicle)
                }
            }
        }
    }
}

private struct SummaryTiles: View {
    let summary: VehicleSummary

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Tile(value: VehicleSummary.mpgText(summary.averageMPG), label: "Avg MPG")
                Tile(value: VehicleSummary.pricePerGallonText(summary.averagePricePerGallon), label: "Avg $/gal")
                Tile(value: VehicleSummary.spendText(summary.fuelSpend), label: "Fuel spend")
            }

            // The third tile used to read "Total spend" and summed service work
            // as well, while the two tiles beside it were fuel-only — $13,928
            // against $5,245 of fuel, with nothing on screen saying so. Both
            // figures are now named rather than one standing for the other.
            if summary.serviceSpend > 0 {
                Text("+ \(VehicleSummary.spendText(summary.serviceSpend)) service · \(VehicleSummary.spendText(summary.totalSpend)) all-in")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private struct Tile: View {
        let value: String
        let label: String

        var body: some View {
            VStack(spacing: 4) {
                Text(value)
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(FuelTrackerModule.accent.color)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

private struct FillUpRow: View {
    let entry: FuelEntry
    let mpg: Double?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.date, format: .dateTime.month().day().year())
                    .font(.subheadline)
                HStack(spacing: 6) {
                    Text("\(entry.odometer.formatted()) mi")
                    if !entry.station.isEmpty {
                        Text("· \(entry.station)")
                    }
                    if !entry.isFullTank {
                        Text("· Partial")
                            .foregroundStyle(FuelTrackerModule.accent.color)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let mpg {
                    Text("\(mpg.formatted(.number.precision(.fractionLength(1)))) mpg")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(FuelTrackerModule.accent.color)
                } else {
                    Text("—")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text("\(entry.gallons.formatted(.number.precision(.fractionLength(2)))) gal · \(entry.totalCost.formatted(.currency(code: "USD")))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
        }
    }
}

private struct ServiceRow: View {
    let entry: FuelEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.services.isEmpty ? "Service" : entry.services)
                    .font(.subheadline)
                    .lineLimit(2)
                Text("\(entry.date.formatted(.dateTime.month().day().year())) · \(entry.odometer.formatted()) mi")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(entry.totalCost.formatted(.currency(code: "USD")))
                .font(.subheadline)
                .monospacedDigit()
        }
    }
}
