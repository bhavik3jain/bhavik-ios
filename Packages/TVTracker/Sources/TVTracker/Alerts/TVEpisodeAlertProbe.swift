#if DEBUG
import Core
import Foundation
import SwiftData
import UserNotifications

/// `-TVEpisodeAlertProbe YES` (Debug, with `-InMemoryStores YES`): at launch,
/// runs the TV seeder if `-TVSeedShows YES` asks for it, one refresh from
/// TMDB that ignores the twelve-hour ledger (none without a key), then
/// prints the new-episode alert plan and what the system holds pending.
/// `-TVEpisodeAlertProbeQuit YES` quits when it's done.
///
/// A simulator can't be made to deliver a 9:00 alert on demand, and nothing
/// on screen lists what's pending; this is how to see the plan. The plan is
/// printed even with alerts off — as what turning them on would schedule.
/// In-memory stores only: the refresh writes episodes, which on the real
/// store would sync to iCloud.
public enum TVEpisodeAlertProbe {
    public static var isRequested: Bool { UserDefaults.standard.bool(forKey: "TVEpisodeAlertProbe") }
    public static var quitsWhenDone: Bool { UserDefaults.standard.bool(forKey: "TVEpisodeAlertProbeQuit") }

    @MainActor
    public static func run(container: ModelContainer, print: (String) -> Void) async {
        let context = container.mainContext
        let apiKey = SyncedKeychain.string(forKey: TVTrackerModule.apiKeyDefaultsKey) ?? ""
        if DebugSeed.isRequested {
            await DebugSeed.run(context: context, apiKey: apiKey)
        }
        let shows = (try? context.fetch(FetchDescriptor<Show>(sortBy: [SortDescriptor(\.name)]))) ?? []
        print("\(counted(shows.count, "show")) in the store")
        for show in shows {
            print("  \(show.name) — \(show.status.displayName), \(counted(show.episodeCount, "episode")), TMDB id \(show.tmdbID)")
        }

        if apiKey.isEmpty {
            print("refresh: no TMDB key, so nothing refreshed — the plan comes from what's stored")
        } else {
            let summary = await TVEpisodeAlerts.refresh(context: context, apiKey: apiKey, force: true, asOf: .now)
            print("refresh: \(counted(summary.refreshedShows, "show")), \(summary.insertedEpisodes) added, \(summary.updatedEpisodes) updated\(summary.stoppedEarly ? " (stopped early)" : "")")
            for line in summary.lines { print("  \(line)") }
            if !summary.failures.isEmpty { print("  failed: \(summary.failures.joined(separator: ", "))") }
        }

        let preferences = EpisodeAlertStore.shared.preferences
        let time = preferences.time().formatted(date: .omitted, time: .shortened)
        print("preferences: alerts \(preferences.isEnabled ? "on" : "off"), at \(time), \(preferences.mutedShows.count) muted")
        var planned = preferences
        planned.isEnabled = true
        let plan = TVEpisodeAlerts.plan(context: context, preferences: planned, asOf: .now)
        print("plan: \(counted(plan.count, "notification"))\(preferences.isEnabled ? "" : " — alerts are off, so this is what turning them on would schedule")")
        for alert in plan {
            print("  \(alert.fireDate.formatted(date: .abbreviated, time: .shortened))  \(alert.identifier)")
            print("    \(alert.title): \(alert.body)")
        }

        await TVEpisodeAlerts.reschedule(context: context)
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(EpisodeAlertPlanner.identifierPrefix) }
        let allowed = await SharedChangeNotifications.isAuthorized()
        print("pending with the system: \(pending.count)\(allowed ? "" : " (notifications aren't allowed on this device, so none are scheduled)")")
        print("done")
    }
}
#endif
