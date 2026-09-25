import Core
import CoreData
import SwiftUI

public enum FinanceTrackerModule {
    public static let accent = ModuleAccent(name: "Finance", color: Color(red: 0.11, green: 0.50, blue: 0.25))

    /// The hub row's and peek's icon.
    public static let symbolName = "chart.line.uptrend.xyaxis.circle.fill"

    /// No SwiftData models: Finance is on Core Data from the start so a
    /// household's balance sheet can be shared with a partner. See `FinanceModel`.
    ///
    /// `context` and `container` are the module's own store, built in
    /// `BhavikApp.init()` — re-scoped onto the standard keys here so every
    /// view below reads `@Environment(\.managedObjectContext)` and
    /// `\.financePersistentContainer`, exactly as Points does.
    @MainActor
    public static func rootView(context: NSManagedObjectContext, container: NSPersistentCloudKitContainer) -> some View {
        FinanceRootView()
            .environment(\.managedObjectContext, context)
            .environment(\.financePersistentContainer, container)
    }
}
