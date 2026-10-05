import Combine
import Foundation
import UserNotifications

/// The delivery half of shared-change notifications: the user's settings,
/// asking for permission, posting, and what happens when one is shown or
/// tapped. `SharedChangeNotifier` decides *what* to say; this decides whether
/// and how it reaches the screen.
///
/// Two paths reach the screen. The rich one is local —
/// `UNUserNotificationCenter` on this device — and only exists once this
/// device has imported the change: while the app is running, when a CloudKit
/// silent push wakes it, or the next time it's opened. iOS never delivers a
/// silent push to an app the user force-quit, so that one can lag the
/// partner's edit by as long as the app stays shut. The other comes straight
/// from iCloud (`SharedChangeServerAlerts`): a fixed "Rome & Amalfi was
/// updated" that arrives with the app not running at all. When the local one
/// posts it takes the iCloud alert's place, and while the app is in front
/// the iCloud alert isn't shown at all.
public enum SharedChangeNotifications {
    /// The Settings toggle "Changes to shared items". On by default, but
    /// nothing is shown until the system permission has been granted, which
    /// is asked for when sharing starts, from that toggle, or by the first
    /// iCloud-alert pass that finds something already shared.
    public static let enabledKey = "sharedChangeNotificationsEnabled"

    /// One per module, so a busy shared Finance household can be muted
    /// without losing a partner's trip edits. On by default.
    public static func moduleEnabledKey(_ moduleID: String) -> String {
        "sharedChangeNotifications.\(moduleID)"
    }

    /// `userInfo` keys on every posted notification.
    public static let moduleUserInfoKey = "module"
    public static let rootUserInfoKey = "root"
    /// The burst's change lines (`SharedChangeNotice.changes`), for the list
    /// a tap opens. Absent for a single change.
    public static let changesUserInfoKey = "changes"
    /// Where inside its tracker a tap goes, in the module's own words — set
    /// only by a module's own notice, never by a shared-change one: Finance's
    /// "September's report is ready" carries `finance.report:2026-09`. Core
    /// passes it on untouched (`SharedChangeNotificationRouter.destinationToOpen`);
    /// the app hands it to the module that understands it.
    public static let destinationUserInfoKey = "destination"
    /// `true` on a tracker's own scheduled reminder — TV's "a new episode is
    /// out today" — which is no shared change: shown and routed like one,
    /// but never recorded in `SharedChangeActivityLog`, whose entries the
    /// Notification Status page reads as the shared-change pipeline's work.
    /// A reminder held back because TV was on screen read there as "Not
    /// shown: … was on screen", beside the partner's edits.
    public static let reminderUserInfoKey = "reminder"

