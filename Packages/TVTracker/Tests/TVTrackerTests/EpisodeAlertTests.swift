import Foundation
import SwiftData
import Testing
@testable import TVTracker

/// Noon in New York on Monday 5 October 2026 (16:00 UTC).
private let now = Date(timeIntervalSince1970: 1_791_216_000)

private let newYork: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

/// An air date the way TMDB sends it: a day, read as midnight UTC.
private func tmdb(_ day: String) -> Date { TMDBDate.parse(day)! }

private func episode(_ season: Int, _ number: Int, _ name: String = "", airs day: String?, watched: Bool = false) -> EpisodeAlertPlanner.EpisodeInput {
    .init(season: season, number: number, name: name, airDate: day.map(tmdb), isWatched: watched)
}

private func show(
    _ name: String,
    tmdbID: Int,
    status: ShowStatus = .watching,
    _ episodes: [EpisodeAlertPlanner.EpisodeInput]
) -> EpisodeAlertPlanner.ShowInput {
    .init(tmdbID: tmdbID, name: name, status: status, episodes: episodes)
}

private func enabled(at minute: Int = EpisodeAlertPreferences.defaultMinuteOfDay, muting muted: Set<String> = []) -> EpisodeAlertPreferences {
    var preferences = EpisodeAlertPreferences()
    preferences.isEnabled = true
    preferences.minuteOfDay = minute
    preferences.mutedShows = muted
    return preferences
}

private func plan(_ shows: [EpisodeAlertPlanner.ShowInput], _ preferences: EpisodeAlertPreferences = enabled()) -> [EpisodeAlertPlanner.Alert] {
    EpisodeAlertPlanner.plan(shows: shows, preferences: preferences, asOf: now, calendar: newYork)
}

// MARK: - One episode

@Test func anEpisodeAlertsAtNineOnItsAirDate() throws {
    let alerts = plan([show("Severance", tmdbID: 95396, [episode(2, 5, "Trojan's Horse", airs: "2026-10-09")])])
    let alert = try #require(alerts.first)
    #expect(alerts.count == 1)
    #expect(alert.identifier == "tv.newEpisode.tmdb:95396.2026-10-09")
    #expect(alert.title == "Severance")
    #expect(alert.body == "S02E05 \u{201C}Trojan's Horse\u{201D} is out today.")
    #expect(alert.fireComponents == DateComponents(year: 2026, month: 10, day: 9, hour: 9, minute: 0))
    // 9:00 EDT, not the evening before: TMDB's midnight UTC is 8 p.m. on
    // the 8th in New York.
    #expect(alert.fireDate == Date(timeIntervalSince1970: 1_791_550_800))
}

@Test func anUntitledEpisodeIsNamedByItsCode() {
    #expect(plan([show("Severance", tmdbID: 1, [episode(2, 6, airs: "2026-10-16")])]).first?.body == "S02E06 is out today.")
}

@Test func anAirDatePickedByHandIsReadInLocalTime() {
    // Add Episode's date picker: 11 p.m. on the 9th in New York, which is
    // already the 10th in UTC.
    let picked = newYork.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 23))!
    #expect(EpisodeAlertPlanner.airDay(of: picked, calendar: newYork) == DateComponents(year: 2026, month: 10, day: 9))
    #expect(EpisodeAlertPlanner.airDay(of: tmdb("2026-10-09"), calendar: newYork) == DateComponents(year: 2026, month: 10, day: 9))
}

// MARK: - Several at once

@Test func episodesOutTheSameDayShareOneAlert() throws {
    let alerts = plan([show("The Bear", tmdbID: 136315, [
        episode(3, 2, airs: "2026-10-07"),
        episode(3, 1, airs: "2026-10-07"),
        episode(3, 3, airs: "2026-10-07"),
        episode(3, 4, airs: "2026-10-14"),
    ])])
    #expect(alerts.count == 2, "One per show per day")
    let first = try #require(alerts.first)
    #expect(first.body == "3 new episodes of The Bear are out today: S03E01–E03.")
    #expect(first.episodeCodes == ["S03E01", "S03E02", "S03E03"])
    #expect(alerts.last?.body == "S03E04 is out today.")
}

