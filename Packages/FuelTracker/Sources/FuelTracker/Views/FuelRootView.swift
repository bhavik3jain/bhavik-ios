import Core
import SwiftData
import SwiftUI

struct FuelRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Vehicle.createdAt) private var vehicles: [Vehicle]
    @State private var selectedVehicleID: PersistentIdentifier?
    @State private var selection = "vehicle"

    private var selectedVehicle: Vehicle? {
        if let selectedVehicleID, let match = vehicles.first(where: { $0.persistentModelID == selectedVehicleID }) {
            return match
        }
        return vehicles.first
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: ModuleTab.home) {
                Color.clear
            }
            Tab("Vehicle", systemImage: "car.fill", value: "vehicle") {
                VehicleLogView(vehicle: selectedVehicle, vehicles: vehicles, selectedVehicleID: $selectedVehicleID)
            }
            Tab("Trends", systemImage: "chart.xyaxis.line", value: "trends") {
                TrendsView(vehicle: selectedVehicle)
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
}
