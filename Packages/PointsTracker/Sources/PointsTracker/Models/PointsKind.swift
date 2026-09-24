import Foundation

/// What sort of loyalty programme an account belongs to. Stored as a raw
/// string on `SharedPointsAccount`, so adding a case is not a schema change.
public enum PointsKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case creditCard
    case hotel
    case airline

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .creditCard: "Credit Card"
        case .hotel: "Hotel"
        case .airline: "Airline"
        }
    }

    /// Plural heading for a section of this kind.
    public var groupName: String {
        switch self {
        case .creditCard: "Credit Cards"
        case .hotel: "Hotels"
        case .airline: "Airlines"
        }
    }

    public var symbolName: String {
        switch self {
        case .creditCard: "creditcard.fill"
        case .hotel: "bed.double.fill"
        case .airline: "airplane"
        }
    }

    /// Airlines count miles; everyone else counts points.
    public var unit: PointsUnit {
        self == .airline ? .miles : .points
    }
}

public enum PointsUnit: Sendable {
    case points
    case miles

    public var singular: String { self == .miles ? "mile" : "point" }
    public var abbreviation: String { self == .miles ? "mi" : "pts" }
}
