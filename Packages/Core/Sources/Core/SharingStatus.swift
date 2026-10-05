import CloudKit
import CoreData
import Foundation
import Observation

/// Whether an object participates in a `CKShare`, and if so, this device's
/// relationship to it. Purely descriptive: nothing here mutates a share or an
/// object, so a view can show a "Shared" badge or an owner/participant label
/// without importing CloudKit itself.
public enum SharingStatus: Equatable, Sendable {
    case notShared
    /// This device owns the share. `participantCount` is
    /// `CKShare.participants.count`, which includes the owner.
    case owned(participantCount: Int)
    case sharedWithMe(role: CKShare.ParticipantRole, permission: CKShare.ParticipantPermission)
}

public enum SharingStatusResolver {
    /// Looks up whether `object` participates in a `CKShare` at all, and if so
    /// whether the current device is the owner or a participant.
    ///
    /// Returns `.notShared` if the object isn't shared, if it has no
    /// `currentUserParticipant` (shouldn't happen for a share this device can
    /// see, but read as unshared rather than guess), or if the lookup itself
    /// fails — CloudKit unreachable, no iCloud account, the object not yet
    /// saved (`fetchShares(matching:)` simply omits an unsaved object's ID
    /// from the result rather than throwing, per its own header comment, so
    /// that case falls out of the same `nil` check). Sharing status is
    /// cosmetic UI, never something to crash or block editing over.
    ///
    /// **Synchronous, on the main thread**: `fetchShares(matching:)` waits for
    /// the container's request executor, which iCloud's own imports and
    /// exports hold. Only for decisions that must not act on a stale answer —
    /// `FinanceFold` never folding away a household this person has shared —
    /// and those run rarely. A badge goes through `badgeStatus(for:in:)`.
    @MainActor
    public static func status(for object: NSManagedObject, in container: NSPersistentCloudKitContainer) -> SharingStatus {
        status(of: (try? container.fetchShares(matching: [object.objectID]))?[object.objectID])
    }

    /// For a "Shared" badge or label: this device's last known answer at once,
    /// with the lookup itself done off the main thread (`SharingStatusCache`).
    /// Every badge used to call `status(for:in:)` from a view body, so each
    /// redraw of a trip list, a garage or a guide waited on the container's
    /// executor on the main thread — the same wait that deadlocked Share on
    /// TestFlight build 16 (see CloudShareCalls.swift). `.notShared` until the
    /// first lookup lands, a moment later; the view redraws when it does.
    @MainActor
    public static func badgeStatus(for object: NSManagedObject, in container: NSPersistentCloudKitContainer) -> SharingStatus {
        SharingStatusCache.shared.status(for: object.objectID, in: container)
    }

    /// The status a share (or none) gives this device.
    public static func status(of share: CKShare?) -> SharingStatus {
        guard let share, let currentUser = share.currentUserParticipant else { return .notShared }
        if currentUser.role == .owner {
            return .owned(participantCount: share.participants.count)
        }
        return .sharedWithMe(role: currentUser.role, permission: currentUser.permission)
    }

    /// Whether the current user can edit `object` — for a view deciding
    /// whether to show or enable an edit control. Never waits on iCloud.
    ///
    /// It used to be `canUpdateRecord(forManagedObjectWith:)` straight from
    /// view bodies. For an object in the shared store that call looks its
    /// share up through the container's request executor, which iCloud's own
    /// imports and exports hold — so on the partner's devices every redraw of
    /// a shared trip, car, guide or household waited on the main thread
    /// behind whatever import was running, for as long as it ran (after a
    /// sync reset, minutes). It answers the way that call does, from what's
    /// known locally:
    /// - an unsaved object, or one in this person's own (private) store: yes,
    ///   as `canUpdateRecord` answers for those without asking anything;
    /// - one in the shared store: the permission its share gave this person
    ///   when it was last looked up (`SharingStatusCache`, off the main
    ///   thread); before that lookup lands, the last answer seen for that
    ///   store, which is right on every launch after the first; with neither,
    ///   no — an edit control appears a moment late rather than letting a
    ///   view-only participant save something iCloud will refuse.
    ///
    /// Not for deciding where data is written: see `canEditNow`.
    @MainActor
    public static func canEdit(_ object: NSManagedObject, in container: NSPersistentCloudKitContainer) -> Bool {
        SharingStatusCache.shared.canEdit(object.objectID, in: container)
    }

