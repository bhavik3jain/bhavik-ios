import Combine
import Foundation
import SwiftUI
import TripTracker

/// The "Apple Intelligence in Trips" switch in Settings: on unless the person
/// turned it off. Read at the app root into Trips' `\.tripAdvisorEnabled` —
/// the module never reads this store itself — so off means no model UI
/// anywhere in Trips, no prewarm, and nothing sent to the model; the plain
/// plan check stays.
///
/// Synced through iCloud key-value storage exactly like `TrackerLayoutStore`:
/// a single preference, turned off on the phone, is off on the Mac too.
/// Mirrored to UserDefaults so the first frame on a new device has a value
/// before the key-value store's first sync lands.
@MainActor
final class TripsIntelligenceStore: ObservableObject {
    static let shared = TripsIntelligenceStore()

    private static let key = "tripsAppleIntelligenceEnabled"

    @Published private(set) var isEnabled: Bool

    private let defaults = UserDefaults.standard
    private let cloud = NSUbiquitousKeyValueStore.default
    private var observer: (any NSObjectProtocol)?

    private init() {
        // Absent means never touched: on. `bool(forKey:)` would read that as off.
        isEnabled = defaults.object(forKey: Self.key) as? Bool ?? true
        // A change made on another device while the app wasn't running is
        // cached locally but only notified to a running process — see
        // `TrackerLayoutStore.init`.
        adoptCloudValue()
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.adoptCloudValue() }
        }
        cloud.synchronize()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.key)
        cloud.set(enabled, forKey: Self.key)
    }

    /// Takes iCloud's value when there is one; mirrored locally but not
    /// written back, which would only echo it to every other device.
    private func adoptCloudValue() {
        guard let incoming = cloud.object(forKey: Self.key) as? Bool, incoming != isEnabled else { return }
        isEnabled = incoming
        defaults.set(incoming, forKey: Self.key)
    }
}

/// Hands the switch to Trips at the root, so it reaches the module's
/// full-screen cover and every sheet inside it.
struct TripsIntelligenceSetting: ViewModifier {
    @ObservedObject private var store = TripsIntelligenceStore.shared

    func body(content: Content) -> some View {
        content.environment(\.tripAdvisorEnabled, store.isEnabled)
    }
}

/// Settings' "Apple Intelligence in Trips" switch — in the phone's Settings
/// screen and, through it, the Mac's Settings window (⌘,), which shows the
/// same `AppSettingsView` as its General tab.
///
/// Hidden, not disabled, where the system or the hardware can never run the
/// model (`showsSetting`): below iOS 26 / macOS 26 or without Apple
/// Intelligence hardware a switch could do nothing, and Trips shows only the
/// plain plan check there anyway.
struct TripsIntelligenceSection: View {
    @ObservedObject private var store = TripsIntelligenceStore.shared
    @Environment(\.tripAdvisor) private var advisor

    private static var deviceName: String {
        #if os(macOS)
        "Mac"
        #else
        "iPhone"
        #endif
    }

    var body: some View {
        let availability = advisor.availability
        if availability.showsSetting {
            Section {
                Toggle(isOn: Binding(get: { store.isEnabled }, set: { store.setEnabled($0) })) {
                    Label("Apple Intelligence in Trips", systemImage: "sparkles")
                }
            } header: {
                Text("Apple Intelligence")
            } footer: {
                Text(footer(availability: availability))
            }
        }
    }

    private func footer(availability: TripAdvisorAvailability) -> String {
        // Not "nothing leaves": the model's work stays on the device, but
        // Suggest Places sends a word ("museum") and a map area to Apple Maps.
        let about = "Reviews your plan and suggests places with Apple Intelligence, on this \(Self.deviceName). Your trip isn't sent anywhere; place searches use Apple Maps."
        guard store.isEnabled else { return about }
        switch availability {
        case .notEnabled: return "\(about) Turn on Apple Intelligence in Settings to use it."
        case .notReady: return "\(about) Apple Intelligence is still getting ready."
        case .unsupportedLanguage: return "\(about) Apple Intelligence doesn't support this \(Self.deviceName)'s language yet."
        case .available, .deviceNotEligible, .unsupportedOS, .turnedOff: return about
        }
    }
}
