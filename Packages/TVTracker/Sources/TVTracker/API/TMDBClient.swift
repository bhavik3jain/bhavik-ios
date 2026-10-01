import Foundation

public struct TMDBShowSummary: Identifiable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let overview: String
    public let posterPath: String
    public let firstAirDate: Date?
}

public struct TMDBMovieSummary: Identifiable, Sendable, Equatable {
    public let id: Int
    public let title: String
    public let overview: String
    public let posterPath: String
    public let releaseDate: Date?
    /// Minutes, and zero from search results — the search endpoint omits it,
    /// so it is filled in by `movieDetail(id:)`.
    public let runtime: Int
}

/// What the movie screen shows beyond what's stored: read live each time,
/// like the posters, so none of it syncs through iCloud.
public struct TMDBMovieDetails: Sendable, Equatable {
    public let summary: TMDBMovieSummary
    public let tagline: String
    public let genres: [String]
    /// TMDB's 0–10 audience score; zero when too few have voted.
    public let rating: Double
    public let voteCount: Int
}

/// One episode's own page: what it's about, a still, who made it and who's
/// in it. Read live each time, like a movie's details; none of it syncs.
public struct TMDBEpisodeDetails: Sendable, Equatable {
    public struct GuestStar: Sendable, Equatable, Identifiable {
        public let name: String
        public let character: String
        public var id: String { name + "|" + character }
    }

    public let name: String
    public let overview: String
    public let airDate: Date?
    /// Minutes; zero when TMDB doesn't know.
    public let runtime: Int
    /// A path under `TMDBClient.stillBaseURL`; empty when there's no still.
    public let stillPath: String
    /// TMDB's 0–10 audience score; zero when too few have voted.
    public let rating: Double
    public let voteCount: Int
    public let directors: [String]
    public let writers: [String]
    public let guestStars: [GuestStar]
}

public struct TMDBEpisode: Sendable, Equatable {
    public let id: Int
    public let name: String
    public let seasonNumber: Int
    public let episodeNumber: Int
    public let airDate: Date?
}

public enum TMDBError: LocalizedError {
    case missingAPIKey
    case unauthorized
    case rateLimited
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add a TMDB API key in Settings to search for shows."
        case .unauthorized:
            "TMDB rejected that API key. Check it in Settings."
        case .rateLimited:
            "TMDB is rate limiting requests. Try again in a moment."
        case .network(let detail):
            detail
        }
    }
}

/// Reads show and episode metadata from TMDB.
///
/// Only the catalog lives here — what you have watched is yours and stays in
/// SwiftData, so the app keeps working offline and without a key.
public struct TMDBClient: Sendable {
    public static let attribution = "This product uses the TMDB API but is not endorsed or certified by TMDB."
    public static let imageBaseURL = "https://image.tmdb.org/t/p/w342"
    /// Wider than a poster: an episode still fills the width of its screen.
    public static let stillBaseURL = "https://image.tmdb.org/t/p/w780"

    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func searchShows(query: String) async throws -> [TMDBShowSummary] {
        guard !apiKey.isEmpty else { throw TMDBError.missingAPIKey }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://api.themoviedb.org/3/search/tv")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: trimmed)
        ]

