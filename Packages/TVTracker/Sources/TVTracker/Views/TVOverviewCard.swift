import Core
import SwiftUI

public extension TVTrackerModule {
    /// The Mac Overview's TV card: the backlog, with the posters of what to
    /// watch next.
    ///
    /// `episodes` is the unwatched episodes, fetched in one query
    /// (`Schedule.unwatched`) — see `Schedule` for why not `show.episodes`.
    @MainActor
    static func overviewCard(shows: [Show], episodes: [Episode], asOf now: Date = .now, open: @escaping () -> Void) -> some View {
        // Counted per show, not listed per episode: the list cost over half
        // the main thread at launch — see `Schedule.backlog`. Both halves in
        // one pass — see `Schedule.glance`.
        let glance = Schedule.glance(episodes: episodes, asOf: now)
        return TVOverviewCard(
            backlog: glance.backlog,
            upcoming: glance.upcoming,
            hasShows: !shows.isEmpty,
            open: open
        )
    }
}

struct TVOverviewCard: View {
    let backlog: Backlog
    let upcoming: [ScheduledEpisode]
    let hasShows: Bool
    let open: () -> Void

    /// One poster per show, oldest-waiting first, so three episodes of the same
    /// show don't fill the row with the same artwork. Caught up, the shows
    /// airing next instead.
    ///
    /// De-duplicated by name in both cases, since the ForEach below is keyed
    /// on it: the backlog is grouped per `Show` record, and with no unique
    /// constraint under CloudKit two devices adding the same show make two
    /// records of one name — a duplicate ForEach ID, which SwiftUI draws
    /// unpredictably.
    private var posters: [(name: String, path: String)] {
        let all = backlog.isEmpty
            ? upcoming.map { (name: $0.showName, path: $0.posterPath) }
            : backlog.shows.map { (name: $0.showName, path: $0.posterPath) }
        var seen = Set<String>()
        return all.filter { seen.insert($0.name).inserted }
    }

    /// "From 6 shows", or — caught up — what airs next.
    private var caption: String {
        if !backlog.isEmpty {
            return "From \(counted(backlog.shows.count, "show"))"
        }
        guard let next = upcoming.first else { return "Nothing new on the schedule" }
        let when = next.airDate.map { " · \($0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))" } ?? ""
        return "Next: \(next.showName)\(when)"
    }

    var body: some View {
        OverviewCard(accent: TVTrackerModule.accent, icon: TVTrackerModule.symbolName, open: open) {
            if !hasShows {
                OverviewEmptyState("No shows yet", message: "Add one from Watching.")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if backlog.isEmpty {
                        OverviewValue("All caught up")
                    } else {
                        OverviewValue(
                            String(backlog.episodeCount),
                            unit: backlog.episodeCount == 1 ? "episode ready" : "episodes ready"
                        )
                    }
                    OverviewCaption(caption)
                    Spacer(minLength: 8)
                    HStack(spacing: 8) {
                        ForEach(posters.prefix(5), id: \.name) { poster in
                            PosterView(path: poster.path, width: 40)
                                .accessibilityLabel(poster.name)
                                .help(poster.name)
                        }
                    }
                }
            }
        }
    }
}
