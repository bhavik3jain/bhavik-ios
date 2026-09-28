import Core // Only reached on macOS, where Core stands in for the iOS-only SwiftUI API below.
import SwiftData
import SwiftUI

struct ShowDetailView: View {
    @Bindable var show: Show
    @Environment(\.modelContext) private var modelContext
    @State private var showingAddEpisode = false

    private var seasons: [(season: Int, episodes: [Episode])] {
        Dictionary(grouping: show.orderedEpisodes, by: \.seasonNumber)
            .map { (season: $0.key, episodes: $0.value.sorted { $0.episodeNumber < $1.episodeNumber }) }
            .sorted { $0.season < $1.season }
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    PosterView(path: show.posterPath, width: 76)

                    VStack(alignment: .leading, spacing: 8) {
                        if show.episodeCount > 0 {
                            HStack {
                                Text("\(show.watchedCount) of \(show.episodeCount) watched")
                                    .font(.subheadline)
                                Spacer()
                                Text(show.progress, format: .percent.precision(.fractionLength(0)))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            ProgressView(value: show.progress)
                                .tint(TVTrackerModule.accent.color)
                        }

                        if !show.overview.isEmpty {
                            Text(show.overview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                    }
                }
                .padding(.vertical, 4)

                Picker("Status", selection: $show.statusRaw) {
                    ForEach(ShowStatus.allCases, id: \.rawValue) { status in
                        Text(status.displayName).tag(status.rawValue)
                    }
                }
            }

            if let next = show.nextUnwatched, next.hasAired() {
                Section {
                    Button {
                        next.setWatched(true)
                        show.refreshStatus()
                    } label: {
                        Label("Mark \(next.code) watched", systemImage: "checkmark.circle")
                    }
                    .tint(TVTrackerModule.accent.color)
                }
            }

            ForEach(seasons, id: \.season) { season, episodes in
                Section("Season \(season)") {
                    ForEach(episodes) { episode in
                        EpisodeRow(episode: episode)
                    }
                }
            }

            Section {
                Button {
                    showingAddEpisode = true
                } label: {
                    Label("Add Episode", systemImage: "plus")
                }
            } footer: {
                if show.episodeCount == 0 {
                    Text("Add episodes by hand, or search TMDB when adding a show to pull the full episode list.")
                }
            }
        }
        .navigationTitle(show.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAddEpisode) {
            AddEpisodeView(show: show)
        }
    }
}

private struct EpisodeRow: View {
    @Bindable var episode: Episode

    var body: some View {
        Button {
            episode.setWatched(!episode.isWatched)
            // Ticking the first episode should stop the show claiming you
            // haven't started it, and unticking the last should stop it
            // claiming you finished.
            episode.show?.refreshStatus()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: episode.isWatched ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(episode.isWatched ? TVTrackerModule.accent.color : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(episode.code)\(episode.name.isEmpty ? "" : " · \(episode.name)")")
                        .foregroundStyle(.primary)
                        .font(.subheadline)
                    if let airDate = episode.airDate {
                        Text(episode.hasAired()
                             ? airDate.formatted(.dateTime.month().day().year())
                             : "Airs \(airDate.formatted(.dateTime.month().day().year()))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No air date")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
        }
        .buttonStyle(.plain)
        .disabled(!episode.hasAired() && !episode.isWatched)
        .opacity(episode.hasAired() || episode.isWatched ? 1 : 0.5)
    }
}

private struct AddEpisodeView: View {
    let show: Show
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var seasonNumber = 1
    @State private var episodeNumber = 1
    @State private var name = ""
    @State private var hasAirDate = false
    @State private var airDate = Date.now

    var body: some View {
        SheetStack {
            Form {
                Stepper("Season \(seasonNumber)", value: $seasonNumber, in: 1...50)
                Stepper("Episode \(episodeNumber)", value: $episodeNumber, in: 1...200)
                TextField("Title (optional)", text: $name)
                Toggle("Has air date", isOn: $hasAirDate)
                if hasAirDate {
                    DatePicker("Air date", selection: $airDate, displayedComponents: .date)
                }
            }
            .navigationTitle("Add Episode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let episode = Episode(
                            name: name,
                            seasonNumber: seasonNumber,
                            episodeNumber: episodeNumber,
                            airDate: hasAirDate ? airDate : nil
                        )
                        episode.show = show
                        modelContext.insert(episode)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
