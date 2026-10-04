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

// Settings' switch for this store is in `AppleIntelligenceSection`
// (FinanceIntelligenceStore.swift), beside Finance's.
