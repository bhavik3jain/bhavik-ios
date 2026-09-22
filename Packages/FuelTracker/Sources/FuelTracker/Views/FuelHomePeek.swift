import Core
import SwiftUI

public extension FuelTrackerModule {
    /// What long-pressing Fuel on the home screen shows: every vehicle at once,
    /// most recently filled first, without opening the module.
    @MainActor
    static func homePeek(vehicles: [SharedVehicle]) -> some View {
        FuelHomePeek(summaries: VehicleSummary.fleet(vehicles))
    }
}

struct FuelHomePeek: View {
    let summaries: [VehicleSummary]

    private var subtitle: String {
        guard !summaries.isEmpty else { return "" }
        let fuel = summaries.reduce(0) { $0 + $1.fuelSpend }
        return "\(counted(summaries.count, "vehicle")) · \(VehicleSummary.spendText(fuel)) on fuel"
    }

    var body: some View {
        ModulePeekCard(accent: FuelTrackerModule.accent, icon: "fuelpump.fill", subtitle: subtitle) {
            if summaries.isEmpty {
                PeekEmpty("No vehicles yet. Add one in the Garage tab.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(summaries.prefix(4)) { summary in
                        PeekRow(
                            summary.name,
                            detail: detail(for: summary),
                            value: summary.averageMPG.map { "\(VehicleSummary.mpgText($0)) mpg" } ?? "",
                            tint: FuelTrackerModule.accent.color
                        )
                    }
                }
            }
        }
    }

    private func detail(for summary: VehicleSummary) -> String {
        var parts: [String] = []
        if summary.averagePricePerGallon != nil {
            parts.append("\(VehicleSummary.pricePerGallonText(summary.averagePricePerGallon))/gal")
        }
        if let last = summary.lastFillUp {
            parts.append("filled \(last.formatted(.relative(presentation: .named)))")
        }
        return parts.isEmpty ? "No fill-ups yet" : parts.joined(separator: " · ")
    }
}