    /// `canEdit`, asked of Core Data's own sharing records there and then —
    /// synchronous, on the main thread, waiting on the container's executor.
    /// Only for the rare decisions that must not act on a stale or unknown
    /// answer: which household new data is written into, and folding
    /// duplicate households. Like `status(for:in:)`, never from a view body.
    ///
    /// `canUpdateRecord` already defaults permissively (a temporary objectID,
    /// a store not backed by CloudKit and the private database all answer
    /// `true`), so there's no error path to catch.
    @MainActor
    public static func canEditNow(_ object: NSManagedObject, in container: NSPersistentCloudKitContainer) -> Bool {
        container.canUpdateRecord(forManagedObjectWith: object.objectID)
    }
}

/// Sharing status for badges, looked up on a background queue and kept per
/// object, so no view body ever waits on iCloud. See
/// `SharingStatusResolver.badgeStatus(for:in:)`.
///
/// An answer is reused for `maxAge`, then looked up again the next time a view
/// asks, while the old one keeps showing. Sharing a thing, or stopping, clears
/// everything (`invalidateAll()`), so a badge changes as soon as the share
/// sheet closes rather than up to `maxAge` later.
@MainActor
@Observable
public final class SharingStatusCache {
    public static let shared = SharingStatusCache()

    /// How long a looked-up status is shown before it's checked again.
    nonisolated static let maxAge: TimeInterval = 30

    /// Observed: a view that read an object's status redraws when it lands.
    private var statuses: [NSManagedObjectID: SharingStatus] = [:]
    /// Not observed: written from inside view bodies, which must not
    /// invalidate the view that's drawing.
    @ObservationIgnored private var checkedAt: [NSManagedObjectID: Date] = [:]
    @ObservationIgnored private var inFlight: Set<NSManagedObjectID> = []
    /// The share each lookup found, kept for the Mac's share sheet: it can
    /// show an existing share's link and people at once instead of waiting
    /// its turn on the container's executor behind iCloud's own sync, which
    /// is what made the Mac's Share buttons slow. The sheet still fetches a
    /// fresh one and replaces this when it lands.
    @ObservationIgnored private var shares: [NSManagedObjectID: CKShare] = [:]

    init() {}

    public func status(for objectID: NSManagedObjectID, in container: NSPersistentCloudKitContainer, asOf now: Date = .now) -> SharingStatus {
        // An unsaved object can't be shared, and its ID is about to change.
        guard !objectID.isTemporaryID else { return .notShared }
        if Self.needsLookup(checkedAt: checkedAt[objectID], isInFlight: inFlight.contains(objectID), asOf: now) {
            lookUp(objectID, in: container)
        }
        return statuses[objectID] ?? .notShared
    }

    /// The share the last lookup found for `objectID`, if any. Possibly stale
    /// by up to `maxAge`, or by a share made, changed or stopped since.
    public func cachedShare(for objectID: NSManagedObjectID) -> CKShare? {
        shares[objectID]
    }

    /// See `SharingStatusResolver.canEdit(_:in:)`. Reads `statuses` for an
    /// object in the shared store, so the view asking redraws when its
    /// lookup lands.
    public func canEdit(_ objectID: NSManagedObjectID, in container: NSPersistentCloudKitContainer, asOf now: Date = .now) -> Bool {
        guard !objectID.isTemporaryID,
              let store = objectID.persistentStore,
              container.databaseScope(of: store) == .shared
        else { return true }
        _ = status(for: objectID, in: container, asOf: now)
        return Self.editability(
            lookedUp: statuses[objectID],
            storeDefault: store.identifier.flatMap { storeEditability[$0] }
        )
    }

