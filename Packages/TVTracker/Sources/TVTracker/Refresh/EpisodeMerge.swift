import Foundation
import SwiftData

/// What one refresh does to a show's episodes, worked out from plain values
/// before anything is touched — see `TVEpisodeRefresher`.
///
/// Episodes are matched by (season, episode number), the way TMDB and the
/// show screen both count them. A matched episode takes TMDB's name, air date
/// and id; one TMDB lists that isn't here is added. Nothing is ever deleted —
/// an episode added by hand, or one TMDB has since dropped, stays — and
/// watched state is never read or written: it's the one thing here that is
/// the person's, not the catalog's.
///
/// Before this, a show's episodes were fetched once, when it was added, and
/// never again: a season announced later, an air date that moved, a "TBA"
/// that got its title, none of it ever reached the app, so Up Next ran dry
/// and there was nothing to notify about.
struct EpisodeMerge: Equatable {
    /// One of the show's own episodes, as the merge needs it.
    struct Local: Equatable {
        let season: Int
        let number: Int
        let tmdbID: Int
        let name: String
        let airDate: Date?
    }

    struct Update: Equatable {
        /// Into the `local` array the merge was built from.
        let index: Int
        let name: String
        let airDate: Date?
        let tmdbID: Int
    }

    let updates: [Update]
    let inserts: [TMDBEpisode]

    init(local: [Local], remote: [TMDBEpisode]) {
        var byNumber: [Key: [Int]] = [:]
        for (index, episode) in local.enumerated() {
            byNumber[Key(episode.season, episode.number), default: []].append(index)
        }
        let knownIDs = Set(local.map(\.tmdbID).filter { $0 > 0 })

        var updates: [Update] = []
        var inserts: [TMDBEpisode] = []
        var seen: Set<Key> = []
        for episode in remote {
            let key = Key(episode.seasonNumber, episode.episodeNumber)
            // TMDB listing the same number twice would otherwise insert it twice.
            guard seen.insert(key).inserted else { continue }
            if let indices = byNumber[key] {
                // Every copy, if two devices have each added it (see
                // `TVEpisodeRefresher`): kept in step, and never a third.
                for index in indices {
                    let current = local[index]
                    // Never blanked: TMDB sends an empty name or no date for
                    // what it doesn't know yet, which mustn't wipe a title or
                    // a date typed in by hand.
                    let name = episode.name.isEmpty ? current.name : episode.name
                    let airDate = episode.airDate ?? current.airDate
                    let tmdbID = episode.id > 0 ? episode.id : current.tmdbID
                    if name != current.name || airDate != current.airDate || tmdbID != current.tmdbID {
                        updates.append(Update(index: index, name: name, airDate: airDate, tmdbID: tmdbID))
                    }
                }
            } else if episode.id > 0, knownIDs.contains(episode.id) {
                // Already here under other numbers — TMDB renumbered it.
                // Adding it again would show it twice, and moving the one
                // here (watched, perhaps) isn't a refresh's call to make.
                continue
            } else {
                inserts.append(episode)
            }
        }
        self.updates = updates
        self.inserts = inserts
    }

    var isEmpty: Bool { updates.isEmpty && inserts.isEmpty }

    /// Writes the merge into `show`. `episodes` must be the array the
    /// merge's `local` was built from, in the same order.
    @MainActor
    func apply(to show: Show, episodes: [Episode], in context: ModelContext) {
        for update in updates {
            let episode = episodes[update.index]
            if episode.name != update.name { episode.name = update.name }
            if episode.airDate != update.airDate { episode.airDate = update.airDate }
            if episode.tmdbID != update.tmdbID { episode.tmdbID = update.tmdbID }
        }
        for payload in inserts {
            let episode = Episode(
                tmdbID: payload.id,
                name: payload.name,
                seasonNumber: payload.seasonNumber,
                episodeNumber: payload.episodeNumber,
                airDate: payload.airDate
            )
            episode.show = show
            context.insert(episode)
        }
    }

    private struct Key: Hashable {
        let season: Int
        let number: Int
        init(_ season: Int, _ number: Int) {
            self.season = season
            self.number = number
        }
    }
}

extension EpisodeMerge.Local {
    /// Reads each property once — every one is a lookup in SwiftData's
    /// backing store (see `Schedule`).
    @MainActor
    init(_ episode: Episode) {
        self.init(
            season: episode.seasonNumber,
            number: episode.episodeNumber,
            tmdbID: episode.tmdbID,
            name: episode.name,
            airDate: episode.airDate
        )
    }
}

/// Which of a show's seasons a refresh asks TMDB for.
///
/// One request per season is the cost of a refresh, so only the seasons that
/// can have changed are fetched: one that's new, one TMDB counts more episodes
/// in than are here, the latest season of a show still running (where new
/// episodes are announced), and any season with an episode still to air, with
/// no date, or aired in the last fortnight (dates move and titles arrive
/// around then). A long-finished show costs the one request for its season
/// list. Specials (season 0) are never fetched: TMDB files trailers and
/// recaps there, which `show(id:)` leaves out when a show is added too.
enum EpisodeRefreshPlan {
    static let settlingPeriod: TimeInterval = 14 * 86_400

    static func seasonsToFetch(
        remote: TMDBShowSeasons,
        local: [EpisodeMerge.Local],
        asOf now: Date = .now
    ) -> [Int] {
        let seasons = remote.seasons.filter { $0.number > 0 }
        let latest = seasons.map(\.number).max()
        let bySeason = Dictionary(grouping: local, by: \.season)
        let settledBefore = now.addingTimeInterval(-settlingPeriod)
        var wanted: [Int] = []
        for season in seasons {
            let here = bySeason[season.number] ?? []
            let numbers = Set(here.map(\.number))
            let isNew = here.isEmpty
            let hasMore = season.episodeCount.map { $0 > numbers.count } ?? false
            let isGrowing = !remote.hasEnded && season.number == latest
            let isSettling = here.contains { episode in
                guard let airDate = episode.airDate else { return true }
                return airDate > settledBefore
            }
            if isNew || hasMore || isGrowing || isSettling, !wanted.contains(season.number) {
                wanted.append(season.number)
            }
        }
        return wanted.sorted()
    }
}
