import Foundation

/// How a refresh from iCloud ended. Every case says what actually happened —
/// there is no "done" that only means a spinner ran for a while.
public enum CloudRefreshOutcome: Sendable, Equatable {
    /// Every store asked about finished a fresh import.
    case updated(at: Date)
    /// No fresh import finished in time. Whatever iCloud sends still lands on
    /// its own afterwards; this only says the wait gave up.
    case timedOut(lastSyncedAt: Date?)
    /// A fresh import finished with an error.
    case failed(String)
    /// The iCloud account can't sync at all right now.
    case unavailable(CloudSyncState)
    /// Nothing in scope is backed by iCloud (an in-memory store).
    case notSyncing
}

/// The words for sync freshness, in one place so Settings, the Mac sidebar and
/// any refresh message say the same thing the same way.
public enum CloudSyncStatusText {
    /// A one-line freshness label: "Checking iCloud…", "Updated just now",
    /// "Last synced 5 min ago", "Last synced today at 3:12 PM",
    /// "Last synced yesterday at 9:05 AM", "Last synced Sep 3".
    public static func lastSynced(
        _ lastSyncedAt: Date?,
        isRefreshing: Bool = false,
        asOf now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        if isRefreshing { return "Checking iCloud…" }
        guard let lastSyncedAt else { return "Not synced yet" }

        // A clock a second or two out between the event's timestamp and `now`
        // shouldn't read as a sync from the future.
        let elapsed = max(0, now.timeIntervalSince(lastSyncedAt))
        if elapsed < 60 { return "Updated just now" }
        if elapsed < 60 * 60 { return "Last synced \(Int(elapsed / 60)) min ago" }

        var time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
        time.timeZone = calendar.timeZone
        if calendar.isDate(lastSyncedAt, inSameDayAs: now) {
            return "Last synced today at \(lastSyncedAt.formatted(time))"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(lastSyncedAt, inSameDayAs: yesterday) {
            return "Last synced yesterday at \(lastSyncedAt.formatted(time))"
        }
        var day = Date.FormatStyle(locale: locale, calendar: calendar).month(.abbreviated).day()
        day.timeZone = calendar.timeZone
        return "Last synced \(lastSyncedAt.formatted(day))"
    }

    /// What to tell someone after they asked for a refresh, or `nil` when the
    /// freshness label already says it all.
    public static func message(for outcome: CloudRefreshOutcome) -> String? {
        switch outcome {
        case .updated:
            nil
        case .timedOut:
            "iCloud hasn't sent anything new yet. Changes from other devices keep arriving on their own while the app is open."
        case .failed(let error):
            "iCloud couldn't sync: \(error)"
        case .unavailable(let state):
            state.explanation
        case .notSyncing:
            "This copy of the app isn't syncing with iCloud."
        }
    }

    /// The Mac sidebar footer's short form: "Synced just now", "Synced 5 min
    /// ago", "Synced at 3:12 PM", "Synced yesterday", "Synced Sep 3". The
    /// footer is 240pt wide beside a bold status line, so it drops the
    /// "Last"/"today at" that `lastSynced` spells out for Settings.
    public static func synced(
        _ lastSyncedAt: Date?,
        isRefreshing: Bool = false,
        asOf now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        if isRefreshing { return "Checking iCloud…" }
        guard let lastSyncedAt else { return "Not synced yet" }
        let elapsed = max(0, now.timeIntervalSince(lastSyncedAt))
        if elapsed < 60 { return "Synced just now" }
        if elapsed < 60 * 60 { return "Synced \(Int(elapsed / 60)) min ago" }
        if calendar.isDate(lastSyncedAt, inSameDayAs: now) {
            var time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
            time.timeZone = calendar.timeZone
            return "Synced at \(lastSyncedAt.formatted(time))"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(lastSyncedAt, inSameDayAs: yesterday) {
            return "Synced yesterday"
        }
        var day = Date.FormatStyle(locale: locale, calendar: calendar).month(.abbreviated).day()
        day.timeZone = calendar.timeZone
        return "Synced \(lastSyncedAt.formatted(day))"
    }

    /// The footer's bold line. Only says "up to date" once something has
    /// actually synced, and owns up to a failed refresh rather than leaving
    /// the last good time on screen as if all were well.
    public static func headline(
        lastSyncedAt: Date?,
        isRefreshing: Bool,
        lastOutcome: CloudRefreshOutcome?
    ) -> String {
        if isRefreshing { return "Syncing with iCloud" }
        switch lastOutcome {
        case .failed?: return "iCloud couldn't sync"
        case .unavailable?: return "iCloud unavailable"
        case .notSyncing?: return "Not syncing"
        case .updated?, .timedOut?, nil: break
        }
        return lastSyncedAt == nil ? "iCloud" : "iCloud up to date"
    }
}
