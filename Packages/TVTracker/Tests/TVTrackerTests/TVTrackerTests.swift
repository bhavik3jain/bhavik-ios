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
    #expect(Episode(name: "", seasonNumber: 0, episodeNumber: 123).code == "S00E123", "Specials and long runs")
    for number in [-3, 0, 5, 9, 10, 99, 100] {
        #expect(Episode.twoDigits(number) == String(format: "%02d", number))
    }
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

@MainActor
@Test func readyCountAgreesWithTheReadyList() throws {
    let context = try makeContext()
    let watching = makeShow(in: context, name: "Watching", episodes: [(1, 1, -10), (1, 2, -3), (1, 3, 7), (2, 1, nil)])
    _ = makeShow(in: context, name: "Other", episodes: [(1, 1, -5)])
    _ = makeShow(in: context, name: "Done", status: .completed, episodes: [(1, 1, -10)])
    _ = makeShow(in: context, name: "Abandoned", status: .dropped, episodes: [(1, 1, -10)])
    try context.save()
    watching.orderedEpisodes[0].setWatched(true)

    let shows = try context.fetch(FetchDescriptor<Show>())
    #expect(Schedule.readyCount(shows: shows, asOf: now) == 2)
    #expect(Schedule.readyCount(shows: shows, asOf: now) == Schedule.readyToWatch(shows: shows, asOf: now).count)
    #expect(watching.unwatchedAiredCount(asOf: now) == watching.unwatchedAired(asOf: now).count)
}

@MainActor
@Test func backlogAgreesWithTheReadyList() throws {
    let context = try makeContext()
    let watching = makeShow(in: context, name: "Watching", episodes: [(1, 1, -10), (1, 2, -3), (1, 3, 7), (2, 1, nil)])
    _ = makeShow(in: context, name: "Older", episodes: [(1, 1, -20), (1, 2, -1)])
    _ = makeShow(in: context, name: "Caught up", episodes: [(1, 1, 3)])
    _ = makeShow(in: context, name: "Done", status: .completed, episodes: [(1, 1, -30)])
    try context.save()
    watching.orderedEpisodes[0].setWatched(true)

    let shows = try context.fetch(FetchDescriptor<Show>())
    let backlog = Schedule.backlog(shows: shows, asOf: now)
    let ready = Schedule.readyToWatch(shows: shows, asOf: now)
    #expect(backlog.episodeCount == ready.count)
    #expect(backlog.episodeCount == 3)
    // The ready list's shows in the order they first appear in it: one
    // poster per show, the one waiting longest first.
    var seen = Set<String>()
    #expect(backlog.shows.map(\.showName) == ready.map(\.showName).filter { seen.insert($0).inserted })
    #expect(backlog.shows.map(\.showName) == ["Older", "Watching"])
    #expect(backlog.shows.map(\.episodeCount) == [2, 1])
}

@MainActor
@Test func everyEpisodeInOneFetchGivesWhatTheShowsDo() throws {
    let context = try makeContext()
    let watching = makeShow(in: context, name: "Watching", episodes: [(1, 1, -10), (1, 2, -3), (1, 3, 7), (1, 4, 7), (2, 1, nil)])
    _ = makeShow(in: context, name: "Older", episodes: [(1, 1, -20), (1, 2, -1), (1, 3, 2)])
    _ = makeShow(in: context, name: "Done", status: .completed, episodes: [(1, 1, -30), (1, 2, 1)])
    _ = makeShow(in: context, name: "Unstarted", status: .notStarted, episodes: [(1, 1, -30)])
    try context.save()
    watching.orderedEpisodes[0].setWatched(true)

    // What HomeView's `@Query(filter: Schedule.unwatched)` hands over: the
    // unwatched episodes of every show, in no particular order.
    let shows = try context.fetch(FetchDescriptor<Show>())
    let episodes = try context.fetch(FetchDescriptor<Episode>(predicate: Schedule.unwatched))
    #expect(episodes.count == 10, "The watched one is left out")

    #expect(Schedule.readyCount(episodes: episodes, asOf: now) == Schedule.readyCount(shows: shows, asOf: now))
    #expect(Schedule.readyToWatch(episodes: episodes, asOf: now).map(\.id) == Schedule.readyToWatch(shows: shows, asOf: now).map(\.id))
    #expect(Schedule.backlog(episodes: episodes, asOf: now) == Schedule.backlog(shows: shows, asOf: now))
    #expect(Schedule.upcoming(episodes: episodes, asOf: now).map(\.id) == Schedule.upcoming(shows: shows, asOf: now).map(\.id))

    #expect(Schedule.readyToWatch(episodes: episodes, asOf: now).map(\.code) == ["S01E01", "S01E02", "S01E02"])
    #expect(Schedule.upcoming(episodes: episodes, asOf: now).map(\.showName) == ["Older", "Watching"])
    #expect(Schedule.upcoming(episodes: episodes, asOf: now).last?.code == "S01E03", "A double bill offers the first of the two")
}

