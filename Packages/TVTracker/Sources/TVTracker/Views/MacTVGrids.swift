import Core
import SwiftData
import SwiftUI

/// TV on the Mac: posters in a grid, the way the TV app lays out a library,
/// in place of the phone's rows — which, across a desktop window, were a
/// thumbnail at one edge and a thin progress line running the width of it.
private let posterColumns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20, alignment: .top)]

/// The shows being watched, by status, each a poster with its progress.
struct MacShowsGrid: View {
    let groups: [(ShowStatus, [Show])]
    let remove: (Show) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(groups, id: \.0) { status, shows in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(status.displayName)
                            .font(.title3.weight(.semibold))
                        LazyVGrid(columns: posterColumns, alignment: .leading, spacing: 24) {
                            ForEach(shows) { show in
                                NavigationLink {
                                    ShowDetailView(show: show)
                                } label: {
                                    ShowPosterCard(show: show)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Remove Show", systemImage: "trash", role: .destructive) { remove(show) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

private struct ShowPosterCard: View {
    let show: Show

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterFrame(path: show.posterPath) {
                if show.episodeCount > 0 {
                    ProgressView(value: show.progress)
                        .progressViewStyle(.linear)
                        .tint(TVTrackerModule.accent.color)
                        .padding(8)
                        .background(.black.opacity(0.35))
                }
            }
            Text(show.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if let next = show.nextUnwatched {
                Text(next.hasAired() ? "Next up \(next.code)" : "Waiting on \(next.code)")
                    .font(.caption)
                    .foregroundStyle(next.hasAired() ? TVTrackerModule.accent.color : .secondary)
            } else if show.episodeCount > 0 {
                Text("\(show.watchedCount) of \(show.episodeCount) watched")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
    }
}

/// Movies: the watchlist, then what's been watched, as posters.
struct MacMoviesGrid: View {
    let watchlist: [Movie]
    let watched: [Movie]
    let remove: (Movie) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section("Watchlist", watchlist)
                section("Watched", watched)
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ movies: [Movie]) -> some View {
        if !movies.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.title3.weight(.semibold))
                LazyVGrid(columns: posterColumns, alignment: .leading, spacing: 24) {
                    ForEach(movies) { movie in
                        NavigationLink {
                            MovieDetailView(movie: movie)
                        } label: {
                            MoviePosterCard(movie: movie)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(movie.isWatched ? "Mark Unwatched" : "Mark Watched", systemImage: movie.isWatched ? "circle" : "checkmark.circle") {
                                movie.setWatched(!movie.isWatched)
                            }
                            Divider()
                            Button("Remove Movie", systemImage: "trash", role: .destructive) { remove(movie) }
                        }
                    }
                }
            }
        }
    }
}

private struct MoviePosterCard: View {
    let movie: Movie

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterFrame(path: movie.posterPath) {
                if movie.isWatched {
                    HStack {
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, TVTrackerModule.accent.color)
                            .padding(8)
                    }
                } else if !movie.hasReleased() {
                    Text("Coming soon")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.5), in: .capsule)
                        .foregroundStyle(.white)
                        .padding(8)
                }
            }
            Text(movie.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text([movie.releaseDate.map { $0.formatted(.dateTime.year()) }, movie.formattedRuntime].compactMap(\.self).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
    }
}

/// A 2:3 poster filling its grid cell, with something laid over its foot.
private struct PosterFrame<Overlay: View>: View {
    let path: String
    @ViewBuilder let overlay: () -> Overlay

    var body: some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                PosterImage(path: path)
            }
            .overlay(alignment: .bottom) { overlay() }
            .clipShape(.rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
    }
}

/// A poster with no fixed size, for `PosterFrame`: `PosterView` takes a width.
private struct PosterImage: View {
    let path: String

    var body: some View {
        if !path.isEmpty, let url = URL(string: TMDBClient.imageBaseURL + path) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.fill.tertiary)
            }
        } else {
            Rectangle().fill(.fill.tertiary)
                .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
        }
    }
}
