import Foundation
import SwiftData

/// Which copies of a show's episodes to delete, worked out from plain values
/// — see `EpisodeFolder`.
///
/// Two devices that refresh a show before either's new episodes have synced
/// each add the same episode, and the library then showed it twice: two rows
/// in Up Next, two on the show screen, and a show that never completed
/// because one copy stayed unwatched. Copies are the same (season, episode
/// number); the one kept is the best by what every device can see alike —
/// watched first (earliest), then one with TMDB's id, a name, an air date.
///
/// Every device folds, often at the same moment, and nothing synced tells two
/// identical copies apart (SwiftData never shows CloudKit's record names), so
/// the rule has to be safe however each device breaks a tie:
/// - A copy worse than the best is deleted: every device ranks it the same,
///   so none deletes the one another keeps.
/// - Copies tied for best and unwatched: all but one go. Two devices may keep
///   different ones and between them delete both; nothing of the person's is
///   in an unwatched copy, and the show is marked due so the next refresh
///   adds it back from TMDB (`mayHaveDeletedEveryCopy`).
/// - Copies tied for best and watched: all stay. Deleting both would lose
///   that they were watched; the rare pair left is harmless next to that.
struct EpisodeDuplicates: Equatable {
    struct Copy: Equatable {
        let season: Int
        let number: Int
        let tmdbID: Int
        let name: String
        let airDate: Date?
        let isWatched: Bool
        let watchedAt: Date?
    }

    /// Into the `copies` the fold was built from.
    let deletions: [Int]
    /// Whether a deleted copy was tied with the one kept, so another device
    /// may have deleted that one: the show should be refreshed soon.
    let mayHaveDeletedEveryCopy: Bool

    init(_ copies: [Copy]) {
        var groups: [Key: [Int]] = [:]
        for (index, copy) in copies.enumerated() {
            groups[Key(copy.season, copy.number), default: []].append(index)
        }
        var deletions: [Int] = []
        var tiedDeletion = false
        for indices in groups.values where indices.count > 1 {
            let best = indices.map { Rank(copies[$0]) }.min()!
            let tied = indices.filter { Rank(copies[$0]) == best }
            deletions += indices.filter { Rank(copies[$0]) != best }
            if !copies[tied[0]].isWatched, tied.count > 1 {
                deletions += tied.dropFirst()
                tiedDeletion = true
            }
        }
        self.deletions = deletions.sorted()
        self.mayHaveDeletedEveryCopy = tiedDeletion
    }

    var isEmpty: Bool { deletions.isEmpty }

    private struct Key: Hashable {
        let season: Int
        let number: Int
        init(_ season: Int, _ number: Int) {
            self.season = season
            self.number = number
        }
    }

    /// Lower is better. Only synced values, so every device agrees.
    private struct Rank: Comparable {
        let unwatched: Int
        let watchedAt: Date
        let noTMDBID: Int
        let noName: Int
        let noAirDate: Int

        init(_ copy: Copy) {
            unwatched = copy.isWatched ? 0 : 1
            // Watched earlier is when it was first watched; one without a
            // date (an old import) loses to one with.
            watchedAt = copy.isWatched ? (copy.watchedAt ?? .distantFuture) : .distantFuture
            noTMDBID = copy.tmdbID > 0 ? 0 : 1
            noName = copy.name.isEmpty ? 1 : 0
            noAirDate = copy.airDate == nil ? 1 : 0
        }

        static func < (lhs: Rank, rhs: Rank) -> Bool {
            (lhs.unwatched, lhs.watchedAt, lhs.noTMDBID, lhs.noName, lhs.noAirDate)
                < (rhs.unwatched, rhs.watchedAt, rhs.noTMDBID, rhs.noName, rhs.noAirDate)
        }
    }
}

extension EpisodeDuplicates.Copy {
    /// Reads each property once — every one is a lookup in SwiftData's
    /// backing store (see `Schedule`).
    init(_ episode: Episode) {
        self.init(
            season: episode.seasonNumber,
            number: episode.episodeNumber,
            tmdbID: episode.tmdbID,
            name: episode.name,
            airDate: episode.airDate,
            isWatched: episode.isWatched,
            watchedAt: episode.watchedAt
        )
    }
}

/// Folds every show's duplicate episodes (`EpisodeDuplicates`), on a context
/// of its own off the main thread: it reads every episode in the library, and
/// reading them on the main thread was most of what the Mac's TV card cost
/// (see `Schedule`).
@ModelActor
actor EpisodeFolder {
    struct Outcome: Equatable, Sendable {
        var deleted = 0
        /// TMDB ids of shows to refresh soon (`TVRefreshLedger.markDue`).
        var dueAgain: [Int] = []
    }

    func fold() -> Outcome {
        var outcome = Outcome()
        guard let shows = try? modelContext.fetch(FetchDescriptor<Show>()) else { return outcome }
        for show in shows {
            let episodes = show.episodes ?? []
            guard episodes.count > 1 else { continue }
            let duplicates = EpisodeDuplicates(episodes.map(EpisodeDuplicates.Copy.init))
            guard !duplicates.isEmpty else { continue }
            for index in duplicates.deletions {
                modelContext.delete(episodes[index])
            }
            outcome.deleted += duplicates.deletions.count
            if duplicates.mayHaveDeletedEveryCopy, show.tmdbID > 0 {
                outcome.dueAgain.append(show.tmdbID)
            }
            // A copy left unwatched kept the show from completing. Only that
            // way round: re-deriving the status could turn one set to
            // Watching by hand back to "Haven't started".
            let remaining = (show.episodes ?? []).filter { !$0.isDeleted && $0.seasonNumber > 0 }
            if show.status == .watching, !remaining.isEmpty, remaining.allSatisfy(\.isWatched) {
                show.status = .completed
            }
        }
        if outcome.deleted > 0 { try? modelContext.save() }
        return outcome
    }
}
