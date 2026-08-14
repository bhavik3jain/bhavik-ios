#if DEBUG
import Foundation
import SwiftData

/// Imports a CSV sitting in the app's Documents folder on launch.
///
/// Debug builds only, and only when launched with `-FuelSeedCSV` — it saves
/// re-driving the file picker when trying the app out on a simulator.
public enum FuelDebugSeed {
    public static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "FuelSeedCSV")
    }

    @MainActor
    public static func run(context: ModelContext) {
        guard (try? context.fetchCount(FetchDescriptor<Vehicle>())) == 0 else { return }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let files = try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil),
              let csv = files.first(where: { $0.pathExtension.lowercased() == "csv" })
        else { return }

        _ = try? FuellyImporter.importCSV(at: csv, into: context)
    }
}
#endif
