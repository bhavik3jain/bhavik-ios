import Core
import Foundation
import SwiftData

public struct LibraryImportSummary: Sendable, Equatable {
    public var showsImported = 0
    public var showsAlreadyPresent = 0
    public var moviesImported = 0
    public var moviesAlreadyPresent = 0
    public var episodesMarkedWatched = 0
    public var moviesMarkedWatched = 0
    /// Specials — season 0 — that were watched and so were pulled in even
    /// though the numbered seasons are what normally count.
    public var specialsImported = 0
    /// Watches naming an episode TMDB doesn't list, usually because the show
    /// was renumbered upstream after it was watched. Named rather than counted:
    /// a bare number gives you nothing to act on.
    public var unmatched: [String] = []
    public var failedShows: [String] = []

    public var totalImported: Int { showsImported + moviesImported }
}

public enum LibraryImportError: LocalizedError {
    case unreadableFile
    case missingLibrary
    case missingWatches
    case missingAPIKey

    public var errorDescription: String? {
        switch self {
        case .unreadableFile:
            "That file couldn't be read as text."
        case .missingLibrary:
            "No library file found. Select both library.csv and watches.csv from the export."
        case .missingWatches:
            "No watches file found. Select both library.csv and watches.csv from the export."
        case .missingAPIKey:
            "Add a TMDB API key in Settings first — the import needs it to look up episodes."
        }
    }
}

/// A watch-history export, parsed and cross-referenced, ready to import.
public struct LibraryExport: Sendable, Equatable {
    public struct Title: Sendable, Equatable {
        public let tmdbID: Int
        public let name: String
        public let isDropped: Bool
    }

    struct EpisodeKey: Hashable, Sendable {
        let season: Int
        let episode: Int
    }

    public var shows: [Title] = []
    public var movies: [Title] = []
    var episodeWatches: [Int: [EpisodeKey: Date]] = [:]
    var movieWatches: [Int: Date] = [:]
    /// What the import will walk, and therefore how long it will take: one TMDB
    /// round trip per title, plus one per season for shows.
    public var titleCount: Int { shows.count + movies.count }
}

/// Reads a watch-history export — `library.csv` for what you track, `watches.csv` for
/// what you've seen.
///
/// The export only identifies things by TMDB id, so every title still has to be
/// looked up to get episode lists, posters and runtimes. That makes this a slow,
/// network-bound import rather than a parse, which is why it reports progress
/// and can be cancelled part way.
public enum LibraryImporter {
    // MARK: - Parsing

