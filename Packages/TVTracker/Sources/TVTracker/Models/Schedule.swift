import Foundation

public struct ScheduledEpisode: Identifiable, Sendable {
    public let id: PersistentEpisodeID
    public let showName: String
    public let code: String
    public let episodeName: String
    public let airDate: Date?

    public struct PersistentEpisodeID: Hashable, Sendable {
        let showName: String
        let code: String
    }
}

public enum Schedule {
    /// Episodes that have aired but are still unwatched, oldest first — the
    /// backlog to catch up on.
    public static func readyToWatch(shows: [Show], asOf now: Date = .now) -> [ScheduledEpisode] {
        shows
            .filter { $0.status == .watching }
            .flatMap { show in
                show.unwatchedAired(asOf: now).map { episode in
                    ScheduledEpisode(
                        id: .init(showName: show.name, code: episode.code),
                        showName: show.name,
                        code: episode.code,
                        episodeName: episode.name,
                        airDate: episode.airDate
                    )
                }
            }
            .sorted { ($0.airDate ?? .distantPast) < ($1.airDate ?? .distantPast) }
    }

    /// The next episode still to air for each show being watched, soonest first.
    public static func upcoming(shows: [Show], asOf now: Date = .now) -> [ScheduledEpisode] {
        shows
            .filter { $0.status == .watching }
            .compactMap { show -> ScheduledEpisode? in
                guard let episode = show.nextToAir(asOf: now) else { return nil }
                return ScheduledEpisode(
                    id: .init(showName: show.name, code: episode.code),
                    showName: show.name,
                    code: episode.code,
                    episodeName: episode.name,
                    airDate: episode.airDate
                )
            }
            .sorted { ($0.airDate ?? .distantFuture) < ($1.airDate ?? .distantFuture) }
    }
}
