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
    @ObservedObject private var notificationRouter = SharedChangeNotificationRouter.shared

    // Each module's own data, so a row can say what is actually going on
    // rather than repeating a fixed description.
    @Query(filter: #Predicate<WorkoutSession> { $0.finishedAt != nil }, sort: \WorkoutSession.startedAt, order: .reverse)
    private var sessions: [WorkoutSession]
    @Query private var shows: [Show]
    // The unwatched episodes, in one fetch, for the TV figures below (hub
    // row, peek, sidebar, Overview card). Reached through `show.episodes`
    // instead, each episode was a fault that cost a SQLite round trip of its
    // own the first time anything read it — several thousand of them, on the
    // main thread, every launch. See `Schedule`.
    @Query(filter: Schedule.unwatched) private var episodes: [Episode]
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
    // months come back; the peek and detail keep the household the module
    // shows (which is why they take the container) and pick its newest.
    @Environment(\.financeManagedObjectContext) private var financeContext
    // The container itself, for Finance's Share button and sharing-status
    // badges — same reasoning as `fuelPersistentContainer` above.
    @Environment(\.financePersistentContainer) private var financePersistentContainer
    @Environment(CloudSyncMonitor.self) private var syncMonitor: CloudSyncMonitor?
    @StateObject private var financeMonthFetch = ManagedObjectFetch<SharedFinanceMonth>(
        SharedFinanceMonth.fetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \SharedFinanceMonth.yearMonth, ascending: true)])
    )
    private var financeMonths: [SharedFinanceMonth] { financeMonthFetch.results }
    /// Written by a Fuel peek's "Open My X3" so the module opens on that car.
    @AppStorage(FuelTrackerModule.selectedVehicleDefaultsKey) private var selectedVehicleName = ""

    #if os(macOS)
    /// The section each tracker was last left on in the Mac sidebar, so coming
    /// back to Fuel lands on Trends again — what a tab bar's own selection did.
    @State private var macSections: [SelectedModule: String] = [:]
    /// The trip the sidebar has open under Trips; nil shows the trip list.
    @State private var openTripID: NSManagedObjectID?
    @State private var tripSection: TripSection = .plan
    @State private var showsPastTrips = false
    #endif

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
        // A tapped shared-change notification opens its tracker: the same
        // selection the hub row, the Mac sidebar and ⌘1… set. `initial`, so
        // a tap that launched the app is picked up once the hub exists.
        .onChange(of: notificationRouter.moduleToOpen, initial: true) { _, raw in
            guard let raw, let module = SelectedModule(rawValue: raw) else { return }
            notificationRouter.moduleToOpen = nil
            selectedModule = module
        }
        // What's on screen, so a notification about it is held back while
        // the app is in front — see SharedChangeNotificationDelegate.
        .onChange(of: selectedModule, initial: true) { _, module in
            notificationRouter.foregroundModuleID = module?.rawValue
        }
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
            // Every store at once, not `.refreshesFromCloud()`: this list's
            // `\.managedObjectContext` is Trips' alone, and the hub's counts come
            // from all eight trackers.
            .refreshable { await syncMonitor?.refresh() }
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
    /// there is no dismiss control to build and no sheet to size.
    ///
    /// The sidebar also picks the tracker's section, nested under it, so a
    /// module shows no tab bar here (`ModuleLayout.sidebar`). It used to embed
    /// each module's phone chrome unchanged — a row of tabs under the toolbar
    /// and a "Home" tab that, with no sheet to dismiss, just bounced back to
    /// the module's first tab.
    private var macBody: some View {
        NavigationSplitView {
            // Re-read once a minute, as the sync footer is: "Day 3" and "in 12
            // days" were read from `.now` only when a query changed, so a
            // window left open overnight still said yesterday's.
            TimelineView(.everyMinute) { context in
                List(selection: sidebarSelection) {
                    Label("Overview", systemImage: "square.grid.2x2")
                        .tag(MacSidebarItem.overview)

                    Section("Trackers") {
                        ForEach(layoutStore.visibleModules) { module in
                            MacSidebarRow(accent: module.accent, icon: module.icon, detail: sidebarDetail(for: module, asOf: context.date))
                                .tag(MacSidebarItem.tracker(module))
                                .contextMenu { contextMenuItems(for: module) }
                            if module == selectedModule {
                                nestedRows(for: module, asOf: context.date)
                            }
                        }
                    }
                }
            }
            // ⌘R had nothing on screen to show it working unless Settings
            // happened to be open; the sidebar is always there.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let syncMonitor { MacSyncFooter(monitor: syncMonitor) }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            if let selectedModule {
                moduleContent(
                    for: selectedModule,
                    section: sectionBinding(for: selectedModule),
                    trip: openTripBinding,
                    tripSection: $tripSection
                )
                .environment(\.moduleLayout, .sidebar)
                .presentsShareSheets()
                // A fresh identity per tracker, so switching trackers can't
                // leave one module's navigation state bleeding into another's
                // view — the same freshness a fullScreenCover's own dismissal
                // and re-presentation gives it on iOS. Per tracker, not per
                // section: a module keeps its own state (Fuel's add sheet)
                // across its sections, as it does across its tabs.
                .id(selectedModule)
            } else {
                MacOverview(
                    modules: layoutStore.visibleModules,
                    syncMonitor: syncMonitor,
                    open: { selectedModule = $0 },
                    // Only a trip under way has a day's plan to show; with
                    // nothing under way Trips lists what's coming up in the
                    // same height as every other row.
                    isTall: { module, now in
                        module == .trips && !TripTrackerModule.sidebarTrips(trips, asOf: now).underWay.isEmpty
                    }
                ) { module, now in
                    overviewCard(for: module, asOf: now)
                }
            }
        }
        // Menu-bar shortcuts (⌘0 for Overview, ⌘1 onward per visible tracker)
        // act on this window's selection, handed to BhavikApp's commands as
        // the focused scene's value. They used to go by a notification every
        // window listened for, so with a second window open (File ▸ New
        // Window) ⌘2 switched both of them.
        .focusedSceneValue(\.trackerSelection, $selectedModule)
        #if DEBUG
        // `-MacOpenTracker fuel` (or `fuel/trends`) opens a tracker, on a
        // section, at launch: the only way to look at a tracker's Mac layout
        // from a script, since nothing outside the app can click the sidebar
        // without Accessibility access. Navigation only — it writes nothing.
        .onAppear {
            guard let raw = UserDefaults.standard.string(forKey: "MacOpenTracker") else { return }
            let parts = raw.split(separator: "/").map(String.init)
            guard let first = parts.first, let module = SelectedModule(rawValue: first) else { return }
            if parts.count > 1 { macSections[module] = parts[1] }
            selectedModule = module
        }
        #endif
        // Hiding the open tracker (from Settings, or on another device) would
        // otherwise leave it in the detail pane with no sidebar row selected
        // and no way back to it. Overview is always there to fall back to.
        .onChange(of: layoutStore.visibleModules) { _, visible in
            if let selectedModule, !visible.contains(selectedModule) { self.selectedModule = nil }
        }
        // A trip deleted or archived on another device dropped the detail pane
        // back to the list, but the selection still named it — so neither
        // Trips nor any trip showed as selected.
        .onChange(of: tripResults.map(\.objectID)) { _, ids in
            if let openTripID, !ids.contains(openTripID) { self.openTripID = nil }
        }
        // A past trip opened from the list, or open when "Past trips" was
        // folded, was selected inside a collapsed disclosure: nothing in the
        // sidebar looked selected.
        .onChange(of: openTripID, initial: true) { _, id in
            guard let id, TripTrackerModule.sidebarTrips(trips).past.contains(where: { $0.objectID == id }) else { return }
            showsPastTrips = true
        }
    }

    /// The open trip, as the trip list inside Trips writes it. A different
    /// trip opens on Plan, as it does from the sidebar — the list used to
    /// write `openTripID` directly, so trip B opened on whatever face trip A
    /// was left on.
    private var openTripBinding: Binding<NSManagedObjectID?> {
        Binding {
            openTripID
        } set: { id in
            if id != openTripID { tripSection = .plan }
            openTripID = id
        }
    }

    /// The List's selection, read from and written to the state the detail
    /// pane is actually built from — which tracker, which of its sections,
    /// which trip. A tracker with sections is shown selected on its section
    /// row, so choosing the tracker's own row lands on the section it was
    /// last left on, as reopening a tab bar did.
    private var sidebarSelection: Binding<MacSidebarItem?> {
        Binding {
            guard let module = selectedModule else { return .overview }
            if module == .trips, let openTripID { return .trip(openTripID) }
            if module.sections.count > 1 { return .section(module, sectionBinding(for: module).wrappedValue) }
            return .tracker(module)
        } set: { item in
            switch item {
            case .overview?:
                selectedModule = nil
            case .tracker(let module)?:
                if module == .trips { openTripID = nil }
                selectedModule = module
            case .section(let module, let section)?:
                macSections[module] = section
                selectedModule = module
            case .trip(let id)?:
                if openTripID != id { tripSection = .plan }
                openTripID = id
                selectedModule = .trips
            case nil:
                // A click on empty sidebar space clears a List's selection;
                // the detail pane stays as it was rather than going blank.
                break
            }
        }
    }

    private func sectionBinding(for module: SelectedModule) -> Binding<String> {
        Binding {
            macSections[module] ?? module.sections.first?.id ?? ""
        } set: {
            macSections[module] = $0
        }
    }

    /// Under the open tracker: its sections when it has more than one, or —
    /// for Trips, whose one section is the list — the trips themselves.
    @ViewBuilder
    private func nestedRows(for module: SelectedModule, asOf now: Date) -> some View {
        if module == .trips {
            let groups = TripTrackerModule.sidebarTrips(trips, asOf: now)
            ForEach(groups.current) { trip in
                MacNestedRow(
                    title: trip.title,
                    dot: groups.underWay.contains(trip.objectID) ? module.accent.color : nil
                )
                .tag(MacSidebarItem.trip(trip.objectID))
            }
            if !groups.past.isEmpty {
                DisclosureGroup(isExpanded: $showsPastTrips) {
                    ForEach(groups.past) { trip in
                        MacNestedRow(title: trip.title)
                            .tag(MacSidebarItem.trip(trip.objectID))
                    }
                } label: {
                    MacNestedRow(title: "Past trips")
                }
            }
        } else if module.sections.count > 1 {
            ForEach(module.sections) { section in
                MacNestedRow(title: section.title)
                    .tag(MacSidebarItem.section(module, section.id))
            }
        }
    }

    /// The short figure at the trailing edge of a sidebar row — "Day 3", "36",
    /// "30.9" — or nothing when there's no single number worth showing. The
    /// Overview has the sentences.
    private func sidebarDetail(for module: SelectedModule, asOf now: Date) -> String? {
        switch module {
        case .trips: return TripTrackerModule.sidebarDetail(trips: trips, asOf: now)
        case .explore: return ExploreTrackerModule.sidebarDetail(guides: guides)
        case .fuel: return FuelTrackerModule.sidebarDetail(vehicles: vehicles)
        case .finance: return FinanceTrackerModule.sidebarDetail(months: financeMonths, container: financePersistentContainer)
        case .tv:
            // A count, not the list: `readyToWatch` built and sorted every
            // backlog episode on each render of the sidebar, which is every
            // click in it.
            let ready = Schedule.readyCount(episodes: episodes, asOf: now)
            return ready > 0 ? String(ready) : nil
        case .parcels:
            let onTheWay = parcels.count { !$0.status.isSettled }
            return onTheWay > 0 ? String(onTheWay) : nil
        case .gym, .points: return nil
        }
    }

    /// Each tracker's Overview card, fed from the queries above so no module
    /// reads another's data — the same arrangement as the phone's peeks.
    @ViewBuilder
    private func overviewCard(for module: SelectedModule, asOf now: Date) -> some View {
        let open = { selectedModule = module }
        switch module {
        case .trips:
            TripTrackerModule.overviewCard(trips: trips, asOf: now) { id, section in
                openTripID = id
                tripSection = section
                selectedModule = .trips
            }
        case .explore: ExploreTrackerModule.overviewCard(guides: guides, open: open)
        case .fuel: FuelTrackerModule.overviewCard(vehicles: vehicles, open: open)
        case .finance: FinanceTrackerModule.overviewCard(months: financeMonths, container: financePersistentContainer, open: open)
        case .gym: GymTrackerModule.overviewCard(sessions: sessions, asOf: now, open: open)
        case .tv: TVTrackerModule.overviewCard(shows: shows, episodes: episodes, asOf: now, open: open)
        case .parcels: ParcelTrackerModule.overviewCard(parcels: parcels, open: open)
        case .points: PointsTrackerModule.overviewCard(accounts: pointsAccounts, asOf: now, open: open)
        }
    }
    #endif

    // MARK: - Shared: which module is which

    /// A tracker's root view. The bindings are the Mac sidebar's, which picks
    /// the section (or, for Trips, the trip and its face) in place of the
    /// module's own tab bar; the phone leaves them nil.
    @ViewBuilder
    private func moduleContent(
        for module: SelectedModule,
        section: Binding<String>? = nil,
        trip: Binding<NSManagedObjectID?>? = nil,
        tripSection: Binding<TripSection>? = nil
    ) -> some View {
        switch module {
        case .gym:
            GymTrackerModule.rootView(section: section)
        case .fuel:
            // Always set by the time a module can be opened — BhavikApp's
            // WindowGroup sets `\.fuelManagedObjectContext` and
            // `\.fuelPersistentContainer` unconditionally in `.init()`,
            // before any view (this one included) exists.
            FuelTrackerModule.rootView(context: fuelContext!, container: fuelPersistentContainer!, section: section)
        case .tv:
            TVTrackerModule.rootView(section: section)
        case .parcels:
            ParcelTrackerModule.rootView(section: section)
        case .trips:
            // Always set by the time a module can be opened — BhavikApp's
            // WindowGroup sets `\.tripPersistentContainer` unconditionally in
            // `.init()`, before any view (this one included) exists.
            TripTrackerModule.rootView(
                context: tripContext,
                container: tripPersistentContainer!,
                trip: trip,
                tripSection: tripSection
            )
        case .explore:
            // Always set by the time a module can be opened — BhavikApp's
            // WindowGroup sets `\.exploreManagedObjectContext` and
            // `\.explorePersistentContainer` unconditionally in `.init()`,
            // before any view (this one included) exists. One section, so
            // nothing for the sidebar to pick.
            ExploreTrackerModule.rootView(context: exploreContext!, container: explorePersistentContainer!)
        case .points:
            // Always set by the time a module can be opened — BhavikApp's
            // WindowGroup sets `\.pointsManagedObjectContext` and
            // `\.pointsPersistentContainer` unconditionally in `.init()`,
            // before any view (this one included) exists.
            PointsTrackerModule.rootView(context: pointsContext!, container: pointsPersistentContainer!, section: section)
        case .finance:
            // Always set by the time a module can be opened — BhavikApp's
            // WindowGroup sets `\.financeManagedObjectContext` and
            // `\.financePersistentContainer` unconditionally in `.init()`,
            // before any view (this one included) exists.
            FinanceTrackerModule.rootView(context: financeContext!, container: financePersistentContainer!, section: section)
                .environment(\.financeNumbersExporter, .forThisPlatform)
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
        case .finance: FinanceTrackerModule.homeDetail(months: financeMonths, container: financePersistentContainer)
        }
    }

    @ViewBuilder
    private func peek(for module: SelectedModule) -> some View {
        switch module {
        case .trips: TripTrackerModule.homePeek(trips: trips)
        case .explore: ExploreTrackerModule.homePeek(guides: guides)
        case .gym: GymTrackerModule.homePeek(sessions: sessions)
        case .tv: TVTrackerModule.homePeek(episodes: episodes)
        case .parcels: ParcelTrackerModule.homePeek(parcels: parcels)
        case .fuel: FuelTrackerModule.homePeek(vehicles: vehicles)
        case .points: PointsTrackerModule.homePeek(accounts: pointsAccounts)
        case .finance: FinanceTrackerModule.homePeek(months: financeMonths, container: financePersistentContainer)
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
        let ready = Schedule.readyCount(episodes: episodes)
        if ready > 0 { return "\(counted(ready, "episode")) ready" }
        if shows.isEmpty { return "No shows yet" }
        let upcoming = Schedule.upcoming(episodes: episodes).count
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
        case .trips: TripTrackerModule.symbolName
        case .explore: ExploreTrackerModule.symbolName
        case .gym: GymTrackerModule.symbolName
        case .tv: TVTrackerModule.symbolName
        case .parcels: ParcelTrackerModule.symbolName
        case .fuel: FuelTrackerModule.symbolName
        case .points: PointsTrackerModule.symbolName
        case .finance: FinanceTrackerModule.symbolName
        }
    }

    /// The module's own screens: its tabs on the phone, the rows nested under
    /// it in the Mac sidebar.
    var sections: [ModuleSection] {
        switch self {
        case .trips: TripTrackerModule.sections
        case .explore: ExploreTrackerModule.sections
        case .gym: GymTrackerModule.sections
        case .tv: TVTrackerModule.sections
        case .parcels: ParcelTrackerModule.sections
        case .fuel: FuelTrackerModule.sections
        case .points: PointsTrackerModule.sections
        case .finance: FinanceTrackerModule.sections
        }
    }

}

