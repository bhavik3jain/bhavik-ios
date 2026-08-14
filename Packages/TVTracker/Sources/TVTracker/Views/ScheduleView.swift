import SwiftData
import SwiftUI

struct ScheduleView: View {
    @Query private var shows: [Show]

    private var ready: [ScheduledEpisode] { Schedule.readyToWatch(shows: shows) }
    private var upcoming: [ScheduledEpisode] { Schedule.upcoming(shows: shows) }

    var body: some View {
        NavigationStack {
            Group {
                if ready.isEmpty && upcoming.isEmpty {
                    ContentUnavailableView(
                        "Nothing queued",
                        systemImage: "calendar",
                        description: Text("Episodes you haven't watched yet, and the next ones due to air, show up here.")
                    )
                } else {
                    List {
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
