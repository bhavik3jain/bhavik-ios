import Foundation
import Synchronization

// What Settings' Notification Status page reads: a short log of what the
// shared-change pipeline did with each download, and a plain-language check
// of everything that has to be true for a notification to reach the screen.
//
// Why it exists: a partner reported getting nothing when a shared Finance
// household changed, and nothing in the pipeline said why. Every stage —
// permission, the Settings switches, the iCloud alert subscriptions, the
// notifier's filters — fails silently by design, so from the outside "no
// notification" looked the same whichever one it was.

// MARK: - Activity log

/// One thing the pipeline did, or decided not to do.
public struct SharedChangeLogEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        /// A notification was handed to the system.
        case posted
        /// The system refused it — usually no permission.
        case refused
        /// Changes made by this iCloud account on another of its devices.
        case ownEdit
        /// Downloaded changes to something that isn't shared.
        case notShared
        /// The download that follows accepting a share — held back on purpose.
        case justJoined
        /// The Settings switch for the feature or the tracker is off.
        case muted
        /// Shown nothing because the tracker was on screen.
        case onScreen
        /// The Status page's test notification.
        case test
        /// Notified, but as "Someone": who made the change couldn't be named.
        case unnamed
    }

    public let id: UUID
    public var date: Date
    public var moduleID: String
    public var outcome: Outcome
    /// "Household" — or the notification's body, for `posted`.
    public var detail: String
    /// How many times this same thing happened in a row (see `merging`).
    public var count: Int

    public init(id: UUID = UUID(), date: Date = .now, moduleID: String, outcome: Outcome, detail: String, count: Int = 1) {
        self.id = id
        self.date = date
        self.moduleID = moduleID
        self.outcome = outcome
        self.detail = detail
        self.count = count
    }

    /// "Not notified: your own edit from another device".
    public var summary: String {
        switch outcome {
        case .posted: "Notified: \(detail)"
        case .refused: "Not shown — the system refused it: \(detail)"
        case .ownEdit: "Not notified: your own edit from another device (\(detail))"
        case .notShared: "Not notified: \(detail) isn't shared"
        case .justJoined: "Not notified: the download after joining \(detail)"
        case .muted: "Not notified: switched off in Settings (\(detail))"
        case .onScreen: "Not shown: \(detail) was on screen"
        case .test: "Test notification: \(detail)"
        case .unnamed: "Said \u{201C}Someone\u{201D}: \(detail)"
        }
    }
}

/// The last few dozen entries, newest first, kept in UserDefaults so they
/// outlive the process — a silent push wakes the app for seconds at a time.
public enum SharedChangeActivityLog {
    static let defaultsKey = "sharedChangeActivityLog"
    static let capacity = 50
    /// A repeat within this long of the entry before it is folded into it.
    static let mergeWindow: TimeInterval = 15 * 60

    private static let lock = Mutex<Void>(())

    public static func record(_ entry: SharedChangeLogEntry, defaults: UserDefaults = .standard) {
        lock.withLock { _ in
            let updated = merging(entry, into: read(defaults))
            if let data = try? JSONEncoder().encode(updated) {
                defaults.set(data, forKey: defaultsKey)
            }
        }
    }

    public static func entries(defaults: UserDefaults = .standard) -> [SharedChangeLogEntry] {
        lock.withLock { _ in read(defaults) }
    }

    public static func clear(defaults: UserDefaults = .standard) {
        lock.withLock { _ in defaults.removeObject(forKey: defaultsKey) }
    }

