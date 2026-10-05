import Foundation
import SwiftData
import Testing
@testable import TVTracker

// Two devices refreshing a show before either's new episodes synced each
// added the same one. The fold must be safe with every device folding at once
// and nothing synced to tell identical copies apart.

private let t0 = Date(timeIntervalSince1970: 1_791_216_000)

private func copy(
    _ season: Int = 2,
    _ number: Int = 5,
    tmdbID: Int = 77,
    name: String = "Trojan's Horse",
    airDate: Date? = t0,
    watchedAt: Date? = nil
) -> EpisodeDuplicates.Copy {
    EpisodeDuplicates.Copy(
        season: season, number: number, tmdbID: tmdbID, name: name,
        airDate: airDate, isWatched: watchedAt != nil, watchedAt: watchedAt
    )
}

@Test func anUnwatchedCopyGoesWhenAnotherIsWatched() {
    let fold = EpisodeDuplicates([copy(), copy(watchedAt: t0)])
    #expect(fold.deletions == [0])
    // Every device ranks them the same, so none deletes the one kept.
    #expect(!fold.mayHaveDeletedEveryCopy)
}

@Test func theEarliestWatchedCopyIsKept() {
    let fold = EpisodeDuplicates([copy(watchedAt: t0 + 60), copy(watchedAt: t0)])
    #expect(fold.deletions == [0])
}

@Test func aCopyMissingWhatTMDBKnowsLoses() {
    #expect(EpisodeDuplicates([copy(tmdbID: 0), copy()]).deletions == [0])
    #expect(EpisodeDuplicates([copy(), copy(name: "")]).deletions == [1])
    #expect(EpisodeDuplicates([copy(airDate: nil), copy()]).deletions == [0])
}

@Test func identicalUnwatchedCopiesKeepOneAndAskForARefresh() {
    // Two devices may keep different ones and delete both between them;
    // nothing of the person's is lost, and the refresh adds it back.
    let fold = EpisodeDuplicates([copy(), copy(), copy()])
    #expect(fold.deletions == [1, 2])
    #expect(fold.mayHaveDeletedEveryCopy)
}

@Test func identicalWatchedCopiesAllStay() {
    // Deleting both on two devices would lose that it was watched.
    #expect(EpisodeDuplicates([copy(watchedAt: t0), copy(watchedAt: t0)]).isEmpty)
}

@Test func differentEpisodesAreNeverCopies() {
    #expect(EpisodeDuplicates([copy(2, 5), copy(2, 6), copy(3, 5)]).isEmpty)
}

// MARK: - In the library

@MainActor
private func makeContainer() throws -> ModelContainer {
    let schema = Schema(TVTrackerModule.models)
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [configuration])
}

@MainActor
private func episode(_ number: Int, of show: Show, in context: ModelContext, watched: Bool = false) -> Episode {
    let episode = Episode(tmdbID: 100 + number, name: "Episode \(number)", seasonNumber: 1, episodeNumber: number, airDate: t0)
    episode.show = show
    context.insert(episode)
    if watched { episode.setWatched(true, at: t0) }
    return episode
}

@MainActor
@Test func theFolderLeavesOneOfEachAndCompletesAShowItHeldBack() async throws {
    let container = try makeContainer()
    let context = ModelContext(container)
    let show = Show(tmdbID: 9, name: "Severance")
    context.insert(show)
    show.status = .watching
    _ = episode(1, of: show, in: context, watched: true)
    _ = episode(2, of: show, in: context, watched: true)
    // The other device's copy of episode 2, still unwatched: the one thing
    // keeping the show from completing.
    _ = episode(2, of: show, in: context)
    try context.save()

    let outcome = await EpisodeFolder(modelContainer: container).fold()
    #expect(outcome.deleted == 1)
    #expect(outcome.dueAgain.isEmpty)

    let fresh = ModelContext(container)
    let episodes = try fresh.fetch(FetchDescriptor<Episode>())
    #expect(episodes.count == 2)
    let allWatched = episodes.allSatisfy { $0.isWatched }
    #expect(allWatched)
    let status = try fresh.fetch(FetchDescriptor<Show>()).first?.status
    #expect(status == .completed)
}

@MainActor
@Test func theFolderAsksForARefreshAfterATiedDeletion() async throws {
    let container = try makeContainer()
    let context = ModelContext(container)
    let show = Show(tmdbID: 9, name: "Severance")
    context.insert(show)
    _ = episode(3, of: show, in: context)
    _ = episode(3, of: show, in: context)
    try context.save()

    let outcome = await EpisodeFolder(modelContainer: container).fold()
    #expect(outcome.deleted == 1)
    #expect(outcome.dueAgain == [9])
}

@MainActor
@Test func tickingAnEpisodeTicksEveryCopyOfIt() throws {
    let context = ModelContext(try makeContainer())
    let show = Show(tmdbID: 9, name: "Severance")
    context.insert(show)
    let first = episode(4, of: show, in: context)
    let second = episode(4, of: show, in: context)
    let other = episode(5, of: show, in: context)

    first.toggleWatched(at: t0)
    #expect(first.isWatched && second.isWatched)
    #expect(!other.isWatched)

    second.toggleWatched()
    #expect(!first.isWatched && !second.isWatched)
}

@Test func aShowMarkedDueIsRefreshedWhateverItsStamp() {
    let defaults = UserDefaults(suiteName: "EpisodeFoldTests.\(UUID().uuidString)")!
    let ledger = TVRefreshLedger(defaults: defaults)
    ledger.markRefreshed(9, at: t0)
    #expect(!ledger.isDue(9, asOf: t0 + 60))
    ledger.markDue(9)
    #expect(ledger.isDue(9, asOf: t0 + 60))
}
