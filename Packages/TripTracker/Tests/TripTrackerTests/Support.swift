import Core
import CoreData
import Foundation
import ObjectiveC
@testable import TripTracker

/// Associated-object key for tying a returned context's lifetime to the
/// container that built it — see `makeContext()`. `objc_setAssociatedObject`
/// only ever uses this variable's fixed address, as a `&`-taken pointer, never
/// its value — `nonisolated(unsafe)` is safe here for exactly that reason.
private nonisolated(unsafe) var associatedContainerKey: UInt8 = 0

@MainActor
func makeContext() throws -> NSManagedObjectContext {
    // A fresh, uniquely-named container per call, not one fixed name shared by
    // every test: Swift Testing runs test functions in parallel by default,
    // and two containers built from the same name resolve to the same default
    // store URL — even the in-memory store type keeps that URL as the
    // coordinator's registration key, so two tests racing to add their own
    // in-memory store "at" it corrupted each other's data intermittently.
    let container = CloudSharedStore.makeContainer(
        name: "TripStoreTests-\(UUID().uuidString)",
        model: TripModel.make(),
        containerID: "iCloud.com.bhavikjain.trackers.tests",
        inMemory: true
    )
    let context = container.viewContext
    // Apple's own documented gotcha: nothing else keeps `container` alive once
    // this function returns just its `viewContext` — a context does NOT retain
    // its own container — so without this, ARC was free to deallocate it right
    // after `makeContext()` returned, and every test reading back through the
    // context afterward (which is all of them) was working against a
    // half-torn-down store. Tying its lifetime to the context it handed out
    // fixes that without changing every test's signature.
    objc_setAssociatedObject(context, &associatedContainerKey, container, .OBJC_ASSOCIATION_RETAIN)
    return context
}

/// Model-backed tests go through `SharedTrip.dates`, which uses the current
/// calendar, so their fixtures are built with it too.
let current = Calendar.current

func day(_ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    current.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

/// Rome & Amalfi, 6–14 June 2026, inserted with nothing planned yet.
@MainActor
func makeRome(in context: NSManagedObjectContext) -> SharedTrip {
    let trip = SharedTrip(context: context, title: "Rome & Amalfi", destination: "Rome, Italy", startDate: day(6, 6), endDate: day(6, 14))
    trip.latitude = 41.9
    trip.longitude = 12.5
    return trip
}

@MainActor
@discardableResult
func addItem(
    _ title: String,
    to trip: SharedTrip,
    in context: NSManagedObjectContext,
    day index: Int,
    at time: (Int, Int)? = nil,
    minutes: Int = 0,
    sortOrder: Int = 0,
    kind: ItemKind = .sight,
    done: Bool = false,
    placed: Bool = false
) -> SharedItineraryItem {
    // Times are deliberately typed on an unrelated date: only the time of day
    // may matter.
    let start = time.map { day(1, 3, $0.0, $0.1) }
    let item = SharedItineraryItem(context: context, title: title, kind: kind, dayIndex: index, startTime: start, sortOrder: sortOrder)
    item.durationMinutes = minutes
    item.isDone = done
    if placed {
        item.latitude = 41.9
        item.longitude = 12.48
    }
    item.trip = trip
    return item
}

@MainActor
@discardableResult
func addFlight(
    _ designator: (String, String),
    to trip: SharedTrip,
    in context: NSManagedObjectContext,
    day index: Int,
    departs: Date? = nil,
    arrives: Date? = nil,
    code: String = ""
) -> SharedFlight {
    let flight = SharedFlight(context: context, airlineCode: designator.0, number: designator.1, originCode: "FCO", destinationCode: "LHR", dayIndex: index)
    flight.departsAt = departs
    flight.arrivesAt = arrives
    flight.confirmationCode = code
    flight.trip = trip
    return flight
}

/// An item at a given spot — `addItem`'s `placed:` puts everything on one point.
@MainActor
@discardableResult
func addPlace(
    _ title: String,
    to trip: SharedTrip,
    in context: NSManagedObjectContext,
    day index: Int = SharedItineraryItem.unassignedDayIndex,
    at point: (Double, Double)?,
    kind: ItemKind = .sight
) -> SharedItineraryItem {
    let item = addItem(title, to: trip, in: context, day: index, kind: kind)
    item.latitude = point?.0
    item.longitude = point?.1
    return item
}

extension DayPlan {
    var titles: [String] { entries.map(\.title) }
}
