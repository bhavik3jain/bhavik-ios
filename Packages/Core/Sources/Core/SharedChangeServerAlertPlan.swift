import Foundation

// The pure half of the iCloud-delivered alerts about shared changes: which
// CloudKit subscriptions should exist, what they say, and how that compares
// with what the server already holds. No CloudKit here, so it is testable
// with plain values; `SharedChangeServerAlerts` gathers the inputs and makes
// the calls.
//
// Why these exist at all: the local notifications (`SharedChangeNotifier`)
// only happen once this device has imported the change, and iOS never wakes
// a force-quit app with the silent push that would make it import. A
// subscription whose `notificationInfo` carries an alert is shown by the
// system straight from Apple's push, with the app not running at all. The
// price is that the text is fixed when the subscription is saved: it can
// name the shared trip, but never who changed it or what.
//
// What CloudKit supports, from the CKRecordZoneSubscription,
// CKDatabaseSubscription, CKQuerySubscription and CKSubscription reference
// pages (checked September 2026):
//
// - Record zone subscriptions: the private database only. Query
//   subscriptions: public and private only. The shared database takes
//   nothing but a CKDatabaseSubscription, which fires for any zone in it —
//   so a participant's alert can't say which share changed.
// - "A subscription applies only to the user that creates it", and CloudKit
//   "sends push notifications to all devices with that subscription except
//   for the one that makes the original changes". So the device that made an
//   edit never hears about it, but the same iCloud account's *other* devices
//   do: editing a shared trip on the iPad alerts the iPhone. There is no
//   "not from this user" option. A CKQuerySubscription filtered on
//   `lastModifiedUserRecordID` might avoid it on the owner's side only, but
//   would need a Queryable index on that system field for every Core Data
//   record type (a Console deployment), one subscription per zone per record
//   type, and an inequality predicate on a system reference that nothing
//   documents as supported — and it can't exist in the shared database at
//   all. Not done. `SharedChangeServerAlertCleanup` removes such an alert
//   once this device imports the change and sees it was the user's own,
//   which only helps while the app is still alive in the background.
// - Subscriptions belong to the iCloud account, not the device. Every device
//   signed in to the account shows these alerts, so the Settings switch
//   that creates or deletes them acts for all of them.
// - NSPersistentCloudKitContainer keeps silent subscriptions of its own
//   ("com.apple.coredata.cloudkit.private.subscription" and its shared
//   sibling). Ours all start with `SharedChangeServerAlertID.prefix`, and
//   nothing here reads, changes or deletes a subscription without it.
// - A CKSubscription.NotificationInfo has no thread identifier and no
//   custom userInfo. What a delivered alert does carry is its category and
//   CloudKit's own "ck" payload, which names the subscription — so the
//   subscription ID is what tells a tapped or superseded alert apart.

/// Our subscription IDs, which encode what an alert is about.
public enum SharedChangeServerAlertID {
    /// Every subscription this app saves for an alert starts with this. Only
    /// subscriptions with it are ever deleted.
    public static let prefix = "multitrack.alert."

    /// The participant's single subscription on the shared database.
    public static let shared = prefix + "shared"

    static let zonePrefix = prefix + "zone."

    /// The owner's subscription on one shared zone of their private database.
    /// `moduleID` is `HomeView`'s `SelectedModule` raw value, which never
    /// contains a dot; the zone name may.
    public static func zone(moduleID: String, zoneName: String) -> String {
        "\(zonePrefix)\(moduleID).\(zoneName)"
    }

    /// What CloudKit is asked to send as `apns-collapse-id`, which APNs
    /// caps at 64 bytes — a zone subscription's ID is longer, and a push
    /// with an oversized one is refused outright. The end of the ID is kept:
    /// it holds the zone's UUID.
    public static func collapseID(for id: String) -> String {
        guard id.utf8.count > 64 else { return id }
        return "mt." + String(decoding: id.utf8.suffix(61), as: UTF8.self)
    }

    public enum Parsed: Equatable, Sendable {
        case zone(moduleID: String, zoneName: String)
        case shared
    }

    /// Which tracker a tapped alert should open. A zone alert names its
    /// module; the participant's alert only can when everything shared with
    /// this user is in one tracker. Otherwise nil, and the app just opens.
    public static func moduleToOpen(subscriptionID: String?, participatingModuleIDs: Set<String>) -> String? {
        switch subscriptionID.flatMap(SharedChangeServerAlertID.parse) {
        case .zone(let moduleID, _):
            return moduleID
        case .shared:
            return participatingModuleIDs.count == 1 ? participatingModuleIDs.first : nil
        case nil:
            return nil
        }
    }

