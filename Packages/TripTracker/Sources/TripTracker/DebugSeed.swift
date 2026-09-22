#if DEBUG
import Core
import CoreData
import Foundation

/// Adds a trip under way, two coming up and one finished, so the module has
/// something in it on a fresh simulator. Debug builds only, only when launched
/// with `-TripSeed YES`, and never once any trip exists — the dates are built
/// around today, so seeding twice would stack a second copy of every trip.
public enum TripDebugSeed {
    public static var isRequested: Bool {
        // Never against a store `TripLegacyMigration` has already run against —
        // that device may be holding real, possibly-shared trips (or simply
        // have already decided there was nothing to migrate), and stacking
        // fake ones on top of either is never what `-TripSeed` is asking for.
        UserDefaults.standard.bool(forKey: "TripSeed") && !TripLegacyMigration.hasRun
    }

    @MainActor
    public static func run(context: NSManagedObjectContext, asOf now: Date = .now) {
        let existing = (try? context.count(for: Trip.fetchRequest())) ?? 0
        guard existing == 0 else { return }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today) ?? today }
        func at(_ offset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day(offset)) ?? day(offset)
        }

        // In progress: today is day 3 of 9.
        let rome = Trip(context: context, title: "Rome & Amalfi", destination: "Rome, Italy", startDate: day(-2), endDate: day(6))
        rome.latitude = 41.9028
        rome.longitude = 12.4964

        let places: [(String, ItemKind, Int, Date?, Int, String, Double, Double, Bool)] = [
            ("Hotel de Russie", .lodging, 0, at(-2, 15), 0, "Via del Babuino 9", 41.9105, 12.4768, true),
            ("Colosseum", .sight, 0, at(-2, 17), 90, "Piazza del Colosseo", 41.8902, 12.4922, true),
            ("Vatican Museums", .sight, 1, at(-1, 9), 180, "Viale Vaticano", 41.9065, 12.4536, true),
            ("Galleria Borghese", .sight, 2, at(0, 9, 30), 90, "Piazzale Scipione Borghese 5", 41.9142, 12.4921, true),
            ("Lunch at Armando al Pantheon", .food, 2, at(0, 13), 0, "Salita dei Crescenzi 31", 41.8989, 12.4768, true),
            ("Da Enzo al 29", .food, 2, at(0, 20), 0, "Via dei Vascellari 29", 41.8886, 12.4775, false),
            ("Wander Trastevere", .activity, 2, nil, 0, "Trastevere", 41.8894, 12.4700, false),
            ("Pantheon", .sight, 3, at(1, 10), 60, "Piazza della Rotonda", 41.8986, 12.4769, false),
            ("Train to Salerno", .transit, 4, at(2, 8, 45), 90, "Roma Termini", 41.9010, 12.5018, false),
            ("Amalfi apartment", .lodging, 4, at(2, 14), 0, "Via Lorenzo d'Amalfi", 40.6340, 14.6027, false),
            ("Path of the Gods", .activity, 5, at(3, 8), 240, "Bomerano", 40.6260, 14.5320, false),
        ]
        for (order, place) in places.enumerated() {
            let item = ItineraryItem(context: context, title: place.0, kind: place.1, dayIndex: place.2, startTime: place.3, sortOrder: order)
            item.durationMinutes = place.4
            item.address = place.5
            item.latitude = place.6
            item.longitude = place.7
            if place.8 { item.toggleDone(asOf: now) }
            if place.0 == "Da Enzo al 29" { item.detail = "Dinner" }
            item.trip = rome
        }

        let outbound = Flight(context: context, airlineCode: "BA", number: "285", originCode: "LHR", destinationCode: "FCO", dayIndex: 0)
        outbound.departsAt = at(-2, 8, 5)
        outbound.arrivesAt = at(-2, 11, 45)
        outbound.seat = "14A"
        outbound.confirmationCode = "ABC123"
        outbound.trip = rome
        let home = Flight(context: context, airlineCode: "BA", number: "286", originCode: "FCO", destinationCode: "LHR", dayIndex: 8)
        home.departsAt = at(6, 18, 40)
        home.arrivesAt = at(6, 20, 25)
        home.seat = "32K"
        home.terminal = "3"
        home.confirmationCode = "ABC123"
        home.trip = rome

        let hotel = Booking(context: context, title: "Hotel de Russie", kind: .lodging, code: "RM-88412", provider: "Rome")
        hotel.startsAt = day(-2)
        hotel.endsAt = day(2)
        hotel.trip = rome
        let flat = Booking(context: context, title: "Amalfi apartment", kind: .lodging, code: "HMX4920", provider: "Amalfi")
        flat.startsAt = day(2)
        flat.endsAt = day(6)
        flat.secureNote = "4471#"
        flat.trip = rome
        let car = Booking(context: context, title: "Avis · Salerno station", kind: .car, code: "IT-77301", provider: "Avis")
        car.startsAt = at(2, 11)
        car.trip = rome

        // Upcoming: one inside the forecast window, one well beyond it.
        let lisbon = Trip(context: context, title: "Lisbon long weekend", destination: "Lisbon, Portugal", startDate: day(5 + 9), endDate: day(5 + 12))
        lisbon.latitude = 38.7223
        lisbon.longitude = -9.1393

        let tokyo = Trip(context: context, title: "Tokyo", destination: "Tokyo, Japan", startDate: day(40), endDate: day(51))
        tokyo.latitude = 35.6762
        tokyo.longitude = 139.6503
        let sushi = ItineraryItem(context: context, title: "Tsukiji outer market", kind: .food, dayIndex: 1, startTime: at(41, 7))
        sushi.latitude = 35.6655
        sushi.longitude = 139.7708
        sushi.trip = tokyo

        // Finished.
        let reykjavik = Trip(context: context, title: "Reykjavik", destination: "Reykjavik, Iceland", startDate: day(-60), endDate: day(-55))
        reykjavik.latitude = 64.1466
        reykjavik.longitude = -21.9426
        let lagoon = ItineraryItem(context: context, title: "Sky Lagoon", kind: .activity, dayIndex: 2)
        lagoon.latitude = 64.1160
        lagoon.longitude = -21.9422
        lagoon.toggleDone(asOf: day(-58))
        lagoon.trip = reykjavik

        try? context.saveIfNeeded()
    }
}
#endif