    public static func isEnabled(moduleID: String, defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: enabledKey) as? Bool ?? true)
            && (defaults.object(forKey: moduleEnabledKey(moduleID)) as? Bool ?? true)
    }

    /// Makes this app's delegate the notification center's. Must run before
    /// the app finishes launching (Apple's own requirement), or a tap that
    /// launches the app is never delivered to it — `BhavikApp.init()` is
    /// early enough.
    @MainActor
    public static func install() {
        UNUserNotificationCenter.current().delegate = SharedChangeNotificationDelegate.shared
    }

    /// Asks for permission if it has never been asked and the user hasn't
    /// turned the setting off. Called at the moments sharing starts —
    /// creating a share, accepting one — never at launch, where a prompt out
    /// of nowhere is usually refused.
    public static func requestAuthorizationIfUndetermined() async {
        guard UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true else { return }
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Asks for permission from the Settings toggle. Returns whether
    /// notifications can now be shown — `false` once the user has refused,
    /// since only the system Settings app can undo that.
    public static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }

    /// Whether the system will show them at all.
    public static func isAuthorized() async -> Bool {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    /// Whether the permission question has never been put to the user.
    public static func isUndetermined() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined
    }

    /// Whether the system permission was refused, so the Settings screen can
    /// say where to turn it back on instead of a toggle that does nothing.
    public static func isDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    /// What the system's notification settings come to, for the Status page.
    public static func healthPermission() async -> (permission: SharedChangeHealthFacts.Permission, showsAlerts: Bool) {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let permission: SharedChangeHealthFacts.Permission
        switch settings.authorizationStatus {
        case .notDetermined: permission = .notAsked
        case .denied: permission = .denied
        case .provisional: permission = .quiet
        default: permission = .allowed
        }
        // Banners on, or at least the lock screen — anything a person would see.
        let showsAlerts = settings.alertSetting == .enabled || settings.lockScreenSetting == .enabled
        return (permission, showsAlerts)
    }

    /// The Status page's "Send Test Notification": a plain notification
    /// `delay` seconds from now, so there's time to leave the app or lock
    /// the screen first. Returns the system's error, if it refused.
    public static func sendTest(after delay: TimeInterval = 5) async -> String? {
        let content = UNMutableNotificationContent()
        content.title = "Multitrack"
        content.body = "Test notification — if you can see this, notifications reach this device."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(delay, 1), repeats: false)
        let request = UNNotificationRequest(identifier: "notification-status.test", content: content, trigger: trigger)
        do {
            try await UNUserNotificationCenter.current().add(request)
            SharedChangeActivityLog.record(SharedChangeLogEntry(moduleID: "app", outcome: .test, detail: "scheduled"))
            return nil
        } catch {
            SharedChangeActivityLog.record(SharedChangeLogEntry(moduleID: "app", outcome: .test, detail: "refused: \(error.localizedDescription)"))
            return error.localizedDescription
        }
    }

    /// Posts `notice` unless the user has turned its module (or the whole
    /// feature) off. Without permission the center drops it silently, which
    /// is the right outcome.
    static func post(_ notice: SharedChangeNotice, moduleName: String) {
        guard isEnabled(moduleID: notice.moduleID) else {
            SharedChangeActivityLog.record(SharedChangeLogEntry(moduleID: notice.moduleID, outcome: .muted, detail: notice.title))
            return
        }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        // Two households are both called "Household" by default, so the title
        // alone can't say whether it was Points or Finance.
        content.subtitle = moduleName
        // The change lines too: the lock screen shows the first few, a long
        // press the rest of what fits, and a tap opens all of them.
        content.body = notice.expandedBody
        content.sound = .default
        content.threadIdentifier = notice.identifier
        var userInfo: [String: Any] = [moduleUserInfoKey: notice.moduleID, rootUserInfoKey: notice.rootKey]
        if !notice.changes.isEmpty {
            userInfo[changesUserInfoKey] = Array(notice.changes.prefix(SharedChangeDigest.maximumChanges))
        }
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil)
        let serverAlert = notice.serverAlertID
        UNUserNotificationCenter.current().add(request) { error in
            SharedChangeActivityLog.record(SharedChangeLogEntry(
                moduleID: notice.moduleID,
                outcome: error == nil ? .posted : .refused,
                detail: error.map { "\(notice.body) (\($0.localizedDescription))" } ?? notice.body
            ))
            // Says who and what, so iCloud's "… was updated" about the same
            // share has nothing left to add.
            guard error == nil, let serverAlert else { return }
            SharedChangeServerAlertInbox.removeDelivered(subscriptionIDs: [serverAlert])
        }
    }
}

/// What the app's own screens and the notification delegate share: which
/// tracker is on screen, and which one a tapped notification asked to open.
@MainActor
public final class SharedChangeNotificationRouter: ObservableObject {
    public static let shared = SharedChangeNotificationRouter()
    private init() {}

    /// The tracker the user is looking at, set by the hub (`HomeView`).
    /// A notification about it is held back while the app is in front — the
    /// change is already on screen.
    public var foregroundModuleID: String?

    /// Set when a notification is tapped; the hub opens that tracker and
    /// clears it. Published rather than posted, so a tap that launched the
    /// app is still waiting when the hub first appears.
    @Published public var moduleToOpen: String?

    /// The tapped notification's list of changes, shown over its tracker by
    /// `.showsSharedChangeDigest(moduleID:)`, which clears it. Only set for a
    /// notification about more than one change.
    @Published public var digestToShow: SharedChangeDigest?

    /// A tapped notification's `destinationUserInfoKey`, for the app to hand
    /// to its module (Finance's report for a month) and clear. Published for
    /// the same reason as `moduleToOpen`: a tap that launched the app must
    /// still be waiting when the first window appears.
    @Published public var destinationToOpen: String?
}

