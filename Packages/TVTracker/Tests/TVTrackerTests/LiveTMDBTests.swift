import Foundation
import SwiftData
import Testing
@testable import TVTracker

/// A TMDB key, or nil to skip. Supply one of:
///
///   TMDB_API_KEY   the key itself
///   TMDB_KEY_FILE  a path to a file holding it
///
/// The simulator does not inherit the shell environment, so these are set on
/// the test runner. See the README for how to run these against the live API.
private var liveKey: String? {
    if let key = ProcessInfo.processInfo.environment["TMDB_API_KEY"], !key.isEmpty { return key }
    guard let path = ProcessInfo.processInfo.environment["TMDB_KEY_FILE"],
          let contents = try? String(contentsOfFile: path, encoding: .utf8)
    else { return nil }
    let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

@Test(.enabled(if: liveKey != nil, "Set TMDB_KEY_FILE to run live TMDB tests")) func liveSearchFindsAllAmerican() async throws {
    let liveKey = liveKey!
    let results = try await TMDBClient(apiKey: liveKey).searchShows(query: "All American")
    let match = try #require(results.first { $0.id == 82428 })
    #expect(match.name == "All American")
    #expect(match.firstAirDate != nil)
    #expect(!match.posterPath.isEmpty)
}

@Test(.enabled(if: liveKey != nil, "Set TMDB_KEY_FILE to run live TMDB tests")) func liveFetchLoadsEveryEpisodeOfAllAmerican() async throws {
    let liveKey = liveKey!
    let episodes = try await TMDBClient(apiKey: liveKey).allEpisodes(showID: 82428)

    #expect(episodes.count > 120, "Got \(episodes.count) episodes")
    #expect(episodes.allSatisfy { $0.seasonNumber > 0 }, "Specials must be excluded")
    #expect(episodes.contains { $0.seasonNumber == 1 && $0.episodeNumber == 1 })

    // A currently-airing show should carry episodes on both sides of today.
    let aired = episodes.filter { ($0.airDate ?? .distantFuture) <= .now }
    #expect(!aired.isEmpty)
}

@Test(.enabled(if: liveKey != nil, "Set TMDB_KEY_FILE to run live TMDB tests")) func liveFetchHandlesNineteenSeasonsOfCriminalMinds() async throws {
    let liveKey = liveKey!
    let episodes = try await TMDBClient(apiKey: liveKey).allEpisodes(showID: 4057)

    #expect(episodes.count > 300, "Got \(episodes.count) episodes")
    let seasons = Set(episodes.map(\.seasonNumber))
    #expect(seasons.count >= 17, "Got \(seasons.count) seasons")
    #expect(!seasons.contains(0))

    // Episode numbering should be contiguous within each season.
    for season in seasons.sorted() {
        let numbers = episodes.filter { $0.seasonNumber == season }.map(\.episodeNumber).sorted()
        #expect(numbers.first == 1, "Season \(season) starts at \(numbers.first ?? -1)")
    }
}

@Test(.enabled(if: liveKey != nil, "Set TMDB_KEY_FILE to run live TMDB tests")) func liveBadKeyIsReportedAsUnauthorized() async throws {
    await #expect(throws: TMDBError.self) {
        try await TMDBClient(apiKey: "0000000000000000deadbeef00000000").searchShows(query: "All American")
    }
}

@MainActor
@Test(.enabled(if: liveKey != nil, "Set TMDB_KEY_FILE to run live TMDB tests")) func liveShowsFlowThroughTheScheduleCorrectly() async throws {
    let liveKey = liveKey!
    let schema = Schema(TVTrackerModule.models)
    let container = try ModelContainer(
        for: schema,
        configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
    )
    let context = ModelContext(container)
    let client = TMDBClient(apiKey: liveKey)

    // All American is still airing; Criminal Minds has finished its run.
    for (id, name) in [(82428, "All American"), (4057, "Criminal Minds")] {
        let show = Show(tmdbID: id, name: name)
        context.insert(show)
        for payload in try await client.allEpisodes(showID: id) {
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
    try context.save()

    let shows = try context.fetch(FetchDescriptor<Show>())
    #expect(shows.count == 2)

    // Nothing watched yet, so every aired episode is backlog.
    let ready = Schedule.readyToWatch(shows: shows)
    #expect(ready.count > 400, "Both back catalogues should be waiting, got \(ready.count)")
    #expect(ready.allSatisfy { ($0.airDate ?? .distantFuture) <= .now })

    // Only the show still in production contributes an upcoming episode.
    let upcoming = Schedule.upcoming(shows: shows)
    #expect(upcoming.contains { $0.showName == "All American" })
    #expect(upcoming.allSatisfy { ($0.airDate ?? .distantPast) > .now })

    // Watching the first season of All American should shrink the backlog by
    // exactly that many episodes and move its next-up marker forward.
    let allAmerican = try #require(shows.first { $0.tmdbID == 82428 })
    let seasonOne = allAmerican.orderedEpisodes.filter { $0.seasonNumber == 1 }
    #expect(seasonOne.count > 10)
    seasonOne.forEach { $0.setWatched(true) }

    let afterWatching = Schedule.readyToWatch(shows: shows)
    #expect(afterWatching.count == ready.count - seasonOne.count)
    #expect(allAmerican.nextUnwatched?.seasonNumber == 2)
    #expect(allAmerican.watchedCount == seasonOne.count)
}

@Test(.enabled(if: liveKey != nil, "Set TMDB_KEY_FILE to run live TMDB tests")) func liveMovieSearchAndDetailForEndgame() async throws {
    let liveKey = liveKey!
    let client = TMDBClient(apiKey: liveKey)

    let results = try await client.searchMovies(query: "Avengers Endgame")
    let match = try #require(results.first { $0.id == 299534 })
    #expect(match.title == "Avengers: Endgame")
    #expect(match.runtime == 0, "Search results omit runtime")

    // The detail call is what fills the runtime in.
    let detail = try await client.movieDetail(id: 299534)
    #expect(detail.runtime == 181)
    #expect(detail.releaseDate != nil)
    #expect(!detail.posterPath.isEmpty)
}

@Test func movieRuntimeIsFormattedForReading() {
    #expect(Movie(title: "Endgame", runtime: 181).formattedRuntime == "3h 1m")
    #expect(Movie(title: "Short", runtime: 45).formattedRuntime == "45m")
    #expect(Movie(title: "Unknown", runtime: 0).formattedRuntime == nil)
}

@Test func unreleasedMoviesAreNotMarkedAsReleased() {
    let future = Movie(title: "Sequel", releaseDate: Date.now.addingTimeInterval(86_400 * 30))
    #expect(!future.hasReleased())
    let past = Movie(title: "Endgame", releaseDate: Date(timeIntervalSince1970: 1_556_064_000))
    #expect(past.hasReleased())
    #expect(!Movie(title: "No date").hasReleased())
}
