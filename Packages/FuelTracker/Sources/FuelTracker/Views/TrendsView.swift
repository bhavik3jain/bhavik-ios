import Charts
import SwiftUI

struct TrendsView: View {
    let vehicle: SharedVehicle?
    let summary: VehicleSummary?
    let summaries: [VehicleSummary]
    let perform: (VehicleChipAction, VehicleSummary) -> Void

    private var points: [MPGPoint] {
        FuelStatistics.mpgPoints(for: vehicle?.orderedFillUps ?? [])
    }

    private var monthlySpend: [(month: Date, total: Double)] {
        let entries = vehicle?.entries ?? []
        return FuelStatistics.monthlySpend(for: entries.filter { $0.kind == .fillUp }).suffix(12)
    }

    /// Chart bounds drawn from the data itself, so the plot fills the frame
    /// instead of stranding the line above a long empty run up from zero.
    private var odometerRange: ClosedRange<Int> {
        guard let low = points.first?.odometer, let high = points.last?.odometer, low < high else {
            return 0...1
        }
        let padding = max((high - low) / 40, 1)
        return (low - padding)...(high + padding)
    }

    private var mpgRange: ClosedRange<Double> {
        let values = points.map(\.mpg)
        guard let low = values.min(), let high = values.max(), low < high else { return 0...40 }
        let padding = max((high - low) * 0.15, 1)
        return max(0, low - padding)...(high + padding)
    }

    /// Fill-ups whose date disagrees with their position by odometer, which
    /// usually means a mistyped year in the original log.
    private var outOfOrderDates: [SharedFuelEntry] {
        let byOdometer = vehicle?.orderedFillUps ?? []
        return byOdometer.enumerated().filter { index, entry in
            if index > 0, entry.date < byOdometer[index - 1].date { return true }
            if index < byOdometer.count - 1, entry.date > byOdometer[index + 1].date { return true }
            return false
        }
        .map(\.element)
    }

    var body: some View {
        NavigationStack {
            Group {
                if vehicle == nil {
                    // Distinct from "not enough data": with no vehicle at all
                    // the old copy told you to log fill-ups against nothing.
                    ContentUnavailableView(
                        "No vehicles",
                        systemImage: "car",
                        description: Text("Add a vehicle in the Garage tab, or import a Fuelly export.")
                    )
                } else if points.isEmpty {
                    ContentUnavailableView(
                        "Not enough data",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Log at least two full fill-ups to see fuel economy over time.")
                    )
                } else {
                    List {
                        Section("MPG over time") {
                            // Plotted against distance travelled rather than date: exported
                            // logs occasionally carry a mistyped year, which would send a
                            // date-based line doubling back on itself.
                            Chart(points) { point in
                                LineMark(
                                    x: .value("Odometer", point.odometer),
                                    y: .value("MPG", point.mpg)
                                )
                                .foregroundStyle(FuelTrackerModule.accent.color)
                                .interpolationMethod(.monotone)

                                if let average = summary?.averageMPG {
                                    RuleMark(y: .value("Average", average))
                                        .foregroundStyle(.secondary.opacity(0.4))
                                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                }
                            }
                            .chartXScale(domain: odometerRange)
                            .chartYScale(domain: mpgRange)
                            .chartXAxisLabel("Odometer")
                            .frame(height: 200)
                            .padding(.vertical, 8)
                        }

                        if !monthlySpend.isEmpty {
                            Section("Monthly fuel spend") {
                                Chart(monthlySpend, id: \.month) { item in
                                    BarMark(
                                        x: .value("Month", item.month, unit: .month),
                                        y: .value("Spend", item.total)
                                    )
                                    .foregroundStyle(FuelTrackerModule.accent.color)
                                }
                                .frame(height: 180)
                                .padding(.vertical, 8)
                            }
                        }

                        Section("Best and worst tanks") {
                            if let best = points.max(by: { $0.mpg < $1.mpg }) {
                                TankRow(label: "Best", point: best)
                            }
                            if let worst = points.min(by: { $0.mpg < $1.mpg }) {
                                TankRow(label: "Worst", point: worst)
                            }
                        }

                        if !outOfOrderDates.isEmpty {
                            Section("Check these dates") {
                                ForEach(outOfOrderDates) { entry in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.date, format: .dateTime.month().day().year())
                                            .font(.subheadline)
                                        Text("\(entry.odometer.formatted()) mi — dated out of order against the odometer")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // Named after the vehicle: this screen drew one car's charts under a
            // flat "Trends" title, with no picker and nothing saying whose data
            // it was.
            .navigationTitle(summary?.name ?? "Trends")
            .vehicleSwitcher(summaries: summaries, selectedID: summary?.id, perform: perform)
        }
    }
}

private struct TankRow: View {
    let label: String
    let point: MPGPoint

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline)
                Text("\(point.date.formatted(.dateTime.month().day().year())) · \(point.miles) mi")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(point.mpg.formatted(.number.precision(.fractionLength(1)))) mpg")
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(FuelTrackerModule.accent.color)
        }
    }
}