        let payload: SearchResponse = try await get(components)
        return payload.results.map(\.summary)
    }

    public func searchMovies(query: String) async throws -> [TMDBMovieSummary] {
        guard !apiKey.isEmpty else { throw TMDBError.missingAPIKey }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://api.themoviedb.org/3/search/movie")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: trimmed)
        ]

        let payload: MovieSearchResponse = try await get(components)
        return payload.results.map(\.summary)
    }

    /// Re-reads a movie to pick up the runtime, which search results omit.
    public func movieDetail(id: Int) async throws -> TMDBMovieSummary {
        try await movieDetails(id: id).summary
    }

    /// Everything the movie screen shows: the same request as `movieDetail`,
    /// with the tagline, genres and rating it already carries.
    public func movieDetails(id: Int) async throws -> TMDBMovieDetails {
        guard !apiKey.isEmpty else { throw TMDBError.missingAPIKey }
        var components = URLComponents(string: "https://api.themoviedb.org/3/movie/\(id)")!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        let payload: MovieDetailResponse = try await get(components)
        return payload.details
    }

    /// Fetches every episode of a show by walking its seasons. Specials
    /// (season 0) are skipped — they are rarely what you are tracking.
    public func allEpisodes(showID: Int) async throws -> [TMDBEpisode] {
        try await show(id: showID).episodes
    }

    /// A show's own details together with its full episode list.
    ///
    /// Fetching the episodes already costs a `/tv/{id}` request, which carries
    /// the name, overview and poster as well — `allEpisodes` simply threw those
    /// away. An import walking a hundred shows would otherwise ask for each one
    /// twice.
    ///
    /// Season 0 is omitted by default: TMDB files trailers, recaps and
    /// behind-the-scenes clips there, and counting those as episodes would make
    /// every show's progress unreachable. Pass `includingSpecials` when
    /// something has actually been watched from it — an import restoring a
    /// watched special needs the episode to exist to attach it to.
    public func show(
        id: Int,
        includingSpecials: Bool = false
    ) async throws -> (summary: TMDBShowSummary, episodes: [TMDBEpisode]) {
        guard !apiKey.isEmpty else { throw TMDBError.missingAPIKey }

        var components = URLComponents(string: "https://api.themoviedb.org/3/tv/\(id)")!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        let detail: ShowDetailResponse = try await get(components)

        var episodes: [TMDBEpisode] = []
        for season in detail.seasons where season.season_number > 0 || includingSpecials {
            var seasonComponents = URLComponents(
                string: "https://api.themoviedb.org/3/tv/\(id)/season/\(season.season_number)"
            )!
            seasonComponents.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
            let seasonDetail: SeasonDetailResponse = try await get(seasonComponents)
            episodes.append(contentsOf: seasonDetail.episodes.map(\.episode))
        }
        return (detail.summary(id: id), episodes)
    }

    /// One episode's synopsis, still, runtime, rating, director, writers and
    /// guest stars, for the episode screen.
    public func episodeDetails(showID: Int, season: Int, episode: Int) async throws -> TMDBEpisodeDetails {
        guard !apiKey.isEmpty else { throw TMDBError.missingAPIKey }
        var components = URLComponents(string: "https://api.themoviedb.org/3/tv/\(showID)/season/\(season)/episode/\(episode)")!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        let payload: EpisodeDetailResponse = try await get(components)
        return payload.details
    }

    /// The episode payload's parsing on its own, for tests.
    static func decodeEpisodeDetails(_ data: Data) throws -> TMDBEpisodeDetails {
        try JSONDecoder().decode(EpisodeDetailResponse.self, from: data).details
    }

    private func get<T: Decodable>(_ components: URLComponents) async throws -> T {
        guard let url = components.url else { throw TMDBError.network("Could not build a request URL.") }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200..<300: break
                case 401: throw TMDBError.unauthorized
                case 429: throw TMDBError.rateLimited
                default: throw TMDBError.network("TMDB returned status \(http.statusCode).")
                }
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as TMDBError {
            throw error
        } catch let error as DecodingError {
            throw TMDBError.network("TMDB sent data in an unexpected shape. \(error.localizedDescription)")
        } catch {
            throw TMDBError.network(error.localizedDescription)
        }
    }
}

// MARK: - Wire format

private struct SearchResponse: Decodable {
    let results: [Result]

    struct Result: Decodable {
        let id: Int
        let name: String
        let overview: String?
        let poster_path: String?
        let first_air_date: String?

        var summary: TMDBShowSummary {
            TMDBShowSummary(
                id: id,
                name: name,
                overview: overview ?? "",
                posterPath: poster_path ?? "",
                firstAirDate: TMDBDate.parse(first_air_date)
            )
        }
    }
}

