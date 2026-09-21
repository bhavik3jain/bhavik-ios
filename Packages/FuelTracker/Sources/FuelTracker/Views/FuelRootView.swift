import Core
import SwiftData
import SwiftUI

struct FuelRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Vehicle.createdAt) private var vehicles: [Vehicle]

    /// The chosen vehicle's name, or "" for none chosen yet. `@AppStorage`
    /// rather than `@State` because `fullScreenCover` builds this view afresh
    /// every time the module is opened, which threw the choice away on the way
    /// back to the hub.
    @AppStorage(FuelTrackerModule.selectedVehicleDefaultsKey) private var selectedVehicleName = ""
    @State private var selection = "vehicle"
    /// Held here so a chip's "Log a fill-up" can open the sheet from either tab.
    @State private var showingAddEntry = false

    private var summaries: [VehicleSummary] {
        VehicleSummary.fleet(vehicles)
    }

    private var selectedSummary: VehicleSummary? {
        VehicleSelection.resolve(
            storedName: selectedVehicleName.isEmpty ? nil : selectedVehicleName,
            among: summaries
        )
    }

    private var selectedVehicle: Vehicle? {
        guard let selectedSummary else { return nil }
        return vehicles.first { $0.persistentModelID == selectedSummary.id }
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: ModuleTab.home) {
                Color.clear
            }
            Tab("Vehicle", systemImage: "car.fill", value: "vehicle") {
                VehicleLogView(
                    vehicle: selectedVehicle,
                    summary: selectedSummary,
                    summaries: summaries,
                    showingAddEntry: $showingAddEntry,
                    perform: handle
                )
            }
            Tab("Trends", systemImage: "chart.xyaxis.line", value: "trends") {
                TrendsView(
                    vehicle: selectedVehicle,
                    summary: selectedSummary,
                    summaries: summaries,
                    perform: handle
                )
            }
            Tab("Garage", systemImage: "building.2.fill", value: "garage") {
                GarageView()
            }
        }
        .tint(FuelTrackerModule.accent.color)
        .minimizesTabBarOnScroll()
        .dismissesOnHomeTab($selection, restoringTo: "vehicle")
        #if DEBUG
        .task {
            guard FuelDebugSeed.isRequested else { return }
            FuelDebugSeed.run(context: modelContext)
        }
        #endif
    }

    private func handle(_ action: VehicleChipAction, _ summary: VehicleSummary) {
        selectedVehicleName = summary.name
        switch action {
        case .select:
            break
        case .logFillUp:
            selection = "vehicle"
            showingAddEntry = true
        case .showTrends:
            selection = "trends"
        }
    }
}
