import Core
import SwiftUI

/// The card shown when a vehicle's chip is long-pressed.
///
/// Read-only by construction: context-menu previews do not forward taps, so
/// nothing in here is interactive, and every action lives in the menu beneath.
struct VehiclePeekCard: View {
    let summary: VehicleSummary

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "car.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(FuelTrackerModule.accent.color, in: RoundedRectangle(cornerRadius: 8))
                Text(summary.name)
                    .font(.headline)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                Stat(value: VehicleSummary.mpgText(summary.averageMPG), label: "Avg MPG")
                Stat(value: VehicleSummary.pricePerGallonText(summary.averagePricePerGallon), label: "Avg $/gal")
                Stat(value: VehicleSummary.spendText(summary.fuelSpend), label: "Fuel spend")
                Stat(value: summary.lastOdometer.map { "\($0.formatted()) mi" } ?? "—", label: "Odometer")
                Stat(
                    value: summary.lastFillUp.map { $0.formatted(.dateTime.month().day().year()) } ?? "—",
                    label: "Last fill-up"
                )
                Stat(value: summary.fillUpCount.formatted(), label: "Fill-ups")
            }

            if summary.serviceSpend > 0 {
                Text("\(counted(summary.serviceCount, "service record")) · \(VehicleSummary.spendText(summary.serviceSpend)) · \(VehicleSummary.spendText(summary.totalSpend)) all-in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private struct Stat: View {
        let value: String
        let label: String

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(FuelTrackerModule.accent.color)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    // A fixed line height, so a value the scale factor shrank
                    // (a long date) doesn't lift its label above its neighbours'.
                    .frame(height: 26, alignment: .leading)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
