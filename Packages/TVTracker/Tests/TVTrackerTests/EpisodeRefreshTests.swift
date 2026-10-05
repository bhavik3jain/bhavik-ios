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

private let now = Date(timeIntervalSince1970: 1_791_216_000) // 2026-10-05 16:00 UTC
private func days(_ count: Double) -> Date { now.addingTimeInterval(count * 86_400) }

private func remote(_ season: Int, _ number: Int, id: Int = 0, name: String = "", airDate: Date? = nil) -> TMDBEpisode {
    TMDBEpisode(id: id, name: name, seasonNumber: season, episodeNumber: number, airDate: airDate)
}

private func local(_ season: Int, _ number: Int, id: Int = 0, name: String = "", airDate: Date? = nil) -> EpisodeMerge.Local {
    EpisodeMerge.Local(season: season, number: number, tmdbID: id, name: name, airDate: airDate)
}

/// A fresh, empty defaults domain, so the ledger starts from nothing.
private func scratchDefaults() -> UserDefaults {
    let name = "tv.refresh.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

// MARK: - The merge

@Test func aMergeUpdatesByNumberAndAddsWhatsNew() {
    let merge = EpisodeMerge(
        local: [local(1, 1, id: 11, name: "Pilot", airDate: days(-30)), local(1, 2, name: "TBA")],
        remote: [
            remote(1, 1, id: 11, name: "Pilot", airDate: days(-30)),
            remote(1, 2, id: 12, name: "The Real Title", airDate: days(3)),
            remote(1, 3, id: 13, name: "New One", airDate: days(10)),
        ]
    )
    #expect(merge.updates == [EpisodeMerge.Update(index: 1, name: "The Real Title", airDate: days(3), tmdbID: 12)],
            "Only what changed — the pilot is already right")
    #expect(merge.inserts.map(\.episodeNumber) == [3])
}

@Test func aMergeNeverBlanksWhatTMDBDoesntKnowYet() {
    let merge = EpisodeMerge(
        local: [local(2, 1, id: 21, name: "Typed by hand", airDate: days(5))],
        remote: [remote(2, 1, id: 21, name: "", airDate: nil)]
    )
    #expect(merge.isEmpty, "An empty name or a missing date from TMDB leaves the episode's own")
}

@Test func aMergeAddsAnEpisodeListedTwiceOnce() {
    let merge = EpisodeMerge(local: [], remote: [remote(1, 1, id: 1), remote(1, 1, id: 1)])
    #expect(merge.inserts.count == 1)
}

/// Two devices that each added the same new episode: both copies follow
/// TMDB, and no third is added.
@Test func aMergeKeepsCopiesInStepAndAddsNoThird() {
    let merge = EpisodeMerge(
        local: [local(3, 5, id: 35, name: "Old"), local(3, 5, id: 35, name: "Old")],
        remote: [remote(3, 5, id: 35, name: "New", airDate: days(1))]
    )
    #expect(merge.updates.map(\.index) == [0, 1])
    #expect(merge.inserts.isEmpty)
}

@Test func aRenumberedEpisodeIsNotAddedAgain() {
    let merge = EpisodeMerge(
        local: [local(1, 10, id: 110, name: "Finale")],
        remote: [remote(2, 1, id: 110, name: "Finale")]
    )
    #expect(merge.inserts.isEmpty, "TMDB moved it to S02E01; it's already here as S01E10")
    #expect(merge.updates.isEmpty)
}

@MainActor
@Test func applyingAMergeKeepsWatchedStateAndEveryLocalEpisode() throws {
    let context = try makeContext()
    let show = Show(tmdbID: 42, name: "Severance")
    show.status = .watching
    context.insert(show)
    let watched = Episode(tmdbID: 0, name: "Good News About Hell", seasonNumber: 1, episodeNumber: 1, airDate: days(-900))
    watched.show = show
    context.insert(watched)
    watched.setWatched(true, at: days(-800))
    let handMade = Episode(name: "Behind the scenes", seasonNumber: 9, episodeNumber: 1)
    handMade.show = show
    context.insert(handMade)
    try context.save()

    let episodes = show.episodes ?? []
    let merge = EpisodeMerge(
        local: episodes.map(EpisodeMerge.Local.init),
        remote: [
            remote(1, 1, id: 101, name: "Good News About Hell", airDate: days(-900)),
            remote(2, 5, id: 205, name: "Trojan's Horse", airDate: days(2)),
        ]
    )
    merge.apply(to: show, episodes: episodes, in: context)
    try context.save()

    #expect(show.episodeCount == 3, "One added, none removed — the hand-made one TMDB doesn't list stays")
    #expect(watched.tmdbID == 101)
    #expect(watched.isWatched, "A refresh never touches watched state")
    #expect(watched.watchedAt == days(-800))
    let added = try #require(show.orderedEpisodes.first { $0.seasonNumber == 2 })
    #expect(added.name == "Trojan's Horse")
    #expect(added.show === show)
    #expect(!added.isWatched)
}

