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

private extension ItineraryDocument {
    var dayPages: [DayPage] {
        pages.compactMap { if case .day(let page) = $0 { page } else { nil } }
    }

    var confirmationLines: [Confirmation] {
        pages.flatMap { page -> [Confirmation] in
            if case .confirmations(let lines, _, _) = page { lines } else { [] }
        }
    }
}

@Test func chunksSplitIntoRunsOfAtMostTheSize() {
    #expect(ItineraryDocument.chunks(25, size: 12) == [0..<12, 12..<24, 24..<25])
    #expect(ItineraryDocument.chunks(12, size: 12) == [0..<12])
    #expect(ItineraryDocument.chunks(13, size: 12) == [0..<12, 12..<13])
}

@Test func anEmptyRunStillMakesOnePage() {
    #expect(ItineraryDocument.chunks(0, size: 12) == [0..<0])
}

@MainActor
@Test func aCoverThenAPagePerDay() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Galleria Borghese", to: trip, in: context, day: 2, at: (9, 30), placed: true)

    let document = ItineraryDocument(trip: trip)
    guard case .cover(let cover) = document.pages.first else {
        Issue.record("The first page is the cover")
        return
    }
    #expect(cover.title == "Rome & Amalfi")
    #expect(cover.facts == "9 days · 1 place")
    #expect(document.dayPages.map(\.dayNumber) == Array(1...9), "Empty days still get their page")
    #expect(document.dayPages[2].lines.map(\.title) == ["Galleria Borghese"])
    #expect(document.dayPages[0].lines.isEmpty)
    #expect(document.pages.count == 10, "No confirmations page without any codes")
}

@MainActor
@Test func aLongDayContinuesOntoMorePages() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    for index in 0..<25 {
        addItem("Stop \(index)", to: trip, in: context, day: 3, at: (8, index), sortOrder: index)
    }

    let document = ItineraryDocument(trip: trip, linesPerPage: 12)
    let dayFour = document.dayPages.filter { $0.dayNumber == 4 }
    #expect(dayFour.map(\.lines.count) == [12, 12, 1])
    #expect(dayFour.map(\.part) == [1, 2, 3])
    #expect(dayFour.allSatisfy { $0.partCount == 3 })
    #expect(dayFour.flatMap(\.lines).map(\.title) == (0..<25).map { "Stop \($0)" }, "Continuations keep the day's order")
    #expect(document.dayPages.count == 9 + 2)
}

@MainActor
@Test func dayPagesFollowTheTimelineOrder() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Wander", to: trip, in: context, day: 2)
    addItem("Dinner", to: trip, in: context, day: 2, at: (20, 0))
    addFlight(("BA", "9"), to: trip, in: context, day: 2, departs: day(6, 8, 7, 0))

    let lines = ItineraryDocument(trip: trip).dayPages[2].lines
    #expect(lines.map(\.title) == ["BA 9 · FCO → LHR", "Dinner", "Wander"])
    #expect(lines.last?.time == "—")
    #expect(lines.first?.symbolName == "airplane")
}

@MainActor
@Test func confirmationsListFlightsThenBookingsByKind() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addFlight(("BA", "286"), to: trip, in: context, day: 8, departs: day(6, 14, 18, 40), code: "ABC123")
    let car = SharedBooking(context: context, title: "Avis", kind: .car, code: "IT-77301")
    let hotel = SharedBooking(context: context, title: "Hotel de Russie", kind: .lodging, code: "RM-88412")
    for booking in [car, hotel] {
        booking.trip = trip
    }

    let lines = ItineraryDocument(trip: trip).confirmationLines
    #expect(lines.map(\.code) == ["ABC123", "RM-88412", "IT-77301"])
    #expect(lines.map(\.section) == ["Flights", "Lodging", "Car"])
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
    let everything = strings(in: document)

    #expect(everything.contains("HMX4920"), "The ordinary code is shared")
    #expect(!everything.contains { $0.contains("DOOR-4471") }, "The door code is not")
}

// MARK: - Formatting

@Test func durationsReadAsHoursAndMinutes() {
    #expect(ItineraryFormat.duration(minutes: 0) == "")
    #expect(ItineraryFormat.duration(minutes: 45) == "45m")
    #expect(ItineraryFormat.duration(minutes: 120) == "2h")
    #expect(ItineraryFormat.duration(minutes: 90) == "1h 30m")
}
