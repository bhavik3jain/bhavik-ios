import Core
import CoreData
import Foundation
import PDFKit
import Testing
@testable import TripTracker

/// Where the render test writes its PDF: set `TEST_RUNNER_ITINERARY_PDF_DIR`
/// on the `xcodebuild test` command line (the simulator shares the Mac's file
/// system, so a host path works). Unset — as in CI — the test reports a named
/// skip rather than writing anywhere.
private let renderDirectory = ProcessInfo.processInfo.environment["ITINERARY_PDF_DIR"]

/// A made-up but realistic trip: every kind of entry, a long day, an empty
/// day, a timed flight each way, bookings of three kinds and an idea.
@MainActor
func makeSampleTrip(in context: NSManagedObjectContext) -> SharedTrip {
    let trip = makeRome(in: context)
    func item(_ title: String, day: Int, at time: (Int, Int)? = nil, minutes: Int = 0, kind: ItemKind = .sight, address: String = "", detail: String = "", order: Int = 0) {
        let added = addItem(title, to: trip, in: context, day: day, at: time, minutes: minutes, sortOrder: order, kind: kind, placed: true)
        added.address = address
        added.detail = detail
    }
    let outbound = addFlight(("BA", "548"), to: trip, in: context, day: 0, departs: day(6, 6, 7, 15), arrives: day(6, 6, 10, 45), code: "XK7P2M")
    outbound.originCode = "LHR"
    outbound.destinationCode = "FCO"
    outbound.terminal = "5"
    outbound.seat = "14A"
    item("Check in, Hotel Campo de' Fiori", day: 0, at: (14, 0), kind: .lodging, address: "Via del Biscione 6")
    item("Campo de' Fiori market", day: 0, at: (16, 0), minutes: 60, kind: .food)
    item("Dinner at Roscioli", day: 0, at: (20, 30), minutes: 90, kind: .food, address: "Via dei Giubbonari 21", detail: "Booked for 4 — ask for the cellar table")
    item("Colosseum & Forum", day: 1, at: (9, 0), minutes: 180, address: "Piazza del Colosseo", detail: "Skip-the-line entry; meet at the Arch of Constantine")
    item("Lunch in Monti", day: 1, at: (13, 0), minutes: 60, kind: .food)
    item("Palatine Hill", day: 1, at: (15, 0), minutes: 120)
    item("Trastevere walk", day: 1, kind: .activity)
    item("Vatican Museums", day: 2, at: (8, 0), minutes: 240, address: "Viale Vaticano", detail: "Tickets on the phone; dress code covers shoulders and knees")
    item("St Peter's Basilica", day: 2, at: (12, 30), minutes: 90)
    item("Castel Sant'Angelo", day: 2, at: (15, 0), minutes: 90)
    item("Gelato at Fatamorgana", day: 2, kind: .food)
    item("Galleria Borghese", day: 3, at: (9, 30), minutes: 120, detail: "Timed entry — arrive 30 minutes early for the cloakroom")
    item("Pantheon", day: 3, at: (13, 0), minutes: 45)
    item("Trevi Fountain", day: 3, at: (14, 0), minutes: 30)
    item("Spanish Steps", day: 3, at: (15, 0), minutes: 30)
    item("Aperitivo on a rooftop", day: 3, at: (18, 30), minutes: 90, kind: .food)
    item("Train to Naples, then ferry", day: 4, at: (9, 5), minutes: 240, kind: .transit, detail: "Frecciarossa 9519 from Termini, then SNAV from Molo Beverello")
    item("Check in, Positano flat", day: 4, at: (15, 0), kind: .lodging, address: "Via Cristoforo Colombo 30")
    item("Path of the Gods", day: 5, at: (8, 30), minutes: 240, kind: .activity, detail: "Bomerano to Nocelle; bring water and proper shoes")
    item("Boat to Capri", day: 6, at: (9, 0), minutes: 480, kind: .activity, detail: "Blue Grotto if the sea allows")
    item("Ravello gardens", day: 7, at: (10, 0), minutes: 180)
    item("Farewell dinner", day: 7, at: (20, 0), minutes: 120, kind: .food, address: "Da Adolfo")
    addFlight(("BA", "2607"), to: trip, in: context, day: 8, departs: day(6, 14, 18, 40), arrives: day(6, 14, 20, 25), code: "XK7P2M").seat = "14A"
    let hotel = SharedBooking(context: context, title: "Hotel Campo de' Fiori", kind: .lodging, code: "RM-88412", provider: "Booking.com")
    hotel.startsAt = day(6, 6, 14)
    hotel.endsAt = day(6, 10, 11)
    hotel.contactPhone = "+39 06 687 4886"
    let flat = SharedBooking(context: context, title: "Positano flat", kind: .lodging, code: "HMX4920", provider: "Airbnb")
    flat.startsAt = day(6, 10, 15)
    flat.endsAt = day(6, 14, 10)
    flat.secureNote = "DOOR-4471#"
    let train = SharedBooking(context: context, title: "Rome → Naples", kind: .train, code: "PNR 7XQ2LA", provider: "Trenitalia")
    train.startsAt = day(6, 10, 9, 5)
    let museum = SharedBooking(context: context, title: "Vatican Museums", kind: .tickets, code: "VAT-230611-88", provider: "Musei Vaticani")
    museum.startsAt = day(6, 8, 8)
    for booking in [hotel, flat, train, museum] {
        booking.trip = trip
    }
    addItem("Aventine keyhole", to: trip, in: context, day: SharedItineraryItem.unassignedDayIndex, placed: true)
    return trip
}

