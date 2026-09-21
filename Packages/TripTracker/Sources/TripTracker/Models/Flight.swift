import Foundation
import SwiftData

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

    /// "BA 286", or whatever part of it exists.
    public var designator: String {
        [airlineCode, number].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "FCO → LHR".
    public var route: String {
        guard !originCode.isEmpty || !destinationCode.isEmpty else { return "" }
        return "\(originCode.isEmpty ? "?" : originCode) → \(destinationCode.isEmpty ? "?" : destinationCode)"
    }

    /// "BA 286 · FCO → LHR".
    public var headline: String {
        let parts = [designator, route].filter { !$0.isEmpty }
        return parts.isEmpty ? "Flight" : parts.joined(separator: " · ")
    }
}
