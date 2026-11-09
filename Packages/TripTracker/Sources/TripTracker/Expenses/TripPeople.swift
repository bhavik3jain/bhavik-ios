import Foundation

// MARK: - Plain inputs

/// One person in a trip's `CKShare`, as plain values. The view layer fills
/// these from the cached share (`ShareSnapshot(share:)`); nothing here touches
/// CloudKit, so the roster is a pure function of them.
public struct ShareParticipantSnapshot: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case accepted
        /// Invited, not yet accepted: no user record yet, so no key — listed
        /// greyed out, "Joins the split when they accept".
        case pending
    }

    /// `owner` for the share's owner, `ck:<recordName>` for an accepted
    /// participant; nil for a pending invitee, or an accepted one whose record
    /// name this device can't tell.
    public var key: PersonKey?
    /// Given name where iCloud has one, else the full name, else their email
    /// or phone number. Possibly empty.
    public var name: String
    public var status: Status
    public var isCurrentUser: Bool

    public init(key: PersonKey?, name: String, status: Status, isCurrentUser: Bool = false) {
        self.key = key
        self.name = name
        self.status = status
        self.isCurrentUser = isCurrentUser
    }
}

/// A trip's share, as plain values.
public struct ShareSnapshot: Sendable, Equatable {
    /// In the share's own order.
    public var participants: [ShareParticipantSnapshot]
    /// Who this device's user is — see `TripPeople.currentUserKey`. Nil when
    /// it can't tell: the UI then shows no "you" figures rather than a guess.
    public var currentUserKey: PersonKey?

    public init(participants: [ShareParticipantSnapshot], currentUserKey: PersonKey?) {
        self.participants = participants
        self.currentUserKey = currentUserKey
    }

    /// The name the share gives `key`, if it gives one.
    public func name(for key: PersonKey) -> String? {
        participants.first { $0.key == key && !$0.name.isEmpty }?.name
    }

    /// Keys of everyone who has accepted, owner included.
    public var acceptedKeys: Set<PersonKey> {
        Set(participants.filter { $0.status == .accepted }.compactMap(\.key))
    }
}

/// What this device knows about a trip's share.
public enum TripShareState: Sendable, Equatable {
    /// Not shared — or shared by this person, looked up and gone. Participant
    /// snapshot rows read as people who've left.
    case notShared
    /// Shared, but the share isn't cached yet: snapshot rows are taken at their
    /// word, so nobody flickers to "Left" before the lookup lands.
    case unknown
    case shared(ShareSnapshot)

    public var snapshot: ShareSnapshot? {
        if case .shared(let snapshot) = self { snapshot } else { nil }
    }
}

/// A `SharedTripPerson` row as plain values.
public struct PersonRecord: Sendable, Equatable {
    public var key: PersonKey
    public var name: String
    public var kind: PersonRowKind
    public var mergedInto: PersonKey?
    public var isHidden: Bool
    public var sortOrder: Int
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        key: PersonKey,
        name: String,
        kind: PersonRowKind,
        mergedInto: PersonKey? = nil,
        isHidden: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.key = key
        self.name = name
        self.kind = kind
        self.mergedInto = mergedInto
        self.isHidden = isHidden
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var stamp: Date { updatedAt ?? createdAt ?? .distantPast }
}

// MARK: - The roster

/// Someone the Split face lists.
public struct TripPerson: Identifiable, Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// In the trip's share now (owner included), or the owner of an
        /// unshared trip.
        case iCloud
        /// Added by hand, without the app.
        case manual
        /// Was in the share, isn't any more; their history and balance stay.
        case left
        /// Invited, not accepted yet.
        case pending
    }

    public let id: String
    /// Nil only for a pending invitee (or a participant whose record name
    /// can't be told) — someone who can't be paid or split with yet.
    public let key: PersonKey?
    /// The best name known, possibly empty — see `label`.
    public let name: String
    public let source: Source
    public let isMe: Bool
    /// A manual person hidden from new splits; still in the figures.
    public let isHidden: Bool

    /// "You", their name, or "Someone".
    public var label: String {
        if isMe { return "You" }
        return name.isEmpty ? "Someone" : name
    }

    /// Whether a new expense can include them or be paid by them.
    public var canBeSplitWith: Bool {
        key != nil && !isHidden && (source == .iCloud || source == .manual)
    }

    /// Whether a payment can be recorded to or from them — anyone with a key,
    /// including someone who has left and still owes or is owed.
    public var canSettle: Bool { key != nil && source != .pending }
}

