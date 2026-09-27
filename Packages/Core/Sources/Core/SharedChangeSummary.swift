import CloudKit
import CoreData
import Foundation

// The pure half of shared-change notifications: which history changes count,
// who made them, and how a burst of them turns into one notification. No
// Core Data store and no CloudKit here, so all of it is testable with plain
// values. `SharedChangeNotifier` feeds it from the real persistent history.

// MARK: - What a module says about a change

/// How one object changed, as persistent history recorded it.
public enum SharedChangeKind: Sendable, Equatable {
    case inserted
    case updated
    case deleted
}

/// What a module's describer is handed alongside the changed object.
public struct SharedObjectChange: Sendable, Equatable {
    public let kind: SharedChangeKind
    /// Attribute and relationship names an update touched. Empty for an insert.
    public let updatedProperties: Set<String>

    public init(kind: SharedChangeKind, updatedProperties: Set<String> = []) {
        self.kind = kind
        self.updatedProperties = updatedProperties
    }
}

/// A module's wording for one changed object: which shared root it belongs
/// to, what that root is called, and what happened, phrased to follow a
/// person's name — "added Gelato at Giolitti to Day 3".
public struct SharedChangeDescription: Sendable {
    /// The CKShare root the object hangs off — a trip, a vehicle, a guide, a
    /// household. Changes under one root become one notification.
    public let rootID: NSManagedObjectID
    /// "Rome & Amalfi". The notification's title.
    public let rootTitle: String
    public let action: String

    public init(rootID: NSManagedObjectID, rootTitle: String, action: String) {
        self.rootID = rootID
        self.rootTitle = rootTitle
        self.action = action
    }
}

/// Supplied by each Core Data module (`TripTrackerModule.describeSharedChange`
/// and its siblings) and handed to `SharedChangeNotifier` by the app, so Core
/// words a notification without importing any module. Called on the
/// notifier's own background context: read the object, never save it. `nil`
/// means "not worth a notification" — an entity the module doesn't share, an
/// object that has lost its root, or a change nobody would want to hear about.
public typealias SharedChangeDescriber = @Sendable (NSManagedObject, SharedObjectChange) -> SharedChangeDescription?

// MARK: - Filtering persistent history

/// One change from `NSPersistentHistoryTransaction.changes`, as plain values.
public struct HistoryChangeRecord: Sendable, Equatable {
    /// The object ID's URI, stable for the life of the store.
    public let objectKey: String
    public let entityName: String
    public let kind: SharedChangeKind
    public let updatedProperties: Set<String>

    public init(objectKey: String, entityName: String, kind: SharedChangeKind, updatedProperties: Set<String> = []) {
        self.objectKey = objectKey
        self.entityName = entityName
        self.kind = kind
        self.updatedProperties = updatedProperties
    }
}

/// One `NSPersistentHistoryTransaction`, as plain values.
public struct HistoryTransactionRecord: Sendable, Equatable {
    public let author: String?
    public let changes: [HistoryChangeRecord]

    public init(author: String?, changes: [HistoryChangeRecord]) {
        self.author = author
        self.changes = changes
    }
}

public enum SharedChangeFilter {
    /// The `transactionAuthor` `NSPersistentCloudKitContainer`'s mirroring
    /// delegate writes every import from CloudKit under. Not a public
    /// constant anywhere in the SDK; confirmed as a literal in CoreData's own
    /// binary alongside its siblings `.export`, `.reset`, `.setup` and
    /// `.migration`, which are the mirroring delegate's bookkeeping, never
    /// another person's edit.
    public static let cloudKitImportAuthor = "NSCloudKitMirroringDelegate.import"

    /// What `CloudSharedStore.makeContainer` stamps on each container's view
    /// context, so this device's own saves are named as such in history
    /// rather than left anonymous. The filter below already keeps imports
    /// only; this makes a local save impossible to mistake for one.
    public static let appAuthor = "app"

    /// The changes worth describing, one per object, in the order each
    /// object first changed.
    ///
    /// Only CloudKit imports count — everything else is this device's own
    /// work or the mirroring delegate's bookkeeping. Deletions are dropped:
    /// a deleted object can't be read, so it can't be traced to its root or
    /// described, and a whole root disappearing (the owner stopped sharing,
    /// or deleted the trip) is not a change to tell anyone about. An object
    /// inserted and then updated within the batch reads as the insert; one
    /// that is deleted anywhere in the batch is dropped entirely. Entities
    /// outside `entityNames` — the mirroring delegate's own metadata tables
    /// share the store — are ignored.
    public static func relevantChanges(
        in transactions: [HistoryTransactionRecord],
        entityNames: Set<String>
    ) -> [HistoryChangeRecord] {
        var order: [String] = []
        var merged: [String: HistoryChangeRecord] = [:]
        var deleted: Set<String> = []

        for transaction in transactions where transaction.author == cloudKitImportAuthor {
            for change in transaction.changes where entityNames.contains(change.entityName) {
                if change.kind == .deleted {
                    deleted.insert(change.objectKey)
                    continue
                }
                if let existing = merged[change.objectKey] {
                    merged[change.objectKey] = HistoryChangeRecord(
                        objectKey: existing.objectKey,
                        entityName: existing.entityName,
                        kind: existing.kind == .inserted ? .inserted : change.kind,
                        updatedProperties: existing.updatedProperties.union(change.updatedProperties)
                    )
                } else {
                    order.append(change.objectKey)
                    merged[change.objectKey] = change
                }
            }
        }
        return order.filter { !deleted.contains($0) }.compactMap { merged[$0] }
    }
}