/// Two devices that each added the same new episode (see
/// `TVEpisodeRefresher`): announced once, and not at all once either copy
/// is ticked off.
@Test func twoCopiesOfAnEpisodeAlertOnce() throws {
    let alerts = plan([show("The Bear", tmdbID: 136315, [
        episode(3, 1, airs: "2026-10-07"),
        episode(3, 1, airs: "2026-10-07"),
        episode(3, 2, airs: "2026-10-07"),
        episode(3, 3, airs: "2026-10-14", watched: true),
        episode(3, 3, airs: "2026-10-14"),
    ])])
    #expect(alerts.count == 1)
    let alert = try #require(alerts.first)
    #expect(alert.body == "2 new episodes of The Bear are out today: S03E01–E02.")
    #expect(alert.episodeCodes == ["S03E01", "S03E02"])
}

@Test func episodesOutOfSequenceAreEachNamed() {
    let codes = EpisodeAlertPlanner.codes([episode(1, 9, airs: nil), episode(2, 1, airs: nil)])
    #expect(codes == "S01E09, S02E01")
    #expect(EpisodeAlertPlanner.codes([episode(4, 1, airs: nil), episode(4, 3, airs: nil)]) == "S04E01, S04E03")
}

@Test func twoShowsOnTheSameDayEachGetTheirOwn() {
    let alerts = plan([
        show("Slow Horses", tmdbID: 2, [episode(5, 1, airs: "2026-10-08")]),
        show("Andor", tmdbID: 1, [episode(2, 1, airs: "2026-10-08")]),
        show("Abbott Elementary", tmdbID: 3, [episode(5, 1, airs: "2026-10-06")]),
    ])
    #expect(alerts.map(\.showName) == ["Abbott Elementary", "Andor", "Slow Horses"], "Soonest first, then by name")
}

// MARK: - What doesn't alert

@Test func onlyUnwatchedNumberedEpisodesOfShowsBeingWatchedAlert() {
    let alerts = plan([
        show("Watching", tmdbID: 1, [
            episode(1, 1, airs: "2026-10-07", watched: true),
            episode(0, 1, "Trailer", airs: "2026-10-07"),
            episode(1, 2, airs: nil),
        ]),
        show("Not Started", tmdbID: 2, status: .notStarted, [episode(1, 1, airs: "2026-10-07")]),
        show("Completed", tmdbID: 3, status: .completed, [episode(1, 1, airs: "2026-10-07")]),
        show("Dropped", tmdbID: 4, status: .dropped, [episode(1, 1, airs: "2026-10-07")]),
    ])
    #expect(alerts.isEmpty, "Watched, a special, no date, or a show not being watched")
}

@Test func aMutedShowNeverAlerts() {
    let shows = [
        show("Severance", tmdbID: 95396, [episode(2, 5, airs: "2026-10-09")]),
        show("Home Movies", tmdbID: 0, [episode(1, 1, airs: "2026-10-09")]),
    ]
    #expect(plan(shows).count == 2)
    let muted = enabled(muting: [EpisodeAlertPreferences.muteKey(tmdbID: 95396, name: "Severance")])
    #expect(plan(shows, muted).map(\.showName) == ["Home Movies"])
    let byName = enabled(muting: [EpisodeAlertPreferences.muteKey(tmdbID: 0, name: "Home Movies")])
    #expect(plan(shows, byName).map(\.showName) == ["Severance"], "One added by hand is muted by its name")
}

@Test func aTimeAlreadyGoneTodayIsSkipped() {
    let today = [show("Severance", tmdbID: 1, [episode(2, 5, airs: "2026-10-05")])]
    #expect(plan(today).isEmpty, "9:00 has passed at noon")
    let evening = plan(today, enabled(at: 20 * 60))
    #expect(evening.first?.fireComponents == DateComponents(year: 2026, month: 10, day: 5, hour: 20, minute: 0))
    #expect(plan([show("Severance", tmdbID: 1, [episode(2, 4, airs: "2026-10-04")])], enabled(at: 23 * 60)).isEmpty, "Yesterday's")
}

@Test func onlyTheNextThreeWeeksArePlanned() {
    let alerts = plan([show("Severance", tmdbID: 1, [
        episode(2, 1, airs: "2026-10-25"), // 20 days on: the last day in
        episode(2, 2, airs: "2026-10-26"), // 21 days on: out
    ])])
    #expect(alerts.map(\.episodeCodes) == [["S02E01"]])
}

@Test func thePlanIsCappedSoonestFirst() {
    let shows = (0..<60).map { index in
        let day = 6 + index % 20
        return show("Show \(index)", tmdbID: index + 1, [episode(1, 1, airs: "2026-10-\(Episode.twoDigits(day))")])
    }
    let alerts = plan(shows)
    #expect(alerts.count == EpisodeAlertPlanner.maximumAlerts)
    #expect(EpisodeAlertPlanner.maximumAlerts + 12 < 64, "Under iOS's 64 pending, alongside Finance's twelve")
    #expect(alerts.map(\.fireDate) == alerts.map(\.fireDate).sorted())
    #expect(alerts.last?.day.day == 19, "Three shows a day from the 6th: the 40th lands on the 19th")
}

