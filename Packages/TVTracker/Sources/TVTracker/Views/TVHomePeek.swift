import Core
import SwiftUI

public extension TVTrackerModule {
    /// What long-pressing TV on the home screen shows: the backlog to catch up
    /// on, then what airs next.
    @MainActor
    static func homePeek(shows: [Show], asOf now: Date = .now) -> some View {
        TVHomePeek(
            ready: Schedule.readyToWatch(shows: shows, asOf: now),
            upcoming: Schedule.upcoming(shows: shows, asOf: now)
        )
    }
}

struct TVHomePeek: View {
    let ready: [ScheduledEpisode]
    let upcoming: [ScheduledEpisode]

    var body: some View {
        ModulePeekCard(
            accent: TVTrackerModule.accent,
            icon: "tv.fill",
            subtitle: ready.isEmpty ? "All caught up" : "\(counted(ready.count, "episode")) ready"
        ) {
            if ready.isEmpty && upcoming.isEmpty {
                PeekEmpty("Nothing to watch and nothing coming up.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    // Oldest first, so the top row is what to watch next.
                    ForEach(ready.prefix(3)) { episode in
                        PeekRow(episode.showName, detail: label(episode), value: "Ready", tint: TVTrackerModule.accent.color)
                    }
                    if !upcoming.isEmpty {
                        Text("Coming up")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .padding(.top, ready.isEmpty ? 0 : 2)
                        ForEach(upcoming.prefix(ready.isEmpty ? 4 : 2)) { episode in
                            PeekRow(
                                episode.showName,
                                detail: label(episode),
                                value: episode.airDate.map { $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) } ?? ""
                            )
                        }
                    }
                }
            }
        }
    }

    private func label(_ episode: ScheduledEpisode) -> String {
        episode.episodeName.isEmpty ? episode.code : "\(episode.code) · \(episode.episodeName)"
    }
}
