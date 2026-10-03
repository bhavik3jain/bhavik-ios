import Core
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Settings → Notifications → Notification Status: why a shared change did
/// or didn't become a notification on this device.
///
/// Built after a partner got nothing when a shared Finance household changed,
/// with no way to tell which of the pipeline's silent stages had stopped it —
/// permission, the switches, iCloud's alert subscriptions, or the notifier's
/// own filters. The check itself is Core's `SharedChangeHealth`; the history
/// is `SharedChangeActivityLog`. Open it on the device that isn't being
/// notified.
struct NotificationStatusView: View {
    @State private var facts: SharedChangeHealthFacts?
    @State private var entries: [SharedChangeLogEntry] = []
    @State private var checking = false
    @State private var testMessage: String?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            verdict

            if let facts {
                deviceSection(facts)
                iCloudSection(facts)
            }

            downloadsSection

            Section {
                Button("Send Test Notification", systemImage: "bell.and.waves.left.and.right") {
                    Task {
                        let error = await SharedChangeNotifications.sendTest()
                        testMessage = error.map { "The system refused it: \($0)" }
                            ?? "Sending in 5 seconds — leave the app or lock the screen to see it as a banner."
                        entries = SharedChangeActivityLog.entries()
                    }
                }
                ShareLink(item: report, subject: Text("Multitrack notification status")) {
                    Label("Share Report", systemImage: "square.and.arrow.up")
                }
            } footer: {
                if let testMessage {
                    Text(testMessage)
                } else {
                    Text("A test that arrives means this device can show notifications; one that doesn't points at the system's settings, including Focus.")
                }
            }