// MARK: - Which seasons to fetch

private func seasons(_ list: [(Int, Int?)], ended: Bool) -> TMDBShowSeasons {
    TMDBShowSeasons(seasons: list.map { TMDBShowSeasons.Season(number: $0.0, episodeCount: $0.1) }, hasEnded: ended)
}

@Test func aLongFinishedShowFetchesNoSeasons() {
    let here = (1...3).map { local(1, $0, airDate: days(-400)) } + (1...3).map { local(2, $0, airDate: days(-300)) }
    #expect(EpisodeRefreshPlan.seasonsToFetch(remote: seasons([(0, 4), (1, 3), (2, 3)], ended: true), local: here, asOf: now).isEmpty)
}

@Test func theSeasonsThatCanHaveChangedAreFetched() {
    let here = (1...3).map { local(1, $0, airDate: days(-400)) }
        + (1...2).map { local(2, $0, airDate: days(-300)) }
        + [local(3, 1, airDate: days(-3)), local(3, 2, airDate: nil)]
    let fetched = EpisodeRefreshPlan.seasonsToFetch(
        remote: seasons([(0, 9), (1, 3), (2, 4), (3, 2), (4, nil)], ended: false),
        local: here,
        asOf: now
    )
    // 1: finished and complete. 2: TMDB counts four, two here. 3: aired
    // three days ago, and one with no date. 4: new, and the latest of a show
    // still running. 0: specials, never.
    #expect(fetched == [2, 3, 4])
}

@Test func theLatestSeasonOfARunningShowIsAlwaysFetched() {
    let here = (1...8).map { local(5, $0, airDate: days(-100)) }
    #expect(EpisodeRefreshPlan.seasonsToFetch(remote: seasons([(5, 8)], ended: false), local: here, asOf: now) == [5])
    #expect(EpisodeRefreshPlan.seasonsToFetch(remote: seasons([(5, 8)], ended: true), local: here, asOf: now).isEmpty)
}

