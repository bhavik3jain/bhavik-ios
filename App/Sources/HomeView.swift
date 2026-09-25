import Core
import CoreData
import ExploreTracker
import FinanceTracker
import FuelTracker
import GymTracker
import ParcelTracker
import PointsTracker
import SwiftData
import SwiftUI
import TripTracker
import TVTracker

struct HomeView: View {
    @State private var selectedModule: SelectedModule?
    /// Which trackers the hub and the Mac sidebar list, in what order — set
    /// from Settings' Customize Trackers screen.
    @ObservedObject private var layoutStore = TrackerLayoutStore.shared

    // Each module's own data, so a row can say what is actually going on
    // rather than repeating a fixed description.
    @Query(filter: #Predicate<WorkoutSession> { $0.finishedAt != nil }, sort: \WorkoutSession.startedAt, order: .reverse)
    private var sessions: [WorkoutSession]
    @Query private var shows: [Show]
    @Query(filter: #Predicate<Parcel> { !$0.isArchived }) private var parcels: [Parcel]
    // Trips moved to Core Data — see BhavikApp.init()'s tripContainer, which
    // sets this environment key at the WindowGroup level the same way
    // .modelContainer(container) does for every @Query above. Read here both
    // for this view's own summary (below) and to pass on explicitly to
    // TripTrackerModule.rootView(context:) in moduleContent(for:) — a module
    // is handed its context explicitly rather than relying on it having been
    // set globally, since a second Core Data module (Fuel, Explore) will need
    // a context of its own that can't share this one environment key.
    @Environment(\.managedObjectContext) private var tripContext
    // The container itself, for Trips' Share button and sharing-status badges
    // — see Core's `ModulePersistentContainers.swift`.
    @Environment(\.tripPersistentContainer) private var tripPersistentContainer
    // Phase (under way, upcoming, finished) is worked out from the dates in
    // Swift; only the stored archive flag can go in the predicate.
    @FetchRequest(sortDescriptors: [], predicate: NSPredicate(format: "isArchived == NO"))
    private var tripResults: FetchedResults<SharedTrip>
    private var trips: [SharedTrip] { Array(tripResults) }
    // Fuel moved to Core Data too — see BhavikApp.init()'s fuelContainer.
    // Reads Core's own `\.fuelManagedObjectContext` key rather than
    // `\.managedObjectContext`, which Trips already occupies at this level —
    // see ModuleManagedObjectContexts.swift's doc comment. And unlike Trips'
    // `tripResults` above, this can't be a plain `@FetchRequest` either: that
    // property wrapper only ever reads `\.managedObjectContext`, which on
    // this same view already resolves to Trips' container, so a second
    // `@FetchRequest` declared here would silently query the wrong store.
    // `ManagedObjectFetch` fetches directly against the context it's handed
    // instead — see its own doc comment.
    @Environment(\.fuelManagedObjectContext) private var fuelContext
    // The container itself, for Fuel's Share button and sharing-status badges
    // — same reasoning as `tripPersistentContainer` above.
    @Environment(\.fuelPersistentContainer) private var fuelPersistentContainer
    @StateObject private var vehicleFetch = ManagedObjectFetch<SharedVehicle>(
        SharedVehicle.fetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \SharedVehicle.createdAt, ascending: true)])
    )
    private var vehicles: [SharedVehicle] { vehicleFetch.results }
    // Explore moved to Core Data too — see BhavikApp.init()'s exploreContainer
    // and its own `\.exploreManagedObjectContext` key, the same reasoning as
    // Fuel's `fuelContext`/`vehicleFetch` above.
    @Environment(\.exploreManagedObjectContext) private var exploreContext
    // The container itself, for Explore's Share button and sharing-status
    // badges — same reasoning as `fuelPersistentContainer` above.
    @Environment(\.explorePersistentContainer) private var explorePersistentContainer
    @StateObject private var guideFetch = ManagedObjectFetch<SharedGuide>(
        SharedGuide.fetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \SharedGuide.createdAt, ascending: false)])
    )
    private var guides: [SharedGuide] { guideFetch.results }
    // Points is Core Data too — see BhavikApp.init()'s pointsContainer and
    // its own `\.pointsManagedObjectContext` key, the same reasoning as
    // Explore's `exploreContext`/`guideFetch` above.
    @Environment(\.pointsManagedObjectContext) private var pointsContext
    // The container itself, for Points' Share button and sharing-status
    // badges — same reasoning as `fuelPersistentContainer` above.
    @Environment(\.pointsPersistentContainer) private var pointsPersistentContainer
    @StateObject private var pointsAccountFetch = ManagedObjectFetch<SharedPointsAccount>(
        SharedPointsAccount.fetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \SharedPointsAccount.createdAt, ascending: true)])
    )
    private var pointsAccounts: [SharedPointsAccount] { pointsAccountFetch.results }
    // Finance is Core Data too — see BhavikApp.init()'s financeContainer and
    // its own `\.financeManagedObjectContext` key, the same reasoning as
    // Points' `pointsContext`/`pointsAccountFetch` above. Every household's
    // months come back; the peek and detail pick the newest.
    @Environment(\.financeManagedObjectContext) private var financeContext
    // The container itself, for Finance's Share button and sharing-status
    // badges — same reasoning as `fuelPersistentContainer` above.
    @Environment(\.financePersistentContainer) private var financePersistentContainer
    @StateObject private var financeMonthFetch = ManagedObjectFetch<SharedFinanceMonth>(
        SharedFinanceMonth.fetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \SharedFinanceMonth.yearMonth, ascending: true)])
    )
    private var financeMonths: [SharedFinanceMonth] { financeMonthFetch.results }
    /// Written by a Fuel peek's "Open My X3" so the module opens on that car.
    @AppStorage(FuelTrackerModule.selectedVehicleDefaultsKey) private var selectedVehicleName = ""

    var body: some View {
        Group {
            #if os(macOS)
            macBody
            #else
            iOSBody
            #endif
        }
        // Starts (or restarts, if the environment value ever changes) the
        // Fuel fetch — see `vehicleFetch`'s own doc comment for why this
        // can't just be a `@FetchRequest` alongside `tripResults` above.
        .task(id: fuelContext) {
            guard let fuelContext else { return }
            vehicleFetch.start(context: fuelContext)
        }
        // Starts (or restarts) the Explore fetch, same reasoning as the Fuel
        // one just above.
        .task(id: exploreContext) {
            guard let exploreContext else { return }
            guideFetch.start(context: exploreContext)
        }
        // Starts (or restarts) the Points fetch, same reasoning again.
        .task(id: pointsContext) {
            guard let pointsContext else { return }
            pointsAccountFetch.start(context: pointsContext)
        }
        // Starts (or restarts) the Finance fetch, same reasoning again.
        .task(id: financeContext) {
            guard let financeContext else { return }
            financeMonthFetch.start(context: financeContext)
        }
        .showsShareAcceptOutcome()
    }

    // MARK: - iOS: hub list, modules as a full-screen cover

    private var iOSBody: some View {
        NavigationStack {
            List {
                ForEach(layoutStore.visibleModules) { module in
                    ModuleRow(
                        accent: module.accent,
                        icon: module.icon,
                        detail: detail(for: module)
                    ) { selectedModule = module }
                        // Each row peeks on a long press: the module's own summary
                        // card, fed from the queries above so no module reads
                        // another's data.
                        .contextMenu {
                            contextMenuItems(for: module)
                        } preview: {
                            peek(for: module)
                        }
                }
            }
            .navigationTitle("Trackers")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        AppSettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .fullScreenCover(item: $selectedModule) { module in
                moduleContent(for: module)
                    .presentsShareSheets()
            }
        }
    }

    // MARK: - macOS: a sidebar, modules in the detail pane

    #if os(macOS)
    /// Replaces the hub-and-sheet pattern with the split view a Mac app is
    /// expected to have: the sidebar IS the way in and out of a tracker, so
    /// there is no dismiss control to build and no sheet to size. A module's
    /// own root view is unchanged from iOS — including its internal "Home" tab,
    /// whose whole job upstream is dismissing a sheet. Embedded here it has
    /// nothing to dismiss, so tapping it just bounces back to the module's own
    /// first tab; leaving a tracker is what the sidebar is for now.
    private var macBody: some View {
        NavigationSplitView {
            List(layoutStore.visibleModules, selection: $selectedModule) { module in
                MacSidebarRow(accent: module.accent, icon: module.icon, detail: detail(for: module))
                    .tag(module)
                    .contextMenu {
                        contextMenuItems(for: module)
                    } preview: {
                        peek(for: module)
                    }
            }
            .navigationTitle("Trackers")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
            .toolbar {
                ToolbarItem {
                    NavigationLink {
                        AppSettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
        } detail: {
            if let selectedModule {
                moduleContent(for: selectedModule)
                    .presentsShareSheets()
                    // A fresh identity per tracker, so switching trackers can't
                    // leave one module's navigation state bleeding into another's
                    // view — the same freshness a fullScreenCover's own dismissal
                    // and re-presentation gives it on iOS.
                    .id(selectedModule)
            } else {
                ContentUnavailableView("Select a Tracker", systemImage: "square.grid.2x2")
            }
        }
        .navigationSplitViewStyle(.balanced)
        // Menu-bar shortcuts (⌘1 onward, one per visible tracker), posted from
        // BhavikApp's commands — a Scene's .commands can't reach into a
        // WindowGroup's view state directly, so it goes by notification
        // instead of a shared observable.
        .onReceive(NotificationCenter.default.publisher(for: .selectTracker)) { note in
            guard let raw = note.userInfo?["module"] as? String, let module = SelectedModule(rawValue: raw) else { return }
            selectedModule = module
        }
        .onAppear {
            // An empty detail pane on first launch reads as broken, not calm.
            if selectedModule == nil { selectedModule = layoutStore.visibleModules.first }
        }
        // Hiding the open tracker (from Settings, or on another device) would
        // otherwise leave it in the detail pane with no sidebar row selected
        // and no way back to it.
        .onChange(of: layoutStore.visibleModules) { _, visible in
            if let selectedModule, !visible.contains(selectedModule) { self.selectedModule = nil }
        }
    }
    #endif

    // MARK: - Shared: which module is which

    @ViewBuilder
    private func moduleContent(for module: SelectedModule) -> some View {
        switch module {
        case .gym:
            GymTrackerModule.rootView()
        case .fuel:
            // Always set by the time a module can be opened — BhavikApp's
            // WindowGroup sets `\.fuelManagedObjectContext` and
            // `\.fuelPersistentContainer` unconditionally in `.init()`,
            // before any view (this one included) exists.
            FuelTrackerModule.rootView(context: fuelContext!, container: fuelPersistentContainer!)
        case .tv:
            TVTrackerModule.rootView()
        case .parcels:
            ParcelTrackerModule.rootView()
        case .trips:
            // Always set by the time a module can be opened — BhavikApp's
            // WindowGroup sets `\.tripPersistentContainer` unconditionally in
            // `.init()`, before any view (this one included) exists.
            TripTrackerModule.rootView(context: tripContext, container: tripPersistentContainer!)
        case .explore:
            // Always set by the time a module can be opened — BhavikApp's
            // WindowGroup sets `\.exploreManagedObjectContext` and
            // `\.explorePersistentContainer` unconditionally in `.init()`,
            // before any view (this one included) exists.
            ExploreTrackerModule.rootView(context: exploreContext!, container: explorePersistentContainer!)
        case .points:
            // Always set by the time a module can be opened — BhavikApp's
            // WindowGroup sets `\.pointsManagedObjectContext` and
            // `\.pointsPersistentContainer` unconditionally in `.init()`,
            // before any view (this one included) exists.
            PointsTrackerModule.rootView(context: pointsContext!, container: pointsPersistentContainer!)
        case .finance:
            // Always set by the time a module can be opened — BhavikApp's
            // WindowGroup sets `\.financeManagedObjectContext` and
            // `\.financePersistentContainer` unconditionally in `.init()`,
            // before any view (this one included) exists.
            FinanceTrackerModule.rootView(context: financeContext!, container: financePersistentContainer!)
        }
    }

    private func detail(for module: SelectedModule) -> String {
        switch module {
        case .trips: TripTrackerModule.homeDetail(trips: trips)
        // Counts only, so no pins needed — order doesn't change a total.
        case .explore: GuideSummary.homeDetail(for: guides.map { GuideSummary.summarize($0) })
        case .gym: gymDetail
        case .tv: tvDetail
        case .parcels: parcelDetail
        case .fuel: fuelDetail
        case .points: PointsTrackerModule.homeDetail(accounts: pointsAccounts)
        case .finance: FinanceTrackerModule.homeDetail(months: financeMonths)
        }
    }

    @ViewBuilder
    private func peek(for module: SelectedModule) -> some View {
        switch module {
        case .trips: TripTrackerModule.homePeek(trips: trips)
        case .explore: ExploreTrackerModule.homePeek(guides: guides)
        case .gym: GymTrackerModule.homePeek(sessions: sessions)
        case .tv: TVTrackerModule.homePeek(shows: shows)
        case .parcels: ParcelTrackerModule.homePeek(parcels: parcels)
        case .fuel: FuelTrackerModule.homePeek(vehicles: vehicles)
        case .points: PointsTrackerModule.homePeek(accounts: pointsAccounts)
        case .finance: FinanceTrackerModule.homePeek(months: financeMonths)
        }
    }

    @ViewBuilder
    private func contextMenuItems(for module: SelectedModule) -> some View {
        openButton(module.accent.name, module)
        // Fuel is the one module whose peek can jump straight into a specific
        // car rather than just opening the module.
        if module == .fuel, vehicles.count > 1 {
            ForEach(VehicleSummary.fleet(vehicles)) { summary in
                Button {
                    selectedVehicleName = summary.name
                    selectedModule = .fuel
                } label: {
                    Label("Open \(summary.name)", systemImage: "car.fill")
                }
            }
        }
    }

    private func openButton(_ name: String, _ module: SelectedModule) -> some View {
        Button {
            selectedModule = module
        } label: {
            Label("Open \(name)", systemImage: "arrow.up.forward.app")
        }
    }

    private var gymDetail: String {
        guard let last = sessions.first else { return "No workouts yet" }
        return "Last workout \(last.startedAt.formatted(.relative(presentation: .named)))"
    }

    private var tvDetail: String {
        let ready = Schedule.readyToWatch(shows: shows).count
        if ready > 0 { return "\(counted(ready, "episode")) ready" }
        if shows.isEmpty { return "No shows yet" }
        let upcoming = Schedule.upcoming(shows: shows).count
        return upcoming > 0 ? "Nothing to watch, \(upcoming) coming up" : "All caught up"
    }

    private var parcelDetail: String {
        let onTheWay = parcels.count { !$0.status.isSettled }
        if onTheWay > 0 { return "\(counted(onTheWay, "order")) on the way" }
        return parcels.isEmpty ? "No orders" : "Nothing on the way"
    }

    // Used to describe `vehicles.first` alone, so a second car never appeared
    // on the hub. The string is built in FuelTracker, where it can be tested.
    private var fuelDetail: String {
        VehicleSummary.homeDetail(for: VehicleSummary.fleet(vehicles))
    }
}

/// Identifies a tracker across both platforms: the value iOS's fullScreenCover
/// presents by, macOS's sidebar selects by, and the menu-bar shortcut
/// notification carries by raw value.
enum SelectedModule: String, Identifiable, Hashable, CaseIterable {
    case trips
    case explore
    case gym
    case tv
    case parcels
    case fuel
    // Last, so an existing saved layout picks it up at the end of the list.
    case points
    // Last for the same reason.
    case finance
    var id: String { rawValue }

    /// Name and color, for the hub, the sidebar, Settings and the Trackers menu.
    var accent: ModuleAccent {
        switch self {
        case .trips: TripTrackerModule.accent
        case .explore: ExploreTrackerModule.accent
        case .gym: GymTrackerModule.accent
        case .tv: TVTrackerModule.accent
        case .parcels: ParcelTrackerModule.accent
        case .fuel: FuelTrackerModule.accent
        case .points: PointsTrackerModule.accent
        case .finance: FinanceTrackerModule.accent
        }
    }

    var icon: String {
        switch self {
        case .trips: "suitcase.rolling.fill"
        case .explore: "map.fill"
        case .gym: "dumbbell.fill"
        case .tv: "tv.fill"
        case .parcels: "shippingbox.fill"
        case .fuel: "fuelpump.fill"
        case .points: "star.circle.fill"
        case .finance: FinanceTrackerModule.symbolName
        }
    }
}

extension Notification.Name {
    /// Posted by BhavikApp's ⌘1… menu commands; userInfo["module"] is a
    /// `SelectedModule` raw value. A notification rather than a shared
    /// observable because a Scene's `.commands` sits outside the WindowGroup
    /// and has no direct line to HomeView's own state.
    static let selectTracker = Notification.Name("com.bhavikjain.trackers.selectTracker")
}

private struct ModuleRow: View {
    let accent: ModuleAccent
    let icon: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(accent.color, in: RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 2) {
                    Text(accent.name)
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

#if os(macOS)
/// A sidebar row. No chevron and no button action — `List(selection:)` on the
/// enclosing list already makes the whole row a click target and shows the
/// selected one highlighted, the way Mail's or Notes' sidebar does.
private struct MacSidebarRow: View {
    let accent: ModuleAccent
    let icon: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(accent.color, in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 1) {
                Text(accent.name)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}
#endif
