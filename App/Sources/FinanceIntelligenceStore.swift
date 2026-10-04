import Combine
import Core
import FinanceTracker
import Foundation
import SwiftUI
import TripTracker

/// Finance's two kinds of setting: the "Apple Intelligence in Finance" switch
/// (on unless turned off) and the "Finance reports" section
/// (`FinanceReportPreferences`). Read at the app root into Finance's
/// `\.financeAdvisorEnabled` and `\.financeReportPreferences` — the module
/// never reads this store itself — so off means no model UI anywhere in
/// Finance, no prewarm and nothing sent to the model; the plain month check
/// stays.
///
/// Synced through iCloud key-value storage exactly like
/// `TripsIntelligenceStore`: a preference changed on the phone is changed on
/// the Mac too. Mirrored to UserDefaults so the first frame on a new device
/// has a value before the key-value store's first sync lands — and so the
/// report-ready notice, decided on `SharedChangeNotifier`'s background queue,
/// can read "Notify when a report is ready" without the main actor
/// (`storedPreferences()`).
@MainActor
final class FinanceIntelligenceStore: ObservableObject {
    static let shared = FinanceIntelligenceStore()

    enum Key {
        static let enabled = "financeAppleIntelligenceEnabled"
        static let reviewOnFinish = "financeReports.reviewOnFinish"
        static let notifyWhenReady = "financeReports.notifyWhenReady"
        static let includeTables = "financeReports.includeTables"
        /// The owner's name; "" is Everyone, the same as never set.
        static let defaultOwnerName = "financeReports.defaultOwnerName"

        static let switches = [enabled, reviewOnFinish, notifyWhenReady, includeTables]
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var preferences: FinanceReportPreferences

    private let defaults = UserDefaults.standard
    private let cloud = NSUbiquitousKeyValueStore.default
    private var observer: (any NSObjectProtocol)?

    private init() {
        isEnabled = Self.storedIsEnabled()
        preferences = Self.storedPreferences()
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

    // MARK: - Reading, from any thread

    /// Absent means never touched, which is each switch's default — on.
    /// `bool(forKey:)` would read that as off.
    nonisolated static func storedIsEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Key.enabled) as? Bool ?? true
    }

    nonisolated static func storedPreferences(defaults: UserDefaults = .standard) -> FinanceReportPreferences {
        let standard = FinanceReportPreferences.standard
        let owner = (defaults.string(forKey: Key.defaultOwnerName) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return FinanceReportPreferences(
            reviewOnFinish: defaults.object(forKey: Key.reviewOnFinish) as? Bool ?? standard.reviewOnFinish,
            notifyWhenReady: defaults.object(forKey: Key.notifyWhenReady) as? Bool ?? standard.notifyWhenReady,
            includeTables: defaults.object(forKey: Key.includeTables) as? Bool ?? standard.includeTables,
            defaultOwnerName: owner.isEmpty ? nil : owner
        )
    }

    // MARK: - Writing

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        write(enabled, forKey: Key.enabled)
    }

    func update(_ change: (inout FinanceReportPreferences) -> Void) {
        var next = preferences
        change(&next)
        guard next != preferences else { return }
        if next.reviewOnFinish != preferences.reviewOnFinish { write(next.reviewOnFinish, forKey: Key.reviewOnFinish) }
        if next.notifyWhenReady != preferences.notifyWhenReady { write(next.notifyWhenReady, forKey: Key.notifyWhenReady) }
        if next.includeTables != preferences.includeTables { write(next.includeTables, forKey: Key.includeTables) }
        if next.defaultOwnerName != preferences.defaultOwnerName {
            write(next.defaultOwnerName ?? "", forKey: Key.defaultOwnerName)
        }
        preferences = next
    }

    private func write(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
        cloud.set(value, forKey: key)
    }

    /// Takes iCloud's values where there are any; mirrored locally but not
    /// written back, which would only echo them to every other device.
    private func adoptCloudValues() {
        for key in Key.switches {
            if let incoming = cloud.object(forKey: key) as? Bool {
                defaults.set(incoming, forKey: key)
            }
        }
        if let owner = cloud.string(forKey: Key.defaultOwnerName) {
            defaults.set(owner, forKey: Key.defaultOwnerName)
        }
        let enabled = Self.storedIsEnabled(defaults: defaults)
        if enabled != isEnabled { isEnabled = enabled }
        let stored = Self.storedPreferences(defaults: defaults)
        if stored != preferences { preferences = stored }
    }
}

