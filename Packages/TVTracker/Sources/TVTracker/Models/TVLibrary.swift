import Foundation
import SwiftData

/// The one way a show or film enters this person's own library. Add Show,
/// Add Movie and a watch list's "Add to My Library" all come through here, so
/// a title picked off a list arrives exactly as one searched for would — with
/// its episodes, or a film's runtime — rather than as a third copy of the
/// insert code that drifts from the other two.
///
/// The library is SwiftData and never shared: a title copied in from a list
/// someone shared is this person's from then on, and nothing links it back.
public enum TVLibrary {
    /// What a show added to the library looks like before its episodes.
    /// A title with no name — a typed one left blank — is "New Show", as
    /// Add Show's by-hand button always named it.
    static func makeShow(_ title: WatchListTitle) -> Show {
        Show(
            tmdbID: title.tmdbID,
            name: named(title.title, fallback: "New Show"),
            overview: title.overview,
            posterPath: title.posterPath
        )
    }

    /// A film as the library stores it. `detail` is TMDB's own record when
    /// it could be read — it carries the runtime, which search results and
    /// watch lists don't — and wins over what the list or search said.
    static func makeMovie(_ title: WatchListTitle, releaseDate: Date? = nil, detail: TMDBMovieSummary? = nil) -> Movie {
        guard let detail else {
            return Movie(
                tmdbID: title.tmdbID,
                title: named(title.title, fallback: "New Movie"),
                overview: title.overview,
                posterPath: title.posterPath,
                releaseDate: releaseDate
            )
        }
        return Movie(
            tmdbID: detail.id,
            title: named(detail.title, fallback: named(title.title, fallback: "New Movie")),
            overview: detail.overview.isEmpty ? title.overview : detail.overview,
            posterPath: detail.posterPath.isEmpty ? title.posterPath : detail.posterPath,
            releaseDate: detail.releaseDate ?? releaseDate,
            runtime: detail.runtime
        )
    }

    /// Inserts `title` as a show with no episodes — Add Show's by-hand path,
    /// and the first half of `addShow`.
    @MainActor
    @discardableResult
    static func insertShow(_ title: WatchListTitle, into context: ModelContext) -> Show {
        let show = makeShow(title)
        context.insert(show)
        return show
    }

    /// Adds a show and, when it's a TMDB one and there's a key to ask with,
    /// its episodes. The show is kept even when they can't be loaded, so the
    /// add isn't lost; the error comes back for the caller to show.
    @MainActor
    static func addShow(_ title: WatchListTitle, apiKey: String, to context: ModelContext) async -> (show: Show, episodesError: (any Error)?) {
        let show = insertShow(title, into: context)
        guard title.isFromTMDB, !apiKey.isEmpty else { return (show, nil) }
        do {
            let episodes = try await TMDBClient(apiKey: apiKey).allEpisodes(showID: title.tmdbID)
            for payload in episodes {
                let episode = Episode(
                    tmdbID: payload.id,
                    name: payload.name,
                    seasonNumber: payload.seasonNumber,
                    episodeNumber: payload.episodeNumber,
                    airDate: payload.airDate
                )
                episode.show = show
                context.insert(episode)
            }
            return (show, nil)
        } catch {
            return (show, error)
        }
    }

    /// Adds a film, re-reading it from TMDB first for the runtime when it's a
    /// TMDB one and there's a key. A failed read isn't worth losing the film
    /// over: it goes in with what's known. `releaseDate` is a search result's,
    /// for when that read fails — a watch list only keeps the year.
    @MainActor
    @discardableResult
    static func addMovie(_ title: WatchListTitle, releaseDate: Date? = nil, apiKey: String, to context: ModelContext) async -> Movie {
        var detail: TMDBMovieSummary?
        if title.isFromTMDB, !apiKey.isEmpty {
            detail = try? await TMDBClient(apiKey: apiKey).movieDetail(id: title.tmdbID)
        }
        let movie = makeMovie(title, releaseDate: releaseDate, detail: detail)
        context.insert(movie)
        return movie
    }

