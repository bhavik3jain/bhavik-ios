import Core
import CoreData
import SwiftUI

struct FinanceRootView: View {
    /// The module's own Core Data context — set by `FinanceTrackerModule.rootView(context:container:)`.
    @Environment(\.managedObjectContext) private var context
    @Environment(\.financePersistentContainer) private var container

    @State private var selection = "summary"

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: ModuleTab.home) {
                Color.clear
            }
            Tab("Summary", systemImage: "chart.line.uptrend.xyaxis", value: "summary") {
                SummaryView()
            }
            Tab("Months", systemImage: "calendar", value: "months") {
                MonthsView()
            }
            Tab("Spending", systemImage: "creditcard", value: "spending") {
                SpendingView()
            }
            Tab("Holdings", systemImage: "building.columns", value: "holdings") {
                HoldingsView()
            }
        }
        .tint(FinanceTrackerModule.accent.color)
        .minimizesTabBarOnScroll()
        .dismissesOnHomeTab($selection, restoringTo: "summary")
        #if DEBUG
        .task {
            guard FinanceDebugSeed.isRequested else { return }
            // Waits for iCloud like Points' seeder does, so a seeded second
            // device doesn't mint a household of its own before the first
            // device's has arrived.
            guard await CloudKitImportGate.waitForFirstImport(of: container) else { return }
            FinanceDebugSeed.run(context: context, container: container)
        }
        #endif
    }
}
