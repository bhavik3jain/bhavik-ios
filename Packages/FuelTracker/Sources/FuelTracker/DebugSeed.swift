#if DEBUG
import CoreData
import Foundation

/// Imports a CSV sitting in the app's Documents folder on launch.
///
/// Debug builds only, and only when launched with `-FuelSeedCSV` — it saves
/// re-driving the file picker when trying the app out on a simulator.
public enum FuelDebugSeed {
    public static var isRequested: Bool {
        // Never against a store `FuelLegacyMigration` has already run against —
        // that device may be holding real, possibly-shared vehicles (or simply
        // have already decided there was nothing to migrate), and stacking a
        // fake garage on top of either is never what `-FuelSeedCSV` is asking
        // for.
        UserDefaults.standard.bool(forKey: "FuelSeedCSV") && !FuelLegacyMigration.hasRun
    }

    @MainActor
    public static func run(context: NSManagedObjectContext) {
        guard (try? context.count(for: Vehicle.fetchRequest())) == 0 else { return }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let files = try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil),
              let csv = files.first(where: { $0.pathExtension.lowercased() == "csv" })
        else { return }

        _ = try? FuellyImporter.importCSV(at: csv, into: context)
    }
}
#endif
