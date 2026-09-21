import Foundation
import SwiftData

public enum ItemKind: String, Codable, CaseIterable, Sendable {
    case sight
    case food
    case activity
    case lodging
    case transit
    case other

    public var displayName: String {
        switch self {
        case .sight: "Sight"
        case .food: "Food & drink"
        case .activity: "Activity"
        case .lodging: "Stay"
        case .transit: "Getting around"
        case .other: "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .sight: "building.columns"
        case .food: "fork.knife"
        case .activity: "figure.walk"
        case .lodging: "bed.double"
        case .transit: "tram"
        case .other: "mappin"
        }
    }
}

@Model
public final class ItineraryItem {
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

    public var trip: Trip?

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

    /// Ticks or unticks, stamping when — the stamp is what a finished trip's log
    /// reads back.
    public func toggleDone(asOf now: Date = .now) {
        isDone.toggle()
        doneAt = isDone ? now : nil
    }
}
