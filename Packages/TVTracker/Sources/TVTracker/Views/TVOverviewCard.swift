import Core
import SwiftUI

public extension TVTrackerModule {
    /// The Mac Overview's TV card: the backlog, with the posters of what to
    /// watch next.
    @MainActor
    static func overviewCard(shows: [Show], asOf now: Date = .now, open: @escaping () -> Void) -> some View {
        TVOverviewCard(
            ready: Schedule.readyToWatch(shows: shows, asOf: now),
            upcoming: Schedule.upcoming(shows: shows, asOf: now),
            hasShows: !shows.isEmpty,
            open: open
        )
    }
}

struct TVOverviewCard: View {
    let ready: [ScheduledEpisode]
    let upcoming: [ScheduledEpisode]
    let hasShows: Bool
    let open: () -> Void

    private var headline: String {
        if !ready.isEmpty { return "\(counted(ready.count, "episode")) ready" }
        return hasShows ? "All caught up" : "No shows yet"
    }

    /// One poster per show, oldest-waiting first, so three episodes of the same
    /// show don't fill the row with the same artwork.
    private var posters: [ScheduledEpisode] {
        var seen = Set<String>()
        return (ready.isEmpty ? upcoming : ready).filter { seen.insert($0.showName).inserted }
    }

    var body: some View {
        OverviewCard(accent: TVTrackerModule.accent, icon: TVTrackerModule.symbolName, open: open) {
            VStack(alignment: .leading, spacing: 8) {
                OverviewValue(headline)
                if ready.isEmpty, let next = upcoming.first {
                    Text("Next: \(next.showName)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                HStack(spacing: 8) {
                    ForEach(posters.prefix(4)) { episode in
                        PosterView(path: episode.posterPath, width: 44)
                            .accessibilityLabel(episode.showName)
                    }
                }
            }
        }
    }
}
