import Core
import CoreData
import Foundation

/// Everything the chrome around a vehicle needs to say about it, computed once.
///
/// Extracted so the numbers are testable: the chip strip, the peek card, the
/// summary tiles and the home-screen row all read this instead of each running
/// their own `FuelStatistics` calls over the same entries.
public struct VehicleSummary: Identifiable, Sendable, Equatable {
    public let id: NSManagedObjectID
    public let name: String
    /// `nil`, never `0`, when no two full tanks have closed — an unknown MPG and
    /// an MPG of zero are different things and only one of them is worth showing.
    public let averageMPG: Double?
    public let averagePricePerGallon: Double?
    /// Fill-ups only.
    public let fuelSpend: Double
    /// Service records only. Kept apart from `fuelSpend` because the old
    /// "Total spend" tile silently summed both while the tiles beside it were
    /// fuel-only — $13,928 against $5,245 of fuel, with nothing saying so.
    public let serviceSpend: Double
    public let lastOdometer: Int?
    public let lastFillUp: Date?
    public let fillUpCount: Int
    public let serviceCount: Int

    public var totalSpend: Double { fuelSpend + serviceSpend }

    public init(
        id: NSManagedObjectID,
        name: String,
        averageMPG: Double?,
        averagePricePerGallon: Double?,
        fuelSpend: Double,
        serviceSpend: Double,
        lastOdometer: Int?,
        lastFillUp: Date?,
        fillUpCount: Int,
        serviceCount: Int
    ) {
        self.id = id
        self.name = name
        self.averageMPG = averageMPG
        self.averagePricePerGallon = averagePricePerGallon
        self.fuelSpend = fuelSpend
        self.serviceSpend = serviceSpend
        self.lastOdometer = lastOdometer
        self.lastFillUp = lastFillUp
        self.fillUpCount = fillUpCount
        self.serviceCount = serviceCount
    }
}

public extension VehicleSummary {
    @MainActor
    static func summarize(_ vehicle: Vehicle) -> VehicleSummary {
        let fillUps = vehicle.orderedFillUps
        let services = vehicle.orderedServices

        // The odometer-last fill-up, not the latest by date. Exported logs carry
        // mistyped dates — the same defect that makes `orderedFillUps` sort by
        // odometer — and a single typo'd year would otherwise pin a car to the
        // top of the fleet forever.
        let latest = fillUps.last

        return VehicleSummary(
            id: vehicle.objectID,
            name: vehicle.name,
            averageMPG: FuelStatistics.averageMPG(for: fillUps),
            averagePricePerGallon: FuelStatistics.averagePricePerGallon(for: fillUps),
            fuelSpend: FuelStatistics.totalSpend(for: fillUps),
            serviceSpend: FuelStatistics.totalSpend(for: services),
            lastOdometer: latest?.odometer,
            lastFillUp: latest?.date,
            fillUpCount: fillUps.count,
            serviceCount: services.count
        )
    }

    /// Every vehicle, most recently filled first.
    ///
    /// This ordering is the fix for the reported bug: the module used to open on
    /// `vehicles.first`, which is creation order — and for an imported garage
    /// that is the order the names happened to appear in the Fuelly CSV, which
    /// has nothing to do with which car you drive.
    @MainActor
    static func fleet(_ vehicles: [Vehicle]) -> [VehicleSummary] {
        vehicles
            .map(summarize)
            .sorted { lhs, rhs in
                switch (lhs.lastFillUp, rhs.lastFillUp) {
                case let (left?, right?):
                    left == right ? lhs.name < rhs.name : left > right
                case (_?, nil):
                    true
                case (nil, _?):
                    false
                case (nil, nil):
                    lhs.name < rhs.name
                }
            }
    }

    /// The one-line description under "Fuel" on the home screen.
    ///
    /// Lives here rather than in `HomeView` so it can be tested: the app target
    /// carries no test suite, and this string used to name only `vehicles.first`,
    /// which meant a second car was invisible from the hub.
    static func homeDetail(for summaries: [VehicleSummary]) -> String {
        guard !summaries.isEmpty else { return "No vehicles yet" }

        let known = summaries.filter { $0.averageMPG != nil }
        guard !known.isEmpty else {
            // Vehicles exist, but none has closed two full tanks yet.
            return summaries.count == 1 ? summaries[0].name : counted(summaries.count, "vehicle")
        }

        if known.count == 1, summaries.count == 1 {
            return "\(known[0].name) · \(mpgText(known[0].averageMPG)) mpg"
        }
        return known
            .map { "\($0.name) \(mpgText($0.averageMPG))" }
            .joined(separator: " · ")
            + " mpg"
    }

    /// One fraction digit, the format every MPG in the module uses.
    static func mpgText(_ mpg: Double?) -> String {
        guard let mpg else { return "—" }
        return mpg.formatted(.number.precision(.fractionLength(1)))
    }

    /// Three fraction digits, because that is how fuel is actually priced and
    /// what `FuellyImporter.parseDouble` deliberately preserves — a plain
    /// currency format rounds $5.739 to $5.74 and throws that digit away.
    static func pricePerGallonText(_ price: Double?) -> String {
        guard let price else { return "—" }
        return price.formatted(.currency(code: "USD").precision(.fractionLength(3)))
    }

    static func spendText(_ amount: Double) -> String {
        amount.formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }
}