    /// Works out which file is which by looking at the headers, so the two can
    /// be selected in either order.
    public static func parse(fileURLs: [URL]) throws -> LibraryExport {
        var libraryText: String?
        var watchesText: String?

        for url in fileURLs {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            else { throw LibraryImportError.unreadableFile }

            guard let header = CSVParser.rows(from: text).first else { continue }
            let columns = Set(header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            if columns.contains("list_status") {
                libraryText = text
            } else if columns.contains("season_number"), columns.contains("plays") {
                watchesText = text
            }
        }

        guard let libraryText else { throw LibraryImportError.missingLibrary }
        guard let watchesText else { throw LibraryImportError.missingWatches }
        return parse(libraryText: libraryText, watchesText: watchesText)
    }

    static func parse(libraryText: String, watchesText: String) -> LibraryExport {
        var export = LibraryExport()

        for row in dictionaries(from: libraryText) {
            guard let tmdbID = Int(row["tmdb_id"] ?? "") else { continue }
            let title = LibraryExport.Title(
                tmdbID: tmdbID,
                name: row["title"] ?? "",
                // "stopped" is the only status that maps onto anything
                // here; "for_later" just means unwatched, which the watch
                // records already say.
                isDropped: row["list_status"] == "stopped"
            )
            switch row["type"] {
            case "show": export.shows.append(title)
            case "movie": export.movies.append(title)
            default: break
            }
        }

        for row in dictionaries(from: watchesText) {
            guard let tmdbID = Int(row["tmdb_id"] ?? "") else { continue }
            let watchedAt = parseTimestamp(row["last_watched_at"] ?? "")
                ?? parseTimestamp(row["first_watched_at"] ?? "")

            switch row["type"] {
            case "movie":
                export.movieWatches[tmdbID] = watchedAt ?? .now
            case "episode":
                guard let season = Int(row["season_number"] ?? ""),
                      let episode = Int(row["episode_number"] ?? "")
                else { continue }
                let key = LibraryExport.EpisodeKey(season: season, episode: episode)
                export.episodeWatches[tmdbID, default: [:]][key] = watchedAt ?? .now
            default:
                break
            }
        }

        return export
    }

    // MARK: - Importing

    /// Walks every title, fetching from TMDB and writing records as it goes.
    ///
    /// Saves after each title rather than once at the end: an import of this
    /// size takes minutes, and a cancellation half way should keep what it
    /// already fetched rather than discarding the lot.
    @MainActor
    public static func run(
        _ export: LibraryExport,
        apiKey: String,
        into context: ModelContext,
        progress: @MainActor (Int, Int, String) -> Void = { _, _, _ in }
    ) async throws -> LibraryImportSummary {
        guard !apiKey.isEmpty else { throw LibraryImportError.missingAPIKey }

        let client = TMDBClient(apiKey: apiKey)
        var summary = LibraryImportSummary()
        var knownShows = try existingShows(in: context)
        var knownMovies = try existingMovies(in: context)

        let total = export.titleCount
        var done = 0

        for title in export.shows {
            try Task.checkCancellation()
            done += 1
            progress(done, total, title.name)

            // Already tracked: there is nothing to fetch, but the watch
            // history still has to land — it is usually the whole reason for
            // importing. Skipping the title outright silently dropped it.
            if let existing = knownShows[title.tmdbID] {
                summary.showsAlreadyPresent += 1
                summary.episodesMarkedWatched += markWatched(
                    existing, from: export.episodeWatches[title.tmdbID] ?? [:]
                )
                try context.save()
                continue
            }

            do {
                let watches = export.episodeWatches[title.tmdbID] ?? [:]
                // Season 0 is only worth the extra request when something in it
                // was actually watched.
                let wantsSpecials = watches.keys.contains { $0.season == 0 }
                let (detail, episodes) = try await client.show(
                    id: title.tmdbID,
                    includingSpecials: wantsSpecials
                )

                let show = Show(
                    tmdbID: title.tmdbID,
                    // The export's own title is the fallback: a show TMDB has
                    // since renamed should still import under the name it was
                    // tracked as.
                    name: detail.name.isEmpty ? title.name : detail.name,
                    overview: detail.overview,
                    posterPath: detail.posterPath
                )
                context.insert(show)

                var watchedCount = 0
                var specialsKept = 0
                var matched: Set<LibraryExport.EpisodeKey> = []
                for tmdbEpisode in episodes {
                    let key = LibraryExport.EpisodeKey(
                        season: tmdbEpisode.seasonNumber,
                        episode: tmdbEpisode.episodeNumber
                    )
                    // Season 0 holds trailers and recaps as well as real
                    // specials. Keeping only the watched ones means progress
                    // stays reachable instead of counting clips nobody watches.
                    if tmdbEpisode.seasonNumber == 0, watches[key] == nil { continue }

                    let episode = Episode(
                        tmdbID: tmdbEpisode.id,
                        name: tmdbEpisode.name,
                        seasonNumber: tmdbEpisode.seasonNumber,
                        episodeNumber: tmdbEpisode.episodeNumber,
                        airDate: tmdbEpisode.airDate
                    )
                    episode.show = show
                    context.insert(episode)

                    if let watchedAt = watches[key] {
                        episode.setWatched(true, at: watchedAt)
                        watchedCount += 1
                        matched.insert(key)
                        if tmdbEpisode.seasonNumber == 0 { specialsKept += 1 }
                    }
                }

                summary.episodesMarkedWatched += watchedCount
                summary.specialsImported += specialsKept
                // Named, so an episode TMDB has renumbered can actually be
                // found and fixed by hand rather than being a number.
                for key in watches.keys where !matched.contains(key) {
                    summary.unmatched.append(
                        "\(title.name) S\(String(format: "%02d", key.season))E\(String(format: "%02d", key.episode))"
                    )
                }

                // The export has no "completed": a finished show just sits in
                // "watching" forever. Deriving it from the episodes is closer to
                // what the library actually means.
                if title.isDropped {
                    show.status = .dropped
                } else if !episodes.isEmpty,
                          watchedCount >= episodes.count(where: { $0.seasonNumber > 0 }) {
                    show.status = .completed
                } else {
                    show.status = .watching
                }

                knownShows[title.tmdbID] = show
                summary.showsImported += 1
                try context.save()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                summary.failedShows.append(title.name)
            }
        }

        for title in export.movies {
            try Task.checkCancellation()
            done += 1
            progress(done, total, title.name)

            if let existing = knownMovies[title.tmdbID] {
                summary.moviesAlreadyPresent += 1
                if let watchedAt = export.movieWatches[title.tmdbID], !existing.isWatched {
                    existing.setWatched(true, at: watchedAt)
                    summary.moviesMarkedWatched += 1
                    try context.save()
                }
                continue
            }

            do {
                let detail = try await client.movieDetail(id: title.tmdbID)
                let movie = Movie(
                    tmdbID: title.tmdbID,
                    title: detail.title.isEmpty ? title.name : detail.title,
                    overview: detail.overview,
                    posterPath: detail.posterPath,
                    releaseDate: detail.releaseDate,
                    runtime: detail.runtime
                )
                if let watchedAt = export.movieWatches[title.tmdbID] {
                    movie.setWatched(true, at: watchedAt)
                    summary.moviesMarkedWatched += 1
                }
                context.insert(movie)

                knownMovies[title.tmdbID] = movie
                summary.moviesImported += 1
                try context.save()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                summary.failedShows.append(title.name)
            }
        }

        return summary
    }

    // MARK: - Helpers

    @MainActor
    private static func existingShows(in context: ModelContext) throws -> [Int: Show] {
        var byID: [Int: Show] = [:]
        for show in try context.fetch(FetchDescriptor<Show>()) where show.tmdbID != 0 {
            byID[show.tmdbID] = show
        }
        return byID
    }

    @MainActor
    private static func existingMovies(in context: ModelContext) throws -> [Int: Movie] {
        var byID: [Int: Movie] = [:]
        for movie in try context.fetch(FetchDescriptor<Movie>()) where movie.tmdbID != 0 {
            byID[movie.tmdbID] = movie
        }
        return byID
    }

    /// Applies the export's watch history to a show that is already tracked,
    /// returning how many episodes changed.
    ///
    /// Anything already marked watched is left alone — the app is the authority
    /// on what has been seen since the export was taken, so this only ever adds.
    @MainActor
    private static func markWatched(
        _ show: Show,
        from watches: [LibraryExport.EpisodeKey: Date]
    ) -> Int {
        guard !watches.isEmpty else { return 0 }

        var changed = 0
        for episode in show.episodes ?? [] {
            let key = LibraryExport.EpisodeKey(
                season: episode.seasonNumber,
                episode: episode.episodeNumber
            )
            guard let watchedAt = watches[key], !episode.isWatched else { continue }
            episode.setWatched(true, at: watchedAt)
            changed += 1
        }

        // A show that just became fully watched shouldn't still say "Watching".
        // A dropped one keeps its status: that was a deliberate choice.
        let episodes = show.episodes ?? []
        if changed > 0, show.status == .watching,
           !episodes.isEmpty, episodes.allSatisfy(\.isWatched) {
            show.status = .completed
        }
        return changed
    }

    /// Header-keyed rows, lowercased so a change of case upstream doesn't
    /// quietly stop matching.
    private static func dictionaries(from text: String) -> [[String: String]] {
        let rows = CSVParser.rows(from: text)
        guard let header = rows.first else { return [] }
        let keys = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }

        return rows.dropFirst().map { row in
            var entry: [String: String] = [:]
            for (index, key) in keys.enumerated() where index < row.count {
                entry[key] = row[index].trimmingCharacters(in: .whitespaces)
            }
            return entry
        }
    }

    /// `2023-07-28T01:43:56.901Z`. Exports always write fractional seconds, but
    /// the plain form is accepted too so a hand-edited file still imports.
    static func parseTimestamp(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        return fractional.date(from: text) ?? plain.date(from: text)
    }

    // ISO8601DateFormatter isn't Sendable. Both are configured once here and
    // only read afterwards, so sharing them is safe.
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