#if os(macOS)
extension FocusedValues {
    /// The key window's open tracker — nil is the Overview — for BhavikApp's
    /// ⌘0… Trackers menu. A Scene's `.commands` sits outside the WindowGroup
    /// and has no direct line to HomeView's own state; a focused value is
    /// that line, and it reaches only the window in front.
    @Entry var trackerSelection: Binding<SelectedModule?>?
}
#endif

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
/// What a Mac sidebar row stands for.
enum MacSidebarItem: Hashable {
    case overview
    case tracker(SelectedModule)
    case section(SelectedModule, String)
    case trip(NSManagedObjectID)
}

/// A tracker's sidebar row: its 22pt tile, its name, and a short figure at the
/// trailing edge. No chevron and no button action — `List(selection:)` on the
/// enclosing list already makes the whole row a click target and shows the
/// selected one highlighted, the way Mail's or Notes' sidebar does.
private struct MacSidebarRow: View {
    let accent: ModuleAccent
    let icon: String
    let detail: String?

    var body: some View {
        HStack(spacing: 8) {
            ModuleIconTile(color: accent.color, symbol: icon, size: 22)
            Text(accent.name)
            Spacer(minLength: 4)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// A section or trip nested under the open tracker: text only, indented to
/// line up with the tracker's name rather than its tile, with a dot at the
/// trailing edge for the trip under way.
///
/// It used to carry an SF Symbol per row (suitcase, clock, car), which gave
/// the nested rows the same weight as the trackers they sit under.
private struct MacNestedRow: View {
    let title: String
    var dot: Color?

    var body: some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            if let dot {
                Circle()
                    .fill(dot)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("In progress")
            }
        }
        .font(.system(size: 12.5))
        .padding(.leading, 30)
    }
}

/// The foot of the sidebar: iCloud's state, when it last synced, and Refresh
/// — the Mac's answer to letting go of a pull.
private struct MacSyncFooter: View {
    let monitor: CloudSyncMonitor

