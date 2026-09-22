import Core
import Foundation

/// A plain value type, not SwiftData- or Core Data-dependent, so it lives here
/// rather than in either `Legacy*` or the new Core Data model files — both
/// `LegacyGuidePlace`/`GuidePlace` read the same `PlaceCategory`, and its
/// rawValue is what's actually stored (in `categoryRaw`), so a case can be
/// added here without it being a schema change on either side.

/// The three shelves every guide is split into.
public enum PlaceCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case foodAndDrinks
    case places
    case activities

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .foodAndDrinks: "Food & Drinks"
        case .places: "Places"
        case .activities: "Activities"
        }
    }

    /// The map's filter chips are narrower than the segmented control.
    public var shortName: String {
        switch self {
        case .foodAndDrinks: "Food"
        case .places: "Places"
        case .activities: "Activities"
        }
    }

    public var symbolName: String {
        switch self {
        case .foodAndDrinks: "fork.knife"
        case .places: "building.columns.fill"
        case .activities: "figure.walk"
        }
    }

    /// "6 food & drinks", "1 place", "2 activities" — the chips on a guide card.
    public func countText(_ count: Int) -> String {
        switch self {
        case .foodAndDrinks: counted(count, "food & drink", plural: "food & drinks")
        case .places: counted(count, "place")
        case .activities: counted(count, "activity", plural: "activities")
        }
    }
}