/// What a tapped notification about several changes opens: every change in
/// the burst, not just the "made 4 changes" the notification led with.
public struct SharedChangeDigest: Identifiable, Equatable, Sendable {
    /// The most lines a notification carries for its list.
    public static let maximumChanges = 50

    public let id = UUID()
    public let moduleID: String
    /// The shared root — "Household", "Rome & Amalfi".
    public let title: String
    /// "Saloni made 4 changes to Household", the notification's first line.
    public let summary: String
    public let changes: [String]
    public let date: Date

    public init(moduleID: String, title: String, summary: String, changes: [String], date: Date = .now) {
        self.moduleID = moduleID
        self.title = title
        self.summary = summary
        self.changes = changes
        self.date = date
    }

    /// The digest a tapped notification carries, or nil for one with no
    /// list: a single change, iCloud's own alert, a test notification.
    public init?(content: UNNotificationContent, date: Date = .now) {
        guard content.categoryIdentifier != SharedChangeServerAlertText.category,
              let moduleID = content.userInfo[SharedChangeNotifications.moduleUserInfoKey] as? String,
              let changes = content.userInfo[SharedChangeNotifications.changesUserInfoKey] as? [String],
              !changes.isEmpty
        else { return nil }
        // The body is the summary followed by the bulleted lines.
        let summary = content.body.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? content.body
        self.init(moduleID: moduleID, title: content.title, summary: summary, changes: changes, date: date)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// What the delegate decides about a notification, kept apart from it so it
/// can be tested without a notification center.
enum SharedChangeNotificationRouting {
    /// How a notification shows while the app is in front.
    static func presentationOptions(
        categoryIdentifier: String,
        moduleID: String?,
        onScreenModuleID: String?
    ) -> UNNotificationPresentationOptions {
        // iCloud's alert, while the app is open and importing the same change
        // itself: the local notification says it better, or the change was on
        // screen already.
        if categoryIdentifier == SharedChangeServerAlertText.category { return [] }
        if let moduleID, moduleID == onScreenModuleID { return [] }
        return [.banner, .list, .sound]
    }

    /// Whether one held back while the app is in front goes in the activity
    /// log as `.onScreen`: a shared change does; iCloud's own alert and a
    /// tracker's reminder (`reminderUserInfoKey`) don't.
    static func logsHeldBack(categoryIdentifier: String, userInfo: [AnyHashable: Any]) -> Bool {
        guard categoryIdentifier != SharedChangeServerAlertText.category,
              userInfo[SharedChangeNotifications.moduleUserInfoKey] is String else { return false }
        return !(userInfo[SharedChangeNotifications.reminderUserInfoKey] as? Bool ?? false)
    }

    /// The tracker a tapped notification opens, or nil to just open the app.
    static func moduleToOpen(
        actionIdentifier: String,
        content: UNNotificationContent,
        participatingModuleIDs: Set<String>
    ) -> String? {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier else { return nil }
        if content.categoryIdentifier == SharedChangeServerAlertText.category {
            return SharedChangeServerAlertID.moduleToOpen(
                subscriptionID: SharedChangeServerAlertInbox.subscriptionID(of: content),
                participatingModuleIDs: participatingModuleIDs
            )
        }
        return content.userInfo[SharedChangeNotifications.moduleUserInfoKey] as? String
    }

    /// Where inside the tracker a tapped notification goes, or nil for the
    /// tracker's own first screen. Only a tap on our own local notification
    /// carries one — iCloud's alert has no custom payload.
    static func destinationToOpen(actionIdentifier: String, content: UNNotificationContent) -> String? {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier,
              content.categoryIdentifier != SharedChangeServerAlertText.category,
              content.userInfo[SharedChangeNotifications.moduleUserInfoKey] is String
        else { return nil }
        return content.userInfo[SharedChangeNotifications.destinationUserInfoKey] as? String
    }
}

/// The notification center's delegate: decides whether a notification shows
/// while the app is in front, and routes a tap to its tracker.
///
/// The completion-handler forms, answered on the main thread, on purpose.
/// This used to implement the `async` forms, which Swift runs on its
/// cooperative pool, not the main thread, and then calls UIKit's completion
/// handler from there. UIKit's handler for a tap updates the app switcher
/// snapshot, which asserts it's on the main thread: tapping any notification
/// killed the app (TestFlight build 16, SIGABRT in
/// `-[UIApplication _performBlockAfterCATransactionCommitSynchronizes:]`
/// under `_updateSnapshotAndStateRestorationWithAction:windowScene:`, on a
/// `com.apple.root.user-initiated-qos.cooperative` thread).
final class SharedChangeNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = SharedChangeNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let content = notification.request.content
        let category = content.categoryIdentifier
        let module = content.userInfo[SharedChangeNotifications.moduleUserInfoKey] as? String
        let logsHeldBack = SharedChangeNotificationRouting.logsHeldBack(categoryIdentifier: category, userInfo: content.userInfo)
        nonisolated(unsafe) let completionHandler = completionHandler
        let title = notification.request.content.title
        Self.onMain {
            let options = SharedChangeNotificationRouting.presentationOptions(
                categoryIdentifier: category,
                moduleID: module,
                onScreenModuleID: SharedChangeNotificationRouter.shared.foregroundModuleID
            )
            if options.isEmpty, let module, logsHeldBack {
                SharedChangeActivityLog.record(SharedChangeLogEntry(moduleID: module, outcome: .onScreen, detail: title))
            }
            completionHandler(options)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let route = Self.route(
            actionIdentifier: response.actionIdentifier,
            content: response.notification.request.content,
            date: response.notification.date
        )
        nonisolated(unsafe) let completionHandler = completionHandler
        Self.onMain {
            route()
            completionHandler()
        }
    }

    /// What a tap does: open the tracker, and the list of changes when the
    /// notification carried one. Worked out off the main thread, applied on
    /// it. `-SharedChangeProbeTap` runs the same thing.
    static func route(actionIdentifier: String, content: UNNotificationContent, date: Date) -> @MainActor @Sendable () -> Void {
        let module = SharedChangeNotificationRouting.moduleToOpen(
            actionIdentifier: actionIdentifier,
            content: content,
            participatingModuleIDs: SharedChangeServerAlerts.participatingModuleIDs
        )
        let digest = module == nil ? nil : SharedChangeDigest(content: content, date: date)
        let destination = module == nil ? nil : SharedChangeNotificationRouting.destinationToOpen(
            actionIdentifier: actionIdentifier,
            content: content
        )
        return {
            if let module { SharedChangeNotificationRouter.shared.moduleToOpen = module }
            if let digest { SharedChangeNotificationRouter.shared.digestToShow = digest }
            if let destination { SharedChangeNotificationRouter.shared.destinationToOpen = destination }
        }
    }

    /// The center calls its delegate on the main thread, so this normally
    /// runs `work` there and then; the hop is only a guard.
    private static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            Task { @MainActor in work() }
        }
    }
}

