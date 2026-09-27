import Core
import SwiftUI

/// Settings' Notifications section: "Changes to shared items", plus one
/// switch per tracker that can be shared. See Core's
/// `SharedChangeNotifications` for what is sent and when.
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
        } header: {
            Text("Notifications")
        } footer: {
            if denied {
                Text("Notifications are turned off for this app. Turn them on in the Settings app to hear when someone changes something you share.")
            } else {
                Text("A notification when someone you share a trip, car, guide or household with changes it. It arrives once this device has downloaded the change from iCloud, which may not be until the next time you open the app.")
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
        guard isOn else { return }
        Task {
            _ = await SharedChangeNotifications.requestAuthorization()
            await refresh()
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
    }
}
