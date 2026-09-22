import Core
import CoreData
import ExploreTracker
import FuelTracker
import GymTracker
import ParcelTracker
import SwiftData
import SwiftUI
import TripTracker
import TVTracker

struct AppSettingsView: View {
    @AppStorage(Appearance.defaultsKey) private var appearanceRaw = Appearance.system.rawValue
    @State private var syncState: CloudSyncState = .checking

    @Query private var sessions: [WorkoutSession]
    @Query private var exercises: [Exercise]
    @Query private var shows: [Show]
    @Query private var movies: [Movie]
    @Query private var parcels: [Parcel]
    // Trips moved to Core Data — see HomeView.swift's own `tripResults` for
    // why this is a @FetchRequest rather than a @Query now. The environment
    // value it reads comes down from BhavikApp's WindowGroup-level
    // `.environment(\.managedObjectContext, tripContainer.viewContext)`, the
    // same as it reaches HomeView — this view is pushed inside the same
    // NavigationStack/NavigationSplitView, not presented across a module
    // boundary, so nothing extra needs to thread it here.
    @FetchRequest(sortDescriptors: []) private var tripResults: FetchedResults<SharedTrip>
    private var trips: [SharedTrip] { Array(tripResults) }
    // Fuel moved to Core Data too. Unlike `tripResults` above, this can't be a
    // plain `@FetchRequest`: that property wrapper only ever reads
    // `\.managedObjectContext`, which on this view already resolves to Trips'
    // container (same reasoning as HomeView's own `vehicleFetch` — see its
    // doc comment on `ManagedObjectFetch`), so a second `@FetchRequest` here
    // would silently query the wrong store for each entity.
    @Environment(\.fuelManagedObjectContext) private var fuelContext
    @StateObject private var vehicleFetch = ManagedObjectFetch<SharedVehicle>(SharedVehicle.fetchRequest())
    @StateObject private var fuelEntryFetch = ManagedObjectFetch<SharedFuelEntry>(SharedFuelEntry.fetchRequest())
    private var vehicles: [SharedVehicle] { vehicleFetch.results }
    private var fuelEntries: [SharedFuelEntry] { fuelEntryFetch.results }
    // Explore moved to Core Data too — same reasoning as Fuel's fetches above:
    // this view already resolves `\.managedObjectContext` to Trips' container,
    // so a plain `@FetchRequest` here would silently query the wrong store.
    @Environment(\.exploreManagedObjectContext) private var exploreContext
    @StateObject private var guideFetch = ManagedObjectFetch<SharedGuide>(SharedGuide.fetchRequest())
    @StateObject private var guidePlaceFetch = ManagedObjectFetch<SharedGuidePlace>(SharedGuidePlace.fetchRequest())
    private var guides: [SharedGuide] { guideFetch.results }
    private var guidePlaces: [SharedGuidePlace] { guidePlaceFetch.results }

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(Appearance.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Appearance")
            } footer: {
                Text("System follows whatever the phone is set to, including its light and dark schedule.")
            }

            Section {
                HStack {
                    Label("iCloud", systemImage: syncState.symbolName)
                    Spacer()
                    if syncState == .checking {
                        ProgressView()
                    } else {
                        Text(syncState.summary)
                            .foregroundStyle(syncState.isHealthy ? Color.secondary : Color.orange)
                    }
                }
            } header: {
                Text("Sync")
            } footer: {
                Text(syncState.explanation)
            }

            Section {
                TrackerRow(
                    accent: TripTrackerModule.accent,
                    icon: "suitcase.rolling.fill",
                    detail: counted(trips.count, "trip"),
                    syncState: syncState
                )
                TrackerRow(
                    accent: ExploreTrackerModule.accent,
                    icon: "map.fill",
                    detail: "\(counted(guides.count, "guide")), \(counted(guidePlaces.count, "place"))",
                    syncState: syncState
                )
                TrackerRow(
                    accent: GymTrackerModule.accent,
                    icon: "dumbbell.fill",
                    detail: "\(counted(sessions.count, "workout")), \(counted(exercises.count, "exercise"))",
                    syncState: syncState
                )
                TrackerRow(
                    accent: TVTrackerModule.accent,
                    icon: "tv.fill",
                    detail: "\(counted(shows.count, "show")), \(counted(movies.count, "movie"))",
                    syncState: syncState
                )
                TrackerRow(
                    accent: ParcelTrackerModule.accent,
                    icon: "shippingbox.fill",
                    detail: counted(parcels.count, "order"),
                    syncState: syncState
                )
                TrackerRow(
                    accent: FuelTrackerModule.accent,
                    icon: "fuelpump.fill",
                    detail: "\(counted(vehicles.count, "vehicle")), \(counted(fuelEntries.count, "entry", plural: "entries"))",
                    syncState: syncState
                )
            } header: {
                Text("Trackers")
            } footer: {
                Text(syncState.isHealthy
                     ? "Counts are what this device holds. Each tracker syncs through the same iCloud account."
                     : "Counts are what this device holds. They aren't syncing while iCloud is \(syncState.summary.lowercased()).")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            syncState = await CloudSync.state(containerID: BhavikApp.cloudContainerID)
        }
        .task(id: fuelContext) {
            guard let fuelContext else { return }
            vehicleFetch.start(context: fuelContext)
            fuelEntryFetch.start(context: fuelContext)
        }
        .task(id: exploreContext) {
            guard let exploreContext else { return }
            guideFetch.start(context: exploreContext)
            guidePlaceFetch.start(context: exploreContext)
        }
    }
}

private struct TrackerRow: View {
    let accent: ModuleAccent
    let icon: String
    let detail: String
    let syncState: CloudSyncState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(accent.color, in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 1) {
                Text(accent.name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: syncState.isHealthy ? "checkmark.icloud" : "icloud.slash")
                .foregroundStyle(syncState.isHealthy ? Color.secondary : Color.orange)
                .accessibilityLabel(syncState.isHealthy ? "Syncing" : "Not syncing")
        }
    }
}
