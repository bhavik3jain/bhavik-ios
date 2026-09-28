import Core
import SwiftUI

/// The garage on the Mac: a card per car with the figures that tell them
/// apart, and a banner above them when a car appears twice. The phone's
/// list was names and fill-up counts at opposite edges of the window.
struct MacGarageView: View {
    let vehicles: [SharedVehicle]
    /// "My X3 appears 3 times"; nil when there's nothing to merge.
    let duplicateSummary: String?
    let sharingLabel: (SharedVehicle) -> String?
    let canEdit: (SharedVehicle) -> Bool
    let merge: () -> Void
    let delete: (SharedVehicle) -> Void

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let duplicateSummary {
                    HStack(spacing: 14) {
                        Image(systemName: "rectangle.stack.badge.minus")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(duplicateSummary)
                                .font(.headline)
                            Text("Most likely copied again when the app was reinstalled. Merging keeps one of each, with every fill-up, and removes the copies.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Merge Duplicate Cars…", action: merge)
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                    }
                    .padding(16)
                    .background(.orange.opacity(0.12), in: .rect(cornerRadius: 14))
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(vehicles) { vehicle in
                        MacVehicleCard(vehicle: vehicle, sharingLabel: sharingLabel(vehicle))
                            .contextMenu {
                                if canEdit(vehicle) {
                                    Button("Delete…", systemImage: "trash", role: .destructive) { delete(vehicle) }
                                }
                            }
                    }
                }
            }
            .padding(20)
        }
    }
}

private struct MacVehicleCard: View {
    @ObservedObject var vehicle: SharedVehicle
    let sharingLabel: String?

    var body: some View {
        let summary = VehicleSummary.summarize(vehicle)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "car.fill")
                    .foregroundStyle(FuelTrackerModule.accent.color)
                Text(vehicle.name.isEmpty ? "Untitled" : vehicle.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if let sharingLabel {
                    Label(sharingLabel, systemImage: "person.2.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(VehicleSummary.mpgText(summary.averageMPG))
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text("mpg")
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Fill-ups").foregroundStyle(.secondary)
                    Text(summary.fillUpCount.formatted()).monospacedDigit()
                }
                GridRow {
                    Text("Last").foregroundStyle(.secondary)
                    Text(summary.lastFillUp.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                }
                GridRow {
                    Text("Fuel spend").foregroundStyle(.secondary)
                    Text(VehicleSummary.spendText(summary.fuelSpend)).monospacedDigit()
                }
            }
            .font(.callout)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }
}
