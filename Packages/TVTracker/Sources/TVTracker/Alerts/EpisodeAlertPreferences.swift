import Combine
import Foundation

/// TV Settings' "New Episode Alerts": whether they're on, what time of day
/// they come, and the shows that never send one.
public struct EpisodeAlertPreferences: Equatable, Sendable {
    /// 9:00 in the morning, the hour Finance's month reminder uses too.
    public static let defaultMinuteOfDay = 9 * 60

    /// Off until the person turns it on: TV Settings, or Up Next's card.
    public var isEnabled = false
    /// Minutes after local midnight.
    public var minuteOfDay = defaultMinuteOfDay
    /// `muteKey(tmdbID:name:)` of each show that never alerts.
    public var mutedShows: Set<String> = []
    /// Up Next's one-time "Turn on alerts?" card was answered.
    public var hasDismissedOffer = false

    public init() {}

    enum Key {
        static let enabled = "tv.newEpisodeAlerts.enabled"
        static let minuteOfDay = "tv.newEpisodeAlerts.minuteOfDay"
        static let mutedShows = "tv.newEpisodeAlerts.mutedShows"
        static let offerDismissed = "tv.newEpisodeAlerts.offerDismissed"
        static let all = [enabled, minuteOfDay, mutedShows, offerDismissed]
    }

    /// Whatever a store holds, read defensively: a key never written, or one
    /// holding something else (an older build, a hand edit), reads as its
    /// default rather than failing the lot. One key per setting, so a time
    /// changed on the Mac and a show muted on the phone both survive the
    /// key-value store's last-writer-wins.
    init(reading value: (String) -> Any?) {
        isEnabled = value(Key.enabled) as? Bool ?? false
        if let minute = value(Key.minuteOfDay) as? Int, (0..<(24 * 60)).contains(minute) {
            minuteOfDay = minute
        }
        if let muted = value(Key.mutedShows) as? [String] {
            mutedShows = Set(muted)
        }
        hasDismissedOffer = value(Key.offerDismissed) as? Bool ?? false
    }

    /// What `init(reading:)` reads back, key by key.
    var storedValues: [String: Any] {
        [
            Key.enabled: isEnabled,
            Key.minuteOfDay: minuteOfDay,
            Key.mutedShows: mutedShows.sorted(),
            Key.offerDismissed: hasDismissedOffer,
        ]
    }

    /// This device's copy — what the background refresh and the scheduler
    /// read. `EpisodeAlertStore` keeps it in step with iCloud's.
    public static func stored(defaults: UserDefaults = .standard) -> Self {
        Self(reading: { defaults.object(forKey: $0) })
    }

    /// How a show is muted. Its TMDB id, which every device agrees on — a
    /// SwiftData identifier is per device. A show added by hand has none, so
    /// it goes by its name.
    public static func muteKey(tmdbID: Int, name: String) -> String {
        tmdbID > 0 ? "tmdb:\(tmdbID)" : "name:\(name)"
    }

    public func isMuted(tmdbID: Int, name: String) -> Bool {
        mutedShows.contains(Self.muteKey(tmdbID: tmdbID, name: name))
    }

    /// The alert time on `day`, for a time picker.
    public func time(on day: Date = .now, calendar: Calendar = .current) -> Date {
        calendar.date(
            bySettingHour: minuteOfDay / 60,
            minute: minuteOfDay % 60,
            second: 0,
            of: day
        ) ?? day
    }

    /// The minute of the day a picked time stands for.
    public static func minuteOfDay(of time: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        return (parts.hour ?? 9) * 60 + (parts.minute ?? 0)
    }

    /// Whether a change from `old` alters what's scheduled.
    func changesSchedule(from old: Self) -> Bool {
        isEnabled != old.isEnabled || minuteOfDay != old.minuteOfDay || mutedShows != old.mutedShows
    }
}

/// The live preferences: iCloud key-value storage, like Trips' and Finance's
/// switches and the tracker layout, so a time picked on the phone holds on
/// the Mac, mirrored to UserDefaults so the first frame on a new device — and
/// a background refresh — has a value before iCloud's first sync lands.
///
/// Notification permission is still each device's own: "on" synced to a Mac
/// that was never asked schedules nothing there until it's allowed from the
/// Mac's TV Settings.
@MainActor
public final class EpisodeAlertStore: ObservableObject {
    public static let shared = EpisodeAlertStore()

    @Published public private(set) var preferences: EpisodeAlertPreferences

    private let defaults = UserDefaults.standard
    private let cloud = NSUbiquitousKeyValueStore.default
    private var observer: (any NSObjectProtocol)?

    private init() {
        preferences = .stored(defaults: defaults)
        // A change made on another device while the app wasn't running is
        // cached locally but only notified to a running process — see
        // `TrackerLayoutStore.init`.
        adoptCloudValues()
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.adoptCloudValues() }
        }
        cloud.synchronize()
    }

    public func setEnabled(_ enabled: Bool) {
        var updated = preferences
        updated.isEnabled = enabled
        if enabled { updated.hasDismissedOffer = true }
        save(updated)
    }

    public func setMinuteOfDay(_ minute: Int) {
        var updated = preferences
        updated.minuteOfDay = max(0, min(minute, 24 * 60 - 1))
        save(updated)
    }

    public func setMuted(_ muted: Bool, tmdbID: Int, name: String) {
        var updated = preferences
        let key = EpisodeAlertPreferences.muteKey(tmdbID: tmdbID, name: name)
        if muted { updated.mutedShows.insert(key) } else { updated.mutedShows.remove(key) }
        save(updated)
    }

    public func dismissOffer() {
        var updated = preferences
        updated.hasDismissedOffer = true
        save(updated)
    }

    private func save(_ updated: EpisodeAlertPreferences) {
        guard updated != preferences else { return }
        let old = preferences
        preferences = updated
        let oldValues = old.storedValues
        for (key, value) in updated.storedValues where !isSame(value, oldValues[key]) {
            defaults.set(value, forKey: key)
            cloud.set(value, forKey: key)
        }
        if updated.changesSchedule(from: old) { TVEpisodeAlerts.preferencesChanged() }
    }

    /// Takes iCloud's values where there are any; mirrored locally but not
    /// written back, which would only echo them to every other device.
    private func adoptCloudValues() {
        var changed = false
        for key in EpisodeAlertPreferences.Key.all {
            if let incoming = cloud.object(forKey: key), !isSame(incoming, defaults.object(forKey: key)) {
                defaults.set(incoming, forKey: key)
                changed = true
            }
        }
        guard changed else { return }
        let old = preferences
        let stored = EpisodeAlertPreferences.stored(defaults: defaults)
        guard stored != old else { return }
        preferences = stored
        if stored.changesSchedule(from: old) { TVEpisodeAlerts.preferencesChanged() }
    }

    private func isSame(_ lhs: Any, _ rhs: Any?) -> Bool {
        guard let rhs else { return false }
        return (lhs as? NSObject)?.isEqual(rhs) ?? false
    }
}
