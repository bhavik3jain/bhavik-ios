import Foundation

/// One computed fuel-economy data point, tied to the fill-up that closed the tank.
public struct MPGPoint: Identifiable, Sendable {
    public let id: Int
    public let date: Date
    public let odometer: Int
    public let miles: Int
    public let gallons: Double
    public let mpg: Double
}

public enum FuelStatistics {
    /// Computes MPG for each full tank.
    ///
    /// Fuel economy is only knowable when the tank is filled: the distance since
    /// the last full tank is divided by every gallon added over that span,
    /// including any partial fills in between. The first fill-up establishes a
    /// baseline odometer reading and yields no MPG of its own.
    public static func mpgPoints(for fillUps: [FuelEntry]) -> [MPGPoint] {
        let ordered = fillUps
            .filter { $0.kind == .fillUp }
            .sorted { $0.odometer < $1.odometer }

        var points: [MPGPoint] = []
        var lastFullTankOdometer: Int?
        var pendingGallons = 0.0

        for entry in ordered {
            pendingGallons += entry.gallons

            guard entry.isFullTank else { continue }

            if let baseline = lastFullTankOdometer {
                let miles = entry.odometer - baseline
                if miles > 0, pendingGallons > 0 {
                    points.append(
                        MPGPoint(
                            id: entry.odometer,
                            date: entry.date,
                            odometer: entry.odometer,
                            miles: miles,
                            gallons: pendingGallons,
                            mpg: Double(miles) / pendingGallons
                        )
                    )
                }
            }

            lastFullTankOdometer = entry.odometer
            pendingGallons = 0
        }

        return points
    }

    /// Lifetime MPG: total distance between the first and last full tank over
    /// all fuel burned in that span. More accurate than averaging per-tank MPG,
    /// which over-weights short tanks.
    public static func averageMPG(for fillUps: [FuelEntry]) -> Double? {
        let points = mpgPoints(for: fillUps)
        guard !points.isEmpty else { return nil }
        let miles = points.reduce(0) { $0 + $1.miles }
        let gallons = points.reduce(0.0) { $0 + $1.gallons }
        guard gallons > 0 else { return nil }
        return Double(miles) / gallons
    }

    public static func averagePricePerGallon(for fillUps: [FuelEntry]) -> Double? {
        let priced = fillUps.filter { $0.kind == .fillUp && $0.gallons > 0 && $0.totalCost > 0 }
        guard !priced.isEmpty else { return nil }
        let cost = priced.reduce(0.0) { $0 + $1.totalCost }
        let gallons = priced.reduce(0.0) { $0 + $1.gallons }
        guard gallons > 0 else { return nil }
        return cost / gallons
    }

    public static func totalSpend(for entries: [FuelEntry]) -> Double {
        entries.reduce(0.0) { $0 + $1.totalCost }
    }

    /// Total spend grouped into calendar months, oldest first.
    public static func monthlySpend(for entries: [FuelEntry], calendar: Calendar = .current) -> [(month: Date, total: Double)] {
        let grouped = Dictionary(grouping: entries) { entry in
            calendar.date(from: calendar.dateComponents([.year, .month], from: entry.date)) ?? entry.date
        }
        return grouped
            .map { (month: $0.key, total: $0.value.reduce(0.0) { $0 + $1.totalCost }) }
            .sorted { $0.month < $1.month }
    }
}
