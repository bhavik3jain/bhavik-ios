import Foundation

/// Who someone is on a trip's split, as a string every device agrees on.
///
/// | raw               | who                                                |
/// |-------------------|----------------------------------------------------|
/// | `owner`           | the share's owner, or me on an unshared trip       |
/// | `ck:<recordName>` | any other accepted share participant               |
/// | `manual:<UUID>`   | someone without the app, made once by one device   |
///
/// The owner is keyed by role, not record name: on the owner's own devices
/// CloudKit names them `__defaultOwner__`, while partners see their real record
/// name, so a record name would give the owner two keys depending on who's
/// looking.
public struct PersonKey: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public static let owner = PersonKey("owner")

    static let participantPrefix = "ck:"
    static let manualPrefix = "manual:"

    public static func participant(recordName: String) -> PersonKey {
        PersonKey(participantPrefix + recordName)
    }

    public static func manual(_ id: UUID = UUID()) -> PersonKey {
        PersonKey(manualPrefix + id.uuidString)
    }

    public var isOwner: Bool { raw == Self.owner.raw }
    public var isManual: Bool { raw.hasPrefix(Self.manualPrefix) }
    /// A share participant other than the owner.
    public var isParticipant: Bool { raw.hasPrefix(Self.participantPrefix) }
    /// The owner or a participant — someone iCloud knows, as opposed to a
    /// manual person.
    public var isFromShare: Bool { isOwner || isParticipant }

    /// The CloudKit user record name of a `ck:` key.
    public var recordName: String? {
        isParticipant ? String(raw.dropFirst(Self.participantPrefix.count)) : nil
    }

    public var isEmpty: Bool { raw.isEmpty }

    public var description: String { raw }

    /// By raw value — the tie order every allocation and settle-up uses, so
    /// every device gets the same answer.
    public static func < (lhs: PersonKey, rhs: PersonKey) -> Bool { lhs.raw < rhs.raw }

    public init(from decoder: any Decoder) throws {
        raw = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}
