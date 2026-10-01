#if DEBUG
import Foundation
import SwiftData

/// Populates the TV module from TMDB so a fresh install has something in it.
///
/// Debug builds only, and only when launched with `-TVSeedShows` — it exists
/// for trying the app out on a simulator, not for normal use.
public enum DebugSeed {
    public static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "TVSeedShows")
    }

    /// TMDB ids for a couple of series and a film.
    private static let showIDs = [(82428, "All American"), (4057, "Criminal Minds")]
    private static let movieIDs = [299534]

    @MainActor
    public static func run(context: ModelContext, apiKey: String) async {
        guard (try? context.fetchCount(FetchDescriptor<Show>())) == 0 else { return }
        // With no key (a fresh simulator), a made-up show instead: the
        // seeder used to do nothing at all, so the show screen couldn't be
        // looked at without typing a key into the simulator first.
        guard !apiKey.isEmpty else {
            seedOffline(context: context)
            return
        }

        let client = TMDBClient(apiKey: apiKey)

        for (id, name) in showIDs {
            // Search by name to pick up artwork and overview, which the
            // episode endpoints don't carry.
            let summary = (try? await client.searchShows(query: name))?.first { $0.id == id }
            let show = Show(
                tmdbID: id,
                name: summary?.name ?? name,
                overview: summary?.overview ?? "",
                posterPath: summary?.posterPath ?? ""
            )
            context.insert(show)
            guard let episodes = try? await client.allEpisodes(showID: id) else { continue }
            for payload in episodes {
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
            // Mark the first two seasons watched so progress is visible.
            for episode in show.orderedEpisodes where episode.seasonNumber <= 2 {
                episode.setWatched(true)
            }
        }

        for id in movieIDs {
            guard let detail = try? await client.movieDetail(id: id) else { continue }
            context.insert(
                Movie(
                    tmdbID: detail.id,
                    title: detail.title,
                    overview: detail.overview,
                    posterPath: detail.posterPath,
                    releaseDate: detail.releaseDate,
                    runtime: detail.runtime
                )
            )
        }

        try? context.save()
    }

    /// Two seasons of eight, all aired, the first half watched; no TMDB ids,
    /// so nothing tries to look them up.
    @MainActor
    private static func seedOffline(context: ModelContext) {
        let show = Show(name: "Sample Show", overview: "A made-up show from the debug seeder, for when there's no TMDB key.")
        context.insert(show)
        let start = Calendar.current.date(byAdding: .day, value: -200, to: .now) ?? .now
        for season in 1...2 {
            for number in 1...8 {
                let aired = Calendar.current.date(byAdding: .day, value: (season - 1) * 70 + number * 7, to: start)
                let episode = Episode(name: "Episode \(number) of season \(season)", seasonNumber: season, episodeNumber: number, airDate: aired)
                episode.show = show
                context.insert(episode)
                if season == 1, number <= 4 { episode.setWatched(true) }
            }
        }
        show.refreshStatus()
        try? context.save()
    }
}
#endif
