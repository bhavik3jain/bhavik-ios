import Foundation

// The Split face's stored enums. Like `ItemKind`, each is kept as its raw
// value (`kindRaw`, `categoryRaw`, `splitModeRaw`) with a fallback on read, so
// adding a case is never a schema change.

/// An expense, or a payment between two people. A payment is an expense whose
/// split gives the whole amount to the person paid, so every balance goes
/// through one code path; it never counts toward the trip's total.
public enum ExpenseKind: String, Codable, CaseIterable, Sendable {
    case expense
    case payment
}

public enum ExpenseCategory: String, Codable, CaseIterable, Sendable {
    case food
    case stay
    case transport
    case activity
    case shopping
    case other

    public var displayName: String {
        switch self {
        case .food: "Food & drink"
        case .stay: "Stay"
        case .transport: "Getting around"
        case .activity: "Activity"
        case .shopping: "Shopping"
        case .other: "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .food: "fork.knife"
        case .stay: "bed.double"
        case .transport: "tram"
        case .activity: "figure.walk"
        case .shopping: "bag"
        case .other: "creditcard"
        }
    }
}

/// How an expense is divided. What each split entry's value means depends on
/// it — see `ExpenseSplit`.
public enum ExpenseSplitMode: String, Codable, CaseIterable, Sendable {
    /// Everyone listed pays the same; values are ignored.
    case equal
    /// Values are each person's amount in minor units, summing to the total.
    case exact
    /// Values are weights — a couple counts as 2.
    case shares
    /// Values are basis points, summing to 10,000.
    case percent

    public var displayName: String {
        switch self {
        case .equal: "Equally"
        case .exact: "Amounts"
        case .shares: "Shares"
        case .percent: "Percent"
        }
    }
}

/// A `SharedTripPerson` row is either someone without the app, added by hand,
/// or a snapshot of a share participant's name, written so the name still
/// resolves offline and after they leave.
public enum PersonRowKind: String, Codable, CaseIterable, Sendable {
    case manual
    case participant
}
