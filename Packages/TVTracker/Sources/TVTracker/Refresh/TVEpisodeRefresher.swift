import Core
import Foundation
import SwiftData

/// Where a refresh reads episodes from: TMDB, or a fake in tests.
protocol TVEpisodeSource: Sendable {
    func seasons(showID: Int) async throws -> TMDBShowSeasons
    func episodes(showID: Int, season: Int) async throws -> [TMDBEpisode]
}

extension TMDBClient: TVEpisodeSource {}

/// When each show was last refreshed, by TMDB id, on this device.
///
/// In UserDefaults rather than on `Show`: a new stored property on a
/// SwiftData model is a CloudKit schema change (the Console ritual, and a
/// Production deploy before any TestFlight build), and a stamp rewritten
/// every twelve hours would sync to every device each time for nothing.
struct TVRefreshLedger {
    static let defaultsKey = "tv.episodeRefresh.lastRefreshed"
    /// At most one refresh per show in this long.
    static let interval: TimeInterval = 12 * 60 * 60

    var defaults: UserDefaults = .standard

    func lastRefreshed(_ tmdbID: Int) -> Date? {
        stamps[String(tmdbID)].map(Date.init(timeIntervalSince1970:))
    }

    func isDue(_ tmdbID: Int, asOf now: Date) -> Bool {
        guard let last = lastRefreshed(tmdbID) else { return true }
        // A clock set back must not hold a show off for as long as it moved.
        return now.timeIntervalSince(last) >= Self.interval || last > now
    }

    func markRefreshed(_ tmdbID: Int, at date: Date) {
        var stamps = stamps
        stamps[String(tmdbID)] = date.timeIntervalSince1970
        defaults.set(stamps, forKey: Self.defaultsKey)
    }

    private var stamps: [String: Double] {
        defaults.dictionary(forKey: Self.defaultsKey) as? [String: Double] ?? [:]
    }
}

/// Re-reads shows' episode lists from TMDB and merges them in
/// (`EpisodeMerge`), so newly announced episodes and moved air dates reach
/// Up Next and the new-episode alerts.
///
/// Shows with a TMDB id that are being watched or not started yet, and
/// completed ones too — a new season of a finished show is exactly what
/// someone wants to hear about. Dropped shows are left alone. Each at most
/// once per `TVRefreshLedger.interval`, the ones being watched first, so a
/// run cut short (a background task's half minute, the module closed) has
/// spent itself where alerts come from; the ledger carries the rest over.
///
/// Two devices refreshing the same show before either's additions have
/// synced each add the same new episode. The merge keeps such copies in step
/// and never adds another, but can't fold them: no synced property tells two
/// copies apart, so two devices tidying at once could each delete the copy
/// the other kept. The twelve-hour ledger keeps that window small.
@MainActor
struct TVEpisodeRefresher {
    struct Summary: Equatable {
        /// "Severance: 2 seasons, 1 added, 3 updated" — one per show refreshed.
        var lines: [String] = []
        var refreshedShows = 0
        var insertedEpisodes = 0
        var updatedEpisodes = 0
        /// Shows that failed; retried on the next run, not twelve hours on.
        var failures: [String] = []
        /// Cancelled, or TMDB refused the key or the rate: the rest wait.
        var stoppedEarly = false

        var changedAnything: Bool { insertedEpisodes > 0 || updatedEpisodes > 0 }
    }

    /// Statuses worth a refresh, in the order they're refreshed.
    static let refreshedStatuses: [ShowStatus] = [.watching, .notStarted, .completed]
    /// Network failures in a row before a run gives up — offline, most likely.
    static let failureLimit = 2

    let source: any TVEpisodeSource
    var ledger = TVRefreshLedger()

    /// The shows due a refresh, in the order to refresh them: watching, then
    /// not started, then completed, and within each the longest-waiting
    /// first. `force` ignores the ledger (the debug probe).
    static func due(_ shows: [Show], ledger: TVRefreshLedger, asOf now: Date, force: Bool = false) -> [Show] {
        shows
            .compactMap { show -> (show: Show, rank: Int, last: Date, name: String)? in
                let tmdbID = show.tmdbID
                guard tmdbID > 0,
                      let rank = refreshedStatuses.firstIndex(of: show.status),
                      force || ledger.isDue(tmdbID, asOf: now) else { return nil }
                return (show, rank, ledger.lastRefreshed(tmdbID) ?? .distantPast, show.name)
            }
            .sorted { ($0.rank, $0.last, $0.name) < ($1.rank, $1.last, $1.name) }
            .map(\.show)
    }

    func refresh(context: ModelContext, asOf now: Date = .now, force: Bool = false) async -> Summary {
        var summary = Summary()
        let dropped = ShowStatus.dropped.rawValue
        let descriptor = FetchDescriptor<Show>(predicate: #Predicate { $0.tmdbID > 0 && $0.statusRaw != dropped })
        guard let shows = try? context.fetch(descriptor) else { return summary }

        var failuresInARow = 0
        for show in Self.due(shows, ledger: ledger, asOf: now, force: force) {
            if Task.isCancelled {
                summary.stoppedEarly = true
                break
            }
            do {
                try await refresh(show, in: context, asOf: now, into: &summary)
                failuresInARow = 0
            } catch TMDBError.unauthorized, TMDBError.missingAPIKey, TMDBError.rateLimited {
                summary.failures.append(show.name)
                summary.stoppedEarly = true
                break
            } catch {
                summary.failures.append(show.name)
                failuresInARow += 1
                // A cancelled request arrives as a network error too.
                if Task.isCancelled || failuresInARow >= Self.failureLimit {
                    summary.stoppedEarly = true
                    break
                }
            }
        }
        return summary
    }

    private func refresh(_ show: Show, in context: ModelContext, asOf now: Date, into summary: inout Summary) async throws {
        let tmdbID = show.tmdbID
        let remote = try await source.seasons(showID: tmdbID)
        let before = (show.episodes ?? []).map(EpisodeMerge.Local.init)
        let seasons = EpisodeRefreshPlan.seasonsToFetch(remote: remote, local: before, asOf: now)
        var fetched: [TMDBEpisode] = []
        for season in seasons {
            fetched += try await source.episodes(showID: tmdbID, season: season)
            // Half a show's seasons would read as a show that shrank no
            // further than it grew; the next run starts it over instead.
            if Task.isCancelled { throw CancellationError() }
        }

        // Read again after the awaits: the person may have added an episode
        // by hand, or a sync brought some in, while TMDB was answering.
        let episodes = show.episodes ?? []
        let merge = EpisodeMerge(local: episodes.map(EpisodeMerge.Local.init), remote: fetched)
        merge.apply(to: show, episodes: episodes, in: context)
        // A finished show with a new season is being watched again. Only
        // then: re-deriving every show's status would turn one set to
        // Watching by hand, with nothing ticked off yet, back to "Haven't
        // started" — and silence its alerts.
        if !merge.inserts.isEmpty, show.status == .completed {
            show.refreshStatus()
        }
        if !merge.isEmpty { try? context.save() }
        ledger.markRefreshed(tmdbID, at: now)

        summary.refreshedShows += 1
        summary.insertedEpisodes += merge.inserts.count
        summary.updatedEpisodes += merge.updates.count
        summary.lines.append(
            "\(show.name): \(counted(seasons.count, "season")) fetched, \(merge.inserts.count) added, \(merge.updates.count) updated"
        )
    }
}