    private var symbol: String {
        if monitor.isRefreshing { return "arrow.triangle.2.circlepath.icloud" }
        switch monitor.lastOutcome {
        case .failed?, .unavailable?, .notSyncing?: return "exclamationmark.icloud"
        default: return monitor.lastSyncedAt == nil ? "icloud" : "checkmark.icloud"
        }
    }

    /// Green only for "iCloud up to date", orange for the headlines that say
    /// it isn't — the same cases `CloudSyncStatusText.headline` reads.
    private var tint: AnyShapeStyle {
        if monitor.isRefreshing { return AnyShapeStyle(.secondary) }
        switch monitor.lastOutcome {
        case .failed?, .unavailable?, .notSyncing?: return AnyShapeStyle(.orange)
        default: return monitor.lastSyncedAt == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green)
        }
    }

    var body: some View {
        // Re-read once a minute, so "5 min ago" doesn't sit frozen.
        TimelineView(.everyMinute) { context in
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(CloudSyncStatusText.headline(
                        lastSyncedAt: monitor.lastSyncedAt,
                        isRefreshing: monitor.isRefreshing,
                        lastOutcome: monitor.lastOutcome
                    ))
                    .font(.system(size: 12, weight: .semibold))
                    Text(CloudSyncStatusText.synced(monitor.lastSyncedAt, isRefreshing: monitor.isRefreshing, asOf: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    Task { await monitor.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(monitor.isRefreshing)
                .accessibilityLabel("Refresh from iCloud")
                .help("Refresh from iCloud (⌘R)")
            }
            // Why a refresh that brought nothing in ended as it did — the long
            // form the footer has no room for.
            .help(monitor.lastOutcome.flatMap(CloudSyncStatusText.message(for:)) ?? "")
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}
#endif
