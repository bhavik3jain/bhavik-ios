import Foundation
import SwiftData

@Model
public final class Vehicle {
    public var name: String = ""
    public var createdAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \FuelEntry.vehicle)
    public var entries: [FuelEntry]? = []

    public init(name: String) {
        self.name = name
        self.createdAt = .now
    }

    /// Fill-ups only, oldest first. Odometer order is authoritative because
    /// exported logs sometimes carry mistyped dates.
    public var orderedFillUps: [FuelEntry] {
        (entries ?? [])
            .filter { $0.kind == .fillUp }
            .sorted { $0.odometer < $1.odometer }
    }

    public var orderedServices: [FuelEntry] {
        (entries ?? [])
            .filter { $0.kind == .service }
            .sorted { $0.date > $1.date }
    }
}
