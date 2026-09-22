import Foundation

/// Plain value types, not SwiftData- or Core Data-dependent, so they live here
/// rather than in either the SwiftData or the Core Data model files — both
/// `ItineraryItem`/`SharedItineraryItem` and `Booking`/`SharedBooking` read the
/// same `ItemKind`/`BookingKind`, and each rawValue is what's actually stored
/// (in `kindRaw`), so a case can be added here without it being a schema
/// change on either side.

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

public enum BookingKind: String, Codable, CaseIterable, Sendable {
    case lodging
    case car
    case train
    case tickets
    case restaurant
    case other

    public var displayName: String {
        switch self {
        case .lodging: "Lodging"
        case .car: "Car"
        case .train: "Train & bus"
        case .tickets: "Tickets"
        case .restaurant: "Restaurant"
        case .other: "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .lodging: "bed.double.fill"
        case .car: "car.fill"
        case .train: "tram.fill"
        case .tickets: "ticket.fill"
        case .restaurant: "fork.knife"
        case .other: "doc.text.fill"
        }
    }
}
