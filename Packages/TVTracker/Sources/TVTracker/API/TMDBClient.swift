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
        guard !apiKey.isEmpty else { throw TMDBError.missingAPIKey }
        var components = URLComponents(string: "https://api.themoviedb.org/3/movie/\(id)")!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        let payload: MovieDetailResponse = try await get(components)
        return payload.summary
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
    /// Season 0 is skipped deliberately: TMDB files trailers, recaps and
    /// behind-the-scenes clips there, and counting those as episodes would make
    /// every show's progress unreachable.
    public func show(id: Int) async throws -> (summary: TMDBShowSummary, episodes: [TMDBEpisode]) {
        guard !apiKey.isEmpty else { throw TMDBError.missingAPIKey }

        var components = URLComponents(string: "https://api.themoviedb.org/3/tv/\(id)")!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        let detail: ShowDetailResponse = try await get(components)

        var episodes: [TMDBEpisode] = []
        for season in detail.seasons where season.season_number > 0 {
            var seasonComponents = URLComponents(
                string: "https://api.themoviedb.org/3/tv/\(id)/season/\(season.season_number)"
            )!
            seasonComponents.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
            let seasonDetail: SeasonDetailResponse = try await get(seasonComponents)
            episodes.append(contentsOf: seasonDetail.episodes.map(\.episode))
        }
        return (detail.summary(id: id), episodes)
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
