import Foundation

/// A show or film as a watch list sees it — a search result about to be
/// added, a title someone typed, or an item already on a list — as plain
/// values, so matching, folding and "Add to My Library" are testable without
/// a store.
public struct WatchListTitle: Equatable, Hashable, Sendable, Identifiable {
    public var mediaType: WatchListMediaType
    /// Zero for a typed title.
    public var tmdbID: Int
    public var title: String
    public var posterPath: String
    public var overview: String
    public var year: Int?

    public init(
        mediaType: WatchListMediaType,
        tmdbID: Int = 0,
        title: String,
        posterPath: String = "",
        overview: String = "",
        year: Int? = nil
    ) {
        self.mediaType = mediaType
        self.tmdbID = tmdbID
        self.title = title
        self.posterPath = posterPath
        self.overview = overview
        self.year = year
    }

    public init(show: TMDBShowSummary) {
        self.init(
            mediaType: .show,
            tmdbID: show.id,
            title: show.name,
            posterPath: show.posterPath,
            overview: show.overview,
            year: Self.year(of: show.firstAirDate)
        )
    }

    public init(movie: TMDBMovieSummary) {
        self.init(
            mediaType: .movie,
            tmdbID: movie.id,
            title: movie.title,
            posterPath: movie.posterPath,
            overview: movie.overview,
            year: Self.year(of: movie.releaseDate)
        )
    }

    /// Search results of one kind share TMDB ids with the other — show 1399
    /// and film 1399 are different titles — so the kind is part of the id.
    public var id: String {
        tmdbID > 0 ? "\(mediaType.rawValue):\(tmdbID)" : "\(mediaType.rawValue):title:\(normalizedTitle)"
    }

    public var isFromTMDB: Bool { tmdbID > 0 }

    /// The title as two people might type it differently: case, accents,
    /// width and runs of spaces don't count.
    public var normalizedTitle: String { Self.normalize(title) }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// TMDB's dates are midnight UTC (`TMDBDate`), so the year is read in UTC
    /// too — in a zone west of it, 2024-01-01 would otherwise read as 2023.
    static func year(of date: Date?) -> Int? {
        guard let date else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.component(.year, from: date)
    }
}

/// An item on a list as plain values: what folding duplicates reads and
/// writes back.
public struct WatchListEntry: Equatable, Sendable {
    public var title: WatchListTitle
    public var addedAt: Date
    public var addedByName: String
    public var note: String
    public var watchedAt: Date?
    public var sortIndex: Double

    public init(
        title: WatchListTitle,
        addedAt: Date,
        addedByName: String = "",
        note: String = "",
        watchedAt: Date? = nil,
        sortIndex: Double = 0
    ) {
        self.title = title
        self.addedAt = addedAt
        self.addedByName = addedByName
        self.note = note
        self.watchedAt = watchedAt
        self.sortIndex = sortIndex
    }
}
