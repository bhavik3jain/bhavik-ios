import Core // Only reached on macOS, where Core stands in for the iOS-only SwiftUI API below.
import SwiftData
import SwiftUI

/// One episode's own screen: its still, what it's about, when it aired, who
/// made it and who's in it, and whether you've seen it. A row in a show's list
/// could only be ticked, so there was nowhere to read what an episode was.
struct EpisodeDetailView: View {
    @Bindable var episode: Episode
    @SyncedSecret(TVTrackerModule.apiKeyDefaultsKey) private var apiKey
    /// Read from TMDB each time, like a movie's details, so none of it syncs;
    /// nil until it arrives, with no key, or for an episode added by hand.
    @State private var details: TMDBEpisodeDetails?

    var body: some View {
        List {
            if let still = stillURL {
                Section {
                    AsyncImage(url: still) { image in
                        image.resizable().aspectRatio(16 / 9, contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(.quaternary).aspectRatio(16 / 9, contentMode: .fit)
                    }
                    .clipShape(.rect(cornerRadius: 10))
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title3)
                        .fontWeight(.semibold)
                    if let show = episode.show {
                        Text("\(show.name) · \(episode.code)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !facts.isEmpty {
                        Text(facts)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let details, details.voteCount > 0, details.rating > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                            Text(details.rating.formatted(.number.precision(.fractionLength(1))) + " / 10")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                if episode.hasAired() || episode.isWatched {
                    Button {
                        episode.toggleWatched()
                        episode.show?.refreshStatus()
                    } label: {
                        Label(
                            episode.isWatched ? "Watched" : "Mark Watched",
                            systemImage: episode.isWatched ? "checkmark.circle.fill" : "circle"
                        )
                    }
                    .tint(TVTrackerModule.accent.color)
                    if let watchedAt = episode.watchedAt {
                        LabeledContent("Watched on", value: watchedAt.formatted(date: .abbreviated, time: .omitted))
                    }
                }
            }

            if let overview = details?.overview, !overview.isEmpty {
                Section("Overview") {
                    Text(overview)
                        .font(.callout)
                }
            }

            if let details, !details.directors.isEmpty || !details.writers.isEmpty {
                Section("Credits") {
                    if !details.directors.isEmpty {
                        LabeledContent("Directed by", value: details.directors.joined(separator: ", "))
                    }
                    if !details.writers.isEmpty {
                        LabeledContent("Written by", value: details.writers.joined(separator: ", "))
                    }
                }
            }

            if let details, !details.guestStars.isEmpty {
                Section {
                    ForEach(details.guestStars.prefix(12)) { guest in
                        LabeledContent(guest.name, value: guest.character)
                    }
                } header: {
                    Text("Guest stars")
                } footer: {
                    Text(TMDBClient.attribution)
                }
            } else if details != nil {
                Section {
                } footer: {
                    // Attribution goes last on the screen, under whatever's last.
                    Text(TMDBClient.attribution)
                }
            }
        }
        .navigationTitle(episode.code)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: episode.persistentModelID) { await loadDetails() }
    }

    private var title: String {
        if !episode.name.isEmpty { return episode.name }
        if let name = details?.name, !name.isEmpty { return name }
        return "Episode \(episode.episodeNumber)"
    }

    private var stillURL: URL? {
        guard let path = details?.stillPath, !path.isEmpty else { return nil }
        return URL(string: TMDBClient.stillBaseURL + path)
    }

    /// "Aired Mar 4, 2024 · 52 min", or whichever of those is known.
    private var facts: String {
        var parts: [String] = []
        if let airDate = episode.airDate ?? details?.airDate {
            let date = airDate.formatted(.dateTime.month(.abbreviated).day().year())
            parts.append(airDate <= .now ? "Aired \(date)" : "Airs \(date)")
        } else {
            parts.append("No air date")
        }
        if let runtime = details?.runtime, runtime > 0 {
            parts.append(Duration.seconds(runtime * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
        }
        return parts.joined(separator: " · ")
    }

    private func loadDetails() async {
        // An episode or show added by hand has no TMDB id to look up.
        guard let showID = episode.show?.tmdbID, showID > 0, !apiKey.isEmpty else { return }
        guard let fetched = try? await TMDBClient(apiKey: apiKey).episodeDetails(
            showID: showID, season: episode.seasonNumber, episode: episode.episodeNumber
        ) else { return }
        details = fetched
        // Fill in what TMDB didn't know when the show was added, without
        // overwriting: a title or an air date that arrived later.
        if episode.name.isEmpty, !fetched.name.isEmpty { episode.name = fetched.name }
        if episode.airDate == nil, let airDate = fetched.airDate { episode.airDate = airDate }
    }
}
