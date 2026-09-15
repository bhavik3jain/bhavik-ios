import Core
import SwiftData
import SwiftUI

/// Fixes one thing the import couldn't place, by hand.
///
/// Matching these automatically is tempting and wrong: the export's id for
/// "Monster (2022)" doesn't resolve, and the best title search returns Monster
/// High. Importing that silently would be worse than reporting the failure, so
/// the choice is put in front of whoever knows what they actually watched.
struct ResolveItemView: View {
    let item: UnresolvedItem
    let export: LibraryExport
    let apiKey: String
    /// Called once the item no longer needs showing, however that happened.
    let onSettled: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var query = ""
    @State private var results: [(id: Int, name: String, subtitle: String, posterPath: String)] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(item.displayName).font(.headline)
                    Text(item.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                switch item {
                case .title:
                    searchSection
                case let .episode(showTMDBID, _, _, _, watchedAt):
                    episodeSection(showTMDBID: showTMDBID, watchedAt: watchedAt)
                }

                Section {
                    Button("Ignore This", role: .destructive) {
                        onSettled()
                        dismiss()
                    }
                } footer: {
                    Text("Removes it from the list. Nothing in your library changes.")
                }
            }
            .navigationTitle("Resolve")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - A title whose id was wrong

    @ViewBuilder
    private var searchSection: some View {
        Section {
            TextField("Search TMDB", text: $query)
                .autocorrectionDisabled()
                .onSubmit { Task { await search() } }
            Button("Search") { Task { await search() } }
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
        } footer: {
            Text("Pick the right entry and it will be imported with the watch history the export recorded against the broken id.")
        }

        if isSearching {
            Section { HStack { ProgressView(); Text("Searching…").foregroundStyle(.secondary) } }
        }

        if let errorMessage {
            Section {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }

        if !results.isEmpty {
            Section("Matches") {
                ForEach(results, id: \.id) { result in
                    Button {
                        Task { await link(to: result.id) }
                    } label: {
                        HStack(spacing: 12) {
                            PosterView(path: result.posterPath, width: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.name).foregroundStyle(.primary)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - An episode TMDB doesn't list

    @ViewBuilder
    private func episodeSection(showTMDBID: Int, watchedAt: Date) -> some View {
        if let show = show(withTMDBID: showTMDBID) {
            Section {
                ForEach(show.orderedEpisodes.filter { !$0.isWatched }) { episode in
                    Button {
                        episode.setWatched(true, at: watchedAt)
                        try? modelContext.save()
                        onSettled()
                        dismiss()
                    } label: {
                        HStack {
                            Text("\(episode.code) · \(episode.name)")
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                }
            } header: {
                Text("Mark one of these watched instead")
            } footer: {
                Text("Only unwatched episodes are listed. The original watch date is kept.")
            }
        } else {
            Section {
                Text("That show isn't in your library any more.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func show(withTMDBID id: Int) -> Show? {
        let descriptor = FetchDescriptor<Show>(predicate: #Predicate { $0.tmdbID == id })
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: - Actions

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        do {
            results = try await LibraryImporter.candidates(
                for: item, query: trimmed, apiKey: apiKey
            )
            if results.isEmpty { errorMessage = "Nothing found for “\(trimmed)”." }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func link(to tmdbID: Int) async {
        do {
            try await LibraryImporter.resolve(
                item, toTMDBID: tmdbID, from: export, apiKey: apiKey, into: modelContext
            )
            onSettled()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
