import Foundation
import SwiftData

@Model
public final class Movie {
    public var tmdbID: Int = 0
    public var title: String = ""
    public var overview: String = ""
    public var posterPath: String = ""
    public var releaseDate: Date?
    /// Minutes. Zero when TMDB doesn't know the runtime yet.
    public var runtime: Int = 0
    public var isWatched: Bool = false
    public var watchedAt: Date?
    public var addedAt: Date = Date.now

    public init(
        tmdbID: Int = 0,
        title: String,
        overview: String = "",
        posterPath: String = "",
        releaseDate: Date? = nil,
        runtime: Int = 0
    ) {
        self.tmdbID = tmdbID
        self.title = title
        self.overview = overview
        self.posterPath = posterPath
        self.releaseDate = releaseDate
        self.runtime = runtime
        self.addedAt = .now
    }

    /// An unreleased film can't have been watched, so the UI offers it as
    /// upcoming rather than as something to tick off.
    public func hasReleased(asOf now: Date = .now) -> Bool {
        guard let releaseDate else { return false }
        return releaseDate <= now
    }

    public func setWatched(_ watched: Bool, at date: Date = .now) {
        isWatched = watched
        watchedAt = watched ? date : nil
    }

    public var formattedRuntime: String? {
        guard runtime > 0 else { return nil }
        let hours = runtime / 60
        let minutes = runtime % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}