    public static func parse(_ id: String) -> Parsed? {
        if id == shared { return .shared }
        guard id.hasPrefix(zonePrefix) else { return nil }
        let rest = id.dropFirst(zonePrefix.count)
        guard let dot = rest.firstIndex(of: "."), dot != rest.startIndex else { return nil }
        let zoneName = rest[rest.index(after: dot)...]
        guard !zoneName.isEmpty else { return nil }
        return .zone(moduleID: String(rest[..<dot]), zoneName: String(zoneName))
    }
}

/// The fixed wording, and the category every such alert is delivered under.
public enum SharedChangeServerAlertText {
    /// What `UNNotificationContent.categoryIdentifier` reads on a delivered
    /// alert — how the notification delegate tells them from the app's own.
    public static let category = "shared-change-server"
    public static let title = "Multitrack"
    public static let participantBody = "Something shared with you was updated"

    /// Long enough for any real name; a push payload has a size limit.
    static let maximumTitleLength = 80

    /// "Rome & Amalfi was updated". A root with no name reads by the
    /// describer's fallback — "a trip" — so that is capitalised.
    public static func ownerBody(rootTitle: String) -> String {
        var name = rootTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count > maximumTitleLength {
            name = String(name.prefix(maximumTitleLength - 1)) + "…"
        }
        if name.isEmpty { name = "Something you share" }
        if name.hasPrefix("a ") || name.hasPrefix("an ") {
            name = name.prefix(1).uppercased() + name.dropFirst()
        }
        return "\(name) was updated"
    }
}

/// One alert subscription, as plain values — either one we want or one the
/// server already holds.
public struct SharedChangeServerAlert: Sendable, Equatable {
    public enum Database: Sendable, Equatable {
        /// The user's private database, where the zones they share live.
        case owned
        /// The shared database, holding the zones others share with them.
        case participating
    }

    public let id: String
    public let database: Database
    /// For a zone subscription; nil for the shared database's.
    public let zoneName: String?
    public let zoneOwnerName: String?
    public let title: String?
    public let subtitle: String?
    public let body: String?
    public let category: String?

    public init(
        id: String,
        database: Database,
        zoneName: String? = nil,
        zoneOwnerName: String? = nil,
        title: String?,
        subtitle: String? = nil,
        body: String?,
        category: String?
    ) {
        self.id = id
        self.database = database
        self.zoneName = zoneName
        self.zoneOwnerName = zoneOwnerName
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.category = category
    }
}

/// A zone this user owns that is shared with someone, as read from the
/// locally cached `CKShare`s.
public struct SharedZoneAlertSource: Sendable, Equatable, Hashable {
    public let moduleID: String
    /// "Trips" — the alert's subtitle, as on the app's own notifications.
    public let moduleName: String
    public let zoneName: String
    public let zoneOwnerName: String
    /// The root's display name, from the module's describer.
    public let rootTitle: String
    /// Someone else is on the share — invited, joined, or able to join by
    /// link. A share with nobody else in it can only ever alert about the
    /// user's own edits on their other devices.
    public let hasOthers: Bool

    public init(moduleID: String, moduleName: String, zoneName: String, zoneOwnerName: String, rootTitle: String, hasOthers: Bool) {
        self.moduleID = moduleID
        self.moduleName = moduleName
        self.zoneName = zoneName
        self.zoneOwnerName = zoneOwnerName
        self.rootTitle = rootTitle
        self.hasOthers = hasOthers
    }
}

/// Everything the plan depends on, gathered without the network.
public struct SharedChangeServerAlertInputs: Sendable, Equatable {
    public var ownedZones: [SharedZoneAlertSource]
    /// Modules with at least one share someone else owns in this user's
    /// shared store.
    public var participatingModuleIDs: Set<String>
    /// Modules whose switch is off in Settings on this device.
    public var mutedModuleIDs: Set<String>

    public init(ownedZones: [SharedZoneAlertSource] = [], participatingModuleIDs: Set<String> = [], mutedModuleIDs: Set<String> = []) {
        self.ownedZones = ownedZones
        self.participatingModuleIDs = participatingModuleIDs
        self.mutedModuleIDs = mutedModuleIDs
    }
}

