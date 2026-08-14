import SwiftData
import SwiftUI

struct FuelRootView: View {
    @Query(sort: \Vehicle.createdAt) private var vehicles: [Vehicle]
    @State private var selectedVehicleID: PersistentIdentifier?

    private var selectedVehicle: Vehicle? {
        if let selectedVehicleID, let match = vehicles.first(where: { $0.persistentModelID == selectedVehicleID }) {
            return match
        }
        return vehicles.first
    }

    var body: some View {
        TabView {
            Tab("Vehicle", systemImage: "car.fill") {
                VehicleLogView(vehicle: selectedVehicle, vehicles: vehicles, selectedVehicleID: $selectedVehicleID)
            }
            Tab("Trends", systemImage: "chart.xyaxis.line") {
                TrendsView(vehicle: selectedVehicle)
            }
            Tab("Garage", systemImage: "building.2.fill") {
                GarageView()
            }
        }
        .tint(FuelTrackerModule.accent.color)
    }
}
