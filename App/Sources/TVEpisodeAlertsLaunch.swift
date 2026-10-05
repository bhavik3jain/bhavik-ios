import Foundation
import SwiftData
import TVTracker
#if os(iOS)
import BackgroundTasks
#endif

/// TV's new-episode alerts (`TVEpisodeAlerts`), wired in at launch: the
/// app's container, for reschedules nothing hands a context to, and on iOS
/// the background refresh that keeps the episode lists — and so the alerts —
/// current without TV being opened. Here rather than in TVTracker because
/// BGTaskScheduler is iOS-only and a feature package carries no `#if os`.
enum TVEpisodeAlertsLaunch {
    /// From `BhavikApp.init()`, on both the real and the in-memory stores.
    /// Early enough for BGTaskScheduler, which takes registrations only
    /// before the app finishes launching.
    @MainActor
    static func start(container: ModelContainer, inMemory: Bool) {
        TVEpisodeAlerts.configure(container: container)
        #if os(iOS)
        TVBackgroundRefresh.register(container: container)
        #endif
        if !inMemory {
            // From what's stored, no TMDB: the Mac has no background refresh,
            // and scheduled only when TV opened, its three weeks of alerts
            // ran out for anyone who used the app but not TV.
            Task { @MainActor in await TVEpisodeAlerts.reschedule() }
        }
        #if DEBUG
        guard TVEpisodeAlertProbe.isRequested else { return }
        guard inMemory else {
            print("[TVEpisodeAlertProbe] needs -InMemoryStores YES: its refresh writes episodes, which on the real store sync to iCloud.")
            return
        }
        Task { @MainActor in
            await TVEpisodeAlertProbe.run(container: container) { line in
                print("[TVEpisodeAlertProbe] \(line)")
                fflush(stdout)
            }
            if TVEpisodeAlertProbe.quitsWhenDone { exit(0) }
        }
        #endif
    }
}

#if os(iOS)
/// iOS's background app refresh for TV: TMDB's newly announced episodes and
/// moved air dates merged in, and the alerts rescheduled to match, while the
/// app isn't open — otherwise a season announced on Monday is only known the
/// next time TV is opened, and its premiere's alert can't be scheduled.
///
/// iOS runs it at its own discretion: `earliestDelay` is the soonest it may,
/// not when it will — less often for an app that's rarely opened, never in
/// Low Power Mode or with Background App Refresh off, and not after the app
/// is force-quit. Asked for only while alerts are on; a run that finds them
/// off does nothing and asks for no other.
enum TVBackgroundRefresh {
    /// Also in `BGTaskSchedulerPermittedIdentifiers` (project.yml). A
    /// registration missing from there is an exception at launch.
    static let identifier = "com.bhavikjain.trackers.tv-refresh"
    static let earliestDelay: TimeInterval = 6 * 60 * 60

    @MainActor private static var isRegistered = false

    @MainActor
    static func register(container: ModelContainer) {
        // A second registration of the same identifier is an exception too.
        guard !isRegistered else { return }
        isRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated { run(task, container: container) }
        }
        guard isRegistered else { return }
        TVEpisodeAlerts.requestBackgroundRefresh = { submitIfNeeded() }
        // An app update drops what was queued; nothing else asks again until
        // TV is next opened.
        submitIfNeeded()
    }

    /// Asks for the next run, unless one is already waiting: every
    /// reschedule calls this, and resubmitting would push the earliest time
    /// back each time TV is opened.
    @MainActor
    static func submitIfNeeded() {
        guard TVEpisodeAlerts.wantsBackgroundRefresh else { return }
        // `@Sendable`, so it isn't taken for main-actor code: the scheduler
        // answers on a queue of its own, and Swift 6 traps a main-actor
        // closure run anywhere else.
        BGTaskScheduler.shared.getPendingTaskRequests { @Sendable requests in
            guard !requests.contains(where: { $0.identifier == identifier }) else { return }
            let request = BGAppRefreshTaskRequest(identifier: identifier)
            request.earliestBeginDate = Date(timeIntervalSinceNow: earliestDelay)
            // Refused on a simulator, and with Background App Refresh off:
            // the alerts then come from what TV last knew.
            try? BGTaskScheduler.shared.submit(request)
        }
    }

    @MainActor
    private static func run(_ task: BGTask, container: ModelContainer) {
        nonisolated(unsafe) let task = task
        // The next one first, so a run cut short still leaves one queued.
        submitIfNeeded()
        let work = Task { @MainActor in
            let finished = await TVEpisodeAlerts.backgroundRefresh(container: container)
            task.setTaskCompleted(success: finished)
        }
        // iOS ending it early: the refresh stops between requests, keeps what
        // it merged (the ledger carries the rest to the next run) and the
        // task is still completed, once, above. `@Sendable` for the reason in
        // `submitIfNeeded`: iOS calls it off the main thread.
        task.expirationHandler = { @Sendable in work.cancel() }
    }
}
#endif
