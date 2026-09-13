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
        NavigationStack {
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

        // Search results carry no runtime, so re-read the movie for it. A
        // failure here is not worth losing the movie over.
        let detail = (try? await TMDBClient(apiKey: apiKey).movieDetail(id: summary.id)) ?? summary

        modelContext.insert(
            Movie(
                tmdbID: detail.id,
                title: detail.title,
                overview: detail.overview,
                posterPath: detail.posterPath,
                releaseDate: detail.releaseDate,
                runtime: detail.runtime
            )
        )
        dismiss()
    }

    private func addManually() {
        let title = query.trimmingCharacters(in: .whitespaces)
        modelContext.insert(Movie(title: title.isEmpty ? "New Movie" : title))
        dismiss()
    }
}
