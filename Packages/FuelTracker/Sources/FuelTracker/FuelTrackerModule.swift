import SwiftData
import SwiftUI
import Core

public enum FuelTrackerModule {
    public static let accent = ModuleAccent(name: "Fuel", color: Color(red: 0.06, green: 0.62, blue: 0.56))

    public static var models: [any PersistentModel.Type] {
        [Vehicle.self, FuelEntry.self]
    }

    @MainActor
    public static func rootView() -> some View {
        FuelRootView()
    }
}
