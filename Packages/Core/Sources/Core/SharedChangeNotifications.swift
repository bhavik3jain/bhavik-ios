import Combine
import Foundation
import UserNotifications

/// The delivery half of shared-change notifications: the user's settings,
/// asking for permission, posting, and what happens when one is shown or
/// tapped. `SharedChangeNotifier` decides *what* to say; this decides whether
/// and how it reaches the screen.
///
/// Everything here is local — `UNUserNotificationCenter` on this device.
/// Nothing is sent from a server, so a notification only exists once this
/// device has imported the change: while the app is running, or the next
/// time it's opened. A CloudKit silent push can wake a suspended app to
/// import sooner only if the app carries the `aps-environment` entitlement,
/// and iOS never delivers one to an app the user force-quit — so a
/// notification can lag the partner's edit by as long as the app stays shut.
public enum SharedChangeNotifications {
    /// The Settings toggle "Changes to shared items". On by default, but
    /// nothing is shown until the system permission has been granted, which
    /// is only ever asked for when sharing starts or from that toggle.
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

    /// Whether the system permission was refused, so the Settings screen can
    /// say where to turn it back on instead of a toggle that does nothing.
    public static func isDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    /// Posts `notice` unless the user has turned its module (or the whole
    /// feature) off. Without permission the center drops it silently, which
    /// is the right outcome.
    static func post(_ notice: SharedChangeNotice, moduleName: String) {
        guard isEnabled(moduleID: notice.moduleID) else { return }
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
        UNUserNotificationCenter.current().add(request) { _ in }
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

/// The notification center's delegate: decides whether a notification shows
/// while the app is in front, and routes a tap to its tracker.
final class SharedChangeNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = SharedChangeNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let module = notification.request.content.userInfo[SharedChangeNotifications.moduleUserInfoKey] as? String
        let onScreen = await MainActor.run { SharedChangeNotificationRouter.shared.foregroundModuleID }
        if let module, module == onScreen { return [] }
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let module = response.notification.request.content.userInfo[SharedChangeNotifications.moduleUserInfoKey] as? String
        else { return }
        await MainActor.run { SharedChangeNotificationRouter.shared.moduleToOpen = module }
    }
}
