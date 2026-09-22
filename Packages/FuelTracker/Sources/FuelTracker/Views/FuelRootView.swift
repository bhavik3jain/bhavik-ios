import Core
import CoreData
import SwiftData
import SwiftUI

struct FuelRootView: View {
    /// The module's own Core Data context — set by `FuelTrackerModule.rootView(context:)`
    /// just above this view, so every descendant reading this same key gets it too.
    @Environment(\.managedObjectContext) private var context
    /// The app-wide SwiftData context, still attached at the WindowGroup level
    /// for Gym/TV/Orders — read here only so `FuelLegacyMigration` has
    /// something to copy real vehicles out of.
    @Environment(\.modelContext) private var legacyContext
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \SharedVehicle.createdAt, ascending: true)])
    private var vehicleResults: FetchedResults<SharedVehicle>
    private var vehicles: [SharedVehicle] { Array(vehicleResults) }

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

    private var selectedVehicle: SharedVehicle? {
        guard let selectedSummary else { return nil }
        return vehicles.first { $0.objectID == selectedSummary.id }
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
        .task {
            FuelLegacyMigration.runIfNeeded(from: legacyContext, into: context)
            #if DEBUG
            guard FuelDebugSeed.isRequested else { return }
            FuelDebugSeed.run(context: context)
            #endif
        }
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