// MARK: - Who made a change

/// Who a change came from, as far as this device can tell.
public enum SharedChangeAuthor: Sendable, Equatable, Hashable {
    /// This iCloud account — from another of the user's own devices. Never
    /// notified: nobody needs telling about their own edit.
    case currentUser
    case named(String)
    /// The record's metadata didn't say, or named nobody in the share.
    case someone
}

/// One participant of the share, as plain values.
public struct ShareParticipantRecord: Sendable, Equatable {
    public let userRecordName: String?
    /// Given name where CloudKit has one — "Saloni", not "Saloni Shah".
    public let displayName: String?
    public let isCurrentUser: Bool

    public init(userRecordName: String?, displayName: String?, isCurrentUser: Bool) {
        self.userRecordName = userRecordName
        self.displayName = displayName
        self.isCurrentUser = isCurrentUser
    }
}

public enum SharedChangeAuthorResolver {
    /// Matches a record's `lastModifiedUserRecordID` against the share's
    /// participants.
    ///
    /// CloudKit writes `CKCurrentUserDefaultName` ("__defaultOwner__") rather
    /// than a real record name for the account doing the reading, so on the
    /// owner's devices their own edits come back under that placeholder.
    public static func author(
        lastModifiedBy recordName: String?,
        participants: [ShareParticipantRecord]
    ) -> SharedChangeAuthor {
        guard let recordName else { return .someone }
        if recordName == CKCurrentUserDefaultName { return .currentUser }
        guard let participant = participants.first(where: { $0.userRecordName == recordName }) else {
            return .someone
        }
        if participant.isCurrentUser { return .currentUser }
        guard let name = participant.displayName, !name.isEmpty else { return .someone }
        return .named(name)
    }

    /// The share's participants, read from the locally cached `CKShare` —
    /// no network.
    public static func participants(of share: CKShare) -> [ShareParticipantRecord] {
        let current = share.currentUserParticipant?.userIdentity.userRecordID?.recordName
        return share.participants.map { participant in
            let recordName = participant.userIdentity.userRecordID?.recordName
            return ShareParticipantRecord(
                userRecordName: recordName,
                displayName: displayName(participant.userIdentity.nameComponents),
                isCurrentUser: recordName != nil && recordName == current
            )
        }
    }

    static func displayName(_ components: PersonNameComponents?) -> String? {
        guard let components else { return nil }
        if let given = components.givenName, !given.isEmpty { return given }
        let full = PersonNameComponentsFormatter.localizedString(from: components, style: .default)
        return full.isEmpty ? nil : full
    }
}

// MARK: - Turning changes into notifications

/// One described change, ready to be coalesced.
public struct SharedChangeEvent: Sendable, Equatable {
    public let moduleID: String
    public let rootKey: String
    public let rootTitle: String
    public let objectKey: String
    public let kind: SharedChangeKind
    public let action: String
    public let author: SharedChangeAuthor
    /// The iCloud alert subscription that covers this root, if one could —
    /// see `SharedChangeServerAlertID`. Lets a posted notification take the
    /// place of iCloud's vaguer alert about the same change.
    public let serverAlertID: String?

    public init(
        moduleID: String,
        rootKey: String,
        rootTitle: String,
        objectKey: String,
        kind: SharedChangeKind,
        action: String,
        author: SharedChangeAuthor,
        serverAlertID: String? = nil
    ) {
        self.moduleID = moduleID
        self.rootKey = rootKey
        self.rootTitle = rootTitle
        self.objectKey = objectKey
        self.kind = kind
        self.action = action
        self.author = author
        self.serverAlertID = serverAlertID
    }

    /// The root itself arriving: a share this device just accepted, whose
    /// whole contents are about to download.
    var isRootArrival: Bool { kind == .inserted && objectKey == rootKey }
}

/// Holds back the download that follows accepting a share.
///
/// Accepting a trip imports the trip and then everything in it, often over
/// several import transactions. Without this, accepting a share you asked for
/// yourself would announce "Saloni made 40 changes to Rome & Amalfi" a moment
/// later. A root's own insert opens a quiet window for everything under it.
public struct SharedRootArrivals: Sendable {
    public var quietWindow: TimeInterval
    private var arrivals: [String: Date] = [:]

    public init(quietWindow: TimeInterval = 10 * 60) {
        self.quietWindow = quietWindow
    }

