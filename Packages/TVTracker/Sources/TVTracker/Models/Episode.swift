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

    /// "S01E04". Padded by hand: `String(format:)` goes through Foundation's
    /// printf for every call, and the Up Next list and the Mac Overview's TV
    /// card build one for each episode in the backlog on every render — the
    /// largest cost left in the card once the sort was fixed.
    public var code: String {
        "S\(Self.twoDigits(seasonNumber))E\(Self.twoDigits(episodeNumber))"
    }

    /// `%02d`: a leading zero for 0–9, as-is otherwise (negatives included).
    static func twoDigits(_ number: Int) -> String {
        (0..<10).contains(number) ? "0\(number)" : String(number)
    }

    public func setWatched(_ watched: Bool, at date: Date = .now) {
        isWatched = watched
        watchedAt = watched ? date : nil
    }
}
