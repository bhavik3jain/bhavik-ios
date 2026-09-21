import Foundation
import SwiftData
@testable import TripTracker

@MainActor
func makeContext() throws -> ModelContext {
    let schema = Schema(TripTrackerModule.models)
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return ModelContext(container)
}

/// Model-backed tests go through `Trip.dates`, which uses the current calendar,
/// so their fixtures are built with it too.
let current = Calendar.current

func day(_ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    current.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

/// Rome & Amalfi, 6–14 June 2026, inserted with nothing planned yet.
@MainActor
func makeRome(in context: ModelContext) -> Trip {
    let trip = Trip(title: "Rome & Amalfi", destination: "Rome, Italy", startDate: day(6, 6), endDate: day(6, 14))
    trip.latitude = 41.9
    trip.longitude = 12.5
    context.insert(trip)
    return trip
}

@MainActor
@discardableResult
func addItem(
    _ title: String,
    to trip: Trip,
    in context: ModelContext,
    day index: Int,
    at time: (Int, Int)? = nil,
    minutes: Int = 0,
    sortOrder: Int = 0,
    kind: ItemKind = .sight,
    done: Bool = false,
    placed: Bool = false
) -> ItineraryItem {
    // Times are deliberately typed on an unrelated date: only the time of day
    // may matter.
    let start = time.map { day(1, 3, $0.0, $0.1) }
    let item = ItineraryItem(title: title, kind: kind, dayIndex: index, startTime: start, sortOrder: sortOrder)
    item.durationMinutes = minutes
    item.isDone = done
    if placed {
        item.latitude = 41.9
        item.longitude = 12.48
    }
    context.insert(item)
    item.trip = trip
    return item
}

@MainActor
@discardableResult
func addFlight(
    _ designator: (String, String),
    to trip: Trip,
    in context: ModelContext,
    day index: Int,
    departs: Date? = nil,
    arrives: Date? = nil,
    code: String = ""
) -> Flight {
    let flight = Flight(airlineCode: designator.0, number: designator.1, originCode: "FCO", destinationCode: "LHR", dayIndex: index)
    flight.departsAt = departs
    flight.arrivesAt = arrives
    flight.confirmationCode = code
    context.insert(flight)
    flight.trip = trip
    return flight
}

extension DayPlan {
    var titles: [String] { entries.map(\.title) }
}