/// The people on a trip's split, from its share and its `SharedTripPerson`
/// rows, plus everything that turns a key into a name.
public struct TripPeople: Sendable, Equatable {
    public let me: PersonKey?
    /// Accepted share participants (owner first), pending invitees, people who
    /// have left, then manual people. Manual people linked to someone else are
    /// left out — they count as that person.
    public let roster: [TripPerson]
    /// Rows folded by key — see `fold`.
    public let rows: [PersonKey: PersonRecord]
    let shareNames: [PersonKey: String]

    public init(share: TripShareState, rows: [PersonRecord], me: PersonKey?) {
        let folded = Self.fold(rows)
        self.me = me
        self.rows = folded
        var shareNames: [PersonKey: String] = [:]
        for participant in share.snapshot?.participants ?? [] {
            if let key = participant.key, !participant.name.isEmpty { shareNames[key] = participant.name }
        }
        self.shareNames = shareNames
        self.roster = Self.buildRoster(share: share, rows: folded, me: me)
    }

    /// Who this device's user is.
    ///
    /// A trip in this person's own (private) store is theirs: `owner`, shared
    /// or not, with no record name to resolve. In the shared store it's the
    /// share's answer (`ShareSnapshot.currentUserKey`), and nil until the share
    /// is cached — never a guess.
    public static func currentUserKey(_ share: TripShareState, isInSharedStore: Bool) -> PersonKey? {
        guard isInSharedStore else { return .owner }
        return share.snapshot?.currentUserKey
    }

    /// Everyone a new expense can include, in roster order.
    public var splittable: [TripPerson] { roster.filter(\.canBeSplitWith) }

    public func person(for key: PersonKey) -> TripPerson? {
        let resolved = resolve(key)
        return roster.first { $0.key == resolved }
    }

    /// The key `key` counts as: a manual person linked to someone
    /// (`mergedIntoKey`) counts as them, following the chain. A cycle reads as
    /// no link at all, so two rows linked to each other never hang the app.
    public func resolve(_ key: PersonKey) -> PersonKey {
        Self.resolveChain(key, rows: rows)
    }

    /// The best name for `key`, after links: the share's, else the newest row's.
    /// Possibly empty.
    public func name(for key: PersonKey) -> String {
        let resolved = resolve(key)
        if let name = shareNames[resolved] { return name }
        if let row = rows[resolved], !row.name.isEmpty { return row.name }
        return rows[key]?.name ?? ""
    }

    /// `name(for:)` for display: "You" for this device's user, "Someone" for
    /// nobody known.
    public func label(for key: PersonKey) -> String {
        let resolved = resolve(key)
        if let me, resolved == me { return "You" }
        let name = name(for: key)
        return name.isEmpty ? "Someone" : name
    }

    /// `label(for:)` for a row that names one key, as the editor's split and
    /// Paid by lists do: a linked manual person keeps their own name with the
    /// link noted, "Alex (counts as Saloni)". Labelled as Saloni, an old
    /// expense split with Alex listed Saloni twice, and ticking both gave her
    /// two shares.
    public func listLabel(for key: PersonKey) -> String {
        let resolved = resolve(key)
        guard resolved != key, let own = rows[key]?.name, !own.isEmpty else { return label(for: key) }
        let target = label(for: resolved)
        return "\(own) (counts as \(target == "You" ? "you" : target))"
    }

    /// One row per key: two devices can each write the same participant's
    /// snapshot. The newest `updatedAt` (else `createdAt`) wins; equal stamps
    /// go to the alphabetically later name, so every device folds alike.
    public static func fold(_ rows: [PersonRecord]) -> [PersonKey: PersonRecord] {
        var folded: [PersonKey: PersonRecord] = [:]
        for row in rows where !row.key.isEmpty {
            guard let existing = folded[row.key] else {
                folded[row.key] = row
                continue
            }
            if row.stamp > existing.stamp || (row.stamp == existing.stamp && row.name > existing.name) {
                folded[row.key] = row
            }
        }
        return folded
    }

    // MARK: Snapshot rows

