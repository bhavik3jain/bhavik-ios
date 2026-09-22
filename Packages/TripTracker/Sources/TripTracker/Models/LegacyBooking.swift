import Foundation
import SwiftData

/// The original SwiftData model. See `LegacyTrip`'s doc comment for why this
/// still exists and must not be deleted.
@Model
public final class LegacyBooking {
    /// "Hotel de Russie".
    public var title: String = ""
    /// Who it's with, "Avis".
    public var provider: String = ""
    /// The confirmation code, the thing the Codes screen exists to copy.
    public var code: String = ""
    public var kindRaw: String = BookingKind.other.rawValue
    /// Check-in, pick-up, doors open.
    public var startsAt: Date?
    /// Check-out, drop-off.
    public var endsAt: Date?
    public var contactPhone: String = ""
    public var notes: String = ""
    public var sortOrder: Int = 0
    /// Door codes, key-safe PINs. Encrypted end to end in CloudKit rather than
    /// only at rest, masked on screen until asked for, and never passed to the
    /// PDF's page model — a shared itinerary goes to people who shouldn't be
    /// able to open the flat.
    @Attribute(.allowsCloudEncryption)
    public var secureNote: String = ""

    public var trip: LegacyTrip?

    public var kind: BookingKind {
        get { BookingKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    public init(title: String, kind: BookingKind, code: String = "", provider: String = "") {
        self.title = title
        self.kindRaw = kind.rawValue
        self.code = code
        self.provider = provider
    }
}
