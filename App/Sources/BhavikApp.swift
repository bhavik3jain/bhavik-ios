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

/// Every module's models: the one list both the real container and the
/// CloudKit schema initializer are built from, so the two can't drift apart.
/// Outside `BhavikApp` because an `App` is main-actor isolated and the
/// initializer reads this from a background task.
enum AppSchema {
    static var models: [any PersistentModel.Type] {
        GymTrackerModule.models + FuelTrackerModule.models + TVTrackerModule.models
            + ParcelTrackerModule.models + TripTrackerModule.models + ExploreTrackerModule.models
    }
}

@main
struct BhavikApp: App {
    /// Named once so the settings screen can ask CloudKit about the same
    /// container the store actually syncs through.
    static let cloudContainerID = "iCloud.com.bhavikjain.trackers"

    let container: ModelContainer
    /// Trips' own Core Data store — the first of the three modules (Trips,
    /// Fuel, Explore) moving off SwiftData onto `CloudSharedStore` for CKShare
    /// support. Threaded to `HomeView` via `.environment(\.managedObjectContext, _)`
    /// below, the same way `.modelContainer(container)` threads the SwiftData
    /// container — see `HomeView.swift` and `TripTrackerModule.rootView(context:)`.
    let tripContainer: NSPersistentCloudKitContainer
    /// Fuel's own Core Data store — the second of the three modules moving
    /// off SwiftData onto `CloudSharedStore`. Threaded to `HomeView` via the
    /// `\.fuelManagedObjectContext` environment key (`Core`'s
    /// `ModuleManagedObjectContexts.swift`) rather than the standard
    /// `\.managedObjectContext` Trips already occupies at this level — see
    /// that file's doc comment for why a second module needs a key of its
    /// own here.
    let fuelContainer: NSPersistentCloudKitContainer
    /// Explore's own Core Data store — the third and last of the three
    /// modules moving off SwiftData onto `CloudSharedStore`. Threaded to
    /// `HomeView` via its own `\.exploreManagedObjectContext` key, the same
    /// reason `fuelContainer` needed one rather than sharing Trips'
    /// `\.managedObjectContext`.
    let exploreContainer: NSPersistentCloudKitContainer
    /// Points' own Core Data store — built on `CloudSharedStore` from the
    /// start rather than migrated off SwiftData, so a household can be shared
    /// via CKShare. Threaded to `HomeView` via its own
    /// `\.pointsManagedObjectContext` key, the same reason `fuelContainer`
    /// and `exploreContainer` needed one.
    let pointsContainer: NSPersistentCloudKitContainer
    /// Finance's own Core Data store — built on `CloudSharedStore` from the
    /// start, like Points, so a household's balance sheet can be shared via
    /// CKShare. Threaded to `HomeView` via its own
    /// `\.financeManagedObjectContext` key, the same reason `pointsContainer`
    /// needed one.
    let financeContainer: NSPersistentCloudKitContainer
    /// Every store's CloudKit mirroring, and the "refresh from iCloud" that
    /// pull-to-refresh, Settings and the Mac's ⌘R all go through. Built before
    /// any container so it hears each store's launch import. See
    /// `CloudSyncMonitor`'s doc comment.
    let syncMonitor = CloudSyncMonitor(containerID: BhavikApp.cloudContainerID)
    @AppStorage(Appearance.defaultsKey) private var appearanceRaw = Appearance.system.rawValue
    // Only reason for an app/scene delegate in an otherwise pure SwiftUI App:
    // CKShare-accept has no SwiftUI-native entry point on either platform.
    // See ShareAcceptDelegate.swift. (It also registers for CloudKit's
    // pushes, for the same lack of a SwiftUI entry point.)
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        do {
            let schema = Schema(AppSchema.models)
            #if DEBUG
            // A schema-initialising launch must never open the real store: the
            // point is that it's safe to run on a phone holding real data. An
            // empty in-memory container keeps SwiftUI's environment satisfied.
            if CloudKitSchemaInitializer.isRequested {
                let scratch = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
                container = try ModelContainer(for: schema, configurations: [scratch])
                // Same reasoning, for Trips' and Fuel's Core Data stores: a
                // schema-probing launch must never touch the real store,
                // these included.
                tripContainer = CloudSharedStore.makeContainer(
                    name: "TripStore",
                    model: TripModel.make(),
                    containerID: Self.cloudContainerID,
                    inMemory: true
                )
                fuelContainer = CloudSharedStore.makeContainer(
                    name: "FuelStore",
                    model: FuelModel.make(),
                    containerID: Self.cloudContainerID,
                    inMemory: true
                )
                exploreContainer = CloudSharedStore.makeContainer(
                    name: "ExploreStore",
                    model: GuideModel.make(),
                    containerID: Self.cloudContainerID,
                    inMemory: true
                )
                pointsContainer = CloudSharedStore.makeContainer(
                    name: "PointsStore",
                    model: PointsModel.make(),
                    containerID: Self.cloudContainerID,
                    inMemory: true
                )
                financeContainer = CloudSharedStore.makeContainer(
                    name: "FinanceStore",
                    model: FinanceModel.make(),
                    containerID: Self.cloudContainerID,
                    inMemory: true
                )
                return
            }
            #endif
            let configuration = ModelConfiguration(
                schema: schema,
                cloudKitDatabase: .private(Self.cloudContainerID)
            )
            container = try ModelContainer(for: schema, configurations: [configuration])

            tripContainer = CloudSharedStore.makeContainer(
                name: "TripStore",
                model: TripModel.make(),
                containerID: Self.cloudContainerID
            )
            // "CD_SharedTrip" — CloudKitSchemaInitializer.swift's own "CD_" +
            // entity name convention for Core Data record types (TripModel's
            // Trip entity is named "SharedTrip", not "Trip" — see
            // TripModel.swift), so an incoming share invitation for a Trip
            // routes to this container.
            ShareAcceptRouter.shared.register(recordTypePrefix: "CD_SharedTrip", container: tripContainer)

            fuelContainer = CloudSharedStore.makeContainer(
                name: "FuelStore",
                model: FuelModel.make(),
                containerID: Self.cloudContainerID
            )
            // "CD_SharedVehicle" — same "CD_" + entity name convention, for
            // Fuel's CKShare root (FuelModel's Vehicle entity is named
            // "SharedVehicle", not "Vehicle" — see FuelModel.swift).
            ShareAcceptRouter.shared.register(recordTypePrefix: "CD_SharedVehicle", container: fuelContainer)

            exploreContainer = CloudSharedStore.makeContainer(
                name: "ExploreStore",
                model: GuideModel.make(),
                containerID: Self.cloudContainerID
            )
            // "CD_SharedGuide" — same "CD_" + entity name convention, for
            // Explore's CKShare root (GuideModel's Guide entity is named
            // "SharedGuide", not "Guide" — see GuideModel.swift).
            ShareAcceptRouter.shared.register(recordTypePrefix: "CD_SharedGuide", container: exploreContainer)

            pointsContainer = CloudSharedStore.makeContainer(
                name: "PointsStore",
                model: PointsModel.make(),
                containerID: Self.cloudContainerID
            )
            // "CD_SharedPointsHousehold" — same "CD_" + entity name
            // convention, for Points' CKShare root (a household, so every
            // owner, account and entry under it shares with it — see
            // PointsModel.swift).
            ShareAcceptRouter.shared.register(recordTypePrefix: "CD_SharedPointsHousehold", container: pointsContainer)

            financeContainer = CloudSharedStore.makeContainer(
                name: "FinanceStore",
                model: FinanceModel.make(),
                containerID: Self.cloudContainerID
            )
            // "CD_SharedFinanceHousehold" — same "CD_" + entity name
            // convention, for Finance's CKShare root (a household, so every
            // owner, account and month under it shares with it — see
            // FinanceModel.swift).
            ShareAcceptRouter.shared.register(recordTypePrefix: "CD_SharedFinanceHousehold", container: financeContainer)

            for container in [tripContainer, fuelContainer, exploreContainer, pointsContainer, financeContainer] {
                syncMonitor.track(container)
            }
            #if DEBUG
            CloudSyncRefreshProbe.scheduleIfRequested(syncMonitor)
            #endif
            Self.startSharedChangeNotifications(
                trips: tripContainer,
                fuel: fuelContainer,
                explore: exploreContainer,
                points: pointsContainer,
                finance: financeContainer
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    /// Local notifications when someone this user shares with changes
    /// something — see Core's `SharedChangeNotifier`. One notifier per
    /// sharing container, each with its module's own wording and the
    /// `SelectedModule` a tap opens. Only on the real stores: the
    /// schema-initialising launch returns before reaching this.
    private static func startSharedChangeNotifications(
        trips: NSPersistentCloudKitContainer,
        fuel: NSPersistentCloudKitContainer,
        explore: NSPersistentCloudKitContainer,
        points: NSPersistentCloudKitContainer,
        finance: NSPersistentCloudKitContainer
    ) {
        SharedChangeNotifications.install()
        let notifiers: [(NSPersistentCloudKitContainer, SelectedModule, SharedChangeDescriber)] = [
            (trips, .trips, TripTrackerModule.describeSharedChange),
            (fuel, .fuel, FuelTrackerModule.describeSharedChange),
            (explore, .explore, ExploreTrackerModule.describeSharedChange),
            (points, .points, PointsTrackerModule.describeSharedChange),
            (finance, .finance, FinanceTrackerModule.describeSharedChange),
        ]
        for (container, module, describe) in notifiers {
            SharedChangeNotifier.start(
                container: container,
                moduleID: module.rawValue,
                moduleName: module.accent.name,
                describe: describe
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if CloudKitSchemaInitializer.isRequested {
                    CloudKitSchemaInitializerView(containerID: Self.cloudContainerID)
                } else {
                    HomeView()
                        .preferredColorScheme(Appearance.stored(appearanceRaw).colorScheme)
                        .modifier(WeatherStub())
                        #if os(macOS)
                        .frame(minWidth: 900, minHeight: 600)
                        #endif
                }
                #else
                HomeView()
                    .preferredColorScheme(Appearance.stored(appearanceRaw).colorScheme)
                    #if os(macOS)
                    .frame(minWidth: 900, minHeight: 600)
                    #endif
                #endif
            }
        }
        .providingStores(of: self)
        #if os(macOS)
        // A left-over default-sized window reads as an unfinished iPhone app
        // squeezed onto a Mac; the sidebar, a three-column Overview and a
        // trip's Plan beside its Ideas inspector all want the width.
        .defaultSize(width: 1280, height: 800)
        .commands {
            TrackerCommands()
            CloudSyncCommands(monitor: syncMonitor)
        }
        #endif

        #if os(macOS)
        // App ▸ Settings…, ⌘, — the Mac's own place for it. A gear in the
        // sidebar pushed Settings into the detail pane in place of whatever
        // tracker was open.
        Settings {
            MacSettingsView()
                .preferredColorScheme(Appearance.stored(appearanceRaw).colorScheme)
        }
        .providingStores(of: self)
        #endif
    }
}

private extension Scene {
    /// Every store and the sync monitor, for a scene's views. The main window
    /// and the Mac's Settings window both need them: Settings counts each
    /// tracker's records, and would read empty stores without them.
    func providingStores(of app: BhavikApp) -> some Scene {
        modelContainer(app.container)
            // Threads Trips' Core Data context to HomeView (its own @FetchRequest,
            // and what it passes on explicitly to TripTrackerModule.rootView(context:))
            // and to the module itself once opened, the same way .modelContainer
            // above threads the SwiftData context to every other module's @Query.
            .environment(\.managedObjectContext, app.tripContainer.viewContext)
            // The container itself (not just its context) — Trips' Share button
            // and its sharing-status badges need it to call `presentShareSheet`
            // and `SharingStatusResolver`. See Core's `ModulePersistentContainers.swift`.
            .environment(\.tripPersistentContainer, app.tripContainer)
            // Fuel's own key — see `fuelContainer`'s doc comment above for why
            // this isn't also `\.managedObjectContext`.
            .environment(\.fuelManagedObjectContext, app.fuelContainer.viewContext)
            // The container itself (not just its context) — Fuel's Share button
            // and its sharing-status badges need it to call `presentShareSheet`
            // and `SharingStatusResolver`. See Core's `ModulePersistentContainers.swift`.
            .environment(\.fuelPersistentContainer, app.fuelContainer)
            // Explore's own key — same reasoning as Fuel's.
            .environment(\.exploreManagedObjectContext, app.exploreContainer.viewContext)
            // The container itself (not just its context) — Explore's Share
            // button and its sharing-status badges need it to call
            // `presentShareSheet` and `SharingStatusResolver`. See Core's
            // `ModulePersistentContainers.swift`.
            .environment(\.explorePersistentContainer, app.exploreContainer)
            // Points' own key — same reasoning as Fuel's.
            .environment(\.pointsManagedObjectContext, app.pointsContainer.viewContext)
            // The container itself (not just its context) — Points' Share button
            // and its sharing-status badges need it, same as Explore's above.
            .environment(\.pointsPersistentContainer, app.pointsContainer)
            // Finance's own key — same reasoning as Fuel's.
            .environment(\.financeManagedObjectContext, app.financeContainer.viewContext)
            // The container itself (not just its context) — Finance's Share
            // button and its sharing-status badges need it, same as Points' above.
            .environment(\.financePersistentContainer, app.financeContainer)
            .environment(app.syncMonitor)
    }
}

#if os(macOS)
/// The Trackers menu: ⌘0 is the Overview, and ⌘1 onward jumps straight to a
/// tracker, numbered in the sidebar's own order and skipping hidden ones, so
/// ⌘1 is always the top row.
/// A Scene's `.commands` sits outside the WindowGroup's view hierarchy, so it
/// can't reach into HomeView's own `@State` — it posts a notification instead,
/// which `HomeView.macBody` listens for.
private struct TrackerCommands: Commands {
    @ObservedObject private var layoutStore = TrackerLayoutStore.shared

    var body: some Commands {
        CommandMenu("Trackers") {
            Button("Overview") {
                NotificationCenter.default.post(name: .selectTracker, object: nil, userInfo: ["module": SelectedModule.overviewID])
            }
            .keyboardShortcut("0", modifiers: .command)
            Divider()
            // Nine at most: ⌘0 and beyond aren't single keystrokes.
            ForEach(Array(layoutStore.visibleModules.prefix(9).enumerated()), id: \.element) { index, module in
                Button(module.accent.name) {
                    NotificationCenter.default.post(name: .selectTracker, object: nil, userInfo: ["module": module.rawValue])
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
    }
}

/// View ▸ Refresh from iCloud, ⌘R. Unlike the Trackers menu this needs no
/// notification: the monitor is the app's own object, not HomeView state.
private struct CloudSyncCommands: Commands {
    let monitor: CloudSyncMonitor

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Refresh from iCloud") {
                Task { await monitor.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(monitor.isRefreshing)
        }
    }
}
#endif

#if DEBUG
/// `-CloudSyncRefreshAfter <seconds>` runs an app-wide refresh that long after
/// launch and prints how it ended — the only way to watch whether a refresh
/// really makes mirroring import, alongside `-com.apple.CoreData.CloudKitDebug 1`
/// and the "CloudSync" log category.
private enum CloudSyncRefreshProbe {
    @MainActor
    static func scheduleIfRequested(_ monitor: CloudSyncMonitor) {
        let delay = UserDefaults.standard.double(forKey: "CloudSyncRefreshAfter")
        guard delay > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            print("CloudSyncRefreshProbe: refreshing at \(Date.now)")
            let outcome = await monitor.refresh()
            print("CloudSyncRefreshProbe: \(outcome) at \(Date.now)")
        }
    }
}

/// `-WeatherStub YES` swaps in made-up weather for the whole app.
///
/// The live WeatherKit provider throws until the WeatherKit capability is
/// enabled for the app ID and the entitlement is added, and Trips and Explore
/// then quietly show no weather at all — so without this there is no way to
/// see a day strip or a weather card on a simulator. Set at the root so it
/// reaches the modules' full-screen covers too.
private struct WeatherStub: ViewModifier {
    func body(content: Content) -> some View {
        if UserDefaults.standard.bool(forKey: "WeatherStub") {
            content.environment(\.weatherProvider, StubWeatherProvider())
        } else {
            content
        }
    }
}
#endif