private struct MovieSearchResponse: Decodable {
    let results: [Result]

    struct Result: Decodable {
        let id: Int
        let title: String
        let overview: String?
        let poster_path: String?
        let release_date: String?

        var summary: TMDBMovieSummary {
            TMDBMovieSummary(
                id: id,
                title: title,
                overview: overview ?? "",
                posterPath: poster_path ?? "",
                releaseDate: TMDBDate.parse(release_date),
                runtime: 0
            )
        }
    }
}

private struct MovieDetailResponse: Decodable {
    let id: Int
    let title: String
    let overview: String?
    let poster_path: String?
    let release_date: String?
    let runtime: Int?
    let tagline: String?
    let genres: [Genre]?
    let vote_average: Double?
    let vote_count: Int?

    struct Genre: Decodable {
        let name: String
    }

    var details: TMDBMovieDetails {
        TMDBMovieDetails(
            summary: summary,
            tagline: tagline ?? "",
            genres: (genres ?? []).map(\.name),
            rating: vote_average ?? 0,
            voteCount: vote_count ?? 0
        )
    }

    var summary: TMDBMovieSummary {
        TMDBMovieSummary(
            id: id,
            title: title,
            overview: overview ?? "",
            posterPath: poster_path ?? "",
            releaseDate: TMDBDate.parse(release_date),
            runtime: runtime ?? 0
        )
    }
}

private struct ShowDetailResponse: Decodable {
    let name: String?
    let overview: String?
    let poster_path: String?
    let first_air_date: String?
    let seasons: [Season]

    struct Season: Decodable {
        let season_number: Int
    }

    func summary(id: Int) -> TMDBShowSummary {
        TMDBShowSummary(
            id: id,
            name: name ?? "",
            overview: overview ?? "",
            posterPath: poster_path ?? "",
            firstAirDate: TMDBDate.parse(first_air_date)
        )
    }
}

private struct SeasonDetailResponse: Decodable {
    let episodes: [EpisodePayload]

    struct EpisodePayload: Decodable {
        let id: Int
        let name: String?
        let season_number: Int
        let episode_number: Int
        let air_date: String?

        var episode: TMDBEpisode {
            TMDBEpisode(
                id: id,
                name: name ?? "",
                seasonNumber: season_number,
                episodeNumber: episode_number,
                airDate: TMDBDate.parse(air_date)
            )
        }
    }
}

private struct EpisodeDetailResponse: Decodable {
    let name: String?
    let overview: String?
    let air_date: String?
    let runtime: Int?
    let still_path: String?
    let vote_average: Double?
    let vote_count: Int?
    let crew: [Crew]?
    let guest_stars: [Guest]?

    struct Crew: Decodable {
        let name: String
        let job: String?
    }

    struct Guest: Decodable {
        let name: String
        let character: String?
    }

    var details: TMDBEpisodeDetails {
        let crew = crew ?? []
        // Once each, in TMDB's order: a writer credited for both the story
        // and the teleplay is still one writer.
        func people(_ jobs: Set<String>) -> [String] {
            var seen: Set<String> = []
            return crew.filter { jobs.contains($0.job ?? "") }.map(\.name).filter { seen.insert($0).inserted }
        }
        return TMDBEpisodeDetails(
            name: name ?? "",
            overview: overview ?? "",
            airDate: TMDBDate.parse(air_date),
            runtime: runtime ?? 0,
            stillPath: still_path ?? "",
            rating: vote_average ?? 0,
            voteCount: vote_count ?? 0,
            directors: people(["Director"]),
            writers: people(["Writer", "Teleplay", "Story", "Screenplay"]),
            guestStars: (guest_stars ?? []).map { TMDBEpisodeDetails.GuestStar(name: $0.name, character: $0.character ?? "") }
        )
    }
}

enum TMDBDate {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// TMDB sends an empty string for unknown dates, which must read as "no
    /// date" rather than a bogus one.
    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return formatter.date(from: text)
    }
}
