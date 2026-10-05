import Core
import Foundation
import SwiftData
import UserNotifications

/// "Severance: S02E05 “Trojan's Horse” is out today" — a local notification
/// on the day a new episode of a show being watched comes out, at the time
/// picked in TV Settings.
///
/// Scheduled ahead on this device (`EpisodeAlertPlanner`), like Finance's
/// month reminder, so nothing has to be running when one is due: rescheduled
/// whenever TV opens, after every refresh, when the preferences change and
/// when an episode is ticked off or a show's status changes. What it can
/// know about is only as fresh as the episode list, which is why the list is
/// now refreshed too (`TVEpisodeRefresher`) — when TV opens, on Up Next's
/// pull to refresh, and on iOS from a background app refresh the system runs
/// at its own discretion (the app registers it: BGTaskScheduler is iOS-only,
/// and a feature package carries no `#if os`). The Mac has no background
/// task; it reschedules whenever it runs.
@MainActor
public enum TVEpisodeAlerts {
    /// The notifications' own category, so nothing mistakes one for a shared
    /// change or iCloud's alert.
    public static let categoryIdentifier = "tv.newEpisode"
    /// `SharedChangeNotifications.destinationUserInfoKey` on every one: a tap
    /// opens TV on Up Next, where the new episode is waiting.
    public static let upNextDestination = "tv.upnext"
    /// The `SelectedModule` raw value a tap opens.
    static let moduleID = "tv"
    static let upNextSection = "upnext"

    private static var container: ModelContainer?

    /// Asks iOS for the next background refresh — set by the app, which owns
    /// the BGTaskScheduler registration; nil on the Mac. Called whenever
    /// alerts are on and have just been rescheduled.
    public static var requestBackgroundRefresh: (@MainActor () -> Void)?

    /// The app's container, for the reschedules nothing hands a context to:
    /// a preference changed in the Mac's Settings window, an iCloud change
    /// to them, the background refresh.
    public static func configure(container: ModelContainer) {
        self.container = container
    }

    // MARK: - Refreshing

    private static var refreshInFlight: Task<TVEpisodeRefresher.Summary, Never>?

    /// How long TV waits for this launch's iCloud import before refreshing
    /// anyway — when it opens, and in the background, where iOS gives the
    /// whole task about half a minute.
    static let importWait: Duration = .seconds(20)
    static let backgroundImportWait: Duration = .seconds(8)

    /// Waits for this launch's iCloud import, folds duplicate episodes,
    /// refreshes the shows that are due, then reschedules. With no TMDB key
    /// there's nothing to refresh from, and the reminders come from what's
    /// already stored.
    ///
    /// The wait is what keeps duplicates rare: a refresh run before the
    /// import added an episode another device had already added and iCloud
    /// was about to bring. Nothing to wait for without a monitor (tests, and
    /// screens with none in their environment).
    public static func refreshAndReschedule(
        context: ModelContext,
        syncMonitor: CloudSyncMonitor? = nil,
        asOf now: Date = .now
    ) async {
        if let syncMonitor { _ = await syncMonitor.waitForSwiftDataImport(timeout: importWait) }
        guard !Task.isCancelled else { return }
        await foldDuplicates()
        if let apiKey = storedAPIKey {
            _ = await refresh(context: context, apiKey: apiKey, asOf: now)
        }
        guard !Task.isCancelled else { return }
        await reschedule(context: context, asOf: now)
    }

    private static var foldInFlight: Task<Void, Never>?

    /// Folds every show's duplicate episodes (`EpisodeFolder`), off the main
    /// thread. Never at once with a refresh: one could read a copy the other
    /// is deleting. A second caller waits for the run under way.
    public static func foldDuplicates() async {
        if let running = foldInFlight { return await running.value }
        guard let container else { return }
        let task = Task { @MainActor in
            _ = await refreshInFlight?.value
            let outcome = await EpisodeFolder(modelContainer: container).fold()
            let ledger = TVRefreshLedger()
            for tmdbID in outcome.dueAgain { ledger.markDue(tmdbID) }
        }
        foldInFlight = task
        await task.value
        foldInFlight = nil
    }

    /// iOS's background app refresh: the due shows on a fresh context of the
    /// app's container, then a reschedule. Nothing when alerts are off — the
    /// refresh runs in the background only for them. Returns whether it got
    /// through everything, for `BGTask.setTaskCompleted(success:)`.
    public static func backgroundRefresh(container: ModelContainer, syncMonitor: CloudSyncMonitor? = nil) async -> Bool {
        guard wantsBackgroundRefresh else { return true }
        if let syncMonitor { _ = await syncMonitor.waitForSwiftDataImport(timeout: backgroundImportWait) }
        guard !Task.isCancelled else { return false }
        await foldDuplicates()
        let context = ModelContext(container)
        var finished = true
        if let apiKey = storedAPIKey {
            let summary = await refresh(context: context, apiKey: apiKey, asOf: .now)
            finished = !summary.stoppedEarly
        }
        guard !Task.isCancelled else { return false }
        await reschedule(context: context)
        return finished && !Task.isCancelled
    }

    /// Whether a background refresh is worth asking iOS for.
    public static var wantsBackgroundRefresh: Bool {
        EpisodeAlertStore.shared.preferences.isEnabled
    }