    /// When `moduleID`'s store last finished a download from iCloud.
    public static func lastImport(moduleID: String, defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: "sharedChangeLastImport.\(moduleID)") as? Date
    }

    static func noteImport(moduleID: String, at date: Date = .now, defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: "sharedChangeLastImport.\(moduleID)")
    }

    /// The last time iCloud's alert subscriptions were brought in line, and
    /// how it went — "Saved 1, deleted 0", or the error.
    public static func lastAlertPass(defaults: UserDefaults = .standard) -> (date: Date, result: String)? {
        guard let date = defaults.object(forKey: "sharedChangeLastAlertPass.date") as? Date,
              let result = defaults.string(forKey: "sharedChangeLastAlertPass.result") else { return nil }
        return (date, result)
    }

    static func noteAlertPass(_ result: String, at date: Date = .now, defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: "sharedChangeLastAlertPass.date")
        defaults.set(result, forKey: "sharedChangeLastAlertPass.result")
    }

    private static func read(_ defaults: UserDefaults) -> [SharedChangeLogEntry] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([SharedChangeLogEntry].self, from: data)) ?? []
    }

    /// Puts `entry` at the front, folding it into the newest entry when it's
    /// the same thing again soon after — a private trip syncing between the
    /// user's own devices would otherwise push everything useful out.
    static func merging(_ entry: SharedChangeLogEntry, into entries: [SharedChangeLogEntry]) -> [SharedChangeLogEntry] {
        var entries = entries
        if var newest = entries.first,
           newest.outcome != .posted, newest.outcome != .test,
           newest.outcome == entry.outcome, newest.moduleID == entry.moduleID, newest.detail == entry.detail,
           entry.date.timeIntervalSince(newest.date) < mergeWindow {
            newest.count += entry.count
            newest.date = entry.date
            entries[0] = newest
            return entries
        }
        entries.insert(entry, at: 0)
        return Array(entries.prefix(capacity))
    }
}

// MARK: - Health check

/// Everything the Status page knows, as plain values.
public struct SharedChangeHealthFacts: Sendable, Equatable {
    public enum Permission: String, Sendable {
        case allowed
        /// Allowed, but delivered quietly to Notification Center only.
        case quiet
        case denied
        case notAsked
    }

    public var permission: Permission
    /// Banners or the lock screen are on — what a notification needs to be seen.
    public var showsAlerts: Bool
    public var switchOn: Bool
    public var mutedModuleIDs: Set<String>
    /// Trackers with something this user shares with someone else.
    public var owningModuleIDs: Set<String>
    /// Trackers with something someone else shares with this user.
    public var participatingModuleIDs: Set<String>
    /// Our alert subscription IDs on the server, or nil when they couldn't
    /// be read (offline, no iCloud).
    public var serverAlertIDs: Set<String>?
    /// How many of `serverAlertIDs` an owner's shares should have.
    public var expectedOwnedAlertCount: Int
    public var serverError: String?

    public init(
        permission: Permission,
        showsAlerts: Bool = true,
        switchOn: Bool = true,
        mutedModuleIDs: Set<String> = [],
        owningModuleIDs: Set<String> = [],
        participatingModuleIDs: Set<String> = [],
        serverAlertIDs: Set<String>? = nil,
        expectedOwnedAlertCount: Int = 0,
        serverError: String? = nil
    ) {
        self.permission = permission
        self.showsAlerts = showsAlerts
        self.switchOn = switchOn
        self.mutedModuleIDs = mutedModuleIDs
        self.owningModuleIDs = owningModuleIDs
        self.participatingModuleIDs = participatingModuleIDs
        self.serverAlertIDs = serverAlertIDs
        self.expectedOwnedAlertCount = expectedOwnedAlertCount
        self.serverError = serverError
    }

    public var sharesAnything: Bool { !owningModuleIDs.isEmpty || !participatingModuleIDs.isEmpty }
}

/// One thing standing between a shared change and a notification.
public struct SharedChangeProblem: Sendable, Equatable, Identifiable {
    public enum Fix: Sendable, Equatable {
        /// Only the system Settings app can change it.
        case openSystemSettings
        case askPermission
        case turnOnSwitch
        case unmute(String)
        case setUpAlertsAgain
        case none
    }

    public let id: String
    public let title: String
    public let detail: String
    public let fix: Fix
    /// Stops every notification, as opposed to some of them.
    public let isBlocking: Bool
}

