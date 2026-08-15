import Core
import FuelTracker
import GymTracker
import ParcelTracker
import SwiftData
import SwiftUI
import TVTracker

struct AppSettingsView: View {
    @AppStorage(Appearance.defaultsKey) private var appearanceRaw = Appearance.system.rawValue
    @State private var syncState: CloudSyncState = .checking

    @Query private var sessions: [WorkoutSession]
    @Query private var exercises: [Exercise]
    @Query private var shows: [Show]
    @Query private var movies: [Movie]
    @Query private var parcels: [Parcel]
    @Query private var vehicles: [Vehicle]
    @Query private var fuelEntries: [FuelEntry]

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
                    detail: counted(parcels.count, "parcel"),
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
