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
        content.body = notice.body
        content.sound = .default
        content.threadIdentifier = notice.identifier
        content.userInfo = [moduleUserInfoKey: notice.moduleID, rootUserInfoKey: notice.rootKey]
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
        nonisolated(unsafe) let completionHandler = completionHandler
        let title = notification.request.content.title
        Self.onMain {
            let options = SharedChangeNotificationRouting.presentationOptions(
                categoryIdentifier: category,
                moduleID: module,
                onScreenModuleID: SharedChangeNotificationRouter.shared.foregroundModuleID
            )
            if options.isEmpty, let module, category != SharedChangeServerAlertText.category {
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
        let module = SharedChangeNotificationRouting.moduleToOpen(
            actionIdentifier: response.actionIdentifier,
            content: response.notification.request.content,
            participatingModuleIDs: SharedChangeServerAlerts.participatingModuleIDs
        )
        nonisolated(unsafe) let completionHandler = completionHandler
        Self.onMain {
            if let module { SharedChangeNotificationRouter.shared.moduleToOpen = module }
            completionHandler()
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
