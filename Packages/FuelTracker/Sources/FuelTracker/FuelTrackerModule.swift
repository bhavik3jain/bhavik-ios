import SwiftData
import SwiftUI
import Core

public enum FuelTrackerModule {
    public static let accent = ModuleAccent(name: "Fuel", color: Color(red: 0.06, green: 0.62, blue: 0.56))

    /// The vehicle the module last opened on, by name.
    ///
    /// Unlike `TVTrackerModule.apiKeyDefaultsKey` and the FedEx keys — whose
    /// names say user defaults but which are really iCloud Keychain accounts —
    /// this one genuinely is `UserDefaults`.
    ///
    /// Stored by name rather than by `PersistentIdentifier`, which is not stable
    /// across a store rebuild or a reinstall. Name is already this module's
    /// de-facto vehicle identity: `FuellyImporter` both de-duplicates and looks
    /// up existing vehicles by it.
    public static let selectedVehicleDefaultsKey = "fuel.selectedVehicle"

    public static var models: [any PersistentModel.Type] {
        [Vehicle.self, FuelEntry.self]
    }

    @MainActor
    public static func rootView() -> some View {
        FuelRootView()
    }
}
