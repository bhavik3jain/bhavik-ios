import Core
import Foundation

/// Which "new episode is out today" notifications to have pending, worked
/// out from plain values so it can be tested without a notification center.
///
/// For each show being watched and not muted, its unwatched episodes airing
/// in the next `horizonDays`, at the chosen time on the air date — one
/// notification per show per day, however many episodes drop at once (a
/// streaming service's whole season would otherwise be ten banners at 9:00).
/// Soonest first, and no more than `maximumAlerts`: iOS keeps only an app's
/// 64 soonest pending requests and silently drops the rest, and Finance's
/// twelve month-start reminders share that allowance.
public enum EpisodeAlertPlanner {
    public static let horizonDays = 21
    public static let maximumAlerts = 40
    /// Every request's identifier starts with this, so a reschedule clears
    /// exactly these and nothing else (Finance's are `finance.monthStart.`).
    public static let identifierPrefix = "tv.newEpisode."

    public struct ShowInput: Sendable {
        public let tmdbID: Int
        public let name: String
        public let status: ShowStatus
        public let episodes: [EpisodeInput]

        public init(tmdbID: Int, name: String, status: ShowStatus, episodes: [EpisodeInput]) {
            self.tmdbID = tmdbID
            self.name = name
            self.status = status
            self.episodes = episodes
        }
    }

    public struct EpisodeInput: Sendable {
        public let season: Int
        public let number: Int
        public let name: String
        public let airDate: Date?
        public let isWatched: Bool

        public init(season: Int, number: Int, name: String, airDate: Date?, isWatched: Bool = false) {
            self.season = season
            self.number = number
            self.name = name
            self.airDate = airDate
            self.isWatched = isWatched
        }

        public var code: String {
            "S\(Episode.twoDigits(season))E\(Episode.twoDigits(number))"
        }
    }

    public struct Alert: Equatable, Sendable {
        public let identifier: String
        /// The show's `EpisodeAlertPreferences.muteKey`.
        public let showKey: String
        public let showName: String
        /// The air date's calendar day.
        public let day: DateComponents
        /// `day` at the chosen time — what the calendar trigger matches.
        public let fireComponents: DateComponents
        /// `fireComponents` in this device's calendar, for ordering.
        public let fireDate: Date
        public let title: String
        public let body: String
        public let episodeCodes: [String]
    }

    public static func plan(
        shows: [ShowInput],
        preferences: EpisodeAlertPreferences,
        asOf now: Date = .now,
        calendar: Calendar = .current
    ) -> [Alert] {
        let today = calendar.startOfDay(for: now)
        guard let horizon = calendar.date(byAdding: .day, value: horizonDays, to: today) else { return [] }
        let hour = preferences.minuteOfDay / 60
        let minute = preferences.minuteOfDay % 60

        var alerts: [Alert] = []
        for show in shows where show.status == .watching {
            let key = EpisodeAlertPreferences.muteKey(tmdbID: show.tmdbID, name: show.name)
            guard !preferences.mutedShows.contains(key) else { continue }

            var byDay: [DayKey: (day: DateComponents, fire: DateComponents, date: Date, episodes: [EpisodeInput])] = [:]
            // Specials are left out, as they are from a show's progress:
            // TMDB files trailers and recaps under season 0.
            for episode in show.episodes where !episode.isWatched && episode.season > 0 {
                guard let airDate = episode.airDate else { continue }
                let day = airDay(of: airDate, calendar: calendar)
                guard let dayStart = calendar.date(from: day), dayStart < horizon else { continue }
                var fire = day
                fire.hour = hour
                fire.minute = minute
                // Past times are skipped: an episode out today is only
                // announced if the chosen time hasn't gone by yet.
                guard let fireDate = calendar.date(from: fire), fireDate > now else { continue }
                let dayKey = DayKey(day)
                byDay[dayKey, default: (day, fire, fireDate, [])].episodes.append(episode)
            }

            for (dayKey, entry) in byDay {
                let episodes = entry.episodes.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
                alerts.append(Alert(
                    identifier: identifierPrefix + key + "." + dayKey.text,
                    showKey: key,
                    showName: show.name,
                    day: entry.day,
                    fireComponents: entry.fire,
                    fireDate: entry.date,
                    title: show.name,
                    body: body(showName: show.name, episodes: episodes),
                    episodeCodes: episodes.map(\.code)
                ))
            }
        }
        return Array(
            alerts
                .sorted { ($0.fireDate, $0.showName, $0.identifier) < ($1.fireDate, $1.showName, $1.identifier) }
                .prefix(maximumAlerts)
        )
    }

