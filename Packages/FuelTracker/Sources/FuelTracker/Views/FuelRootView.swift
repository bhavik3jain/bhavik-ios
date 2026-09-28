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
    @Environment(\.fuelPersistentContainer) private var container
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \SharedVehicle.createdAt, ascending: true)])
    private var vehicleResults: FetchedResults<SharedVehicle>
    private var vehicles: [SharedVehicle] { Array(vehicleResults) }

    /// The chosen vehicle's name, or "" for none chosen yet. `@AppStorage`
    /// rather than `@State` because `fullScreenCover` builds this view afresh
    /// every time the module is opened, which threw the choice away on the way
    /// back to the hub.
    @AppStorage(FuelTrackerModule.selectedVehicleDefaultsKey) private var selectedVehicleName = ""
    /// The Mac sidebar's own selection when it picks the section; nil on the
    /// phone, where the tab bar's selection below does.
    var section: Binding<String>?
    @State private var ownSection = FuelTrackerModule.sections[0].id
    private var selection: Binding<String> { section ?? $ownSection }
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
        ModuleTabView(selection: selection, sections: FuelTrackerModule.sections) { section in
            switch section.id {
            case "trends":
                TrendsView(
                    vehicle: selectedVehicle,
                    summary: selectedSummary,
                    summaries: summaries,
                    perform: handle
                )
            case "garage":
                GarageView()
            default:
                VehicleLogView(
                    vehicle: selectedVehicle,
                    summary: selectedSummary,
                    summaries: summaries,
                    showingAddEntry: $showingAddEntry,
                    perform: handle
                )
            }
        }
        .tint(FuelTrackerModule.accent.color)
        .task {
            // The importer de-duplicates against this device's store only, so
            // it waits until that store has caught up with iCloud — otherwise
            // a second device re-copies what the first already exported. See
            // CloudKitImportGate.
            #if DEBUG
            // Asked before the migration, not after: the migration marks
            // itself run even with nothing to migrate, and `isRequested`
            // refuses a store it has run against, so asking afterwards made
            // -FuelSeedCSV a no-op on every device, a fresh simulator included.
            let seedRequested = FuelDebugSeed.isRequested
            #endif
            if !FuelLegacyMigration.hasRun {
                guard await CloudKitImportGate.waitForFirstImport(of: container) else { return }
            }
            FuelLegacyMigration.runIfNeeded(from: legacyContext, into: context)
            #if DEBUG
            guard seedRequested else { return }
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
            selection.wrappedValue = "vehicle"
            showingAddEntry = true
        case .showTrends:
            selection.wrappedValue = "trends"
        }
    }
}