/// Hands Finance's settings to the module at the root, so they reach its
/// full-screen cover, every sheet inside it and the Mac's report window.
struct FinanceIntelligenceSetting: ViewModifier {
    @ObservedObject private var store = FinanceIntelligenceStore.shared

    func body(content: Content) -> some View {
        content
            .environment(\.financeAdvisorEnabled, store.isEnabled)
            .environment(\.financeReportPreferences, store.preferences)
    }
}

/// A tapped "September's report is ready" (`FinanceReportReady`): the hub has
/// already opened Finance from the same tap (`moduleToOpen`); this hands the
/// month to `FinanceReportRouter`, whose `pending` Finance's root view
/// presents. At the root of every window, so whichever exists when the tap
/// lands takes it, once — `initial`, so a tap that launched the app is still
/// waiting when the first window appears.
struct FinanceReportNotificationRouting: ViewModifier {
    @ObservedObject private var router = SharedChangeNotificationRouter.shared

    func body(content: Content) -> some View {
        content.onChange(of: router.destinationToOpen, initial: true) { _, destination in
            guard let destination, FinanceReportRouter.shared.open(destination: destination) else { return }
            router.destinationToOpen = nil
        }
    }
}

// MARK: - Settings

/// Settings' Apple Intelligence section: one switch per tracker that uses the
/// model, Trips and Finance — in the phone's Settings screen and, through it,
/// the Mac's Settings window (⌘,), which shows the same `AppSettingsView` as
/// its General tab.
///
/// Each switch is hidden, not disabled, where the system or the hardware can
/// never run the model (`showsSetting`, read off the advisor's own
/// availability, never the switch's): below iOS 26 / macOS 26 or without
/// Apple Intelligence hardware a switch could do nothing, and the tracker
/// shows only its plain check there anyway. With neither shown, no section.
struct AppleIntelligenceSection: View {
    @ObservedObject private var trips = TripsIntelligenceStore.shared
    @ObservedObject private var finance = FinanceIntelligenceStore.shared
    @Environment(\.tripAdvisor) private var tripAdvisor
    @Environment(\.financeAdvisor) private var financeAdvisor

    private static var deviceName: String {
        #if os(macOS)
        "Mac"
        #else
        "iPhone"
        #endif
    }

    var body: some View {
        let tripsAvailability = tripAdvisor.availability
        let financeAvailability = financeAdvisor.availability
        let showsTrips = tripsAvailability.showsSetting
        let showsFinance = financeAvailability.showsSetting
        if showsTrips || showsFinance {
            Section {
                if showsTrips {
                    Toggle(isOn: Binding(get: { trips.isEnabled }, set: { trips.setEnabled($0) })) {
                        ModuleSwitchLabel(accent: TripTrackerModule.accent, icon: SelectedModule.trips.icon)
                    }
                    .accessibilityLabel("Apple Intelligence in Trips")
                }
                if showsFinance {
                    Toggle(isOn: Binding(get: { finance.isEnabled }, set: { finance.setEnabled($0) })) {
                        ModuleSwitchLabel(accent: FinanceTrackerModule.accent, icon: SelectedModule.finance.icon)
                    }
                    .accessibilityLabel("Apple Intelligence in Finance")
                }
            } header: {
                Text("Apple Intelligence")
            } footer: {
                Text(footer(
                    trips: showsTrips ? tripsAvailability : nil,
                    finance: showsFinance ? financeAvailability : nil
                ))
            }
        }
    }

    /// What each shown switch does, then — once, for whichever is on — why
    /// the model can't answer yet, if it can't. Both trackers ask the same
    /// system model, so they're never in different states for long.
    private func footer(trips tripsAvailability: TripAdvisorAvailability?, finance financeAvailability: FinanceAdvisorAvailability?) -> String {
        var lines: [String] = []
        if tripsAvailability != nil {
            // Not "nothing leaves": the model's work stays on the device, but
            // Suggest Places sends a word ("museum") and a map area to Apple Maps.
            lines.append("Trips reviews your plan and suggests places on this \(Self.deviceName). Your trip isn't sent anywhere; place searches use Apple Maps.")
        }
        if financeAvailability != nil {
            lines.append("Finance reviews each month on this \(Self.deviceName): what changed, what to watch, what to try next. It sees only the figures the app works out, sends nothing anywhere and never gives investment advice. Turned off, the plain checks stay.")
        }
        var about = lines.joined(separator: "\n\n")
        if let status = status(
            trips: trips.isEnabled ? tripsAvailability : nil,
            finance: finance.isEnabled ? financeAvailability : nil
        ) {
            about += "\n\n" + status
        }
        return about
    }