#if DEBUG
public extension SharedChangeNotifications {
    /// `-SharedChangeProbe <module>`: one burst of made-up changes by
    /// "Saloni", through the real coalescer and `post`, `delay` seconds after
    /// launch — time to leave the app, since a notification about the tracker
    /// on screen is held back. The only way to see one on a simulator, which
    /// can't sign in to iCloud to receive a partner's edit.
    static func postProbe(moduleID: String, moduleName: String, rootTitle: String, actions: [String], after delay: TimeInterval = 8) {
        Task {
            await requestAuthorizationIfUndetermined()
            try? await Task.sleep(for: .seconds(delay))
            var coalescer = SharedChangeCoalescer()
            for (index, action) in actions.enumerated() {
                coalescer.add(SharedChangeEvent(
                    moduleID: moduleID,
                    rootKey: "probe",
                    rootTitle: rootTitle,
                    objectKey: "probe-\(index)",
                    kind: .updated,
                    action: action,
                    author: .named("Saloni")
                ))
            }
            for notice in coalescer.due(force: true) {
                post(notice, moduleName: moduleName)
                // `-SharedChangeProbeTap YES`: tap it too. A simulator's
                // injected touches never reach a notification banner.
                guard UserDefaults.standard.bool(forKey: "SharedChangeProbeTap") else { continue }
                try? await Task.sleep(for: .seconds(2))
                let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
                guard let posted = delivered.first(where: { $0.request.identifier == notice.identifier }) else { continue }
                let route = SharedChangeNotificationDelegate.route(
                    actionIdentifier: UNNotificationDefaultActionIdentifier,
                    content: posted.request.content,
                    date: posted.date
                )
                await MainActor.run { route() }
            }
        }
    }
}
#endif
