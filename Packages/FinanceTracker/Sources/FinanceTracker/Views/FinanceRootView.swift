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
    @State private var mergeOffer: FinanceMergeOffer?
    /// The share whose merge offer was turned down, so it isn't made again.
    @AppStorage("finance.declinedMergeInto") private var declinedMergeInto = ""

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
        .onChange(of: pendingOfferKey, initial: true) { _, key in
            guard key != nil else { return }
            mergeOffer = FinanceHouseholdResolver.mergeOffer(among: Array(households), container: container)
        }
        .alert(
            "Add Your Finances to the Shared Household?",
            isPresented: Binding(get: { mergeOffer != nil }, set: { if !$0 { mergeOffer = nil } }),
            presenting: mergeOffer
        ) { offer in
            Button("Merge") { merge(offer) }
            Button("Keep Separate", role: .cancel) { declinedMergeInto = offer.sharedKey }
        } message: { offer in
            Text(offer.message)
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

    /// The share a merge could be offered for, once iCloud has caught up
    /// (so the own household is complete) and unless it was turned down.
    /// Cheap enough for every render; the full check, which asks CloudKit
    /// whether the own household is itself shared, runs only when this changes.
    private var pendingOfferKey: String? {
        guard hasCaughtUp, let container else { return nil }
        _ = months.count
        let offer = FinanceHouseholdResolver.mergeOffer(
            among: Array(households),
            privateStore: container.privatePersistentStore,
            canEdit: { canEdit($0, in: container) }
        )
        guard let offer, offer.sharedKey != declinedMergeInto else { return nil }
        return offer.sharedKey
    }

    private func merge(_ offer: FinanceMergeOffer) {
        offer.merge(tiebreak: .cloudKit(container))
        do {
            try context.saveIfNeeded()
        } catch {
            // Nothing half-merged is left to sync by the next save.
            context.rollback()
        }
    }
}
