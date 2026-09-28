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

/// The most recently filled car as the card's headline, and the rest of the
/// garage as a line each under it.
///
/// It used to give every car (up to three) a name and a 26pt figure of its
/// own. With three cars that ran past the Overview's row, so the Fuel card
/// stood taller than the cards beside it, and there was no one number to
/// read at a glance.
struct FuelOverviewCard: View {
    let summaries: [VehicleSummary]
    let recentMPG: [NSManagedObjectID: [Double]]
    let open: () -> Void

    var body: some View {
        OverviewCard(accent: FuelTrackerModule.accent, icon: FuelTrackerModule.symbolName, open: open) {
            if let first = summaries.first {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            OverviewValue(VehicleSummary.mpgText(first.averageMPG), unit: "mpg")
                            OverviewCaption(caption(for: first))
                        }
                        Spacer(minLength: 8)
                        sparkline(recentMPG[first.id] ?? [], width: 90, height: 30)
                            .padding(.top, 6)
                    }
                    Spacer(minLength: 6)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(summaries.dropFirst().prefix(2)) { summary in
                            row(summary)
                        }
                    }
                }
            } else {
                OverviewEmptyState("No vehicles yet", message: "Add a car in Garage to log fill-ups.")
            }
        }
    }

    /// "My X3 · filled 3 days ago".
    private func caption(for summary: VehicleSummary) -> String {
        guard let last = summary.lastFillUp else { return summary.name }
        return "\(summary.name) · filled \(last.formatted(.relative(presentation: .named)))"
    }

    private func row(_ summary: VehicleSummary) -> some View {
        HStack(spacing: 10) {
            Text(summary.name)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            sparkline(recentMPG[summary.id] ?? [], width: 56, height: 14)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(VehicleSummary.mpgText(summary.averageMPG))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                Text("mpg")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 62, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func sparkline(_ values: [Double], width: CGFloat, height: CGFloat) -> some View {
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
            .frame(width: width, height: height)
            .accessibilityHidden(true)
        } else {
            Color.clear.frame(width: width, height: height)
        }
    }
}
