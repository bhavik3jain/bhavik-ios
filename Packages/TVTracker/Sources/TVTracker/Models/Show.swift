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

    public var orderedEpisodes: [Episode] {
        (episodes ?? []).sorted {
            ($0.seasonNumber, $0.episodeNumber) < ($1.seasonNumber, $1.episodeNumber)
        }
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
    public func unwatchedAired(asOf now: Date = .now) -> [Episode] {
        orderedEpisodes.filter { !$0.isWatched && $0.hasAired(asOf: now) }
    }

    /// The soonest episode still to air.
    public func nextToAir(asOf now: Date = .now) -> Episode? {
        orderedEpisodes
            .filter { !$0.hasAired(asOf: now) }
            .min { ($0.airDate ?? .distantFuture) < ($1.airDate ?? .distantFuture) }
    }
}
