import Foundation
import SwiftData

public struct ScheduledEpisode: Identifiable, Sendable {
    public let id: PersistentEpisodeID
    public let showName: String
    public let posterPath: String
    public let code: String
    public let episodeName: String
    public let airDate: Date?

    public struct PersistentEpisodeID: Hashable, Sendable {
        let showName: String
        let code: String
    }
}

/// The backlog counted per show — see `Schedule.backlog(shows:asOf:)`.
public struct Backlog: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Identifiable {
        public let showName: String
        public let posterPath: String
        /// When the oldest unwatched, aired episode aired.
        public let oldestAirDate: Date
        public let episodeCount: Int

        public var id: String { showName }
    }

    /// Every ready episode, across all shows being watched.
    public let episodeCount: Int
    /// Shows with anything ready, the one waiting longest first.
    public let shows: [Entry]

    public var isEmpty: Bool { episodeCount == 0 }
}

/// Everything the Mac Overview's TV card draws — the backlog and what airs
/// next — worked out in one pass over the unwatched episodes. See
/// `Schedule.glance(episodes:asOf:)`.
public struct ScheduleGlance: Sendable {
    public let backlog: Backlog
    public let upcoming: [ScheduledEpisode]
}

public enum Schedule {
    // Every function here comes in two forms: one over `shows`, which walks
    // each show's `episodes`, and one over a flat list of the unwatched
    // episodes fetched in one go (`Schedule.unwatched`, as an `@Query`
    // filter), which is what anything drawn on every render should use.
    //
    // The flat forms take the unwatched episodes only, as that query hands
    // them over, and don't read `isWatched` again: a SwiftData getter is a
    // keyed lookup in the model's backing data, not a field read, and
    // re-checking it on every episode was 74 of the 208 main-thread samples
    // the Overview's TV card still cost in a ten-second sample while
    // CloudKit imported. The `shows` forms drop watched episodes first.
    //
    // Walking `show.episodes` hands back faults, and reading the first
    // property of each one is a SQLite fetch of its own on the main thread.
    // The Mac Overview's TV card did that for every episode in the library
    // each time it was built: after the sorting and string-building had
    // been taken out, a five-second sample at launch still spent 832 of
    // 1,406 main-thread samples inside `Episode.isWatched`'s getter, nearly
    // all of it in `NSManagedObjectContext.fetch`. One query loads them all
    // in a single statement instead — and only the unwatched ones: with
    // every episode in the library fetched, just reading `isWatched` on each
    // through SwiftData's getters was still 185 samples of the sidebar's TV
    // count and 177 of the card's backlog.

    /// The `@Query` filter for the flat forms below: the only episodes any
    /// of them looks at.
    public static var unwatched: Predicate<Episode> {
        #Predicate<Episode> { $0.isWatched == false }
    }

    /// Episodes that have aired but are still unwatched, oldest first — the
    /// backlog to catch up on.
    public static func readyToWatch(shows: [Show], asOf now: Date = .now) -> [ScheduledEpisode] {
        readyToWatch(episodes: episodes(of: shows), asOf: now)
    }

    /// `readyToWatch(shows:asOf:)` from the library's unwatched episodes.
    public static func readyToWatch(episodes: [Episode], asOf now: Date = .now) -> [ScheduledEpisode] {
        episodes
            .compactMap { episode -> (ScheduledEpisode, season: Int, number: Int)? in
                guard episode.hasAired(asOf: now),
                      let show = episode.show, show.status == .watching else { return nil }
                return (scheduled(episode, of: show), episode.seasonNumber, episode.episodeNumber)
            }
            // Ties (a double bill) in running order, and then by show, so the
            // list doesn't reshuffle from one render to the next.
            .sorted {
                ($0.0.airDate ?? .distantPast, $0.0.showName, $0.season, $0.number)
                    < ($1.0.airDate ?? .distantPast, $1.0.showName, $1.season, $1.number)
            }
            .map(\.0)
    }

    /// `readyToWatch(shows:asOf:).count` without building, sorting or naming
    /// a single episode — the Mac sidebar's figure beside TV and the hub's
    /// row, both read on every render.
    public static func readyCount(shows: [Show], asOf now: Date = .now) -> Int {
        readyCount(episodes: episodes(of: shows), asOf: now)
    }

    /// `readyCount(shows:asOf:)` from the library's unwatched episodes.
    public static func readyCount(episodes: [Episode], asOf now: Date = .now) -> Int {
        episodes.count { isReady($0, asOf: now) }
    }

