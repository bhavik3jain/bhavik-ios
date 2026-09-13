import Foundation
import Security
import SwiftUI

/// Credentials that follow you between devices, and survive deleting the app.
///
/// `UserDefaults` lives inside the app container, so anything kept there dies
/// with the app and never reaches a second phone. That's wrong for API
/// credentials: your tracked data comes back from CloudKit on reinstall, but
/// the TV and Parcel modules would come back blank and non-functional until you
/// went and found your keys again.
///
/// `kSecAttrSynchronizable` is what places a keychain item into iCloud
/// Keychain, which fixes both halves of that — the values sync to every device
/// on the same Apple ID, and they aren't sitting in a plist in the bargain.
public enum SyncedKeychain {
    public static func string(forKey key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    public static func set(_ value: String, forKey key: String) {
        // Empty means "no credential", which is a delete rather than an empty
        // string — otherwise the settings screens can't tell a cleared key from
        // one that was never entered.
        guard !value.isEmpty else {
            remove(forKey: key)
            return
        }

        let data = Data(value.utf8)
        let query = baseQuery(for: key)

        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }

        var insert = query
        insert[kSecValueData as String] = data
        // Not one of the "ThisDeviceOnly" levels, which iCloud Keychain refuses
        // to sync. AfterFirstUnlock so a background parcel refresh can still
        // read the credentials on a locked phone.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }

    public static func remove(forKey key: String) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
    }

    /// Moves a value written by an older build, which kept these in
    /// `UserDefaults`, so upgrading doesn't silently log you out of TMDB and
    /// FedEx.
    public static func migrateFromUserDefaults(key: String) {
        guard string(forKey: key) == nil else { return }
        let defaults = UserDefaults.standard
        guard let legacy = defaults.string(forKey: key), !legacy.isEmpty else { return }
        set(legacy, forKey: key)
        // Only drop the old copy once the keychain demonstrably has it. A
        // failed SecItemAdd is silent, and deleting first would lose the
        // credential outright.
        guard string(forKey: key) == legacy else { return }
        defaults.removeObject(forKey: key)
    }

    private static func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            // Part of the item's identity, so this only ever matches the
            // synchronising copy and never a stale device-local one.
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
        ]
    }
}

/// `@AppStorage` for things that shouldn't be in `UserDefaults`.
///
/// Reads and writes iCloud Keychain instead, with the same call-site shape:
///
///     @SyncedSecret(TVTrackerModule.apiKeyDefaultsKey) private var apiKey
@propertyWrapper
public struct SyncedSecret: DynamicProperty {
    private let key: String
    @State private var cached: String

    public init(_ key: String) {
        self.key = key
        SyncedKeychain.migrateFromUserDefaults(key: key)
        _cached = State(initialValue: SyncedKeychain.string(forKey: key) ?? "")
    }

    public var wrappedValue: String {
        get { cached }
        nonmutating set {
            cached = newValue
            SyncedKeychain.set(newValue, forKey: key)
        }
    }

    public var projectedValue: Binding<String> {
        // Capturing `self` would pull the whole property wrapper into an
        // escaping @Sendable closure, which it isn't. The State's own binding
        // and the key are all this needs.
        let key = key
        let cached = $cached
        return Binding(
            get: { cached.wrappedValue },
            set: { newValue in
                cached.wrappedValue = newValue
                SyncedKeychain.set(newValue, forKey: key)
            }
        )
    }
}
