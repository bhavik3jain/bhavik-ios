import SwiftData
import SwiftUI

struct WatchingListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Show.addedAt, order: .reverse) private var shows: [Show]
    @State private var showingAddShow = false

    private var grouped: [(ShowStatus, [Show])] {
        ShowStatus.allCases.compactMap { status in
            let matching = shows.filter { $0.status == status }
            return matching.isEmpty ? nil : (status, matching)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if shows.isEmpty {
                    ContentUnavailableView {
                        Label("No shows yet", systemImage: "tv")
                    } description: {
                        Text("Add a show to start tracking which episodes you've watched.")
                    } actions: {
                        Button("Add Show") { showingAddShow = true }
                            .buttonStyle(.borderedProminent)
                            .tint(TVTrackerModule.accent.color)
                    }
                } else {
                    List {
                        ForEach(grouped, id: \.0) { status, statusShows in
                            Section(status.displayName) {
                                ForEach(statusShows) { show in
                                    NavigationLink {
                                        ShowDetailView(show: show)
                                    } label: {
                                        ShowRow(show: show)
                                    }
                                }
                                .onDelete { offsets in
                                    for index in offsets {
                                        modelContext.delete(statusShows[index])
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Watching")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddShow = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddShow) {
                AddShowView()
            }
        }
    }
}

private struct ShowRow: View {
    let show: Show

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(show.name)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(show.watchedCount)/\(show.episodeCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if show.episodeCount > 0 {
                ProgressView(value: show.progress)
                    .tint(TVTrackerModule.accent.color)
            }

            if let next = show.nextUnwatched {
                Text(next.hasAired() ? "Next up: \(next.code)" : "Waiting on \(next.code)")
                    .font(.caption)
                    .foregroundStyle(next.hasAired() ? TVTrackerModule.accent.color : .secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
