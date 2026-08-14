import Foundation
import SwiftData

@Model
public final class Episode {
    public var tmdbID: Int = 0
    public var name: String = ""
    public var seasonNumber: Int = 0
    public var episodeNumber: Int = 0
    public var airDate: Date?
    public var isWatched: Bool = false
    public var watchedAt: Date?

    public var show: Show?

    public init(
        tmdbID: Int = 0,
        name: String,
        seasonNumber: Int,
        episodeNumber: Int,
        airDate: Date? = nil
    ) {
        self.tmdbID = tmdbID
        self.name = name
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.airDate = airDate
    }

    /// An episode with no known air date is treated as unaired, so shows with
    /// incomplete metadata don't claim episodes are ready to watch.
    public func hasAired(asOf now: Date = .now) -> Bool {
        guard let airDate else { return false }
        return airDate <= now
    }

    public var code: String {
        "S\(String(format: "%02d", seasonNumber))E\(String(format: "%02d", episodeNumber))"
    }

    public func setWatched(_ watched: Bool, at date: Date = .now) {
        isWatched = watched
        watchedAt = watched ? date : nil
    }
}
