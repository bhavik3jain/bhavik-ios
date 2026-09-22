import Foundation
import SwiftData

/// The original SwiftData model. See `LegacyTrip`'s doc comment for why this
/// still exists and must not be deleted.
@Model
public final class LegacyItineraryItem {
    public var title: String = ""
    public var detail: String = ""
    public var kindRaw: String = ItemKind.other.rawValue
    /// Days from the trip's first day, not a date — so moving a trip's dates
    /// carries its whole plan along instead of stranding it on the old days.
    public var dayIndex: Int = 0
    /// Settles order among items that share a time, or have none.
    public var sortOrder: Int = 0
    /// Only the time of day is read; the day comes from `dayIndex`, for the same
    /// reason as above.
    public var startTime: Date?
    /// Zero for "no set length".
    public var durationMinutes: Int = 0
    public var address: String = ""
    public var latitude: Double?
    public var longitude: Double?
    public var isDone: Bool = false
    public var doneAt: Date?

    public var trip: LegacyTrip?

    public var kind: ItemKind {
        get { ItemKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    public var hasCoordinate: Bool { latitude != nil && longitude != nil }

    public init(title: String, kind: ItemKind = .other, dayIndex: Int, startTime: Date? = nil, sortOrder: Int = 0) {
        self.title = title
        self.kindRaw = kind.rawValue
        self.dayIndex = dayIndex
        self.startTime = startTime
        self.sortOrder = sortOrder
    }
}