public enum SharedChangeHealth {
    /// The problems, worst first. Empty means everything checkable is fine.
    /// `moduleName` names a tracker by its ID.
    public static func problems(_ facts: SharedChangeHealthFacts, moduleName: (String) -> String = { $0 }) -> [SharedChangeProblem] {
        var problems: [SharedChangeProblem] = []
        switch facts.permission {
        case .denied:
            problems.append(SharedChangeProblem(
                id: "denied",
                title: "Notifications are turned off for Multitrack",
                detail: "This device drops every notification from the app, and iCloud's alerts too. Only the Settings app can turn them back on.",
                fix: .openSystemSettings,
                isBlocking: true
            ))
        case .notAsked:
            problems.append(SharedChangeProblem(
                id: "notAsked",
                title: "Multitrack hasn't been allowed to notify",
                detail: "The question has never been answered on this device, so nothing is shown.",
                fix: .askPermission,
                isBlocking: true
            ))
        case .quiet:
            problems.append(SharedChangeProblem(
                id: "quiet",
                title: "Notifications are delivered quietly",
                detail: "They go to Notification Center without a banner, sound or lock-screen alert, so they're easy to miss.",
                fix: .openSystemSettings,
                isBlocking: false
            ))
        case .allowed:
            if !facts.showsAlerts {
                problems.append(SharedChangeProblem(
                    id: "noAlerts",
                    title: "Banners and lock-screen alerts are off",
                    detail: "Notifications are allowed, but set not to appear on the lock screen or as banners.",
                    fix: .openSystemSettings,
                    isBlocking: false
                ))
            }
        }

        if !facts.switchOn {
            problems.append(SharedChangeProblem(
                id: "switchOff",
                title: "\u{201C}Changes to shared items\u{201D} is off",
                detail: "Turned off in this app's Settings, which also removes iCloud's alerts from every device on this Apple Account.",
                fix: .turnOnSwitch,
                isBlocking: true
            ))
        }

        let sharedModules = facts.owningModuleIDs.union(facts.participatingModuleIDs)
        for module in sharedModules.intersection(facts.mutedModuleIDs).sorted() {
            problems.append(SharedChangeProblem(
                id: "muted.\(module)",
                title: "\(moduleName(module)) is switched off",
                detail: "Changes to what's shared in \(moduleName(module)) aren't notified.",
                fix: .unmute(module),
                isBlocking: false
            ))
        }

        if !facts.sharesAnything {
            problems.append(SharedChangeProblem(
                id: "nothingShared",
                title: "Nothing is shared on this device yet",
                detail: "No shared trip, car, guide or household has reached this device. If someone has shared one, accept it from their link, then open the app and let it sync.",
                fix: .none,
                isBlocking: true
            ))
        } else if facts.switchOn, facts.permission == .allowed || facts.permission == .quiet {
            if let ids = facts.serverAlertIDs {
                let participantMissing = !facts.participatingModuleIDs.isEmpty
                    && !facts.participatingModuleIDs.isSubset(of: facts.mutedModuleIDs)
                    && !ids.contains(SharedChangeServerAlertID.shared)
                let ownedCount = ids.filter { $0 != SharedChangeServerAlertID.shared }.count
                if participantMissing || ownedCount < facts.expectedOwnedAlertCount {
                    problems.append(SharedChangeProblem(
                        id: "serverAlerts",
                        title: "iCloud's alerts aren't set up",
                        detail: "With the app closed, iCloud sends a short alert when something shared changes — but only once this account's alert is set up, and it isn't.",
                        fix: .setUpAlertsAgain,
                        isBlocking: false
                    ))
                }
            } else if let error = facts.serverError {
                problems.append(SharedChangeProblem(
                    id: "serverUnknown",
                    title: "Couldn't check iCloud's alerts",
                    detail: error,
                    fix: .setUpAlertsAgain,
                    isBlocking: false
                ))
            }
        }
        return problems
    }
}
