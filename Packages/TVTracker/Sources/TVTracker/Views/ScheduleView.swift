import Core
import SwiftData
import SwiftUI

struct ScheduleView: View {
    // The unwatched episodes in one fetch rather than each show's
    // `episodes`, whose faults cost a SQLite round trip apiece — see
    // `Schedule`.
    @Query(filter: Schedule.unwatched) private var episodes: [Episode]
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var alerts = EpisodeAlertStore.shared

    private var ready: [ScheduledEpisode] { Schedule.readyToWatch(episodes: episodes) }
    private var upcoming: [ScheduledEpisode] { Schedule.upcoming(episodes: episodes) }

    var body: some View {
        NavigationStack {
            Group {
                if ready.isEmpty && upcoming.isEmpty {
                    ContentUnavailableView(
                        "Nothing queued",
                        systemImage: "calendar",
                        description: Text("Episodes you haven't watched yet, and the next ones due to air, show up here.")
                    )
                    // So the pull below reaches it: a new season is exactly
                    // what an empty Up Next is waiting for.
                    .scrollsForRefresh()
                } else {
                    List {
                        if !upcoming.isEmpty, !alerts.preferences.isEnabled, !alerts.preferences.hasDismissedOffer {
                            Section {
                                EpisodeAlertOfferCard()
                            }
                        }

                        if !ready.isEmpty {
                            Section {
                                ForEach(ready) { item in
                                    ScheduleRow(item: item, isAired: true)
                                }
                            } header: {
                                Text("Ready to watch")
                            } footer: {
                                Text("^[\(ready.count) episode](inflect: true) aired and waiting.")
                            }
                        }

                        if !upcoming.isEmpty {
                            Section("Coming up") {
                                ForEach(upcoming) { item in
                                    ScheduleRow(item: item, isAired: false)
                                }
                            }
                        }
                    }
                }
            }
            // Newly announced episodes and moved air dates from TMDB, for the
            // shows due a look (`TVEpisodeRefresher`), then the alerts.
            .refreshable { await TVEpisodeAlerts.refreshAndReschedule(context: modelContext) }
            .navigationTitle("Up Next")
        }
    }
}

private struct ScheduleRow: View {
    let item: ScheduledEpisode
    let isAired: Bool

    var body: some View {
        HStack(spacing: 12) {
            PosterView(path: item.posterPath, width: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.showName)
                    .fontWeight(.semibold)
                Text("\(item.code)\(item.episodeName.isEmpty ? "" : " · \(item.episodeName)")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let airDate = item.airDate {
                Text(airDate, format: .dateTime.month().day())
                    .font(.caption)
                    .foregroundStyle(isAired ? TVTrackerModule.accent.color : .secondary)
                    .monospacedDigit()
            }
        }
    }
}