            activitySection
        }
        .navigationTitle("Notification Status")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            // Back from the Settings app, where permission may have changed.
            if phase == .active { Task { await refresh() } }
        }
    }

    // MARK: - Verdict

    @ViewBuilder
    private var verdict: some View {
        Section {
            if let facts {
                let problems = SharedChangeHealth.problems(facts, moduleName: moduleName)
                if problems.isEmpty {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Everything's set up").font(.headline)
                            Text("Shared changes will be notified here. If one still doesn't arrive, check the activity below.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                } else {
                    ForEach(problems) { problem in
                        ProblemRow(problem: problem, action: fixAction(for: problem.fix))
                    }
                }
            } else {
                HStack {
                    ProgressView()
                    Text("Checking…").foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Sections

    private func deviceSection(_ facts: SharedChangeHealthFacts) -> some View {
        Section("This device") {
            LabeledContent("Permission", value: permissionText(facts.permission))
            if facts.permission == .allowed || facts.permission == .quiet {
                LabeledContent("Banners or lock screen", value: facts.showsAlerts ? "On" : "Off")
            }
            LabeledContent("Changes to shared items", value: facts.switchOn ? "On" : "Off")
            ForEach(SharedChangeNotificationsSection.modules) { module in
                LabeledContent(module.accent.name) {
                    Text(moduleState(module.rawValue, facts))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func iCloudSection(_ facts: SharedChangeHealthFacts) -> some View {
        Section {
            if let ids = facts.serverAlertIDs {
                if !facts.participatingModuleIDs.isEmpty {
                    LabeledContent("Shared with you", value: ids.contains(SharedChangeServerAlertID.shared) ? "Set up" : "Missing")
                }
                if facts.expectedOwnedAlertCount > 0 {
                    let owned = ids.filter { $0 != SharedChangeServerAlertID.shared }.count
                    LabeledContent("Your shares", value: "\(min(owned, facts.expectedOwnedAlertCount)) of \(facts.expectedOwnedAlertCount) set up")
                }
                if facts.participatingModuleIDs.isEmpty && facts.expectedOwnedAlertCount == 0 {
                    LabeledContent("Alerts", value: "None needed")
                }
            } else {
                LabeledContent("Alerts", value: facts.serverError ?? "Couldn't check")
            }
            if let pass = SharedChangeActivityLog.lastAlertPass() {
                LabeledContent("Last updated") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(pass.date, format: .relative(presentation: .named))
                        Text(pass.result).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button("Set Up Again", systemImage: "arrow.clockwise") { setUpAlertsAgain() }
                .disabled(checking)
        } header: {
            Text("iCloud alerts")
        } footer: {
            Text("With the app closed, iCloud sends a short alert when something shared changes. These alerts belong to the Apple Account, so every device signed in to it gets them.")
        }
    }

    /// Upload beside download per tracker: whether a slow notification was
    /// this device not sending a change, or the other one not fetching it.
    private var downloadsSection: some View {
        Section {
            ForEach(SharedChangeNotificationsSection.modules) { module in
                let upload = SharedChangeActivityLog.lastExport(moduleID: module.rawValue)
                LabeledContent(module.accent.name) {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let failure = upload.failure {
                            Text("Upload failed \(failure.date.formatted(.relative(presentation: .named)))")
                                .foregroundStyle(.red)
                        } else {
                            syncLine("Uploaded", upload.date)
                        }
                        syncLine("Downloaded", SharedChangeActivityLog.lastImport(moduleID: module.rawValue))
                    }
                    .font(.callout)
                }
            }
        } header: {
            Text("Sync with iCloud")
        } footer: {
            Text("After a change is saved, the app stays open in the background for up to \(Int(CloudExportKeeper.limit)) seconds to upload it. Someone you share with gets iCloud's alert once it's uploaded; the detailed notification waits until their device has downloaded it.")
        }
    }

    private func syncLine(_ verb: String, _ date: Date?) -> some View {
        Group {
            if let date {
                Text("\(verb) \(date.formatted(.relative(presentation: .named)))")
            } else {
                Text("\(verb): not yet").foregroundStyle(.secondary)
            }
        }
    }

    private var activitySection: some View {
        Section {
            if entries.isEmpty {
                Text("Nothing yet. Each shared change this device downloads is listed here, with what happened to it.")
                    .foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.summary)
                    HStack(spacing: 6) {
                        Text(moduleName(entry.moduleID))
                        Text("·")
                        Text(entry.date, format: .relative(presentation: .named))
                        if entry.count > 1 {
                            Text("· ×\(entry.count)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            if !entries.isEmpty {
                Button("Clear Activity", role: .destructive) {
                    SharedChangeActivityLog.clear()
                    entries = []
                }
            }
        } header: {
            Text("Recent activity")
        }
    }

    // MARK: - Fixes

    private func fixAction(for fix: SharedChangeProblem.Fix) -> (title: String, run: () -> Void)? {
        switch fix {
        case .openSystemSettings:
            return ("Open Settings", openSystemSettings)
        case .askPermission:
            return ("Allow Notifications", {
                Task {
                    _ = await SharedChangeNotifications.requestAuthorization()
                    SharedChangeServerAlerts.shared.sync(force: true)
                    await refresh(after: 3)
                }
            })
        case .turnOnSwitch:
            return ("Turn On", {
                UserDefaults.standard.set(true, forKey: SharedChangeNotifications.enabledKey)
                Task {
                    _ = await SharedChangeNotifications.requestAuthorization()
                    SharedChangeServerAlerts.shared.sync(force: true)
                    await refresh(after: 3)
                }
            })
        case .unmute(let module):
            return ("Turn On", {
                UserDefaults.standard.set(true, forKey: SharedChangeNotifications.moduleEnabledKey(module))
                SharedChangeServerAlerts.shared.sync(force: true)
                Task { await refresh(after: 3) }
            })
        case .setUpAlertsAgain:
            return ("Set Up Again", setUpAlertsAgain)
        case .none:
            return nil
        }
    }

    private func setUpAlertsAgain() {
        checking = true
        SharedChangeServerAlerts.shared.sync(force: true)
        // The pass runs in the background; give it a moment before reading
        // the server again.
        Task { await refresh(after: 4) }
    }

    private func openSystemSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { openURL(url) }
        #endif
    }

    // MARK: - Reading

    private func refresh(after delay: TimeInterval = 0) async {
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        checking = true
        let (permission, showsAlerts) = await SharedChangeNotifications.healthPermission()
        let status = await SharedChangeServerAlerts.shared.status()
        let defaults = UserDefaults.standard
        facts = SharedChangeHealthFacts(
            permission: permission,
            showsAlerts: showsAlerts,
            switchOn: defaults.object(forKey: SharedChangeNotifications.enabledKey) as? Bool ?? true,
            mutedModuleIDs: status.inputs.mutedModuleIDs,
            owningModuleIDs: Set(status.inputs.ownedZones.filter(\.hasOthers).map(\.moduleID)),
            participatingModuleIDs: status.inputs.participatingModuleIDs,
            serverAlertIDs: status.serverAlertIDs,
            expectedOwnedAlertCount: status.expectedOwnedAlertCount,
            serverError: status.error
        )
        entries = SharedChangeActivityLog.entries()
        checking = false
    }

    private func moduleName(_ id: String) -> String {
        if id == "app" { return "Multitrack" }
        return SelectedModule(rawValue: id)?.accent.name ?? id
    }

    private func moduleState(_ id: String, _ facts: SharedChangeHealthFacts) -> String {
        var parts: [String] = []
        if facts.participatingModuleIDs.contains(id) { parts.append("shared with you") }
        if facts.owningModuleIDs.contains(id) { parts.append("you share") }
        if parts.isEmpty { parts.append("not shared") }
        parts.append(facts.mutedModuleIDs.contains(id) ? "off" : "on")
        return parts.joined(separator: " · ")
    }

    private func permissionText(_ permission: SharedChangeHealthFacts.Permission) -> String {
        switch permission {
        case .allowed: "Allowed"
        case .quiet: "Delivered quietly"
        case .denied: "Turned off"
        case .notAsked: "Not asked yet"
        }
    }

    /// Plain text for Share Report — what to send whoever is helping.
    private var report: String {
        var lines = ["Multitrack notification status — \(Date.now.formatted(date: .abbreviated, time: .shortened))"]
        #if os(iOS)
        lines.append("Device: \(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)")
        #else
        lines.append("Device: Mac, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        #endif
        if let facts {
            lines.append("Permission: \(permissionText(facts.permission)); banners/lock screen \(facts.showsAlerts ? "on" : "off")")
            lines.append("Changes to shared items: \(facts.switchOn ? "on" : "off")")
            for module in SharedChangeNotificationsSection.modules {
                lines.append("  \(module.accent.name): \(moduleState(module.rawValue, facts))")
            }
            if let ids = facts.serverAlertIDs {
                lines.append("iCloud alerts on server: \(ids.isEmpty ? "none" : ids.sorted().joined(separator: ", "))")
            } else {
                lines.append("iCloud alerts: couldn't check — \(facts.serverError ?? "unknown")")
            }
            let problems = SharedChangeHealth.problems(facts, moduleName: moduleName)
            lines.append("Problems: \(problems.isEmpty ? "none" : problems.map(\.title).joined(separator: "; "))")
        }
        if let pass = SharedChangeActivityLog.lastAlertPass() {
            lines.append("Last alert update: \(pass.date.formatted()) — \(pass.result)")
        }
        for module in SharedChangeNotificationsSection.modules {
            let download = SharedChangeActivityLog.lastImport(moduleID: module.rawValue)
            let upload = SharedChangeActivityLog.lastExport(moduleID: module.rawValue)
            var line = "\(module.accent.name): uploaded \(upload.date?.formatted() ?? "never"), downloaded \(download?.formatted() ?? "never")"
            if let failure = upload.failure {
                line += "; last upload failed \(failure.date.formatted()): \(failure.error)"
            }
            lines.append(line)
        }
        lines.append("Recent activity:")
        for entry in entries.prefix(30) {
            lines.append("  \(entry.date.formatted(date: .numeric, time: .shortened)) [\(moduleName(entry.moduleID))] \(entry.summary)\(entry.count > 1 ? " ×\(entry.count)" : "")")
        }
        return lines.joined(separator: "\n")
    }
}

private struct ProblemRow: View {
    let problem: SharedChangeProblem
    let action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(problem.title).font(.headline)
                    Text(problem.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: problem.isBlocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(problem.isBlocking ? .red : .orange)
            }
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.bordered)
                    .padding(.leading, 30)
            }
        }
        .padding(.vertical, 4)
    }
}
