import Core
import CoreData
import SwiftUI

struct FinanceRootView: View {
    /// The module's own Core Data context — set by `FinanceTrackerModule.rootView(context:container:)`.
    @Environment(\.managedObjectContext) private var context
    @Environment(\.financePersistentContainer) private var container

    @State private var selection = "summary"

    /// Every household, and every month so a synced-in duplicate month
    /// re-renders this view: what `FinanceFold.needsTidying` looks at.
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \SharedFinanceHousehold.createdAt, ascending: true)])
    private var households: FetchedResults<SharedFinanceHousehold>
    @FetchRequest(sortDescriptors: [])
    private var months: FetchedResults<SharedFinanceMonth>

    /// Whether this launch's first iCloud import has landed (or the wait
    /// gave up). See `financeCanCreateHousehold`.
    @State private var hasCaughtUp = false

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
        .environment(\.financeCanCreateHousehold, hasCaughtUp)
        .task {
            // Holds back creating a household until iCloud has caught up,
            // like Trips' importer and Points' seeder, so a second device —
            // seeded or typed into — doesn't mint one of its own before the
            // first device's arrives.
            guard await CloudKitImportGate.waitForFirstImport(of: container) else { return }
            hasCaughtUp = true
            #if DEBUG
            if FinanceDebugSeed.isRequested {
                FinanceDebugSeed.run(context: context, container: container)
            }
            #endif
        }
        // Folds a duplicate household or month as soon as a sync brings one
        // in — on both devices at once, which `FinanceFold` is built for.
        .onChange(of: needsTidying, initial: true) { _, needed in
            guard needed else { return }
            let changed = FinanceFold.tidy(
                in: context,
                privateStore: container?.privatePersistentStore,
                canEdit: { canEdit($0, in: container) },
                tiebreak: .cloudKit(container)
            )
            if changed {
                try? context.saveIfNeeded()
            }
        }
        .tint(FinanceTrackerModule.accent.color)
        .minimizesTabBarOnScroll()
        .dismissesOnHomeTab($selection, restoringTo: "summary")
    }

    private var needsTidying: Bool {
        _ = months.count
        return FinanceFold.needsTidying(
            households: Array(households),
            privateStore: container?.privatePersistentStore,
            canEdit: { canEdit($0, in: container) }
        )
    }
}