    /// What the Mac Overview's TV card shows of the backlog: how many episodes
    /// are ready, and which shows they come from, the one waiting longest
    /// first. Nothing per episode — `readyToWatch` built a `ScheduledEpisode`
    /// with its code and name for each of several hundred backlog episodes,
    /// then sorted them, on every render of the Overview; at launch, while
    /// CloudKit's import re-renders it again and again, that was over half
    /// of the main thread in a five-second sample.
    public static func backlog(shows: [Show], asOf now: Date = .now) -> Backlog {
        backlog(episodes: episodes(of: shows), asOf: now)
    }

    /// `backlog(shows:asOf:)` from the library's unwatched episodes.
    public static func backlog(episodes: [Episode], asOf now: Date = .now) -> Backlog {
        glance(episodes: episodes, asOf: now).backlog
    }

    /// The next episode still to air for each show being watched, soonest
    /// first. One already ticked off — a whole season marked watched before
    /// its finale aired — isn't offered as coming up: it's the one after it
    /// that's still to watch.
    public static func upcoming(shows: [Show], asOf now: Date = .now) -> [ScheduledEpisode] {
        upcoming(episodes: episodes(of: shows), asOf: now)
    }

    /// `upcoming(shows:asOf:)` from the library's unwatched episodes.
    public static func upcoming(episodes: [Episode], asOf now: Date = .now) -> [ScheduledEpisode] {
        glance(episodes: episodes, asOf: now).upcoming
    }

    /// `backlog` and `upcoming` together, reading each episode's air date
    /// and show once, and each show's status once rather than once per
    /// episode. The Overview's TV card wants both on every render, and as
    /// two functions that was two walks through SwiftData's getters over
    /// the whole unwatched library.
    public static func glance(episodes: [Episode], asOf now: Date = .now) -> ScheduleGlance {
        // One entry per show, found by a single hash per episode and
        // mutated in place in the array.
        var shows: [(show: Show, ready: Int, oldest: Date?, unaired: [Episode])] = []
        var index: [PersistentIdentifier: Int] = [:]
        for episode in episodes {
            guard let show = episode.show else { continue }
            let slot: Int
            if let found = index[show.persistentModelID] {
                slot = found
            } else {
                slot = shows.count
                index[show.persistentModelID] = slot
                shows.append((show, 0, nil, []))
            }
            if let airDate = episode.airDate, airDate <= now {
                shows[slot].ready += 1
                shows[slot].oldest = min(shows[slot].oldest ?? airDate, airDate)
            } else {
                shows[slot].unaired.append(episode)
            }
        }
        let watching = shows.filter { $0.show.status == .watching }

        let waiting = watching
            .compactMap { entry -> Backlog.Entry? in
                guard entry.ready > 0, let oldest = entry.oldest else { return nil }
                return Backlog.Entry(showName: entry.show.name, posterPath: entry.show.posterPath, oldestAirDate: oldest, episodeCount: entry.ready)
            }
            .sorted { ($0.oldestAirDate, $0.showName) < ($1.oldestAirDate, $1.showName) }
        let backlog = Backlog(episodeCount: waiting.reduce(0) { $0 + $1.episodeCount }, shows: waiting)

        let upcoming = watching
            .compactMap { entry -> ScheduledEpisode? in
                Show.soonestToAir(entry.unaired, asOf: now).map { scheduled($0, of: entry.show) }
            }
            .sorted { ($0.airDate ?? .distantFuture, $0.showName) < ($1.airDate ?? .distantFuture, $1.showName) }
        return ScheduleGlance(backlog: backlog, upcoming: upcoming)
    }

    // MARK: - Helpers

    /// The unwatched episodes of the shows being watched — what the flat
    /// forms expect, and all that everything above looks at anyway.
    private static func episodes(of shows: [Show]) -> [Episode] {
        shows.filter { $0.status == .watching }.flatMap { ($0.episodes ?? []).filter { !$0.isWatched } }
    }

    private static func isReady(_ episode: Episode, asOf now: Date) -> Bool {
        guard episode.hasAired(asOf: now) else { return false }
        return episode.show?.status == .watching
    }

    private static func scheduled(_ episode: Episode, of show: Show) -> ScheduledEpisode {
        let code = episode.code
        return ScheduledEpisode(
            id: .init(showName: show.name, code: code),
            showName: show.name,
            posterPath: show.posterPath,
            code: code,
            episodeName: episode.name,
            airDate: episode.airDate
        )
    }
}