    /// What "Add to My Library" did.
    public enum Addition {
        case addedShow(Show, episodesError: (any Error)?)
        case addedMovie(Movie)
        /// Nothing was added: the library already has it.
        case alreadyInLibrary
    }

    /// A watch list's "Add to My Library": the title goes into this person's
    /// own library unless it's already there (`LibraryIndex`, the list's own
    /// idea of "the same title"). The caller saves.
    @MainActor
    public static func add(_ title: WatchListTitle, apiKey: String, to context: ModelContext) async -> Addition {
        let index = LibraryIndex(
            shows: (try? context.fetch(FetchDescriptor<Show>())) ?? [],
            movies: (try? context.fetch(FetchDescriptor<Movie>())) ?? []
        )
        guard !index.contains(title) else { return .alreadyInLibrary }
        switch title.mediaType {
        case .show:
            let added = await addShow(title, apiKey: apiKey, to: context)
            return .addedShow(added.show, episodesError: added.episodesError)
        case .movie:
            return .addedMovie(await addMovie(title, apiKey: apiKey, to: context))
        }
    }

    /// What to tell someone after "Add to My Library", or nil when it simply
    /// worked — the row's "In your library" says that. A show added with no
    /// key to look its episodes up with says so, rather than sitting in
    /// Watching with nothing to tick off and no word why.
    static func problem(after addition: Addition, adding title: WatchListTitle, apiKey: String) -> String? {
        switch addition {
        case .addedShow(let show, let error?):
            return "Added \(show.name), but its episodes could not be loaded. \(error.localizedDescription)"
        case .addedShow(let show, nil) where title.isFromTMDB && apiKey.isEmpty:
            return "Added \(show.name) without its episodes: there's no TMDB API key in TV's Settings to look them up with."
        case .addedShow, .addedMovie:
            return nil
        case .alreadyInLibrary:
            return "\(title.title) is already in your library."
        }
    }

    private static func named(_ text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

/// Which shows and films this person's library already has — for a watch
/// list's "In your library", and so "Add to My Library" never makes a second
/// copy. "The same title" is exactly `WatchListDuplicates.matches`: the same
/// TMDB id when both have one, else the same name, kind for kind. Sets rather
/// than that pairwise test, since every row of a list asks.
public struct LibraryIndex: Sendable {
    private var tmdbKeys: Set<String> = []
    /// Names of the library's titles with no TMDB id, which any title of the
    /// same name and kind matches.
    private var typedNameKeys: Set<String> = []
    private var nameKeys: Set<String> = []

    public init(_ titles: [WatchListTitle]) {
        for title in titles {
            let nameKey = Self.nameKey(title)
            nameKeys.insert(nameKey)
            if title.isFromTMDB {
                tmdbKeys.insert(title.id)
            } else {
                typedNameKeys.insert(nameKey)
            }
        }
    }

    public init(shows: [Show], movies: [Movie]) {
        self.init(shows.map(WatchListTitle.init(libraryShow:)) + movies.map(WatchListTitle.init(libraryMovie:)))
    }

    public func contains(_ title: WatchListTitle) -> Bool {
        if title.isFromTMDB {
            return tmdbKeys.contains(title.id) || typedNameKeys.contains(Self.nameKey(title))
        }
        return nameKeys.contains(Self.nameKey(title))
    }

    private static func nameKey(_ title: WatchListTitle) -> String {
        "\(title.mediaType.rawValue):\(title.normalizedTitle)"
    }
}

public extension WatchListTitle {
    /// A show already in the library, as a list sees it. The library keeps no
    /// first-air date, so no year.
    init(libraryShow show: Show) {
        self.init(mediaType: .show, tmdbID: show.tmdbID, title: show.name, posterPath: show.posterPath, overview: show.overview)
    }

    init(libraryMovie movie: Movie) {
        self.init(
            mediaType: .movie,
            tmdbID: movie.tmdbID,
            title: movie.title,
            posterPath: movie.posterPath,
            overview: movie.overview,
            year: Self.year(of: movie.releaseDate)
        )
    }
}
