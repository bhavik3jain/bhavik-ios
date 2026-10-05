import Core
import SwiftData
import SwiftUI

// TV's new-episode alerts on screen: what TV's root does when it opens, the
// "New Episode Alerts" section in TV Settings, the bell on a show's screen
// and Up Next's one-time offer. The work itself is `TVEpisodeAlerts`.

/// What TV's root view does for alerts: refresh and reschedule when TV
/// opens, reschedule when shows or episodes change, and take a tapped alert
/// to Up Next.
struct EpisodeAlertsRoot: ViewModifier {
    /// The tab bar's selection on the phone, the sidebar's on the Mac.
    @Binding var section: String
    @Environment(\.modelContext) private var modelContext
    @Environment(CloudSyncMonitor.self) private var syncMonitor: CloudSyncMonitor?
    @ObservedObject private var router = SharedChangeNotificationRouter.shared

    func body(content: Content) -> some View {
        content
            .task { await TVEpisodeAlerts.refreshAndReschedule(context: modelContext, syncMonitor: syncMonitor) }
            // Another device's copy of an episode this one added arrives with
            // an import; folded as it lands, not at the next launch.
            .onChange(of: syncMonitor?.lastSwiftDataImportAt) { _, _ in
                Task { await TVEpisodeAlerts.foldDuplicates() }
            }
            // Every place an episode is ticked off or a status picked saves
            // through SwiftData, so one listener covers them all — the show
            // screen, an episode's own screen, a season's button, a show
            // removed — where calls at each would miss the next one added.
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave).receive(on: DispatchQueue.main)) { note in
                guard TVEpisodeAlerts.concernsAlerts(note.userInfo) else { return }
                TVEpisodeAlerts.dataChanged(context: modelContext)
            }
            // A tapped alert: the hub has opened TV from the same tap
            // (`moduleToOpen`); this lands it on Up Next. `initial`, so a tap
            // that launched the app is still waiting when TV first appears.
            .onChange(of: router.destinationToOpen, initial: true) { _, destination in
                guard destination == TVEpisodeAlerts.upNextDestination else { return }
                router.destinationToOpen = nil
                section = TVEpisodeAlerts.upNextSection
            }
    }
}

/// The notification permission as these screens need it.
private enum AlertPermission {
    case unknown, allowed, notAsked, denied

    static func current() async -> Self {
        if await SharedChangeNotifications.isAuthorized() { return .allowed }
        if await SharedChangeNotifications.isDenied() { return .denied }
        return await SharedChangeNotifications.isUndetermined() ? .notAsked : .denied
    }
}