@Test func everyIdentifierCarriesThePrefix() {
    let alerts = plan([show("A", tmdbID: 1, [episode(1, 1, airs: "2026-10-06"), episode(1, 2, airs: "2026-10-13")])])
    #expect(alerts.allSatisfy { $0.identifier.hasPrefix(EpisodeAlertPlanner.identifierPrefix) })
    #expect(Set(alerts.map(\.identifier)).count == alerts.count)
}

// MARK: - Preferences

@Test func preferencesDefaultToOffAtNine() {
    let preferences = EpisodeAlertPreferences(reading: { _ in nil })
    #expect(!preferences.isEnabled)
    #expect(preferences.minuteOfDay == 9 * 60)
    #expect(preferences.mutedShows.isEmpty)
    #expect(!preferences.hasDismissedOffer)
}

@Test func preferencesReadBackWhatTheyStore() {
    var preferences = EpisodeAlertPreferences()
    preferences.isEnabled = true
    preferences.minuteOfDay = 18 * 60 + 30
    preferences.mutedShows = ["tmdb:1", "name:Home Movies"]
    preferences.hasDismissedOffer = true
    let stored = preferences.storedValues
    #expect(EpisodeAlertPreferences(reading: { stored[$0] }) == preferences)

    // Through a real defaults domain too, where everything comes back as
    // NSNumber and NSArray.
    let name = "tv.alerts.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    for (key, value) in stored { defaults.set(value, forKey: key) }
    #expect(EpisodeAlertPreferences.stored(defaults: defaults) == preferences)
    defaults.removePersistentDomain(forName: name)
}

@Test func preferencesShrugOffValuesOfTheWrongShape() {
    let junk: [String: Any] = [
        EpisodeAlertPreferences.Key.enabled: "yes",
        EpisodeAlertPreferences.Key.minuteOfDay: 24 * 60,
        EpisodeAlertPreferences.Key.mutedShows: [1, 2],
        EpisodeAlertPreferences.Key.offerDismissed: [true],
    ]
    #expect(EpisodeAlertPreferences(reading: { junk[$0] }) == EpisodeAlertPreferences())
    #expect(EpisodeAlertPreferences(reading: { $0 == EpisodeAlertPreferences.Key.minuteOfDay ? -5 : nil }).minuteOfDay == 9 * 60)
}

@Test func aPickedTimeIsAMinuteOfTheDay() {
    var preferences = EpisodeAlertPreferences()
    preferences.minuteOfDay = 7 * 60 + 45
    let time = preferences.time(on: now, calendar: newYork)
    #expect(newYork.dateComponents([.year, .month, .day, .hour, .minute], from: time)
            == DateComponents(year: 2026, month: 10, day: 5, hour: 7, minute: 45))
    #expect(EpisodeAlertPreferences.minuteOfDay(of: time, calendar: newYork) == 7 * 60 + 45)
}

@Test func onlyWhatAltersTheScheduleReschedules() {
    let off = EpisodeAlertPreferences()
    var dismissed = off
    dismissed.hasDismissedOffer = true
    #expect(!dismissed.changesSchedule(from: off), "Answering Up Next's card schedules nothing")
    #expect(enabled().changesSchedule(from: off))
    #expect(enabled(at: 600).changesSchedule(from: enabled()))
    #expect(enabled(muting: ["tmdb:1"]).changesSchedule(from: enabled()))
}

// MARK: - What reschedules

/// The app's container also holds Gym's and Orders' models: only a save
/// touching shows or episodes reschedules TV's alerts.
@MainActor
@Test func onlyASaveTouchingShowsOrEpisodesConcernsAlerts() throws {
    let schema = Schema(TVTrackerModule.models)
    let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    let context = ModelContext(container)

    final class Seen: @unchecked Sendable { var answers: [Bool] = [] }
    let seen = Seen()
    let observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: nil) { note in
        seen.answers.append(TVEpisodeAlerts.concernsAlerts(note.userInfo))
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    context.insert(Movie(title: "Heat"))
    try context.save()
    let show = Show(name: "Severance")
    context.insert(show)
    try context.save()
    show.status = .watching
    try context.save()

    #expect(seen.answers == [false, true, true], "A movie doesn't; a show added or its status changed does")
    #expect(TVEpisodeAlerts.concernsAlerts(nil), "Unreadable: reschedule rather than risk a stale alert")
}
