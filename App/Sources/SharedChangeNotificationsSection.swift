import Core
import FinanceTracker
import SwiftUI

/// Settings' Notifications section: "Changes to shared items", plus one
/// switch per tracker that can be shared. See Core's
/// `SharedChangeNotifications` for what is sent and when.
///
/// The switches also drive iCloud's own alerts (`SharedChangeServerAlerts`).
/// Those are subscriptions on the iCloud account, not settings on this
/// device: turning the main switch off deletes them for every device, and
/// turning it on (or changing a tracker's switch) rebuilds them from this
/// device's choices.
///
/// The main switch shows on only when the setting is on *and* the system
/// permission is granted — a switch that reads on while iOS silently drops
/// every notification would be a lie. Turning it on is also the one place
/// outside sharing itself that asks for that permission.
struct SharedChangeNotificationsSection: View {
    /// The trackers whose data can be shared — the Core Data ones, each
    /// with a `SharedChangeNotifier` started in `BhavikApp`.
    static let modules: [SelectedModule] = [.trips, .explore, .fuel, .points, .finance]

    @AppStorage(SharedChangeNotifications.enabledKey) private var enabled = true
    @State private var authorized = false
    @State private var denied = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Section {
            // The setter is a closure literal, not the bare `setEnabled`
            // method reference: Xcode 26.6 (Swift 6.3.3) crashed in IRGen
            // emitting the reabstraction thunk from that main-actor method to
            // Binding's `@isolated(any) @Sendable (Value) -> Void` setter, and
            // CI's "Build the app" step died with exit 65. A closure is emitted
            // straight at the setter's type, so no thunk is needed.
            Toggle(isOn: Binding(get: { enabled && authorized }, set: { setEnabled($0) })) {
                Label("Changes to shared items", systemImage: "bell.badge")
            }
            if enabled && authorized {
                ForEach(Self.modules) { module in
                    ModuleNotificationToggle(module: module)
                }
            }
            // Always reachable — most of all when something above is off.
            NavigationLink {
                NotificationStatusView()
            } label: {
                Label("Notification Status", systemImage: "stethoscope")
            }
        } header: {
            Text("Notifications")
        } footer: {
            if denied {
                Text("Notifications are turned off for this app. Turn them on in the Settings app to hear when someone changes something you share.")
            } else {
                Text("A notification when someone you share a trip, car, guide or household with changes it. iCloud sends a short alert even when the app is closed, to every device on your Apple Account; the app adds who changed what once it has downloaded the change, which may not be until you next open it.")
            }
        }
        .task { await refresh() }
        // Coming back from the Settings app, where the permission may have
        // just been turned on or off.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    private func setEnabled(_ isOn: Bool) {
        enabled = isOn
        guard isOn else {
            SharedChangeServerAlerts.shared.removeAll()
            return
        }
        Task {
            _ = await SharedChangeNotifications.requestAuthorization()
            await refresh()
            // After the permission answer: the pass only creates
            // subscriptions once notifications can actually be shown here.
            SharedChangeServerAlerts.shared.sync(force: true)
        }
    }

    private func refresh() async {
        authorized = await SharedChangeNotifications.isAuthorized()
        denied = await SharedChangeNotifications.isDenied()
    }
}

private struct ModuleNotificationToggle: View {
    let module: SelectedModule
    @AppStorage private var isOn: Bool

    init(module: SelectedModule) {
        self.module = module
        _isOn = AppStorage(wrappedValue: true, SharedChangeNotifications.moduleEnabledKey(module.rawValue))
    }

    var body: some View {
        Toggle(module.accent.name, isOn: $isOn)
            .onChange(of: isOn) { SharedChangeServerAlerts.shared.sync(force: true) }
    }
}

/// Finance's "fill in the month" reminder on the 1st. Its own section: it
/// isn't about shared changes, and works with nothing shared at all. See
/// `FinanceMonthReminder`.
struct FinanceReminderSection: View {
    @AppStorage(FinanceMonthReminder.enabledKey) private var enabled = true

    var body: some View {
        Section {
            Toggle(isOn: $enabled) {
                Label("Monthly Finance reminder", systemImage: "calendar.badge.clock")
            }
            .onChange(of: enabled) { Task { await FinanceMonthReminder.reschedule() } }
        } footer: {
            Text("On the 1st of each month at 9 AM, a reminder to fill in that month's balances.")
        }
    }
}
