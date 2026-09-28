import Core
import CoreData
import Foundation
import Testing
@testable import TripTracker

/// Every string anywhere in a value, however deeply nested — what the renderer
/// could possibly draw.
private func strings(in value: Any) -> [String] {
    if let string = value as? String { return [string] }
    return Mirror(reflecting: value).children.flatMap { strings(in: $0.value) }
}

@MainActor
@Test func ideasGetTheirOwnListAndAreNotCountedAsPlaces() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Galleria Borghese", to: trip, in: context, day: 2, at: (9, 30), placed: true)
    addItem("Aventine keyhole", to: trip, in: context, day: SharedItineraryItem.unassignedDayIndex, placed: true)

    let document = ItineraryDocument(trip: trip)
    #expect(document.ideas.map(\.title) == ["Aventine keyhole"])
    #expect(document.ideas.allSatisfy { $0.time == nil })
    #expect(document.days.flatMap(\.lines).map(\.title) == ["Galleria Borghese"], "An idea is on no day")
    #expect(document.cover.facts.first { $0.label.hasPrefix("Place") }?.value == "1", "Ideas aren't places yet")
}

@MainActor
@Test func aCoverAndEveryDayOfTheTrip() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Galleria Borghese", to: trip, in: context, day: 2, at: (9, 30), placed: true)

    let document = ItineraryDocument(trip: trip)
    #expect(document.cover.title == "Rome & Amalfi")
    #expect(document.cover.destination == "Rome, Italy")
    #expect(document.cover.facts.map(\.value) == ["9", "1"], "No flights or bookings: no tiles saying 0")
    #expect(document.cover.facts.map(\.label) == ["Days", "Place"], "Each label agrees with its number")
    #expect(document.days.map(\.dayNumber) == Array(1...9), "Empty days are still there")
    #expect(document.days[2].lines.map(\.title) == ["Galleria Borghese"])
    #expect(document.days[0].lines.isEmpty)
    #expect(document.confirmations.isEmpty)
}

@MainActor
@Test func dayLinesFollowTheTimelineOrder() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Wander", to: trip, in: context, day: 2)
    addItem("Dinner", to: trip, in: context, day: 2, at: (20, 0))
    addFlight(("BA", "9"), to: trip, in: context, day: 2, departs: day(6, 8, 7, 0))

    let lines = ItineraryDocument(trip: trip).days[2].lines
    #expect(lines.map(\.title) == ["BA 9 · FCO → LHR", "Dinner", "Wander"])
    #expect(lines.last?.time == nil, "Anytime has no time to print")
    #expect(lines.first?.symbolName == "airplane")
    #expect(lines.map(\.isFlight) == [true, false, false])
}

@MainActor
@Test func confirmationsListFlightsThenBookingsByKind() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addFlight(("BA", "286"), to: trip, in: context, day: 8, departs: day(6, 14, 18, 40), code: "ABC123")
    let car = SharedBooking(context: context, title: "Avis", kind: .car, code: "IT-77301")
    let hotel = SharedBooking(context: context, title: "Hotel de Russie", kind: .lodging, code: "RM-88412")
    hotel.contactPhone = "+39 06 328 881"
    for booking in [car, hotel] {
        booking.trip = trip
    }

    let codes = ItineraryDocument(trip: trip).confirmations
    #expect(codes.map(\.code) == ["ABC123", "RM-88412", "IT-77301"])
    #expect(codes.map(\.section) == ["Flights", "Lodging", "Car"])
    #expect(codes[0].title == "FCO → LHR", "A flight's card leads with its route")
    #expect(codes[0].detail.hasPrefix("BA 286"))
    #expect(!codes[0].date.isEmpty && codes[1].date.isEmpty, "Only a flight carries its day above the route")
    #expect(codes[1].contact == "+39 06 328 881", "The desk's phone number is printed")
}

@MainActor
@Test func aSecureNoteNeverReachesThePageModel() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let flat = SharedBooking(context: context, title: "Amalfi apartment", kind: .lodging, code: "HMX4920")
    flat.secureNote = "DOOR-4471#"
    flat.notes = "Buzz twice"
    flat.trip = trip
    addItem("Arrive", to: trip, in: context, day: 4, at: (14, 0))

    let document = ItineraryDocument(trip: trip)
    let layout = ItineraryLayout(document: document, measure: .fixed)
    let everything = strings(in: document) + strings(in: layout)

    #expect(everything.contains("HMX4920"), "The ordinary code is shared")
    #expect(!everything.contains { $0.contains("DOOR-4471") }, "The door code is not")
}

@MainActor
@Test func weatherGoesOnItsDayAndDatesTheCredit() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let rain = DayWeather(date: current.startOfDay(for: day(6, 7)), highCelsius: 24, lowCelsius: 18, symbolName: "cloud.rain", summary: "Rain")

    let document = ItineraryDocument(trip: trip, weather: [rain], asOf: day(6, 1))
    #expect(document.days[1].weather?.summary == "Rain")
    #expect(document.days[1].weather?.symbolName == "cloud.rain")
    #expect(document.days.filter { $0.weather != nil }.count == 1)
    #expect(document.weatherAsOf != nil)

    let dry = ItineraryDocument(trip: trip, asOf: day(6, 1))
    #expect(dry.weatherAsOf == nil, "No weather, no credit")
}

@MainActor
@Test func weatherBeyondTheForecastWindowIsLeftOff() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let last = DayWeather(date: current.startOfDay(for: day(6, 14)), highCelsius: 27, lowCelsius: 20, symbolName: "sun.max", summary: "Sunny")

    // Fetched a month early: the trip's last day is past the ten-day window,
    // so whatever came back for it isn't a forecast worth printing.
    let document = ItineraryDocument(trip: trip, weather: [last], asOf: day(5, 14))
    #expect(document.days.allSatisfy { $0.weather == nil })
    #expect(document.weatherAsOf == nil)
}

// MARK: - Formatting

@Test func durationsReadAsHoursAndMinutes() {
    #expect(ItineraryFormat.duration(minutes: 0) == "")
    #expect(ItineraryFormat.duration(minutes: 45) == "45m")
    #expect(ItineraryFormat.duration(minutes: 120) == "2h")
    #expect(ItineraryFormat.duration(minutes: 90) == "1h 30m")
}
