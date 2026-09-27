import Charts
import Core
import CoreData
import SwiftUI

public extension FuelTrackerModule {
    /// The Mac Overview's Fuel card: each car's average economy, most recently
    /// filled first, with a sparkline of its last dozen tanks.
    @MainActor
    static func overviewCard(vehicles: [SharedVehicle], open: @escaping () -> Void) -> some View {
        let summaries = VehicleSummary.fleet(vehicles)
        let points = Dictionary(uniqueKeysWithValues: vehicles.map { vehicle in
            (vehicle.objectID, FuelStatistics.mpgPoints(for: vehicle.orderedFillUps).suffix(12).map(\.mpg))
        })
        return FuelOverviewCard(summaries: summaries, recentMPG: points, open: open)
    }

    /// The figure beside Fuel in the Mac sidebar: the most recently filled
    /// car's average, "30.9". Nil until one has a full tank to measure.
    @MainActor
    static func sidebarDetail(vehicles: [SharedVehicle]) -> String? {
        VehicleSummary.fleet(vehicles).first?.averageMPG.map(VehicleSummary.mpgText)
    }
}

struct FuelOverviewCard: View {
    let summaries: [VehicleSummary]
    let recentMPG: [NSManagedObjectID: [Double]]
    let open: () -> Void

    var body: some View {
        OverviewCard(accent: FuelTrackerModule.accent, icon: FuelTrackerModule.symbolName, open: open) {
            if summaries.isEmpty {
                OverviewValue("No vehicles")
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(summaries.prefix(3)) { summary in
                        row(summary)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
    }

    private func row(_ summary: VehicleSummary) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(summary.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                OverviewValue(VehicleSummary.mpgText(summary.averageMPG), unit: "mpg")
            }
            Spacer(minLength: 8)
            let values = recentMPG[summary.id] ?? []
            if values.count > 1 {
                Chart(Array(values.enumerated()), id: \.offset) { point in
                    LineMark(x: .value("Fill-up", point.offset), y: .value("MPG", point.element))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(FuelTrackerModule.accent.color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: (values.min() ?? 0) * 0.95...(values.max() ?? 1) * 1.05)
                .frame(width: 90, height: 30)
                .accessibilityHidden(true)
            }
        }
    }
}