@MainActor
@Test func theGlanceAgreesWithTheListsItReplaces() throws {
    let context = try makeContext()
    let watching = makeShow(in: context, name: "Watching", episodes: [(1, 1, -10), (1, 2, -3), (1, 3, 7), (1, 4, 7), (2, 1, nil)])
    _ = makeShow(in: context, name: "Older", episodes: [(1, 1, -20), (1, 2, -1), (1, 3, 2)])
    _ = makeShow(in: context, name: "Undated", episodes: [(1, 2, nil), (1, 1, nil)])
    _ = makeShow(in: context, name: "Done", status: .completed, episodes: [(1, 1, -30), (1, 2, 1)])
    try context.save()
    watching.orderedEpisodes[0].setWatched(true)
    try context.save()

    let episodes = try context.fetch(FetchDescriptor<Episode>(predicate: Schedule.unwatched))
    let glance = Schedule.glance(episodes: episodes, asOf: now)
    let ready = Schedule.readyToWatch(episodes: episodes, asOf: now)

    #expect(glance.backlog.episodeCount == ready.count)
    #expect(glance.backlog.episodeCount == Schedule.readyCount(episodes: episodes, asOf: now))
    #expect(glance.backlog.shows.map(\.showName) == ["Older", "Watching"])
    #expect(glance.backlog.shows.map(\.episodeCount) == [2, 1])
    // Per show, what `nextToAir` picks from that show's unwatched episodes.
    #expect(glance.upcoming.map(\.showName) == ["Older", "Watching", "Undated"])
    #expect(glance.upcoming.map(\.code) == ["S01E03", "S01E03", "S01E01"])
}

@MainActor
@Test func anEpisodeWatchedBeforeItAiredIsntComingUp() throws {
    let context = try makeContext()
    let show = makeShow(in: context, name: "Show", episodes: [(1, 1, -7), (1, 2, 7), (1, 3, 14)])
    try context.save()
    show.orderedEpisodes[1].setWatched(true)
    try context.save()

    let episodes = try context.fetch(FetchDescriptor<Episode>(predicate: Schedule.unwatched))
    #expect(Schedule.upcoming(episodes: episodes, asOf: now).map(\.code) == ["S01E03"])
    #expect(Schedule.upcoming(shows: [show], asOf: now).map(\.code) == ["S01E03"])
}

@MainActor
@Test func anEmptyBacklogIsEmpty() throws {
    let context = try makeContext()
    _ = makeShow(in: context, name: "Future", episodes: [(1, 1, 5), (1, 2, nil)])
    try context.save()

    let backlog = Schedule.backlog(shows: try context.fetch(FetchDescriptor<Show>()), asOf: now)
    #expect(backlog.isEmpty)
    #expect(backlog.shows.isEmpty)
}

@MainActor
@Test func nextToAirSkipsAiredAndPutsUndatedLast() throws {
    let context = try makeContext()
    let show = makeShow(in: context, name: "Show", episodes: [(2, 1, nil), (1, 9, -1), (1, 10, 14), (1, 11, 21)])
    try context.save()
    #expect(show.nextToAir(asOf: now)?.code == "S01E10")

    let undated = makeShow(in: context, name: "Undated", episodes: [(3, 2, nil), (3, 1, nil), (2, 9, -3)])
    try context.save()
    #expect(undated.nextToAir(asOf: now)?.code == "S03E01", "With no dates at all, the earliest in running order")
}