@Test func showSeasonsDecodeWithTheirCountsAndStatus() throws {
    let json = Data("""
    {"name":"Severance","status":"Returning Series","seasons":[
      {"season_number":0,"episode_count":12},{"season_number":1,"episode_count":9},{"season_number":2}
    ]}
    """.utf8)
    let decoded = try TMDBClient.decodeShowSeasons(json)
    #expect(decoded == seasons([(0, 12), (1, 9), (2, nil)], ended: false))
    let ended = try TMDBClient.decodeShowSeasons(Data(#"{"status":"Canceled","seasons":[]}"#.utf8))
    #expect(ended.hasEnded)
}

// MARK: - The ledger

@Test func aShowIsDueTwelveHoursAfterItsLastRefresh() {
    let ledger = TVRefreshLedger(defaults: scratchDefaults())
    #expect(ledger.isDue(7, asOf: now), "Never refreshed")
    ledger.markRefreshed(7, at: now)
    #expect(!ledger.isDue(7, asOf: now.addingTimeInterval(11 * 3_600)))
    #expect(ledger.isDue(7, asOf: now.addingTimeInterval(12 * 3_600)))
    #expect(ledger.isDue(7, asOf: now.addingTimeInterval(-60)), "A clock set back doesn't hold it off")
    #expect(ledger.isDue(8, asOf: now), "Per show")
}

// MARK: - The refresher

/// TMDB as a dictionary: each show's seasons, each season's episodes.
private final class FakeSource: TVEpisodeSource, @unchecked Sendable {
    var shows: [Int: TMDBShowSeasons] = [:]
    var episodes: [Int: [Int: [TMDBEpisode]]] = [:]
    var failing: [Int: TMDBError] = [:]
    private(set) var requests: [String] = []

    func seasons(showID: Int) async throws -> TMDBShowSeasons {
        requests.append("\(showID)")
        if let error = failing[showID] { throw error }
        return shows[showID] ?? TMDBShowSeasons(seasons: [], hasEnded: false)
    }

    func episodes(showID: Int, season: Int) async throws -> [TMDBEpisode] {
        requests.append("\(showID)/\(season)")
        return episodes[showID]?[season] ?? []
    }
}

@MainActor
private func addShow(
    _ context: ModelContext,
    _ name: String,
    tmdbID: Int,
    status: ShowStatus,
    episodes: [(season: Int, number: Int, watched: Bool)] = []
) -> Show {
    let show = Show(tmdbID: tmdbID, name: name)
    show.status = status
    context.insert(show)
    for spec in episodes {
        let episode = Episode(name: "", seasonNumber: spec.season, episodeNumber: spec.number, airDate: days(-500))
        episode.show = show
        context.insert(episode)
        if spec.watched { episode.setWatched(true, at: days(-400)) }
    }
    return show
}

@MainActor
@Test func onlyShowsWorthARefreshAreRefreshedWatchingFirst() async throws {
    let context = try makeContext()
    _ = addShow(context, "Completed", tmdbID: 3, status: .completed)
    _ = addShow(context, "Not Started", tmdbID: 2, status: .notStarted)
    _ = addShow(context, "Watching", tmdbID: 1, status: .watching)
    _ = addShow(context, "Dropped", tmdbID: 4, status: .dropped)
    _ = addShow(context, "By Hand", tmdbID: 0, status: .watching)
    try context.save()

    let source = FakeSource()
    let ledger = TVRefreshLedger(defaults: scratchDefaults())
    let refresher = TVEpisodeRefresher(source: source, ledger: ledger)
    let summary = await refresher.refresh(context: context, asOf: now)
    #expect(source.requests == ["1", "2", "3"], "Watching, not started, completed; never dropped or one with no TMDB id")
    #expect(summary.refreshedShows == 3)

    let again = await refresher.refresh(context: context, asOf: now.addingTimeInterval(3_600))
    #expect(again.refreshedShows == 0, "Nothing is due an hour later")
    #expect(source.requests.count == 3)

    let forced = await refresher.refresh(context: context, asOf: now.addingTimeInterval(3_600), force: true)
    #expect(forced.refreshedShows == 3, "The probe's forced run ignores the ledger")
}

@MainActor
@Test func aNewSeasonBringsAFinishedShowBackToWatching() async throws {
    let context = try makeContext()
    let finished = addShow(context, "The Bear", tmdbID: 136315, status: .completed, episodes: [(1, 1, true), (1, 2, true)])
    // Set to Watching by hand, nothing ticked off yet: a refresh mustn't
    // re-derive it to "Haven't started" and silence its alerts.
    let eager = addShow(context, "Severance", tmdbID: 95396, status: .watching, episodes: [(1, 1, false)])
    try context.save()

    let source = FakeSource()
    source.shows[136315] = seasons([(1, 2), (2, 1)], ended: false)
    source.episodes[136315] = [2: [remote(2, 1, id: 2001, name: "Beef", airDate: days(5))]]
    source.shows[95396] = seasons([(1, 1), (2, 1)], ended: false)
    source.episodes[95396] = [2: [remote(2, 1, id: 3001, name: "Hello, Ms. Cobel", airDate: days(2))]]

    let summary = await TVEpisodeRefresher(source: source, ledger: TVRefreshLedger(defaults: scratchDefaults()))
        .refresh(context: context, asOf: now)
    #expect(summary.insertedEpisodes == 2)
    #expect(source.requests.contains("136315/2"))
    #expect(!source.requests.contains("136315/1"), "Season 1 is long finished and complete")
    #expect(finished.status == .watching)
    #expect(finished.episodeCount == 3)
    #expect(eager.status == .watching)
}

@MainActor
@Test func aRefreshStopsWhenTMDBRefusesAndAfterRepeatedFailures() async throws {
    let context = try makeContext()
    for id in 1...4 { _ = addShow(context, "Show \(id)", tmdbID: id, status: .watching) }
    try context.save()

    let refused = FakeSource()
    refused.failing[1] = .unauthorized
    let first = await TVEpisodeRefresher(source: refused, ledger: TVRefreshLedger(defaults: scratchDefaults()))
        .refresh(context: context, asOf: now)
    #expect(first.stoppedEarly)
    #expect(refused.requests == ["1"], "A key TMDB refuses is refused for every show")

    let flaky = FakeSource()
    flaky.failing[1] = .network("404")
    let ledger = TVRefreshLedger(defaults: scratchDefaults())
    let second = await TVEpisodeRefresher(source: flaky, ledger: ledger).refresh(context: context, asOf: now)
    #expect(!second.stoppedEarly, "One show failing doesn't stop the others")
    #expect(second.failures == ["Show 1"])
    #expect(second.refreshedShows == 3)
    #expect(ledger.isDue(1, asOf: now), "A failed show is tried again next run")

    let offline = FakeSource()
    for id in 1...4 { offline.failing[id] = .network("offline") }
    let third = await TVEpisodeRefresher(source: offline, ledger: TVRefreshLedger(defaults: scratchDefaults()))
        .refresh(context: context, asOf: now)
    #expect(third.stoppedEarly)
    #expect(offline.requests.count == TVEpisodeRefresher.failureLimit)
}