    /// A participant snapshot row to write: a new one, or a new name for an
    /// existing key.
    public struct ParticipantRowChange: Sendable, Equatable {
        public let key: PersonKey
        public let name: String
        public let isNew: Bool
    }

    /// The snapshot rows a saved expense calls for: one for each share person
    /// it uses (payer or split member) who has no row yet, and a rename for
    /// one whose name has changed. Manual people already have their rows, and
    /// someone the share gives no name gets nothing. Called on save only —
    /// never on opening Split, which would make every visit a synced write and
    /// an iCloud alert for the partner.
    public static func participantRowChanges(
        for keys: some Sequence<PersonKey>,
        share: ShareSnapshot?,
        rows: [PersonRecord]
    ) -> [ParticipantRowChange] {
        guard let share else { return [] }
        let folded = fold(rows)
        return Set(keys).filter(\.isFromShare).sorted().compactMap { key in
            guard let name = share.name(for: key) else { return nil }
            guard let row = folded[key] else { return ParticipantRowChange(key: key, name: name, isNew: true) }
            return row.name == name ? nil : ParticipantRowChange(key: key, name: name, isNew: false)
        }
    }

    // MARK: Building

    static func buildRoster(share: TripShareState, rows: [PersonKey: PersonRecord], me: PersonKey?) -> [TripPerson] {
        var people: [TripPerson] = []
        var listed: Set<PersonKey> = []

        func rowName(_ key: PersonKey) -> String { rows[key]?.name ?? "" }

        switch share {
        case .shared(let snapshot):
            let accepted = snapshot.participants.filter { $0.status == .accepted }
            let ordered = accepted.filter { $0.key == .owner } + accepted.filter { $0.key != .owner }
            for (index, participant) in ordered.enumerated() {
                if let key = participant.key {
                    guard listed.insert(key).inserted else { continue }
                }
                let name = participant.name.isEmpty ? participant.key.map(rowName) ?? "" : participant.name
                people.append(TripPerson(
                    id: participant.key?.raw ?? "unresolved:\(index)",
                    key: participant.key,
                    name: name,
                    source: .iCloud,
                    isMe: participant.isCurrentUser || (participant.key != nil && participant.key == me),
                    isHidden: false
                ))
            }
            for (index, invitee) in snapshot.participants.enumerated() where invitee.status == .pending {
                people.append(TripPerson(
                    id: "pending:\(index):\(invitee.name)",
                    key: nil,
                    name: invitee.name,
                    source: .pending,
                    isMe: false,
                    isHidden: false
                ))
            }
        case .notShared, .unknown:
            listed.insert(.owner)
            people.append(TripPerson(id: PersonKey.owner.raw, key: .owner, name: rowName(.owner), source: .iCloud, isMe: me == .owner, isHidden: false))
        }

        // Share people known only from snapshot rows: gone from the share, or
        // not looked up yet.
        let rest = rows.values
            .filter { $0.key.isFromShare && !listed.contains($0.key) }
            .sorted { ($0.name, $0.key) < ($1.name, $1.key) }
        for row in rest {
            listed.insert(row.key)
            let source: TripPerson.Source = share == .unknown ? .iCloud : .left
            people.append(TripPerson(id: row.key.raw, key: row.key, name: row.name, source: source, isMe: row.key == me, isHidden: false))
        }

        // Manual people, unless linked to someone (they count as them).
        let manual = rows.values
            .filter { !listed.contains($0.key) && !$0.key.isFromShare }
            .filter { row in
                guard let target = row.mergedInto, !target.isEmpty else { return true }
                return resolveChain(row.key, rows: rows) == row.key
            }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                let lhsDate = lhs.createdAt ?? .distantPast, rhsDate = rhs.createdAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate < rhsDate }
                return lhs.key < rhs.key
            }
        for row in manual {
            people.append(TripPerson(id: row.key.raw, key: row.key, name: row.name, source: .manual, isMe: row.key == me, isHidden: row.isHidden))
        }
        return people
    }

    private static func resolveChain(_ key: PersonKey, rows: [PersonKey: PersonRecord]) -> PersonKey {
        var current = key
        var seen: Set<PersonKey> = [key]
        while let next = rows[current]?.mergedInto, !next.isEmpty, next != current {
            guard seen.insert(next).inserted else { return key }
            current = next
        }
        return current
    }
}
