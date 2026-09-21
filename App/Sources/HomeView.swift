import Core
import FuelTracker
import GymTracker
import ParcelTracker
import SwiftData
import SwiftUI
import TVTracker

struct HomeView: View {
    @State private var selectedModule: SelectedModule?

    // Each module's own data, so a row can say what is actually going on
    // rather than repeating a fixed description.
    @Query(filter: #Predicate<WorkoutSession> { $0.finishedAt != nil }, sort: \WorkoutSession.startedAt, order: .reverse)
    private var sessions: [WorkoutSession]
    @Query private var shows: [Show]
    @Query(filter: #Predicate<Parcel> { !$0.isArchived }) private var parcels: [Parcel]
    @Query(sort: \Vehicle.createdAt) private var vehicles: [Vehicle]
    /// Written by a Fuel peek's "Open My X3" so the module opens on that car.
    @AppStorage(FuelTrackerModule.selectedVehicleDefaultsKey) private var selectedVehicleName = ""

    var body: some View {
        NavigationStack {
            List {
                ModuleRow(
                    accent: GymTrackerModule.accent,
                    icon: "dumbbell.fill",
                    detail: gymDetail
                ) { selectedModule = .gym }
                // Each row peeks on a long press: the module's own summary card,
                // fed from the queries above so no module reads another's data.
                .contextMenu {
                    openButton("Gym", .gym)
                } preview: {
                    GymTrackerModule.homePeek(sessions: sessions)
                }

                ModuleRow(
                    accent: TVTrackerModule.accent,
                    icon: "tv.fill",
                    detail: tvDetail
                ) { selectedModule = .tv }
                .contextMenu {
                    openButton("TV", .tv)
                } preview: {
                    TVTrackerModule.homePeek(shows: shows)
                }

                ModuleRow(
                    accent: ParcelTrackerModule.accent,
                    icon: "shippingbox.fill",
                    detail: parcelDetail
                ) { selectedModule = .parcels }
                .contextMenu {
                    openButton("Orders", .parcels)
                } preview: {
                    ParcelTrackerModule.homePeek(parcels: parcels)
                }

                ModuleRow(
                    accent: FuelTrackerModule.accent,
                    icon: "fuelpump.fill",
                    detail: fuelDetail
                ) { selectedModule = .fuel }
                .contextMenu {
                    openButton("Fuel", .fuel)
                    if vehicles.count > 1 {
                        ForEach(VehicleSummary.fleet(vehicles)) { summary in
                            Button {
                                selectedVehicleName = summary.name
                                selectedModule = .fuel
                            } label: {
                                Label("Open \(summary.name)", systemImage: "car.fill")
                            }
                        }
                    }
                } preview: {
                    FuelTrackerModule.homePeek(vehicles: vehicles)
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
                switch module {
                case .gym:
                    GymTrackerModule.rootView()
                case .fuel:
                    FuelTrackerModule.rootView()
                case .tv:
                    TVTrackerModule.rootView()
                case .parcels:
                    ParcelTrackerModule.rootView()
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

private enum SelectedModule: String, Identifiable {
    case gym
    case fuel
    case tv
    case parcels
    var id: String { rawValue }
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
