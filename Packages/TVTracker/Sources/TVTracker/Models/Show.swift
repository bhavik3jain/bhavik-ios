import Foundation
import SwiftData

public enum ShowStatus: String, Codable, CaseIterable, Sendable {
    case watching
    /// In the library, but not begun. Without this everything you ever meant to
    /// watch sits under "Watching" at 0%, which buries what you're actually
    /// part-way through.
    case notStarted
    case completed
    case dropped

    /// Declaration order is section order in the Watching list, so what's in
    /// progress comes first and what's abandoned comes last.
    public var displayName: String {
        switch self {
        case .watching: "Watching"
        case .notStarted: "Haven't started"
        case .completed: "Completed"
        case .dropped: "Dropped"
        }
    }
}

@Model
public final class Show {
    /// TMDB's identifier, kept so metadata can be refreshed even if the show is
    /// renamed upstream. Zero for shows added by hand without a lookup.
    public var tmdbID: Int = 0
    public var name: String = ""
    public var overview: String = ""
    public var posterPath: String = ""
    public var statusRaw: String = ShowStatus.notStarted.rawValue
    public var addedAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \Episode.show)
    public var episodes: [Episode]? = []

    public var status: ShowStatus {
        get { ShowStatus(rawValue: statusRaw) ?? .notStarted }
        set { statusRaw = newValue.rawValue }
    }

    public init(tmdbID: Int = 0, name: String, overview: String = "", posterPath: String = "") {
        self.tmdbID = tmdbID
        self.name = name
        self.overview = overview
        self.posterPath = posterPath
        self.addedAt = .now
    }

    /// Re-derives the status from what's actually been watched.
    ///
    /// Ticking off the first episode should stop a show claiming you haven't
    /// started, and ticking off the last should stop it claiming you're still
    /// watching. Dropped is left alone — that was a deliberate choice, not
    /// something to infer.
    ///
    /// Specials don't count towards finishing: they're bonus material, and
    /// requiring them would put completion out of reach.
    public func refreshStatus() {
        guard status != .dropped else { return }

        let episodes = self.episodes ?? []
        let numbered = episodes.count { $0.seasonNumber > 0 }
        guard numbered > 0 else { return }

        let watched = episodes.count(where: \.isWatched)
        if watched == 0 {
            status = .notStarted
        } else if watched >= numbered {
            status = .completed
        } else {
            status = .watching
        }
    }

    /// Every aired episode of `season` watched, or every one unwatched. An
    /// episode that hasn't aired is left alone either way (it can't have been
    /// watched yet), and one already watched keeps the date it was watched.
    /// The show's status follows, as for a single episode.
    public func setSeasonWatched(_ season: Int, _ watched: Bool, at date: Date = .now, asOf now: Date = .now) {
        for episode in episodes ?? [] where episode.seasonNumber == season {
            if watched {
                if !episode.isWatched, episode.hasAired(asOf: now) { episode.setWatched(true, at: date) }
            } else if episode.isWatched {
                episode.setWatched(false)
            }
        }
        refreshStatus()
    }

    /// Whether every aired episode of `season` is watched — what decides
    /// between offering "Mark Season Watched" and "Mark Season Unwatched".
    /// False for a season with nothing aired yet.
    public func isSeasonWatched(_ season: Int, asOf now: Date = .now) -> Bool {
        let aired = (episodes ?? []).filter { $0.seasonNumber == season && $0.hasAired(asOf: now) }
        return !aired.isEmpty && aired.allSatisfy(\.isWatched)
    }

    public var orderedEpisodes: [Episode] {
        Self.inRunningOrder(episodes ?? [])
    }

    /// `episodes` sorted by season then number, reading each one's numbers
    /// once.
    ///
    /// Sorting on the model's properties directly read them through
    /// SwiftData's backing store on every comparison — four getters each, n
    /// log n times. With a few thousand episodes in the library that was most
    /// of the Mac's main thread at launch: the sidebar's TV count and the
    /// Overview's TV card re-sorted every show on each render, and a sample
    /// of the first five seconds found 79% of it under `orderedEpisodes`.
    static func inRunningOrder(_ episodes: [Episode]) -> [Episode] {
        episodes
            .map { (season: $0.seasonNumber, number: $0.episodeNumber, episode: $0) }
            .sorted { ($0.season, $0.number) < ($1.season, $1.number) }
            .map(\.episode)
    }

    public var watchedCount: Int {
        (episodes ?? []).count { $0.isWatched }
    }

    public var episodeCount: Int {
        (episodes ?? []).count
    }

    public var progress: Double {
        guard episodeCount > 0 else { return 0 }
        return Double(watchedCount) / Double(episodeCount)
    }

    /// The next unwatched episode in running order — what the app offers to
    /// tick off, and the anchor for "what am I up to on this show".
    public var nextUnwatched: Episode? {
        orderedEpisodes.first { !$0.isWatched }
    }

    /// Episodes that have aired but haven't been watched yet.
    /// Filtered before sorting, so only the backlog is ordered — not every
    /// episode the show has.
    public func unwatchedAired(asOf now: Date = .now) -> [Episode] {
        Self.inRunningOrder((episodes ?? []).filter { !$0.isWatched && $0.hasAired(asOf: now) })
    }

    /// How many episodes have aired but haven't been watched — `unwatchedAired`
    /// without building or sorting anything, for a count beside a row.
    public func unwatchedAiredCount(asOf now: Date = .now) -> Int {
        (episodes ?? []).count { !$0.isWatched && $0.hasAired(asOf: now) }
    }

    /// The soonest episode still to air. Ties on the date go to the earlier
    /// episode in running order, as when this sorted every episode first.
    ///
    /// One pass, reading each episode's date and numbers once: it runs for
    /// every show on each render of the Mac Overview's TV card, and sorting
    /// every unaired episode first (a long-running show announces whole
    /// seasons with no dates) was a sort through SwiftData's getters per show.
    public func nextToAir(asOf now: Date = .now) -> Episode? {
        Self.soonestToAir(episodes ?? [], asOf: now)
    }

    /// `nextToAir` over any set of one show's episodes — `Schedule.upcoming`
    /// hands it the ones it fetched in one go rather than walking
    /// `episodes`.
    static func soonestToAir(_ episodes: [Episode], asOf now: Date) -> Episode? {
        var best: (date: Date, season: Int, number: Int, episode: Episode)?
        for episode in episodes {
            let airDate = episode.airDate
            if let airDate, airDate <= now { continue }
            let candidate = (date: airDate ?? .distantFuture, season: episode.seasonNumber, number: episode.episodeNumber, episode: episode)
            if let current = best,
               (current.date, current.season, current.number) <= (candidate.date, candidate.season, candidate.number) {
                continue
            }
            best = candidate
        }
        return best?.episode
    }
}