@MainActor
@Test func unwatchedAiredKeepsRunningOrderAcrossSeasons() throws {
    let context = try makeContext()
    let show = makeShow(in: context, name: "Show", episodes: [(2, 2, -1), (1, 10, -40), (2, 1, -2), (1, 9, -41)])
    try context.save()

    #expect(show.unwatchedAired(asOf: now).map(\.code) == ["S01E09", "S01E10", "S02E01", "S02E02"])
    #expect(show.orderedEpisodes.map(\.code) == ["S01E09", "S01E10", "S02E01", "S02E02"])
}

@MainActor
@Test func nextToAirBreaksADateTieByRunningOrder() throws {
    let context = try makeContext()
    // A double bill: two episodes on the same night, inserted out of order.
    let show = makeShow(in: context, name: "Show", episodes: [(1, 3, 7), (1, 2, 7), (1, 1, -7)])
    try context.save()

    #expect(show.nextToAir(asOf: now)?.code == "S01E02")
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

// MARK: - Show status

@MainActor
@Test func aShowWithNothingWatchedHasNotBeenStarted() throws {
    // The export tracks plenty of shows that were never begun. Filing those
    // under "Watching" at 0% buries the ones actually in progress.
    let context = try makeContext()
    let show = makeShow(in: context, name: "Queued", episodes: [(1, 1, -10), (1, 2, -3)])

    show.refreshStatus()
    #expect(show.status == .notStarted)
}

@MainActor
@Test func watchingOneEpisodeStartsTheShow() throws {
    let context = try makeContext()
    let show = makeShow(in: context, name: "Begun", status: .notStarted, episodes: [(1, 1, -10), (1, 2, -3)])

    show.orderedEpisodes.first?.setWatched(true)
    show.refreshStatus()
    #expect(show.status == .watching)
}

@MainActor
@Test func watchingEveryEpisodeCompletesTheShow() throws {
    let context = try makeContext()
    let show = makeShow(in: context, name: "Finished", episodes: [(1, 1, -10), (1, 2, -3)])

    for episode in show.orderedEpisodes { episode.setWatched(true) }
    show.refreshStatus()
    #expect(show.status == .completed)
}

@MainActor
@Test func unwatchingEverythingReturnsTheShowToNotStarted() throws {
    let context = try makeContext()
    let show = makeShow(in: context, name: "Reset", episodes: [(1, 1, -10), (1, 2, -3)])
    for episode in show.orderedEpisodes { episode.setWatched(true) }
    show.refreshStatus()

    for episode in show.orderedEpisodes { episode.setWatched(false) }
    show.refreshStatus()
    #expect(show.status == .notStarted)
}

@MainActor
@Test func specialsDontStandBetweenAShowAndCompletion() throws {
    // Season 0 is trailers and recaps as often as it is real specials, so
    // requiring them would put completion permanently out of reach.
    let context = try makeContext()
    let show = makeShow(in: context, name: "Bonus", episodes: [(0, 1, -20), (1, 1, -10), (1, 2, -3)])

    for episode in show.orderedEpisodes where episode.seasonNumber > 0 {
        episode.setWatched(true)
    }
    show.refreshStatus()
    #expect(show.status == .completed)
}

@MainActor
@Test func droppingAShowSurvivesWatchingMore() throws {
    // Dropped is a decision, not something to infer from episode counts.
    let context = try makeContext()
    let show = makeShow(in: context, name: "Abandoned", status: .dropped, episodes: [(1, 1, -10), (1, 2, -3)])

    show.orderedEpisodes.first?.setWatched(true)
    show.refreshStatus()
    #expect(show.status == .dropped)
}

@MainActor
@Test func unstartedShowsStayOutOfUpNext() throws {
    // Up Next is what to watch next in what you're watching. Thirty shows you
    // never began would drown it.
    let context = try makeContext()
    _ = makeShow(in: context, name: "Active", status: .watching, episodes: [(1, 1, -10)])
    _ = makeShow(in: context, name: "Queued", status: .notStarted, episodes: [(1, 1, -20)])

    let shows = try context.fetch(FetchDescriptor<Show>())
    let upNext = Schedule.readyToWatch(shows: shows, asOf: now)

    #expect(!upNext.isEmpty)
    #expect(upNext.allSatisfy { $0.showName == "Active" })
}
