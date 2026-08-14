import Foundation
import SwiftData
import Testing
@testable import TVTracker

@MainActor
private func makeContext() throws -> ModelContext {
    let schema = Schema(TVTrackerModule.models)
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return ModelContext(container)
}

private let now = Date(timeIntervalSince1970: 1_750_000_000)
private func daysFromNow(_ days: Int) -> Date {
    now.addingTimeInterval(Double(days) * 86_400)
}

@MainActor
private func makeShow(
    in context: ModelContext,
    name: String,
    status: ShowStatus = .watching,
    episodes: [(season: Int, number: Int, airOffsetDays: Int?)]
) -> Show {
    let show = Show(name: name)
    show.status = status
    context.insert(show)
    for spec in episodes {
        let episode = Episode(
            name: "",
            seasonNumber: spec.season,
            episodeNumber: spec.number,
            airDate: spec.airOffsetDays.map(daysFromNow)
        )
        episode.show = show
        context.insert(episode)
    }
    return show
}

// MARK: - Episode state

@Test func episodeWithoutAnAirDateCountsAsUnaired() {
    let episode = Episode(name: "TBA", seasonNumber: 1, episodeNumber: 1, airDate: nil)
    #expect(!episode.hasAired(asOf: now))
}

@Test func episodeCodeIsZeroPadded() {
    #expect(Episode(name: "", seasonNumber: 1, episodeNumber: 4).code == "S01E04")
    #expect(Episode(name: "", seasonNumber: 12, episodeNumber: 10).code == "S12E10")
}

@Test func markingWatchedRecordsAndClearsTheTimestamp() {
    let episode = Episode(name: "", seasonNumber: 1, episodeNumber: 1)
    episode.setWatched(true, at: now)
    #expect(episode.isWatched)
    #expect(episode.watchedAt == now)

    episode.setWatched(false)
    #expect(!episode.isWatched)
    #expect(episode.watchedAt == nil, "Unwatching must clear the timestamp, not leave a stale one")
}

// MARK: - Progress

@MainActor
@Test func progressCountsWatchedEpisodes() throws {
    let context = try makeContext()
    let show = makeShow(in: context, name: "Severance", episodes: [
        (1, 1, -30), (1, 2, -23), (1, 3, -16), (1, 4, -9)
    ])
    try context.save()

    #expect(show.progress == 0)
    show.orderedEpisodes[0].setWatched(true)
    show.orderedEpisodes[1].setWatched(true)
    #expect(show.progress == 0.5)
    #expect(show.watchedCount == 2)
}

@MainActor
@Test func nextUnwatchedFollowsSeasonThenEpisodeOrder() throws {
    let context = try makeContext()
    let show = makeShow(in: context, name: "The Bear", episodes: [
        (2, 1, -20), (1, 1, -60), (1, 2, -50)
    ])
    try context.save()

    #expect(show.nextUnwatched?.code == "S01E01")
    show.orderedEpisodes[0].setWatched(true)
    #expect(show.nextUnwatched?.code == "S01E02")
}

// MARK: - Schedule

@MainActor
@Test func readyToWatchListsAiredUnwatchedEpisodesOldestFirst() throws {
    let context = try makeContext()
    _ = makeShow(in: context, name: "Show A", episodes: [(1, 1, -10), (1, 2, -3), (1, 3, 7)])
    _ = makeShow(in: context, name: "Show B", episodes: [(1, 1, -5)])
    try context.save()

    let shows = try context.fetch(FetchDescriptor<Show>())
    let ready = Schedule.readyToWatch(shows: shows, asOf: now)

    #expect(ready.count == 3, "The episode airing in a week is not ready yet")
    #expect(ready.map(\.code) == ["S01E01", "S01E01", "S01E02"])
    #expect(ready.first?.showName == "Show A")
}

@MainActor
@Test func upcomingReturnsOneNextEpisodePerShowSoonestFirst() throws {
    let context = try makeContext()
    _ = makeShow(in: context, name: "Later", episodes: [(1, 1, 20), (1, 2, 27)])
    _ = makeShow(in: context, name: "Sooner", episodes: [(1, 1, 3)])
    try context.save()

    let shows = try context.fetch(FetchDescriptor<Show>())
    let upcoming = Schedule.upcoming(shows: shows, asOf: now)

    #expect(upcoming.map(\.showName) == ["Sooner", "Later"])
    #expect(upcoming.count == 2, "Only the next episode of each show is listed")
}

@MainActor
@Test func completedAndDroppedShowsStayOutOfTheSchedule() throws {
    let context = try makeContext()
    _ = makeShow(in: context, name: "Done", status: .completed, episodes: [(1, 1, -10), (1, 2, 5)])
    _ = makeShow(in: context, name: "Abandoned", status: .dropped, episodes: [(1, 1, -10)])
    _ = makeShow(in: context, name: "Active", episodes: [(1, 1, -10)])
    try context.save()

    let shows = try context.fetch(FetchDescriptor<Show>())
    #expect(Schedule.readyToWatch(shows: shows, asOf: now).map(\.showName) == ["Active"])
    #expect(Schedule.upcoming(shows: shows, asOf: now).isEmpty)
}

@MainActor
@Test func watchedEpisodesLeaveTheReadyList() throws {
    let context = try makeContext()
    let show = makeShow(in: context, name: "Show", episodes: [(1, 1, -10), (1, 2, -3)])
    try context.save()

    show.orderedEpisodes[0].setWatched(true)
    let shows = try context.fetch(FetchDescriptor<Show>())
    #expect(Schedule.readyToWatch(shows: shows, asOf: now).map(\.code) == ["S01E02"])
}

// MARK: - TMDB decoding

@Test func tmdbTreatsEmptyAirDatesAsUnknown() {
    #expect(TMDBDate.parse("") == nil, "TMDB sends an empty string rather than null for unknown dates")
    #expect(TMDBDate.parse(nil) == nil)
    #expect(TMDBDate.parse("2026-02-14") != nil)
}

@Test func searchWithoutAnAPIKeyFailsBeforeHittingTheNetwork() async {
    await #expect(throws: TMDBError.self) {
        try await TMDBClient(apiKey: "").searchShows(query: "Severance")
    }
}

@Test func blankQueriesDoNotHitTheNetwork() async throws {
    let results = try await TMDBClient(apiKey: "placeholder").searchShows(query: "   ")
    #expect(results.isEmpty)
}
