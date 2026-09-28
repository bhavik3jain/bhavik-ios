import Charts
import Core
import CoreData
import SwiftUI

struct VehicleLogView: View {
    let vehicle: SharedVehicle?
    let summary: VehicleSummary?
    let summaries: [VehicleSummary]
    @Binding var showingAddEntry: Bool
    let perform: (VehicleChipAction, VehicleSummary) -> Void

    @Environment(\.fuelPersistentContainer) private var container
    @Environment(\.presentShareSheet) private var presentShareSheet
    @Environment(\.moduleLayout) private var layout

    // Read through `badgeStatus`: this device's last known answer at once,
    // looked up again off the main thread (`SharingStatusCache`). It was a
    // synchronous `fetchShares` on every body evaluation, thought cheap, but it
    // waits on the container's executor — the wait that deadlocked Share.
    private var sharingStatus: SharingStatus {
        guard let vehicle, let container else { return .notShared }
        return SharingStatusResolver.badgeStatus(for: vehicle, in: container)
    }
    private var canEdit: Bool {
        guard let vehicle, let container else { return true }
        return SharingStatusResolver.canEdit(vehicle, in: container)
    }

    private var fillUps: [SharedFuelEntry] {
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
            Group {
                if let vehicle, let summary, layout == .sidebar {
                    VehicleDesktopLog(vehicle: vehicle, summary: summary)
                } else if let vehicle, let summary {
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
                                    description: Text("Add one with the + button, or import a Fuelly export in Garage.")
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
                        description: Text("Add a vehicle in Garage, or import a Fuelly export.")
                    )
                    .scrollsForRefresh()
                }
            }
            // On the log alone, applied before `vehicleSwitcher` puts the chips
            // above it. It used to wrap a VStack holding the chip strip too, and
            // `.refreshable` reaches every scroll view below it: the chips'
            // horizontal ScrollView became a pull-to-refresh view of its own,
            // and the phone's log — unlike Trends, which has no refresh — lost
            // its vehicle switch. See `VehicleSwitcher`.
            .refreshesFromCloud()
            .navigationTitle(summary?.name ?? "Fuel")
            // The Mac says who it's shared with under the toolbar's title
            // rather than in a line of its own above the list — or, with
            // several cars, beside the switcher that stands in for the title.
            .moduleSubtitle(sharingStatus.vehicleBadgeLabel)
            .vehicleSwitcher(
                summaries: summaries,
                selectedID: summary?.id,
                badge: sharingStatus.vehicleBadgeLabel,
                perform: perform
            )
            .toolbar {
                if let vehicle {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            if let container {
                                presentShareSheet(ShareSheetRequest(object: vehicle, container: container))
                            }
                        } label: {
                            Image(systemName: "person.crop.circle.badge.plus")
                        }
                        .disabled(container == nil)
                        .accessibilityLabel("Share vehicle")
                    }
                    // A read-only participant can't add a fill-up either
                    // (AddFillUpView's own Save is gated the same way) — no
                    // point opening a sheet that can't be saved.
                    if canEdit {
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
            }
            .sheet(isPresented: $showingAddEntry) {
                if let vehicle {
                    AddFillUpView(vehicle: vehicle)
                }
            }
        }
    }
}

/// The Mac's vehicle page: four figures across the top, the last sixteen
/// tanks' economy as a line, and every fill-up and service in one table.
///
/// It used to be the phone's List stretched across a desktop window — three
/// tiles, then a column of two-line rows with half the window empty beside
/// them, and the services in a section of their own below every fill-up.
private struct VehicleDesktopLog: View {
    let vehicle: SharedVehicle
    let summary: VehicleSummary

    var body: some View {
        let rows = VehicleLogRow.rows(fillUps: vehicle.orderedFillUps, services: vehicle.orderedServices)
        let points = Array(FuelStatistics.mpgPoints(for: vehicle.orderedFillUps).suffix(16))

        VStack(alignment: .leading, spacing: 16) {
            Grid(horizontalSpacing: 12) {
                GridRow {
                    tile("Average", VehicleSummary.mpgText(summary.averageMPG), detail: "mpg, lifetime")
                    tile(
                        "Last fill-up",
                        summary.lastFillUp?.formatted(.dateTime.month(.abbreviated).day()) ?? "—",
                        detail: summary.lastOdometer.map { "\($0.formatted()) mi" } ?? ""
                    )
                    tile(
                        "Fuel this year",
                        VehicleSummary.spendText(VehicleLogRow.spend(on: .fillUp, in: rows)),
                        detail: summary.averagePricePerGallon.map { "\(VehicleSummary.pricePerGallonText($0)) a gallon on average" } ?? ""
                    )
                    tile(
                        "Service this year",
                        VehicleSummary.spendText(VehicleLogRow.spend(on: .service, in: rows)),
                        detail: "\(VehicleSummary.spendText(summary.serviceSpend)) all time"
                    )
                }
            }

            if points.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Miles per gallon · last \(points.count) fill-ups")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    // By odometer, as on Trends: exported logs carry mistyped
                    // dates, and a date axis zigzagged the line back on itself.
                    Chart(points) { point in
                        LineMark(x: .value("Odometer", point.odometer), y: .value("MPG", point.mpg))
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("Odometer", point.odometer), y: .value("MPG", point.mpg))
                            .symbolSize(18)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXScale(domain: .automatic(includesZero: false))
                    .foregroundStyle(FuelTrackerModule.accent.color)
                    .frame(height: 150)
                }
                .padding(14)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if rows.isEmpty {
                ContentUnavailableView(
                    "No fill-ups yet",
                    systemImage: "fuelpump",
                    description: Text("Add one with the + button, or import a Fuelly export in Garage.")
                )
                .frame(maxHeight: .infinity)
            } else {
                table(rows)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func tile(_ label: String, _ value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(FuelTrackerModule.accent.color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func table(_ rows: [VehicleLogRow]) -> some View {
        Table(rows) {
            TableColumn("Date") { row in
                HStack(spacing: 6) {
                    Text(row.date, format: .dateTime.month(.abbreviated).day().year())
                    if row.kind == .service {
                        Text(row.note)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if row.isPartial {
                        Text("Partial")
                            .foregroundStyle(FuelTrackerModule.accent.color)
                    }
                }
            }
            .width(min: 140, ideal: 220)
            TableColumn("Odometer") { row in
                Text("\(row.odometer.formatted()) mi").monospacedDigit()
            }
            TableColumn("Gallons") { row in
                figure(row.gallons.map { $0.formatted(.number.precision(.fractionLength(2))) })
            }
            TableColumn("Price per gal") { row in
                figure(row.pricePerGallon.map { VehicleSummary.pricePerGallonText($0) })
            }
            TableColumn("Total") { row in
                figure(row.total.formatted(.currency(code: "USD")))
            }
            TableColumn("MPG") { row in
                if let mpg = row.mpg {
                    Text(mpg.formatted(.number.precision(.fractionLength(1))))
                        .fontWeight(.semibold)
                        .foregroundStyle(FuelTrackerModule.accent.color)
                        .monospacedDigit()
                } else {
                    figure(nil)
                }
            }
        }
        // No blank striped rows filling the space under the last fill-up.
        .alternatingRowBackgrounds(.disabled)
    }

    private func figure(_ text: String?) -> some View {
        Text(text ?? "—")
            .monospacedDigit()
            .foregroundStyle(text == nil ? .secondary : .primary)
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
    let entry: SharedFuelEntry
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
    let entry: SharedFuelEntry

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
