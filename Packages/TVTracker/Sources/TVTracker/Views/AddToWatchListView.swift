import Core
import CoreData
import SwiftUI

/// Adds shows and films to a watch list: from a TMDB search with this
/// person's own key, or typed by hand without one. Stays open, so a few can
/// go on in a row; a title already on the list says so rather than going on
/// twice.
struct AddToWatchListView: View {
    @ObservedObject var list: SharedWatchList

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @SyncedSecret(TVTrackerModule.apiKeyDefaultsKey) private var apiKey

    @State private var kind: WatchListMediaType = .show
    @State private var query = ""
    @State private var results: [WatchListTitle] = []
    @State private var isSearching = false
    @State private var notice: Notice?
    @State private var showingSettings = false

    private enum Notice: Equatable {
        case added(String)
        case alreadyOnList(String)
        case problem(String)
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var onList: [WatchListTitle] { list.allItems.filter { !$0.isDeleted }.map(\.watchListTitle) }

    var body: some View {
        SheetStack {
            List {
                Section {
                    Picker("Kind", selection: $kind) {
                        Text("Shows").tag(WatchListMediaType.show)
                        Text("Films").tag(WatchListMediaType.movie)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                if apiKey.isEmpty {
                    Section {
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Add a TMDB API key to search", systemImage: "key")
                        }
                    } footer: {
                        Text("Without a key you can still type a title in the search field and add it by hand.")
                    }
                }

                if let notice {
                    Section {
                        noticeLabel(notice)
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

                let onList = onList
                ForEach(results) { result in
                    let isOnList = WatchListDuplicates.firstMatch(for: result, in: onList) != nil
                    Button {
                        add(result)
                    } label: {
                        HStack(spacing: 12) {
                            PosterView(path: result.posterPath, width: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title)
                                    .foregroundStyle(.primary)
                                if let year = result.year {
                                    Text(String(year))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: isOnList ? "checkmark.circle.fill" : "plus.circle")
                                .foregroundStyle(isOnList ? TVTrackerModule.accent.color : .secondary)
                                .accessibilityLabel(isOnList ? "On the list" : "Add")
                        }
                    }
                }

                Section {
                    Button {
                        add(WatchListTitle(mediaType: kind, title: trimmedQuery))
                    } label: {
                        Label(
                            trimmedQuery.isEmpty
                                ? "Type a title to add it by hand"
                                : "Add “\(trimmedQuery)” as a \(kind == .show ? "show" : "film")",
                            systemImage: "square.and.pencil"
                        )
                    }
                    .disabled(trimmedQuery.isEmpty)
                }
            }
            .searchable(text: $query, prompt: kind == .show ? "Search shows" : "Search films")
            .onSubmit(of: .search) {
                Task { await search() }
            }
            .onChange(of: kind) {
                results = []
                notice = nil
                if !trimmedQuery.isEmpty { Task { await search() } }
            }
            .navigationTitle("Add to \(list.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showingSettings) {
                SheetStack { TVSettingsView() }
            }
        }
    }

    @ViewBuilder
    private func noticeLabel(_ notice: Notice) -> some View {
        switch notice {
        case .added(let text):
            Label(text, systemImage: "checkmark.circle")
                .foregroundStyle(TVTrackerModule.accent.color)
        case .alreadyOnList(let text):
            Label(text, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        case .problem(let text):
            Label(text, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private func search() async {
        notice = nil
        // No key: the search field is just where a title is typed.
        guard !apiKey.isEmpty, !trimmedQuery.isEmpty else {
            results = []
            return
        }
        let searchedKind = kind
        let text = trimmedQuery
        isSearching = true
        defer { isSearching = false }
        do {
            let client = TMDBClient(apiKey: apiKey)
            let found: [WatchListTitle] = switch searchedKind {
            case .show: try await client.searchShows(query: text).map(WatchListTitle.init(show:))
            case .movie: try await client.searchMovies(query: text).map(WatchListTitle.init(movie:))
            }
            // Switched to the other kind while this was on its way.
            guard searchedKind == kind else { return }
            results = found
            if found.isEmpty {
                notice = .problem("No \(searchedKind == .show ? "shows" : "films") matched “\(text)”.")
            }
        } catch {
            notice = .problem(error.localizedDescription)
        }
    }

    private func add(_ title: WatchListTitle) {
        guard !list.isDeleted, list.managedObjectContext != nil else { return }
        switch list.add(title, addedByName: WatchListAuthorship.currentUserName(for: list)) {
        case .added(let item):
            do {
                try context.saveIfNeeded()
                notice = .added("Added \(item.title) to \(list.displayName).")
            } catch {
                context.rollback()
                notice = .problem("Couldn't add \(title.title): \(error.localizedDescription)")
            }
        case .alreadyOnList(let item):
            notice = .alreadyOnList("\(item.title) is already on \(list.displayName).")
        }
    }
}