    /// Whether an object in the shared store is editable: the permission its
    /// share gives this person once looked up, else the store's last answer,
    /// else no. A lookup that came back without a share (`fetchShares`
    /// failed, or hasn't caught up with an accepted share) counts as not
    /// knowing — everything in the shared store is in someone's share.
    nonisolated static func editability(lookedUp: SharingStatus?, storeDefault: Bool?) -> Bool {
        switch lookedUp {
        case .sharedWithMe(_, let permission)?: permission == .readWrite
        // The owner's own share can't be in this person's shared store; if it
        // ever reads that way, the owner can edit.
        case .owned?: true
        case .notShared?, nil: storeDefault ?? false
        }
    }

    /// The last permission a lookup found in each shared store, by store
    /// identifier — `canEdit`'s answer while an object's own lookup is still
    /// out. Kept across launches, since the first redraws after launch are
    /// exactly when iCloud's import holds the executor longest. One entry
    /// per store, not per object: a store holds the shares accepted on this
    /// device, almost always one per tracker.
    @ObservationIgnored private var storeEditability: [String: Bool] = UserDefaults.standard
        .dictionary(forKey: SharingStatusCache.storeEditabilityKey) as? [String: Bool] ?? [:]

    nonisolated static let storeEditabilityKey = "SharingStatusCache.storeEditability"

    /// Forgets every answer, after a share was made, changed or stopped. The
    /// statuses shown stay until their fresh lookups land, so nothing flickers.
    public func invalidateAll() {
        checkedAt.removeAll()
        // Touches the observed dictionary (same value) so the views showing a
        // badge redraw, ask again, and so start their fresh lookups.
        statuses = statuses
    }

    /// Whether to look an object up again: never while a lookup is running,
    /// and otherwise when it never was, or not for `maxAge`.
    nonisolated static func needsLookup(checkedAt: Date?, isInFlight: Bool, asOf now: Date) -> Bool {
        guard !isInFlight else { return false }
        guard let checkedAt else { return true }
        return now.timeIntervalSince(checkedAt) >= maxAge
    }

    /// Objects waiting for a lookup, per container, gathered over one pass of
    /// the run loop — every badge a screen draws asks in the same body pass.
    @ObservationIgnored private var pending: [ObjectIdentifier: (container: NSPersistentCloudKitContainer, ids: [NSManagedObjectID])] = [:]

    /// Asks for `objectID` in the next batch. One `fetchShares(matching:)`
    /// per container per batch, not one per badge: a Mac Overview and
    /// sidebar showing twenty trips, cars and guides made twenty calls, each
    /// waiting its turn on the container's executor.
    private func lookUp(_ objectID: NSManagedObjectID, in container: NSPersistentCloudKitContainer) {
        inFlight.insert(objectID)
        let key = ObjectIdentifier(container)
        let isFirst = pending.isEmpty
        pending[key, default: (container, [])].ids.append(objectID)
        guard isFirst else { return }
        Task { @MainActor in self.flush() }
    }

    private func flush() {
        let batches = pending
        pending.removeAll()
        for (_, batch) in batches {
            let ids = batch.ids
            batch.container.fetchSharesInBackground(for: ids) { shares in
                let statuses = ids.map { ($0, SharingStatusResolver.status(of: shares[$0])) }
                Task { @MainActor in
                    for (id, status) in statuses {
                        self.record(status, for: id)
                        self.shares[id] = shares[id]
                    }
                }
            }
        }
    }

    func record(_ status: SharingStatus, for objectID: NSManagedObjectID, asOf now: Date = .now) {
        inFlight.remove(objectID)
        checkedAt[objectID] = now
        // Only a change is written, so a status that stays the same doesn't
        // redraw every screen showing it every `maxAge`.
        if statuses[objectID] != status {
            statuses[objectID] = status
        }
        // Only an accepted share says anything about its store's permission.
        if case .sharedWithMe(_, let permission) = status,
           let storeID = objectID.persistentStore?.identifier,
           storeEditability[storeID] != (permission == .readWrite) {
            storeEditability[storeID] = permission == .readWrite
            UserDefaults.standard.set(storeEditability, forKey: Self.storeEditabilityKey)
        }
    }
}