    /// "S02E05 “Trojan's Horse” is out today." for one episode, or "3 new
    /// episodes of The Bear are out today: S03E01–E03." for several.
    static func body(showName: String, episodes: [EpisodeInput]) -> String {
        guard episodes.count > 1 else {
            guard let episode = episodes.first else { return "" }
            let title = episode.name.isEmpty ? "" : " \u{201C}\(episode.name)\u{201D}"
            return "\(episode.code)\(title) is out today."
        }
        return "\(counted(episodes.count, "new episode")) of \(showName) are out today: \(codes(episodes))."
    }

    /// "S03E01–E03" for a run within one season, otherwise each code.
    static func codes(_ episodes: [EpisodeInput]) -> String {
        guard let first = episodes.first, let last = episodes.last else { return "" }
        let isRun = episodes.allSatisfy { $0.season == first.season }
            && zip(episodes, episodes.dropFirst()).allSatisfy { $1.number == $0.number + 1 }
        if isRun {
            return "\(first.code)–E\(Episode.twoDigits(last.number))"
        }
        return episodes.map(\.code).joined(separator: ", ")
    }

    /// The calendar day an episode airs.
    ///
    /// TMDB gives a date with no time, which `TMDBDate` reads as midnight
    /// UTC: taken in local time, that's the evening before anywhere west of
    /// Greenwich, and every alert would come a day early. So a date at
    /// exactly midnight UTC is read in UTC. Anything else was picked by hand
    /// in a date picker (Add Episode), in local time, and is read that way.
    static func airDay(of date: Date, calendar: Calendar) -> DateComponents {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let clock = utc.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let isTMDBDate = clock.hour == 0 && clock.minute == 0 && clock.second == 0 && (clock.nanosecond ?? 0) == 0
        let parts = (isTMDBDate ? utc : calendar).dateComponents([.year, .month, .day], from: date)
        return DateComponents(year: parts.year, month: parts.month, day: parts.day)
    }

    private struct DayKey: Hashable {
        let year: Int
        let month: Int
        let day: Int

        init(_ components: DateComponents) {
            year = components.year ?? 0
            month = components.month ?? 0
            day = components.day ?? 0
        }

        /// "2026-10-09", for the identifier.
        var text: String {
            "\(year)-\(Episode.twoDigits(month))-\(Episode.twoDigits(day))"
        }
    }
}

extension EpisodeAlertPlanner.ShowInput {
    /// What the planner needs of a show: its unwatched, numbered episodes
    /// with an air date between `start` and `end` — the rest can't alert,
    /// and every property read is a lookup in SwiftData's backing store.
    @MainActor
    init(_ show: Show, airingFrom start: Date, to end: Date) {
        var episodes: [EpisodeAlertPlanner.EpisodeInput] = []
        for episode in show.episodes ?? [] {
            guard let airDate = episode.airDate, airDate >= start, airDate <= end,
                  !episode.isWatched, episode.seasonNumber > 0 else { continue }
            episodes.append(.init(
                season: episode.seasonNumber,
                number: episode.episodeNumber,
                name: episode.name,
                airDate: airDate
            ))
        }
        self.init(tmdbID: show.tmdbID, name: show.name, status: show.status, episodes: episodes)
    }
}
