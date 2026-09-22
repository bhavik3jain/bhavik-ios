import Foundation
import SwiftData

/// The original SwiftData model, under its exact original name. See `Trip`'s
/// (in `SwiftDataTrip.swift`) doc comment for why this still exists, must not
/// be deleted, and must not be renamed.
@Model
public final class Flight {
    /// "BA".
    public var airlineCode: String = ""
    /// "286".
    public var number: String = ""
    /// Airport codes, "FCO".
    public var originCode: String = ""
    public var destinationCode: String = ""
    /// Real moments, unlike an item's time: a flight doesn't move when the trip
    /// around it is rescheduled.
    public var departsAt: Date?
    public var arrivesAt: Date?
    public var seat: String = ""
    public var terminal: String = ""
    public var confirmationCode: String = ""
    /// Which day of the trip the flight sits under.
    public var dayIndex: Int = 0
    public var notes: String = ""

    public var trip: Trip?

    public init(airlineCode: String, number: String, originCode: String, destinationCode: String, dayIndex: Int) {
        self.airlineCode = airlineCode
        self.number = number
        self.originCode = originCode
        self.destinationCode = destinationCode
        self.dayIndex = dayIndex
    }
}
