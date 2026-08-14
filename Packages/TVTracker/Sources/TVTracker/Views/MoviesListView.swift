import SwiftData
import SwiftUI

struct MoviesListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Movie.addedAt, order: .reverse) private var movies: [Movie]
    @State private var showingAddMovie = false

    private var watchlist: [Movie] { movies.filter { !$0.isWatched } }
    private var watched: [Movie] { movies.filter(\.isWatched) }

    var body: some View {
        NavigationStack {
            Group {
                if movies.isEmpty {
                    ContentUnavailableView {
                        Label("No movies yet", systemImage: "film")
                    } description: {
                        Text("Keep a watchlist and tick films off as you see them.")
                    } actions: {
                        Button("Add Movie") { showingAddMovie = true }
                            .buttonStyle(.borderedProminent)
                            .tint(TVTrackerModule.accent.color)
                    }
                } else {
                    List {
                        if !watchlist.isEmpty {
                            Section("Watchlist") {
                                ForEach(watchlist) { movie in
                                    MovieRow(movie: movie)
                                }
                                .onDelete { delete(watchlist, at: $0) }
                            }
                        }
                        if !watched.isEmpty {
                            Section("Watched") {
                                ForEach(watched) { movie in
                                    MovieRow(movie: movie)
                                }
                                .onDelete { delete(watched, at: $0) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Movies")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddMovie = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddMovie) {
                AddMovieView()
            }
        }
    }

    private func delete(_ source: [Movie], at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(source[index])
        }
    }
}

private struct MovieRow: View {
    @Bindable var movie: Movie

    var body: some View {
        Button {
            movie.setWatched(!movie.isWatched)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: movie.isWatched ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(movie.isWatched ? TVTrackerModule.accent.color : .secondary)

                PosterView(path: movie.posterPath, width: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(movie.title)
                        .foregroundStyle(.primary)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    HStack(spacing: 6) {
                        if let releaseDate = movie.releaseDate {
                            Text(releaseDate, format: .dateTime.year())
                        }
                        if let runtime = movie.formattedRuntime {
                            Text("· \(runtime)")
                        }
                        if !movie.hasReleased() {
                            Text("· Unreleased")
                                .foregroundStyle(TVTrackerModule.accent.color)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
        .buttonStyle(.plain)
    }
}
