import Foundation

/// Whether a module's one-time copy out of its old SwiftData store has run
/// for this **iCloud account**, not just this install.
///
/// The importers (`TripLegacyMigration`, `FuelLegacyMigration`,
/// `ExploreLegacyMigration`) used to remember only in UserDefaults, which a
/// reinstall wipes. The old SwiftData records are still in iCloud, so every
/// fresh install ran the copy again and de-duplicated only against whatever
/// had synced down so far, by name: a car not yet downloaded, or one renamed
/// since, was copied again — the user's cars duplicated on each install.
/// Recorded in iCloud key-value storage too, so once any device has finished,
/// no install on that account ever copies again.
public enum LegacyMigrationLedger {
    public static func isComplete(_ key: String) -> Bool {
        UserDefaults.standard.bool(forKey: key)
            || (NSUbiquitousKeyValueStore.default.object(forKey: key) as? Bool ?? false)
    }

    public static func markComplete(_ key: String) {
        UserDefaults.standard.set(true, forKey: key)
        NSUbiquitousKeyValueStore.default.set(true, forKey: key)
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    /// Forgets `key` in both places — for tests, which drive an importer from
    /// scratch, and for debugging a fresh import.
    public static func reset(_ key: String) {
        UserDefaults.standard.removeObject(forKey: key)
        NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
    }
}
