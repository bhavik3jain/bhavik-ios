import Core
import SwiftData
import SwiftUI

struct AddShowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @SyncedSecret(TVTrackerModule.apiKeyDefaultsKey) private var apiKey

    @State private var query = ""
    @State private var results: [TMDBShowSummary] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var importingShowID: Int?
    @State private var showingSettings = false

    var body: some View {
        SheetStack {
            List {
                if apiKey.isEmpty {
                    Section {
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Add a TMDB API key to search", systemImage: "key")
                        }
                    } footer: {
                        Text("Without a key you can still add shows and episodes by hand.")
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
                            Text("Searching…")
                                .foregroundStyle(.secondary)
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
                                Text(result.name)
                                    .foregroundStyle(.primary)
                                if let year = result.firstAirDate {
                                    Text(year, format: .dateTime.year())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if importingShowID == result.id {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(importingShowID != nil)
                }

                Section {
                    Button {
                        addManually()
                    } label: {
                        Label(
                            query.trimmingCharacters(in: .whitespaces).isEmpty
                                ? "Add show by hand"
                                : "Add “\(query)” by hand",
                            systemImage: "square.and.pencil"
                        )
                    }
                }
            }
            .searchable(text: $query, prompt: "Search shows")
            .onSubmit(of: .search) {
                Task { await search() }
            }
            .navigationTitle("Add Show")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SheetStack { TVSettingsView() }
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
            results = try await TMDBClient(apiKey: apiKey).searchShows(query: query)
            if results.isEmpty {
                errorMessage = "No shows matched “\(query)”."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func add(_ summary: TMDBShowSummary) async {
        importingShowID = summary.id
        defer { importingShowID = nil }

        let show = Show(
            tmdbID: summary.id,
            name: summary.name,
            overview: summary.overview,
            posterPath: summary.posterPath
        )
        modelContext.insert(show)

        do {
            let episodes = try await TMDBClient(apiKey: apiKey).allEpisodes(showID: summary.id)
            for payload in episodes {
                let episode = Episode(
                    tmdbID: payload.id,
                    name: payload.name,
                    seasonNumber: payload.seasonNumber,
                    episodeNumber: payload.episodeNumber,
                    airDate: payload.airDate
                )
                episode.show = show
                modelContext.insert(episode)
            }
            dismiss()
        } catch {
            // The show is kept even if the episode list fails, so the work isn't lost.
            errorMessage = "Added \(summary.name), but its episodes could not be loaded. \(error.localizedDescription)"
        }
    }

    private func addManually() {
        let name = query.trimmingCharacters(in: .whitespaces)
        modelContext.insert(Show(name: name.isEmpty ? "New Show" : name))
        dismiss()
    }
}
