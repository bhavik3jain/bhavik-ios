import Foundation
import SwiftData

/// The original SwiftData model. See `LegacyVehicle`'s doc comment for why
/// this still exists and must not be deleted.
@Model
public final class LegacyFuelEntry {
    public var kindRaw: String = EntryKind.fillUp.rawValue
    public var date: Date = Date.now
    public var odometer: Int = 0
    public var gallons: Double = 0
    public var pricePerGallon: Double = 0
    public var totalCost: Double = 0
    /// A partial fill leaves the tank in an unknown state, so its distance
    /// carries forward into the next full tank rather than yielding its own MPG.
    public var isFullTank: Bool = true
    public var octane: String = ""
    public var station: String = ""
    public var notes: String = ""
    /// Service work performed, comma-separated as it appears in exports.
    public var services: String = ""

    public var vehicle: LegacyVehicle?

    public var kind: EntryKind {
        get { EntryKind(rawValue: kindRaw) ?? .fillUp }
        set { kindRaw = newValue.rawValue }
    }

    public init(
        kind: EntryKind = .fillUp,
        date: Date,
        odometer: Int,
        gallons: Double = 0,
        pricePerGallon: Double = 0,
        totalCost: Double = 0,
        isFullTank: Bool = true,
        octane: String = "",
        station: String = "",
        notes: String = "",
        services: String = ""
    ) {
        self.kindRaw = kind.rawValue
        self.date = date
        self.odometer = odometer
        self.gallons = gallons
        self.pricePerGallon = pricePerGallon
        self.totalCost = totalCost
        self.isFullTank = isFullTank
        self.octane = octane
        self.station = station
        self.notes = notes
        self.services = services
    }
}
