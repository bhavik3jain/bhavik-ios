import SwiftData
import SwiftUI

struct TVStatsView: View {
    @Query private var shows: [Show]

    private var watchedEpisodes: [Episode] {
        shows.flatMap { $0.episodes ?? [] }.filter(\.isWatched)
    }

    private var completedShows: Int {
        shows.count { $0.status == .completed }
    }

    private var watchedThisYear: Int {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: .now)
        return watchedEpisodes.count { episode in
            guard let watchedAt = episode.watchedAt else { return false }
            return calendar.component(.year, from: watchedAt) == year
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Tile(value: "\(watchedEpisodes.count)", label: "Episodes")
                        Tile(value: "\(completedShows)", label: "Completed")
                        Tile(value: "\(watchedThisYear)", label: "This year")
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 8)
                }

                if !shows.isEmpty {
                    Section("Progress") {
                        ForEach(shows.sorted { $0.progress > $1.progress }) { show in
                            HStack {
                                Text(show.name)
                                    .font(.subheadline)
                                Spacer()
                                Text("\(show.watchedCount)/\(show.episodeCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                Section {
                    NavigationLink {
                        TVSettingsView()
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                } footer: {
                    Text(TMDBClient.attribution)
                        .font(.caption2)
                }
            }
            .navigationTitle("Stats")
        }
    }
}

private struct Tile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(TVTrackerModule.accent.color)
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 14))
    }
}
