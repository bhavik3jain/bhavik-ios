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

    @State private var scope: Scope = .shows
    @State private var query = ""
    @State private var results: [Candidate] = []
    @State private var isBusy = false
    @State private var errorMessage: String?
    /// The show whose episodes are being browsed, once one has been picked from
    /// the results.
    @State private var drilled: Candidate?
    @State private var drilledEpisodes: [TMDBEpisode] = []
    /// Narrows the show's own episode list, which runs to hundreds for anything
    /// long-running.
    @State private var quickFilter = ""

    private enum Scope: String, CaseIterable {
        case shows = "Shows"
        case movies = "Movies"
    }

    private struct Candidate: Identifiable, Hashable {
        let id: Int
        let name: String
        let subtitle: String
        let posterPath: String
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(item.displayName).font(.headline)
                    Text(item.detail).font(.subheadline).foregroundStyle(.secondary)
                }

                if let drilled {
                    drilledEpisodeSection(for: drilled)
                } else {
                    if case let .episode(showTMDBID, _, _, _, _) = item {
                        quickPickSection(showTMDBID: showTMDBID)
                    }
                    searchSection
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
            .navigationTitle(drilled == nil ? "Resolve" : "Pick Episode")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(drilled == nil ? "Cancel" : "Back") {
                        if drilled == nil { dismiss() } else { drilled = nil; drilledEpisodes = [] }
                    }
                }
            }
            .onAppear {
                // A film that failed to import should search films by default.
                if case let .title(name, _, isShow) = item {
                    scope = isShow ? .shows : .movies
                    query = name
                }
            }
        }
    }

    // MARK: - The show's own episodes

    @ViewBuilder
    private func quickPickSection(showTMDBID: Int) -> some View {
        if let show = localShow(tmdbID: showTMDBID) {
            let unwatched = show.orderedEpisodes.filter { !$0.isWatched }
            let shown = quickFilter.isEmpty
                ? unwatched
                : unwatched.filter {
                    $0.name.localizedCaseInsensitiveContains(quickFilter)
                        || $0.code.localizedCaseInsensitiveContains(quickFilter)
                }

            Section {
                if unwatched.count > 8 {
                    TextField("Filter episodes", text: $quickFilter)
                        .autocorrectionDisabled()
                }
                ForEach(shown.prefix(40)) { episode in
                    Button {
                        markLocal(episode)
                    } label: {
                        Text("\(episode.code) · \(episode.name)")
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
                if shown.count > 40 {
                    Text("…and \(shown.count - 40) more. Filter to narrow it down.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("In \(show.name)")
            } footer: {
                Text("Only unwatched episodes are listed. The original watch date is kept.")
            }
        }
    }

    // MARK: - Searching anything else

    @ViewBuilder
    private var searchSection: some View {
        Section {
            Picker("Look for", selection: $scope) {
                ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: scope) { _, _ in results = [] }

            TextField(scope == .shows ? "Search shows" : "Search films", text: $query)
                .autocorrectionDisabled()
                .onSubmit { Task { await search() } }

            Button("Search") { Task { await search() } }
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
        } header: {
            Text("Find it on TMDB")
        } footer: {
            Text(searchFooter)
        }

        if isBusy {
            Section { HStack { ProgressView(); Text("Working…").foregroundStyle(.secondary) } }
        }

        if let errorMessage {
            Section {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }

        if !results.isEmpty {
            Section("Matches") {
                ForEach(results) { candidate in
                    Button {
                        Task { await choose(candidate) }
                    } label: {
                        HStack(spacing: 12) {
                            PosterView(path: candidate.posterPath, width: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.name).foregroundStyle(.primary)
                                if !candidate.subtitle.isEmpty {
                                    Text(candidate.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if scope == .shows, isEpisodeItem {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var searchFooter: String {
        switch item {
        case .episode:
            scope == .shows
                ? "Pick any show to browse its episodes — useful when the watch belongs to a different show entirely."
                : "Pick a film if this watch was actually a film."
        case .title:
            "Pick the right entry and it will be imported with the watch history the export recorded against the broken id."
        }
    }

    private var isEpisodeItem: Bool {
        if case .episode = item { return true }
        return false
    }

    // MARK: - Episodes of a searched show

    @ViewBuilder
    private func drilledEpisodeSection(for show: Candidate) -> some View {
        Section {
            if drilledEpisodes.isEmpty {
                HStack { ProgressView(); Text("Loading episodes…").foregroundStyle(.secondary) }
            } else {
                TextField("Filter episodes", text: $quickFilter)
                    .autocorrectionDisabled()
                ForEach(filteredDrilled.prefix(40), id: \.id) { episode in
                    Button {
                        Task { await link(episode, ofShow: show) }
                    } label: {
                        Text("S\(String(format: "%02d", episode.seasonNumber))E\(String(format: "%02d", episode.episodeNumber)) · \(episode.name)")
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
                if filteredDrilled.count > 40 {
                    Text("…and \(filteredDrilled.count - 40) more. Filter to narrow it down.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(show.name)
        }
    }

    /// Numbered seasons first, specials after. TMDB returns season 0 first,
    /// which buries S01E01 under a pile of outtakes and deleted scenes.
    private var orderedDrilled: [TMDBEpisode] {
        drilledEpisodes.sorted { a, b in
            if (a.seasonNumber == 0) != (b.seasonNumber == 0) { return b.seasonNumber == 0 }
            if a.seasonNumber != b.seasonNumber { return a.seasonNumber < b.seasonNumber }
            return a.episodeNumber < b.episodeNumber
        }
    }

    private var filteredDrilled: [TMDBEpisode] {
        guard !quickFilter.isEmpty else { return orderedDrilled }
        return orderedDrilled.filter {
            $0.name.localizedCaseInsensitiveContains(quickFilter)
                || "S\(String(format: "%02d", $0.seasonNumber))E\(String(format: "%02d", $0.episodeNumber))"
                    .localizedCaseInsensitiveContains(quickFilter)
        }
    }

    // MARK: - Actions

    private func localShow(tmdbID: Int) -> Show? {
        let descriptor = FetchDescriptor<Show>(predicate: #Predicate { $0.tmdbID == tmdbID })
        return try? modelContext.fetch(descriptor).first
    }

    private func markLocal(_ episode: Episode) {
        guard case let .episode(_, _, _, _, watchedAt) = item else { return }
        episode.setWatched(true, at: watchedAt)
        episode.show?.refreshStatus()
        try? modelContext.save()
        onSettled()
        dismiss()
    }

    private func search() async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            let found = try await LibraryImporter.search(
                query, movies: scope == .movies, apiKey: apiKey
            )
            results = found.map { Candidate(id: $0.id, name: $0.name, subtitle: $0.subtitle, posterPath: $0.posterPath) }
            if results.isEmpty { errorMessage = "Nothing found for “\(query)”." }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func choose(_ candidate: Candidate) async {
        errorMessage = nil

        switch item {
        case let .episode(_, _, _, _, watchedAt):
            if scope == .movies {
                await run {
                    try await LibraryImporter.markMovieWatched(
                        tmdbID: candidate.id, title: candidate.name,
                        watchedAt: watchedAt, apiKey: apiKey, into: modelContext
                    )
                }
            } else {
                // Browse its episodes rather than guessing which one was meant.
                drilled = candidate
                quickFilter = ""
                isBusy = true
                defer { isBusy = false }
                do {
                    drilledEpisodes = try await LibraryImporter.episodes(
                        ofShow: candidate.id, apiKey: apiKey
                    )
                } catch {
                    errorMessage = error.localizedDescription
                    drilled = nil
                }
            }

        case .title:
            await run {
                try await LibraryImporter.resolve(
                    item, toTMDBID: candidate.id, from: export,
                    apiKey: apiKey, into: modelContext
                )
            }
        }
    }

    private func link(_ episode: TMDBEpisode, ofShow show: Candidate) async {
        guard case let .episode(_, _, _, _, watchedAt) = item else { return }
        await run {
            try await LibraryImporter.markEpisodeWatched(
                showTMDBID: show.id,
                showName: show.name,
                seasonNumber: episode.seasonNumber,
                episodeNumber: episode.episodeNumber,
                watchedAt: watchedAt,
                apiKey: apiKey,
                into: modelContext
            )
        }
    }

    private func run(_ work: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await work()
            onSettled()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