    private func status(trips: TripAdvisorAvailability?, finance: FinanceAdvisorAvailability?) -> String? {
        let notEnabled = "Turn on Apple Intelligence in Settings to use it."
        let notReady = "Apple Intelligence is still getting ready."
        let language = "Apple Intelligence doesn't support this \(Self.deviceName)'s language yet."
        switch trips {
        case .notEnabled: return notEnabled
        case .notReady: return notReady
        case .unsupportedLanguage: return language
        case .available, .deviceNotEligible, .unsupportedOS, .turnedOff, nil: break
        }
        switch finance {
        case .notEnabled: return notEnabled
        case .notReady: return notReady
        case .unsupportedLanguage: return language
        case .available, .deviceNotEligible, .unsupportedOS, .turnedOff, nil: return nil
        }
    }
}

/// A tracker's name beside its white-on-accent icon, as the Trackers list in
/// the same screen draws it.
private struct ModuleSwitchLabel: View {
    let accent: ModuleAccent
    let icon: String

    var body: some View {
        Label {
            Text(accent.name)
        } icon: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(accent.color, in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

/// Settings' "Finance reports": whether finishing a month writes its review,
/// whether this device hears about a month finished on another one, whether a
/// shared report carries its table views, and whose figures a report opens on.
struct FinanceReportsSection: View {
    /// The household's people, for "Whose, by default". Matched by name.
    let ownerNames: [String]

    @ObservedObject private var store = FinanceIntelligenceStore.shared
    @Environment(\.financeAdvisor) private var advisor

    var body: some View {
        Section {
            // Only where there's a model to write it: elsewhere the finished
            // month shows its plain check, with or without this switch.
            if store.isEnabled, advisor.availability.showsSetting {
                Toggle("Review when finishing a month", isOn: binding(\.reviewOnFinish))
            }
            Toggle("Notify when a report is ready", isOn: binding(\.notifyWhenReady))
                .onChange(of: store.preferences.notifyWhenReady) { _, on in
                    guard on else { return }
                    Task { await SharedChangeNotifications.requestAuthorizationIfUndetermined() }
                }
            Toggle("Table views in shared reports", isOn: binding(\.includeTables))
            Picker("Whose, by default", selection: ownerBinding) {
                Text("Everyone").tag(String?.none)
                ForEach(ownerOptions, id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
            #if os(iOS)
            .pickerStyle(.navigationLink)
            #endif
        } header: {
            Text("Finance reports")
        } footer: {
            Text("Reports are built on this device when you open them and are never saved to iCloud. A report you share is a file: it won't update if the month changes. \u{201C}Notify when a report is ready\u{201D} tells this device when a month is finished on another one.")
        }
    }

    /// The household's names, plus the saved one if it's no longer among
    /// them (renamed, or removed on another device), so the picker still
    /// shows what reports open on rather than a blank.
    private var ownerOptions: [String] {
        var names = ownerNames
        if let saved = store.preferences.defaultOwnerName, !names.contains(saved) {
            names.append(saved)
        }
        return names
    }

    private func binding(_ keyPath: WritableKeyPath<FinanceReportPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.preferences[keyPath: keyPath] },
            set: { value in store.update { $0[keyPath: keyPath] = value } }
        )
    }

    private var ownerBinding: Binding<String?> {
        Binding(
            get: { store.preferences.defaultOwnerName },
            set: { value in store.update { $0.defaultOwnerName = value } }
        )
    }
}

#if DEBUG
/// `-FinanceAdvisorStub YES` swaps in a made-up month reviewer for the whole
/// app, the way `-TripAdvisorStub YES` swaps Trips': the same answers every
/// run, at once, offline, and on hardware with no Apple Intelligence. Set at
/// the root so it reaches Finance's full-screen cover, Settings and the Mac's
/// report window.
struct FinanceAdvisorStub: ViewModifier {
    func body(content: Content) -> some View {
        if StubFinanceAdvisor.isRequested {
            content.environment(\.financeAdvisor, StubFinanceAdvisor(delay: .milliseconds(250)))
        } else {
            content
        }
    }
}
#endif

/// Everything Finance reads from the app root — its settings, the stub in
/// Debug runs, and the report-ready tap — in one modifier for every scene
/// (the main window, the Mac's Settings window and its report window), so
/// none of them falls back to an environment default by being forgotten.
struct FinanceAppEnvironment: ViewModifier {
    func body(content: Content) -> some View {
        content
            .modifier(FinanceIntelligenceSetting())
            #if DEBUG
            .modifier(FinanceAdvisorStub())
            #endif
            .modifier(FinanceReportNotificationRouting())
    }
}
