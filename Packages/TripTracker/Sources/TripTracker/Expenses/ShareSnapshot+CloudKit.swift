import CloudKit
import Core
import CoreData
import Foundation

public extension ShareSnapshot {
    /// The share's people as plain values, from a `CKShare` already in hand —
    /// `SharingStatusCache.shared.cachedShare(for:)`, never a lookup made here.
    ///
    /// The owner is always `owner`, whatever record name this device sees for
    /// them (`__defaultOwner__` on their own devices, the real one on a
    /// partner's). Other accepted participants are `ck:<recordName>`; pending
    /// invitees have no key. A participant whose record name comes back as
    /// `CKCurrentUserDefaultName` can only be this device's user, and takes
    /// `currentUserRecordName` (a cached `CKContainer.fetchUserRecordID`) if
    /// given — otherwise no key, rather than a guess.
    init(share: CKShare, currentUserRecordName: String? = nil) {
        let current = share.currentUserParticipant
        let me: PersonKey?
        if let current {
            me = current.role == .owner ? .owner : Self.participantKey(current.userIdentity, fallback: currentUserRecordName)
        } else {
            me = nil
        }

        var participants: [ShareParticipantSnapshot] = []
        for participant in share.participants {
            let isCurrentUser = current.map { $0 == participant } ?? false
            let name = Self.name(of: participant.userIdentity)
            if participant.role == .owner {
                participants.append(ShareParticipantSnapshot(key: .owner, name: name, status: .accepted, isCurrentUser: isCurrentUser))
                continue
            }
            switch participant.acceptanceStatus {
            case .accepted:
                let key = Self.participantKey(participant.userIdentity, fallback: isCurrentUser ? currentUserRecordName : nil)
                participants.append(ShareParticipantSnapshot(key: key, name: name, status: .accepted, isCurrentUser: isCurrentUser))
            case .pending:
                participants.append(ShareParticipantSnapshot(key: nil, name: name, status: .pending, isCurrentUser: isCurrentUser))
            default:
                // Removed, or unknown: not on the split from the share's side.
                // Their snapshot row, if any, lists them as having left.
                continue
            }
        }
        self.init(participants: participants, currentUserKey: me)
    }

    private static func participantKey(_ identity: CKUserIdentity, fallback: String?) -> PersonKey? {
        let recordName = identity.userRecordID?.recordName
        if let recordName, !recordName.isEmpty, recordName != CKCurrentUserDefaultName {
            return .participant(recordName: recordName)
        }
        if let fallback, !fallback.isEmpty, fallback != CKCurrentUserDefaultName {
            return .participant(recordName: fallback)
        }
        return nil
    }

    /// Given name, else the full name, else the email or phone they were
    /// invited by. Possibly empty.
    static func name(of identity: CKUserIdentity) -> String {
        if let components = identity.nameComponents {
            if let given = components.givenName, !given.isEmpty { return given }
            let full = PersonNameComponentsFormatter.localizedString(from: components, style: .default)
            if !full.isEmpty { return full }
        }
        if let email = identity.lookupInfo?.emailAddress, !email.isEmpty { return email }
        if let phone = identity.lookupInfo?.phoneNumber, !phone.isEmpty { return phone }
        return ""
    }
}

public extension TripShareState {
    /// What this device knows about `trip`'s share right now, without waiting
    /// on iCloud: the share `SharingStatusCache` already holds, with a lookup
    /// started off the main thread if it's due (the view redraws when it
    /// lands). Never `fetchShares` here — on the main thread that waits on the
    /// container's executor, which is how TestFlight build 16 deadlocked.
    @MainActor
    static func current(
        for trip: SharedTrip,
        in container: NSPersistentCloudKitContainer,
        currentUserRecordName: String? = nil
    ) -> TripShareState {
        _ = SharingStatusCache.shared.status(for: trip.objectID, in: container)
        if let share = SharingStatusCache.shared.cachedShare(for: trip.objectID) {
            return .shared(ShareSnapshot(share: share, currentUserRecordName: currentUserRecordName))
        }
        // Everything in the shared store is in someone's share; not cached yet.
        return isInSharedStore(trip, in: container) ? .unknown : .notShared
    }

    @MainActor
    static func isInSharedStore(_ trip: SharedTrip, in container: NSPersistentCloudKitContainer) -> Bool {
        guard let store = trip.objectID.persistentStore else { return false }
        return container.databaseScope(of: store) == .shared
    }
}

public extension TripPeople {
    /// The trip's people as this device knows them now — see
    /// `TripShareState.current(for:in:)`.
    @MainActor
    static func current(
        for trip: SharedTrip,
        in container: NSPersistentCloudKitContainer,
        currentUserRecordName: String? = nil
    ) -> TripPeople {
        let share = TripShareState.current(for: trip, in: container, currentUserRecordName: currentUserRecordName)
        let me = currentUserKey(share, isInSharedStore: TripShareState.isInSharedStore(trip, in: container))
        return TripPeople(share: share, rows: trip.personRecords, me: me)
    }
}