/// TV Settings' "New Episode Alerts": the switch, the time, and which shows.
struct EpisodeAlertsSettingsSection: View {
    @ObservedObject private var store = EpisodeAlertStore.shared
    @Query(filter: #Predicate<Show> { $0.statusRaw == "watching" }) private var watching: [Show]
    @State private var permission = AlertPermission.unknown

    private var preferences: EpisodeAlertPreferences { store.preferences }

    var body: some View {
        Section {
            Toggle("New Episode Alerts", isOn: Binding(
                get: { preferences.isEnabled },
                set: { isOn in Task { await setEnabled(isOn) } }
            ))
            if preferences.isEnabled {
                DatePicker("Time", selection: Binding(
                    get: { preferences.time() },
                    set: { store.setMinuteOfDay(EpisodeAlertPreferences.minuteOfDay(of: $0)) }
                ), displayedComponents: .hourAndMinute)
                NavigationLink {
                    EpisodeAlertShowsView()
                } label: {
                    LabeledContent("Shows", value: showsSummary)
                }
                if permission == .notAsked {
                    // On here, but turned on on another device: this one has
                    // never been asked, and asking at launch is refused.
                    Button("Allow Notifications on This Device") {
                        Task {
                            _ = await SharedChangeNotifications.requestAuthorization()
                            permission = await AlertPermission.current()
                            await TVEpisodeAlerts.reschedule()
                        }
                    }
                }
            }
        } header: {
            Text("New Episode Alerts")
        } footer: {
            Text(footer)
        }
        .task { permission = await AlertPermission.current() }
    }

    private var showsSummary: String {
        let muted = watching.count { preferences.isMuted(tmdbID: $0.tmdbID, name: $0.name) }
        if watching.isEmpty { return "None watched" }
        return muted == 0 ? "All \(watching.count)" : "\(watching.count - muted) of \(watching.count)"
    }

    private var footer: String {
        if permission == .denied {
            return "Notifications for Multitrack are turned off on this device. Allow them in the system's notification settings to get alerts here."
        }
        guard preferences.isEnabled else {
            return "A notification on the day a new episode of a show you're watching comes out."
        }
        let time = preferences.time().formatted(date: .omitted, time: .shortened)
        return "At \(time) on the day a new episode of a show you're watching comes out. New episodes are looked up on TMDB when TV opens, and in the background when the system allows."
    }

    /// Turning alerts on is the one moment that asks for permission; without
    /// it they stay off, since nothing would ever show.
    private func setEnabled(_ isOn: Bool) async {
        guard isOn else {
            store.setEnabled(false)
            return
        }
        let allowed = await SharedChangeNotifications.requestAuthorization()
        permission = await AlertPermission.current()
        if allowed { store.setEnabled(true) }
    }
}

/// Which shows alert: every show being watched, each with its own switch.
struct EpisodeAlertShowsView: View {
    @ObservedObject private var store = EpisodeAlertStore.shared
    @Query(filter: #Predicate<Show> { $0.statusRaw == "watching" }, sort: \Show.name) private var watching: [Show]

    var body: some View {
        Form {
            Section {
                if watching.isEmpty {
                    Text("No shows being watched.")
                        .foregroundStyle(.secondary)
                }
                ForEach(watching) { show in
                    Toggle(show.name, isOn: Binding(
                        get: { !store.preferences.isMuted(tmdbID: show.tmdbID, name: show.name) },
                        set: { store.setMuted(!$0, tmdbID: show.tmdbID, name: show.name) }
                    ))
                }
            } footer: {
                Text("Only shows you're watching send alerts. The bell on a show's screen does the same.")
            }
        }
        .navigationTitle("Shows")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension View {
    /// A bell in the show screen's toolbar that mutes or unmutes its alerts,
    /// shown while alerts are on.
    func episodeAlertBell(for show: Show) -> some View {
        modifier(EpisodeAlertBell(show: show))
    }
}

private struct EpisodeAlertBell: ViewModifier {
    let show: Show
    @ObservedObject private var store = EpisodeAlertStore.shared

    func body(content: Content) -> some View {
        content.toolbar {
            if store.preferences.isEnabled {
                ToolbarItem(placement: .primaryAction) {
                    let isMuted = store.preferences.isMuted(tmdbID: show.tmdbID, name: show.name)
                    Button {
                        store.setMuted(!isMuted, tmdbID: show.tmdbID, name: show.name)
                    } label: {
                        Image(systemName: isMuted ? "bell.slash" : "bell")
                    }
                    .accessibilityLabel(isMuted ? "Turn On New Episode Alerts" : "Mute New Episode Alerts")
                    .help(isMuted ? "Alerts are muted for this show" : "Alerts are on for this show")
                }
            }
        }
    }
}

/// Up Next's one-time offer to turn alerts on, while there's something
/// coming up to be told about.
struct EpisodeAlertOfferCard: View {
    @ObservedObject private var store = EpisodeAlertStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Know when new episodes are out", systemImage: "bell.badge")
                .font(.headline)
            Text("A notification at \(store.preferences.time().formatted(date: .omitted, time: .shortened)) on the day a new episode of a show you're watching comes out. Change the time or the shows in TV Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Button("Turn On") {
                    Task {
                        if await SharedChangeNotifications.requestAuthorization() {
                            store.setEnabled(true)
                        } else {
                            store.dismissOffer()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                // Bordered, both: in a list row a plain button turns the
                // whole row into one tap target.
                Button("Not Now") { store.dismissOffer() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}
