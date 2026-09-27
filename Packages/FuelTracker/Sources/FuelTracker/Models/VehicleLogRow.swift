import CoreData
import Foundation

/// One row of the Mac vehicle page's table: a fill-up or a service, merged by
/// date, newest first.
///
/// The phone keeps fill-ups and services in two lists. The desktop table has
/// the width to show them in one timeline, so a service reads where it
/// happened between two tanks rather than in a section below every fill-up.
struct VehicleLogRow: Identifiable, Equatable {
    let id: NSManagedObjectID
    let kind: EntryKind
    let date: Date
    let odometer: Int
    /// Nil on a service, which buys no fuel.
    let gallons: Double?
    /// Nil on a service, and on a fill-up with neither a recorded price nor
    /// the gallons and total to work one out from.
    let pricePerGallon: Double?
    let total: Double
    /// Only on a full tank that closed a measurable span — see
    /// `FuelStatistics.mpgPoints(for:)`.
    let mpg: Double?
    let isPartial: Bool
    /// The station on a fill-up, the work done on a service.
    let note: String

    /// Every entry in `fillUps` and `services`, newest first. Two entries on
    /// one day fall back to the odometer, so the later reading still sits
    /// above the earlier one.
    static func rows(fillUps: [SharedFuelEntry], services: [SharedFuelEntry]) -> [VehicleLogRow] {
        let mpgByOdometer = Dictionary(
            FuelStatistics.mpgPoints(for: fillUps).map { ($0.odometer, $0.mpg) },
            uniquingKeysWith: { first, _ in first }
        )
        let fuel = fillUps.map { entry in
            VehicleLogRow(
                id: entry.objectID,
                kind: .fillUp,
                date: entry.date,
                odometer: entry.odometer,
                gallons: entry.gallons,
                pricePerGallon: price(of: entry),
                total: entry.totalCost,
                mpg: entry.isFullTank ? mpgByOdometer[entry.odometer] : nil,
                isPartial: !entry.isFullTank,
                note: entry.station
            )
        }
        let work = services.map { entry in
            VehicleLogRow(
                id: entry.objectID,
                kind: .service,
                date: entry.date,
                odometer: entry.odometer,
                gallons: nil,
                pricePerGallon: nil,
                total: entry.totalCost,
                mpg: nil,
                isPartial: false,
                note: entry.services.isEmpty ? "Service" : entry.services
            )
        }
        return (fuel + work).sorted { lhs, rhs in
            lhs.date != rhs.date ? lhs.date > rhs.date : lhs.odometer > rhs.odometer
        }
    }

    /// What `kind` cost in the calendar year containing `now` — the "Fuel
    /// this year" and "Service this year" tiles.
    static func spend(
        on kind: EntryKind,
        in rows: [VehicleLogRow],
        yearOf now: Date = .now,
        calendar: Calendar = .current
    ) -> Double {
        let year = calendar.component(.year, from: now)
        return rows
            .filter { $0.kind == kind && calendar.component(.year, from: $0.date) == year }
            .reduce(0) { $0 + $1.total }
    }

    /// The recorded price, or the total over the gallons when a Fuelly import
    /// left the price column blank.
    private static func price(of entry: SharedFuelEntry) -> Double? {
        if entry.pricePerGallon > 0 { return entry.pricePerGallon }
        guard entry.gallons > 0, entry.totalCost > 0 else { return nil }
        return entry.totalCost / entry.gallons
    }
}