/// Which subscriptions to save and delete to bring the server in line.
public struct SharedChangeServerAlertPlan: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        /// This device has the switch on and permission granted: create what
        /// is missing, reword what changed, delete what is stale or muted.
        case reconcile
        /// The switch is off here, or permission isn't granted. Subscriptions
        /// belong to the account, and another device may want them, so
        /// nothing is created and nothing still valid is deleted — only
        /// renames are carried over and subscriptions for shares that are
        /// gone are removed.
        case maintain
        /// The switch was just turned off here: delete every one of ours.
        case removeAll
    }

    public var save: [SharedChangeServerAlert]
    public var delete: [SharedChangeServerAlert]

    public init(save: [SharedChangeServerAlert] = [], delete: [SharedChangeServerAlert] = []) {
        self.save = save
        self.delete = delete
    }

    public var isEmpty: Bool { save.isEmpty && delete.isEmpty }

    /// Every alert the inputs could justify, ignoring this device's per-module
    /// switches.
    public static func candidates(for inputs: SharedChangeServerAlertInputs) -> [SharedChangeServerAlert] {
        var alerts = inputs.ownedZones
            .filter(\.hasOthers)
            .sorted { ($0.moduleID, $0.zoneName) < ($1.moduleID, $1.zoneName) }
            .map { zone in
                SharedChangeServerAlert(
                    id: SharedChangeServerAlertID.zone(moduleID: zone.moduleID, zoneName: zone.zoneName),
                    database: .owned,
                    zoneName: zone.zoneName,
                    zoneOwnerName: zone.zoneOwnerName,
                    title: SharedChangeServerAlertText.title,
                    subtitle: zone.moduleName,
                    body: SharedChangeServerAlertText.ownerBody(rootTitle: zone.rootTitle),
                    category: SharedChangeServerAlertText.category
                )
            }
        if !inputs.participatingModuleIDs.isEmpty {
            alerts.append(participantAlert)
        }
        return alerts
    }

    static let participantAlert = SharedChangeServerAlert(
        id: SharedChangeServerAlertID.shared,
        database: .participating,
        title: SharedChangeServerAlertText.title,
        body: SharedChangeServerAlertText.participantBody,
        category: SharedChangeServerAlertText.category
    )

    /// Compares what should exist with `existing` (everything the two
    /// databases returned — anything without our prefix is ignored).
    public static func make(
        mode: Mode,
        inputs: SharedChangeServerAlertInputs,
        existing: [SharedChangeServerAlert]
    ) -> SharedChangeServerAlertPlan {
        let ours = existing.filter { $0.id.hasPrefix(SharedChangeServerAlertID.prefix) }
        let existingByID = Dictionary(ours.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = candidates(for: inputs)

        switch mode {
        case .removeAll:
            return SharedChangeServerAlertPlan(delete: ours)

        case .reconcile:
            let wanted = candidates.filter { alert in
                switch SharedChangeServerAlertID.parse(alert.id) {
                case .zone(let moduleID, _):
                    return !inputs.mutedModuleIDs.contains(moduleID)
                case .shared:
                    // One alert covers every module, so it stays while any
                    // module it could be about is still wanted.
                    return !inputs.participatingModuleIDs.isSubset(of: inputs.mutedModuleIDs)
                case nil:
                    return false
                }
            }
            let wantedIDs = Set(wanted.map(\.id))
            return SharedChangeServerAlertPlan(
                save: wanted.filter { existingByID[$0.id] != $0 },
                delete: ours.filter { !wantedIDs.contains($0.id) }
            )

        case .maintain:
            let candidateIDs = Set(candidates.map(\.id))
            return SharedChangeServerAlertPlan(
                save: candidates.filter { candidate in
                    guard let current = existingByID[candidate.id] else { return false }
                    return current != candidate
                },
                delete: ours.filter { !candidateIDs.contains($0.id) }
            )
        }
    }
}

/// Removing iCloud's alerts once the app knows better.
public enum SharedChangeServerAlertCleanup {
    /// The owner's zone alerts that one imported batch shows were about
    /// nothing but this account's own edits from another device — CloudKit
    /// alerts every device of the account except the one that made the edit.
    ///
    /// The participant's alert is never among them: it covers every share at
    /// once, so a batch from one share can't vouch for all of them.
    public static func ownEditAlertIDs(in events: [SharedChangeEvent]) -> Set<String> {
        var ownOnly: [String: Bool] = [:]
        for event in events {
            guard let id = event.serverAlertID, id != SharedChangeServerAlertID.shared else { continue }
            ownOnly[id] = (ownOnly[id] ?? true) && event.author == .currentUser
        }
        return Set(ownOnly.filter(\.value).keys)
    }
}
