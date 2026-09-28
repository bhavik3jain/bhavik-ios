import Core // Only reached on macOS, where Core stands in for the iOS-only SwiftUI API below.
import SwiftData
import SwiftUI

/// A movie's own screen, the way a show has one: poster, what it's about,
/// and whether you've seen it. Tapping a movie used to tick it watched and
/// nothing more, so there was nowhere to read what one was.
struct MovieDetailView: View {
    @Bindable var movie: Movie
    @SyncedSecret(TVTrackerModule.apiKeyDefaultsKey) private var apiKey
    /// Tagline, genres and rating, read from TMDB each time like the poster,
    /// so none of it syncs; nil until it arrives, or with no key.
    @State private var details: TMDBMovieDetails?

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    PosterView(path: movie.posterPath, width: 96)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(movie.title)
                            .font(.title3)
                            .fontWeight(.semibold)
                        if let tagline = details?.tagline, !tagline.isEmpty {
                            Text(tagline)
                                .font(.subheadline)
                                .italic()
                                .foregroundStyle(.secondary)
                        }
                        Text(facts)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let details, !details.genres.isEmpty {
                            Text(details.genres.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let details, details.voteCount > 0, details.rating > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                                Text(details.rating.formatted(.number.precision(.fractionLength(1))) + " / 10")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)

                if movie.hasReleased() || movie.isWatched {
                    Button {
                        movie.setWatched(!movie.isWatched)
                    } label: {
                        Label(
                            movie.isWatched ? "Watched" : "Mark Watched",
                            systemImage: movie.isWatched ? "checkmark.circle.fill" : "circle"
                        )
                    }
                    .tint(TVTrackerModule.accent.color)
                    if let watchedAt = movie.watchedAt {
                        LabeledContent("Watched on", value: watchedAt.formatted(date: .abbreviated, time: .omitted))
                    }
                } else if let releaseDate = movie.releaseDate {
                    LabeledContent("Releases", value: releaseDate.formatted(date: .abbreviated, time: .omitted))
                } else {
                    Text("No release date yet")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if details != nil, movie.overview.isEmpty {
                    Text(TMDBClient.attribution)
                }
            }

            if !movie.overview.isEmpty {
                Section {
                    Text(movie.overview)
                        .font(.callout)
                } header: {
                    Text("Overview")
                } footer: {
                    // Attribution goes last on the screen, under whatever's last.
                    if details != nil {
                        Text(TMDBClient.attribution)
                    }
                }
            }
        }
        .navigationTitle(movie.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: movie.tmdbID) { await loadDetails() }
    }

    /// "2019 · 3h 1m", or whichever of those is known.
    private var facts: String {
        var parts: [String] = []
        if let releaseDate = movie.releaseDate {
            parts.append(movie.hasReleased()
                         ? releaseDate.formatted(.dateTime.year())
                         : "Releases \(releaseDate.formatted(.dateTime.month(.abbreviated).day().year()))")
        }
        if let runtime = movie.formattedRuntime { parts.append(runtime) }
        return parts.joined(separator: " · ")
    }

    private func loadDetails() async {
        // A movie added by hand has no TMDB id to look up.
        guard movie.tmdbID > 0, !apiKey.isEmpty else { return }
        guard let fetched = try? await TMDBClient(apiKey: apiKey).movieDetails(id: movie.tmdbID) else { return }
        details = fetched
        // Fill in what TMDB didn't know when the movie was added — a runtime
        // or overview that arrived later, or a poster — without overwriting.
        if movie.runtime == 0, fetched.summary.runtime > 0 { movie.runtime = fetched.summary.runtime }
        if movie.overview.isEmpty, !fetched.summary.overview.isEmpty { movie.overview = fetched.summary.overview }
        if movie.posterPath.isEmpty, !fetched.summary.posterPath.isEmpty { movie.posterPath = fetched.summary.posterPath }
        if movie.releaseDate == nil, let releaseDate = fetched.summary.releaseDate { movie.releaseDate = releaseDate }
    }
}
