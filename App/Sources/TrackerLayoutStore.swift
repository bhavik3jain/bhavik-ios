import Combine
import Core
import Foundation

/// The one live `TrackerLayout`, read by the home screen, the Mac sidebar and
/// its Trackers menu, and edited from Settings.
///
/// Synced through iCloud key-value storage — a few hundred bytes of
/// preference, which is exactly what it's for, rather than a CloudKit record
/// type that would need the Console schema ritual. Mirrored to UserDefaults
/// because the key-value store's first sync on a new device can take a while,
/// and the home screen needs a layout on its first frame.
@MainActor
final class TrackerLayoutStore: ObservableObject {
    static let shared = TrackerLayoutStore()

    private static let key = "trackerLayout"
    private static let known = SelectedModule.allCases.map(\.rawValue)

    @Published private(set) var layout: TrackerLayout

    private let defaults = UserDefaults.standard
    private let cloud = NSUbiquitousKeyValueStore.default
    private var observer: (any NSObjectProtocol)?

    private init() {
        layout = Self.decode(defaults.data(forKey: Self.key)) ?? .default(for: Self.known)
        // Also covers a change that reached this device while the app wasn't
        // running: the key-value store caches it locally, but only notifies a
        // process that's running when it lands. Every local edit writes both
        // stores, so the only way they differ here is a newer remote value.
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

    var allModules: [SelectedModule] { layout.order.compactMap(SelectedModule.init(rawValue:)) }
    var visibleModules: [SelectedModule] { layout.visible.compactMap(SelectedModule.init(rawValue:)) }
    var isDefault: Bool { layout == .default(for: Self.known) }

    func isHidden(_ module: SelectedModule) -> Bool { layout.isHidden(module.rawValue) }
    func canHide(_ module: SelectedModule) -> Bool { layout.canHide(module.rawValue) }

    func setHidden(_ hidden: Bool, for module: SelectedModule) {
        var updated = layout
        updated.setHidden(hidden, for: module.rawValue)
        save(updated)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var updated = layout
        updated.move(fromOffsets: source, toOffset: destination)
        save(updated)
    }

    func reset() {
        save(.default(for: Self.known))
    }

    private func save(_ updated: TrackerLayout) {
        guard updated != layout, let data = try? JSONEncoder().encode(updated) else { return }
        layout = updated
        defaults.set(data, forKey: Self.key)
        cloud.set(data, forKey: Self.key)
    }

    /// Takes whatever iCloud holds, if anything. Mirrored to UserDefaults but
    /// deliberately not written back to iCloud, which would just echo it to
    /// every other device as a fresh change.
    private func adoptCloudValue() {
        guard let data = cloud.data(forKey: Self.key), let incoming = Self.decode(data), incoming != layout else { return }
        layout = incoming
        defaults.set(data, forKey: Self.key)
    }

    private static func decode(_ data: Data?) -> TrackerLayout? {
        guard let data, let stored = try? JSONDecoder().decode(TrackerLayout.self, from: data) else { return nil }
        return stored.resolved(against: known)
    }
}