    /// Drops what shouldn't be notified from one batch of events: this
    /// account's own edits, and anything under a root that arrived in this
    /// batch or within the quiet window before it.
    public mutating func admit(_ events: [SharedChangeEvent], asOf now: Date = .now) -> [SharedChangeEvent] {
        arrivals = arrivals.filter { now.timeIntervalSince($0.value) < quietWindow }
        for event in events where event.isRootArrival {
            arrivals[event.rootKey] = now
        }
        return events.filter { $0.author != .currentUser && arrivals[$0.rootKey] == nil }
    }
}

/// A notification ready to post.
public struct SharedChangeNotice: Sendable, Equatable {
    public let moduleID: String
    public let rootKey: String
    public let title: String
    public let body: String
    /// See `SharedChangeEvent.serverAlertID`.
    public let serverAlertID: String?

    public init(moduleID: String, rootKey: String, title: String, body: String, serverAlertID: String? = nil) {
        self.moduleID = moduleID
        self.rootKey = rootKey
        self.title = title
        self.body = body
        self.serverAlertID = serverAlertID
    }

    /// One per root, so a later burst replaces an older unread notification
    /// about the same trip instead of stacking up beside it.
    public var identifier: String { "shared-change.\(moduleID).\(rootKey)" }
}

/// Turns a stream of events into at most one notification per shared root
/// per burst.
///
/// A burst ends once its root has been quiet for `quietPeriod`, or
/// `maximumDelay` after it started if the edits keep coming — a partner
/// planning a whole day in one sitting shouldn't hold every notification back
/// until they stop.
public struct SharedChangeCoalescer: Sendable {
    public var quietPeriod: TimeInterval
    public var maximumDelay: TimeInterval

    private struct Burst: Sendable {
        var moduleID: String
        var rootTitle: String
        var started: Date
        var lastChange: Date
        /// Changed objects in first-changed order, each with the action that
        /// best describes it: its insert if it had one, else its latest.
        var objectOrder: [String] = []
        var actions: [String: (action: String, isInsert: Bool)] = [:]
        var authors: [SharedChangeAuthor] = []
        var serverAlertID: String?
    }

    private var bursts: [String: Burst] = [:]
    private var burstOrder: [String] = []

    public init(quietPeriod: TimeInterval = 4, maximumDelay: TimeInterval = 20) {
        self.quietPeriod = quietPeriod
        self.maximumDelay = maximumDelay
    }

    public var isEmpty: Bool { bursts.isEmpty }

    public mutating func add(_ event: SharedChangeEvent, at now: Date = .now) {
        var burst = bursts[event.rootKey] ?? {
            burstOrder.append(event.rootKey)
            return Burst(moduleID: event.moduleID, rootTitle: event.rootTitle, started: now, lastChange: now)
        }()
        burst.lastChange = now
        // A rename mid-burst should title the notification by the new name.
        burst.rootTitle = event.rootTitle
        burst.serverAlertID = event.serverAlertID ?? burst.serverAlertID
        if !burst.authors.contains(event.author) { burst.authors.append(event.author) }
        let isInsert = event.kind == .inserted
        if let existing = burst.actions[event.objectKey] {
            if !existing.isInsert { burst.actions[event.objectKey] = (event.action, isInsert) }
        } else {
            burst.objectOrder.append(event.objectKey)
            burst.actions[event.objectKey] = (event.action, isInsert)
        }
        bursts[event.rootKey] = burst
    }

    /// When the next burst will be ready, for scheduling a wake-up.
    public var nextDeadline: Date? {
        bursts.values.map(deadline).min()
    }

    /// Removes and returns every burst that is ready by `now` — all of them
    /// when `force` is set, for when the app is about to be suspended.
    public mutating func due(asOf now: Date = .now, force: Bool = false) -> [SharedChangeNotice] {
        var notices: [SharedChangeNotice] = []
        for key in burstOrder {
            guard let burst = bursts[key], force || deadline(burst) <= now else { continue }
            notices.append(Self.summarize(burst, rootKey: key))
            bursts[key] = nil
        }
        burstOrder.removeAll { bursts[$0] == nil }
        return notices
    }

    private func deadline(_ burst: Burst) -> Date {
        min(burst.lastChange.addingTimeInterval(quietPeriod), burst.started.addingTimeInterval(maximumDelay))
    }

    private static func summarize(_ burst: Burst, rootKey: String) -> SharedChangeNotice {
        let who = subject(for: burst.authors)
        let body: String
        if burst.objectOrder.count == 1, let only = burst.actions[burst.objectOrder[0]] {
            body = "\(who) \(only.action)"
        } else {
            body = "\(who) made \(counted(burst.objectOrder.count, "change")) to \(burst.rootTitle)"
        }
        return SharedChangeNotice(
            moduleID: burst.moduleID,
            rootKey: rootKey,
            title: burst.rootTitle,
            body: body,
            serverAlertID: burst.serverAlertID
        )
    }

    /// "Saloni", "Saloni and Alex", or "Someone" when nobody could be named.
    static func subject(for authors: [SharedChangeAuthor]) -> String {
        let names = authors.compactMap { author -> String? in
            if case .named(let name) = author { return name }
            return nil
        }
        guard !names.isEmpty else { return "Someone" }
        return names.formatted(.list(type: .and))
    }
}
