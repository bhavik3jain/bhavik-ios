import Core
import CoreData
import SwiftUI

public enum PointsTrackerModule {
    public static let accent = ModuleAccent(name: "Points", color: Color(red: 0.55, green: 0.36, blue: 0.85))

    /// No SwiftData models: Points was built on Core Data from the start so
    /// a household can be shared with a partner. See `PointsModel`.
    ///
    /// `context` and `container` are the module's own store, built in
    /// `BhavikApp.init()` — re-scoped onto the standard keys here so every
    /// view below reads `@Environment(\.managedObjectContext)` and
    /// `\.pointsPersistentContainer`, exactly as Fuel does.
    @MainActor
    public static func rootView(context: NSManagedObjectContext, container: NSPersistentCloudKitContainer) -> some View {
        PointsRootView()
            .environment(\.managedObjectContext, context)
            .environment(\.pointsPersistentContainer, container)
    }
}
