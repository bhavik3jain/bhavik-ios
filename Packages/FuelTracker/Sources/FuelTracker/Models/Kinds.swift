import Foundation

/// A plain value type, not SwiftData- or Core Data-dependent, so it lives here
/// rather than in either the SwiftData `FuelEntry` (`SwiftDataFuelEntry.swift`)
/// or the Core Data `SharedFuelEntry` model files — both read the same
/// `EntryKind`, and its rawValue is what's actually stored (in `kindRaw`), so
/// a case can be added here without it being a schema change on either side.
public enum EntryKind: String, Codable, CaseIterable, Sendable {
    case fillUp
    case service
}