    /// One refresh at a time. Two at once — TV opened while the background
    /// one ran — would each find the same new episode missing and both add
    /// it; a second caller waits for the first one's result instead.
    static func refresh(
        context: ModelContext,
        apiKey: String,
        force: Bool = false,
        asOf now: Date
    ) async -> TVEpisodeRefresher.Summary {
        if let running = refreshInFlight { return await running.value }
        // Never at once with a fold; see `foldDuplicates`.
        await foldInFlight?.value
        if let running = refreshInFlight { return await running.value }
        let refresher = TVEpisodeRefresher(source: TMDBClient(apiKey: apiKey))
        let task = Task { @MainActor in
            await refresher.refresh(context: context, asOf: now, force: force)
        }
        refreshInFlight = task
        // The caller that started it cancels it: TV closed, or iOS ending the
        // background task. What's done stays done (the ledger).
        let summary = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        refreshInFlight = nil
        return summary
    }

    private static var storedAPIKey: String? {
        guard let key = SyncedKeychain.string(forKey: TVTrackerModule.apiKeyDefaultsKey), !key.isEmpty else { return nil }
        return key
    }

    // MARK: - Scheduling

    private static var rescheduling: Task<Void, Never>?
    private static var pendingReschedule: Task<Void, Never>?

    /// Replaces this app's pending new-episode notifications with a fresh
    /// plan, or just removes them when alerts are off. Never asks for
    /// permission — only turning alerts on does — and schedules nothing
    /// without it.
    ///
    /// One at a time: two overlapping runs could each clear the list before
    /// either had added to it, and the first one's alert for an episode
    /// since ticked off would outlive the second's clear.
    public static func reschedule(context: ModelContext? = nil, asOf now: Date = .now) async {
        let previous = rescheduling
        let context = context ?? container.map { ModelContext($0) }
        let task = Task { @MainActor in
            await previous?.value
            await performReschedule(context: context, asOf: now)
        }
        rescheduling = task
        await task.value
    }

    /// A save touched shows or episodes — a tick, a status picked, a show
    /// removed. Rescheduled half a second after the last of a burst, and not
    /// tied to the view that noticed: closing TV straight after ticking an
    /// episode off must still drop its alert.
    static func dataChanged(context: ModelContext) {
        pendingReschedule?.cancel()
        pendingReschedule = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await reschedule(context: context)
        }
    }

    /// The preferences changed, here or on another device.
    static func preferencesChanged() {
        pendingReschedule?.cancel()
        pendingReschedule = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await reschedule()
        }
    }

    private static func performReschedule(context: ModelContext?, asOf now: Date) async {
        let center = UNUserNotificationCenter.current()
        let stale = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(EpisodeAlertPlanner.identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: stale)

        let preferences = EpisodeAlertStore.shared.preferences
        guard preferences.isEnabled, let context else { return }
        requestBackgroundRefresh?()
        guard await SharedChangeNotifications.isAuthorized() else { return }

        for alert in plan(context: context, preferences: preferences, asOf: now) {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            content.categoryIdentifier = categoryIdentifier
            content.threadIdentifier = EpisodeAlertPlanner.identifierPrefix + alert.showKey
            // Read by Core's notification delegate: a tap opens TV on Up
            // Next; it isn't a shared change, so it's never logged as one.
            content.userInfo = [
                SharedChangeNotifications.moduleUserInfoKey: moduleID,
                SharedChangeNotifications.destinationUserInfoKey: upNextDestination,
                SharedChangeNotifications.reminderUserInfoKey: true,
            ]
            let trigger = UNCalendarNotificationTrigger(dateMatching: alert.fireComponents, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: alert.identifier, content: content, trigger: trigger))
        }
    }

    /// The plan for what's in `context` now.
    static func plan(
        context: ModelContext,
        preferences: EpisodeAlertPreferences,
        asOf now: Date
    ) -> [EpisodeAlertPlanner.Alert] {
        let watching = ShowStatus.watching.rawValue
        let shows = (try? context.fetch(FetchDescriptor<Show>(predicate: #Predicate { $0.statusRaw == watching }))) ?? []
        // Two days either side: TMDB's dates sit at midnight UTC, up to a day
        // off local midnight, and the planner works out the exact day.
        let start = now.addingTimeInterval(-2 * 86_400)
        let end = now.addingTimeInterval(Double(EpisodeAlertPlanner.horizonDays + 2) * 86_400)
        let inputs = shows.map { EpisodeAlertPlanner.ShowInput($0, airingFrom: start, to: end) }
        return EpisodeAlertPlanner.plan(shows: inputs, preferences: preferences, asOf: now)
    }

    /// Whether a SwiftData save touched anything alerts are planned from.
    /// The app's one container holds Gym's and Orders' models too, and a set
    /// logged at the gym has no business rescheduling TV. A save whose
    /// identifiers can't be read counts, rather than risk a stale alert.
    nonisolated static func concernsAlerts(_ userInfo: [AnyHashable: Any]?) -> Bool {
        let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
        var sawIdentifiers = false
        for key in keys {
            guard let identifiers = (userInfo?[key.rawValue] ?? userInfo?[key]) as? [PersistentIdentifier] else { continue }
            sawIdentifiers = true
            if identifiers.contains(where: { alertEntities.contains($0.entityName) }) { return true }
        }
        return !sawIdentifiers
    }

    private nonisolated static let alertEntities: Set<String> = ["Show", "Episode"]
}
