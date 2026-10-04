import Core
import CoreData
import SwiftUI

struct FinanceRootView: View {
    /// The module's own Core Data context — set by `FinanceTrackerModule.rootView(context:container:)`.
    @Environment(\.managedObjectContext) private var context
    @Environment(\.financePersistentContainer) private var container

    /// The Mac sidebar's own selection when it picks the section; nil on the
    /// phone, where the tab bar's selection below does.
    var section: Binding<String>?
    @State private var ownSection = FinanceTrackerModule.sections[0].id

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

    @Environment(\.financeAdvisor) private var advisor
    @Environment(\.financeAdvisorEnabled) private var isAdvisorEnabled
    @Environment(\.financeReportPreferences) private var reportPreferences
    @Environment(\.moduleLayout) private var layout
    /// A report asked for from outside the Summary — a tapped "report is
    /// ready" notification, a debug launch: a cover on the phone, a window on
    /// the Mac (`presentsReport`).
    @State private var report: FinanceReportWindowValue?
    /// `-FinanceOpenReview YES`'s review sheet.
    @State private var debugReview: ReportScope?

    var body: some View {
        ModuleTabView(selection: section ?? $ownSection, sections: FinanceTrackerModule.sections) { section in
            switch section.id {
            case "months": MonthsView()
            case "spending": SpendingView()
            case "holdings": HoldingsView()
            default: SummaryView()
            }
        }
        .toolbar {
            // The Mac's Report button (⇧⌘R) for every section but the
            // Summary, which has its own that follows its Whose filter. With
            // only the Summary's, the shortcut did nothing while Months,
            // Spending or Holdings was selected: the sidebar layout shows just
            // the selected section. On the phone each tab's stack has its own
            // toolbar, so this one wouldn't show there.
            if layout == .sidebar, (section ?? $ownSection).wrappedValue != FinanceTrackerModule.sections[0].id {
                ToolbarItem(placement: .primaryAction) {
                    let scope = reportedScope
                    Button {
                        if let scope { report = FinanceReportWindowValue(scope: scope, ownerName: defaultOwnerName) }
                    } label: {
                        Label("Report", systemImage: "doc.text")
                    }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(scope == nil)
                    .help(scope.map { "Open the \($0.title) report" } ?? "No month to report on yet")
                }
            }
        }
        .environment(\.financeCanCreateHousehold, hasCaughtUp)
        // The review's "Open Gold & Silver" switches to Holdings rather than
        // stacking a second Holdings over the sheet.
        .environment(\.openFinanceSection, OpenFinanceSectionAction { id in
            (section ?? $ownSection).wrappedValue = id
        })
        .task { await MetalPriceFeed.shared.refreshIfStale() }
        // Loads the model ahead of the Summary's review — only when it can
        // run and the person hasn't switched it off, like Trips. Keyed on
        // availability, so a model that finishes downloading is warmed then.
        .task(id: advisor.availability(isEnabled: isAdvisorEnabled)) {
            if advisor.availability(isEnabled: isAdvisorEnabled) == .available {
                advisor.prewarm()
            }
        }
        // A tapped "September's report is ready" (`FinanceReportReady`): the
        // app sets the router and opens Finance; this presents the report and
        // clears it, once.
        .onChange(of: FinanceReportRouter.shared.pending, initial: true) { _, scope in
            guard let scope else { return }
            FinanceReportRouter.shared.pending = nil
            report = FinanceReportWindowValue(scope: scope, ownerName: defaultOwnerName)
        }
        .presentsReport($report)
        .sheet(item: $debugReview) { scope in
            ReviewSheet(scope: scope, filter: .all)
        }
        // Tops up the year of 1st-of-the-month reminders; opening Finance is
        // also the one moment asking for notification permission makes sense
        // for them.
        .task { await FinanceMonthReminder.reschedule() }
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
            await openDebugReport()
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
                isShared: isOwnedShare,
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
    }

    /// The month the Summary headlines, for the Mac's Report button.
    private var reportedScope: ReportScope? {
        _ = months.count
        guard let household = FinanceHouseholdResolver.forDisplay(among: Array(households), container: container) else { return nil }
        return FinanceReportData.defaultScope(for: household, live: MetalPriceFeed.shared.live)
    }

    /// Settings' "Whose by default", while that person is in the household.
    private var defaultOwnerName: String? {
        let owners = households.flatMap { Array($0.owners ?? []) }
        return OwnerFilter.reportDefaultOwnerName(preferred: reportPreferences.defaultOwnerName, owners: owners)
    }

    #if DEBUG
    /// `-FinanceOpenReport YES` presents the report for the month the Summary
    /// headlines, `-FinanceOpenReview YES` its review — the only way to get a
    /// screenshot of either from a script. Runs after the seed, and waits a
    /// little for the store to show its months: a seed lands in the same
    /// turn, a synced household some seconds later.
    private func openDebugReport() async {
        let defaults = UserDefaults.standard
        let opensReport = defaults.bool(forKey: "FinanceOpenReport")
        let opensReview = defaults.bool(forKey: "FinanceOpenReview")
        guard opensReport || opensReview else { return }
        for _ in 0..<20 {
            if let household = FinanceHouseholdResolver.forDisplay(among: Array(households), container: container),
               let scope = FinanceReportData.defaultScope(for: household, live: MetalPriceFeed.shared.live) {
                if opensReport {
                    report = FinanceReportWindowValue(scope: scope, ownerName: defaultOwnerName)
                } else {
                    debugReview = scope
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
        }
    }
    #endif

    private var needsTidying: Bool {
        _ = months.count
        return FinanceFold.needsTidying(
            households: Array(households),
            privateStore: container?.privatePersistentStore,
            canEdit: { canEdit($0, in: container) },
            isShared: isOwnedShare
        )
    }

    /// Whether this person has shared `household` with their partner — the
    /// one `FinanceFold.tidy` must never fold away, or the share goes with it.
    /// Only asked when there are two private households, which is rare.
    private func isOwnedShare(_ household: SharedFinanceHousehold) -> Bool {
        guard let container else { return false }
        if case .owned = SharingStatusResolver.status(for: household, in: container) { return true }
        return false
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
