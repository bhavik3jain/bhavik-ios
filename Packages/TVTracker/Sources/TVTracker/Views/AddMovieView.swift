import Core
import SwiftData
import SwiftUI

struct AddMovieView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @SyncedSecret(TVTrackerModule.apiKeyDefaultsKey) private var apiKey

    @State private var query = ""
    @State private var results: [TMDBMovieSummary] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var importingID: Int?

    var body: some View {
        SheetStack {
            List {
                if apiKey.isEmpty {
                    Section {
                        Label("Add a TMDB API key in Settings to search", systemImage: "key")
                            .foregroundStyle(.secondary)
                    } footer: {
                        Text("Without a key you can still add movies by hand.")
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                if isSearching {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Searching…").foregroundStyle(.secondary)
                        }
                    }
                }

                ForEach(results) { result in
                    Button {
                        Task { await add(result) }
                    } label: {
                        HStack(spacing: 12) {
                            PosterView(path: result.posterPath, width: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title)
                                    .foregroundStyle(.primary)
                                if let releaseDate = result.releaseDate {
                                    Text(releaseDate, format: .dateTime.year())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if importingID == result.id {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(importingID != nil)
                }

                Section {
                    Button {
                        addManually()
                    } label: {
                        Label(
                            query.trimmingCharacters(in: .whitespaces).isEmpty
                                ? "Add movie by hand"
                                : "Add “\(query)” by hand",
                            systemImage: "square.and.pencil"
                        )
                    }
                }
            }
            .searchable(text: $query, prompt: "Search movies")
            .onSubmit(of: .search) {
                Task { await search() }
            }
            .navigationTitle("Add Movie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
    }

    private func search() async {
        errorMessage = nil
        guard !apiKey.isEmpty else {
            errorMessage = TMDBError.missingAPIKey.localizedDescription
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            results = try await TMDBClient(apiKey: apiKey).searchMovies(query: query)
            if results.isEmpty {
                errorMessage = "No movies matched “\(query)”."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func add(_ summary: TMDBMovieSummary) async {
        importingID = summary.id
        defer { importingID = nil }

        // Search results carry no runtime, so `TVLibrary` re-reads the movie
        // for it — the same path a watch list's "Add to My Library" takes. A
        // failure there is not worth losing the movie over.
        await TVLibrary.addMovie(WatchListTitle(movie: summary), releaseDate: summary.releaseDate, apiKey: apiKey, to: modelContext)
        dismiss()
    }

    private func addManually() {
        modelContext.insert(TVLibrary.makeMovie(WatchListTitle(mediaType: .movie, title: query)))
        dismiss()
    }
}