/// A plausible week of June in Rome, as the trip screen would have fetched it.
let sampleWeather: [DayWeather] = ([
    (28, 19, "sun.max", "Sunny"), (27, 20, "cloud.sun", "Partly cloudy"), (29, 21, "sun.max", "Sunny"),
    (24, 18, "cloud.rain", "Rain"), (26, 19, "cloud", "Cloudy"), (27, 20, "sun.max", "Sunny"),
    (28, 21, "cloud.sun", "Partly cloudy"), (29, 22, "sun.max", "Sunny"), (27, 20, "cloud.sun", "Partly cloudy"),
] as [(Double, Double, String, String)]).enumerated().map { index, entry in
    DayWeather(
        date: current.date(byAdding: .day, value: index, to: current.startOfDay(for: day(6, 6)))!,
        highCelsius: entry.0, lowCelsius: entry.1, symbolName: entry.2, summary: entry.3
    )
}

@MainActor
@Test(.enabled(if: renderDirectory != nil, "Set TEST_RUNNER_ITINERARY_PDF_DIR to render the sample itinerary"))
func rendersTheSampleItinerary() throws {
    let context = try makeContext()
    let trip = makeSampleTrip(in: context)
    let document = ItineraryDocument(trip: trip, weather: sampleWeather, asOf: day(6, 5))
    let folder = URL(fileURLWithPath: try #require(renderDirectory), isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("itinerary.pdf")
    try ItineraryPDF.write(document, to: url)
    #expect(FileManager.default.fileExists(atPath: url.path))
}

/// The written file itself, not just the page model: the layout tests prove
/// where things should go, and nothing else checked that `ItineraryPDF`
/// draws one PDF page per layout page, keeps the text as text (a material or
/// shadow anywhere rasterises the page, and it stops being searchable), and
/// never lets the secure note in. Runs in CI, into a throwaway folder.
@MainActor
@Test func theWrittenPDFMatchesItsLayout() throws {
    let context = try makeContext()
    let trip = makeSampleTrip(in: context)
    let document = ItineraryDocument(trip: trip, weather: sampleWeather, asOf: day(6, 5))
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("itinerary.pdf")
    try ItineraryPDF.write(document, to: url)

    let pdf = try #require(PDFDocument(url: url))
    let layout = ItineraryLayout(document: document)
    #expect(pdf.pageCount == layout.pages.count)
    #expect(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Rome & Amalfi")

    var text = ""
    for index in 0..<pdf.pageCount {
        let page = try #require(pdf.page(at: index))
        #expect(page.bounds(for: .mediaBox).size == ItineraryMetrics.pageSize)
        let pageText = page.string ?? ""
        #expect(pageText.contains("Page \(index + 1) of \(pdf.pageCount)"), "Page \(index + 1) is drawn as text")
        let links = page.annotations.compactMap(\.url)
        #expect(links == (layout.pages[index].showsWeather ? [ItineraryLayout.Footer.legalAttributionURL] : []))
        text += pageText
    }
    for code in ["XK7P2M", "RM-88412", "HMX4920", "PNR 7XQ2LA", "VAT-230611-88"] {
        #expect(text.contains(code), "\(code) is printed")
    }
    #expect(!text.contains("DOOR-4471"), "The secure note never reaches the file")
    #expect(text.contains("Aventine keyhole"), "Ideas are printed, on their own page")
}
