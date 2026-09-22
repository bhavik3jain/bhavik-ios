import Core
import CoreData
import SwiftData
import SwiftUI

public enum FuelTrackerModule {
    public static let accent = ModuleAccent(name: "Fuel", color: Color(red: 0.06, green: 0.62, blue: 0.56))

    /// The vehicle the module last opened on, by name.
    ///
    /// Unlike `TVTrackerModule.apiKeyDefaultsKey` and the FedEx keys — whose
    /// names say user defaults but which are really iCloud Keychain accounts —
    /// this one genuinely is `UserDefaults`.
    ///
    /// Stored by name rather than by an object identifier, which is not stable
    /// across a store rebuild or a reinstall. Name is already this module's
    /// de-facto vehicle identity: `FuellyImporter` both de-duplicates and looks
    /// up existing vehicles by it.
    public static let selectedVehicleDefaultsKey = "fuel.selectedVehicle"

    /// The `Legacy*` SwiftData models, not the new Core Data ones — this is
    /// what keeps them registered in `AppSchema.models` in `BhavikApp.swift`,
    /// so `FuelLegacyMigration` still has a store to read real vehicles from.
    /// See `LegacyVehicle`'s own doc comment: do NOT change this to the new
    /// Core Data types, and do NOT drop it from `AppSchema.models` — both are
    /// a later, human-gated step.
    public static var models: [any PersistentModel.Type] {
        [LegacyVehicle.self, LegacyFuelEntry.self]
    }

    /// `context` is the module's own Core Data context — see
    /// `CloudSharedStore.makeContainer` and `BhavikApp.init()`, which builds it
    /// and passes it to this call at `HomeView.swift`'s `moduleContent(for:)`.
    /// Set on the environment here, at the top of the module's own view tree,
    /// rather than relying on the app shell having set it globally — every
    /// view below this one that reads `@Environment(\.managedObjectContext)`
    /// gets it from here.
    @MainActor
    public static func rootView(context: NSManagedObjectContext) -> some View {
        FuelRootView()
            .environment(\.managedObjectContext, context)
    }
}
