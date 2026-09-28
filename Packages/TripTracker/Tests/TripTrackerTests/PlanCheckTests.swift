import Core
import CoreData
import Foundation
import Testing
@testable import TripTracker

// Rome & Amalfi runs 6–14 June 2026; checked from before it starts unless a
// test says otherwise.
private let beforeTrip = day(6, 1)
private let enGB = Locale(identifier: "en_GB")

private let vatican = (41.9065, 12.4536)
private let colosseum = (41.8902, 12.4922)
private let pantheon = (41.8986, 12.4769)
private let trevi = (41.9009, 12.4833)

private func sunny(_ date: Date = day(6, 6)) -> DayWeather {
    DayWeather(date: date, highCelsius: 24, lowCelsius: 15, symbolName: "sun.max.fill", summary: "Sunny")
}

private func rain(_ date: Date = day(6, 7)) -> DayWeather {
    DayWeather(date: date, highCelsius: 19, lowCelsius: 14, symbolName: "cloud.rain.fill", summary: "Rain")
}

@MainActor
@discardableResult
private func stop(
    _ title: String,
    _ trip: SharedTrip,
    _ context: NSManagedObjectContext,
    day index: Int,
    at time: (Int, Int)? = nil,
    minutes: Int = 0,
    point: (Double, Double)? = nil,
    kind: ItemKind = .sight
) -> SharedItineraryItem {
    let item = addItem(title, to: trip, in: context, day: index, at: time, minutes: minutes, kind: kind)
    item.latitude = point?.0
    item.longitude = point?.1
    return item
}

// MARK: - Overlaps

@MainActor
@Test func twoStopsAtOnceAreAnOverlapAndTheLaterOneMoves() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    stop("Colosseum", trip, context, day: 0, at: (9, 0), minutes: 180)
    let borghese = stop("Borghese Gallery", trip, context, day: 0, at: (11, 30), minutes: 120)

    let check = PlanCheck(trip: trip, asOf: beforeTrip)
    let overlap = try #require(check.findings.first { $0.kind == .overlap })

    #expect(overlap.dayIndex == 0)
    #expect(overlap.message == "Day 1: Colosseum runs 30 min into Borghese Gallery.")
    #expect(overlap.items.map(\.title) == ["Colosseum", "Borghese Gallery"])
    #expect(overlap.fixes.map(\.title) == ["Move Borghese Gallery to Day 2", "Send Borghese Gallery to Ideas"])
    #expect(overlap.fixes.allSatisfy { $0.item === borghese })
}

@MainActor
@Test func aStopDuringAFlightMovesAndTheFlightNeverDoes() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addFlight(("BA", "286"), to: trip, in: context, day: 0, departs: day(6, 6, 10, 0), arrives: day(6, 6, 12, 0), code: "SECRET1")
    let lunch = stop("Lunch", trip, context, day: 0, at: (11, 0), minutes: 60, kind: .food)

    let check = PlanCheck(trip: trip, asOf: beforeTrip)
    let overlap = try #require(check.findings.first { $0.kind == .overlap })

    #expect(overlap.message.contains("BA 286"))
    #expect(overlap.message.contains("runs 1 hr into Lunch"))
    #expect(overlap.items == [lunch], "Only itinerary items are moved")
    #expect(overlap.fixes.allSatisfy { $0.item === lunch })
}

@MainActor
@Test func aLongVisitThatSwallowsTwoShortOnesReportsBoth() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    stop("Vatican Museums", trip, context, day: 0, at: (9, 0), minutes: 240)
    stop("Coffee", trip, context, day: 0, at: (10, 0), minutes: 15, kind: .food)
    stop("Sistine Chapel", trip, context, day: 0, at: (11, 0), minutes: 30)

    let overlaps = PlanCheck(trip: trip, asOf: beforeTrip).findings.filter { $0.kind == .overlap }

    #expect(overlaps.map { $0.items.last?.title } == ["Coffee", "Sistine Chapel"])
    #expect(overlaps.allSatisfy { $0.items.first?.title == "Vatican Museums" })
}

@MainActor
@Test func backToBackStopsAreNotAnOverlap() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    stop("Colosseum", trip, context, day: 0, at: (9, 0), minutes: 120)
    stop("Roman Forum", trip, context, day: 0, at: (11, 0), minutes: 60)
    // No set length: it has no end to run into anything.
    stop("Photo stop", trip, context, day: 0, at: (11, 0))

    #expect(!PlanCheck(trip: trip, asOf: beforeTrip).findings.contains { $0.kind == .overlap })
}

// MARK: - Walks

@MainActor
@Test func aWalkLongerThanTheGapIsFlagged() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    stop("Vatican Museums", trip, context, day: 0, at: (9, 0), minutes: 180, point: vatican)
    stop("Colosseum", trip, context, day: 0, at: (12, 10), minutes: 120, point: colosseum)

    let check = PlanCheck(trip: trip, asOf: beforeTrip, locale: enGB)
    let walk = try #require(check.findings.first { $0.kind == .tightTransfer })

    // Distances in the locale's own road units — en_GB reads miles — so the
    // expected text is built the same way.
    let estimate = WalkingEstimate(metres: GeoCoordinate(latitude: vatican.0, longitude: vatican.1)
        .distance(to: GeoCoordinate(latitude: colosseum.0, longitude: colosseum.1)))
    #expect(estimate.walkingMinutes == 44)
    #expect(walk.message == "Day 1: Vatican Museums to Colosseum is \(estimate.distanceText(locale: enGB)), about 44 min on foot, with 10 min between them.")
    #expect(walk.fixes.first?.item.title == "Colosseum")
}

@MainActor
@Test func aRideIsNotAWalk() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    // The train leaves from Roma Termini and arrives 250 km away: its place
    // is its departure, so there's no walk from it to the next stop.
    stop("Train to Salerno", trip, context, day: 0, at: (8, 45), minutes: 90, point: (41.9010, 12.5018), kind: .transit)
    stop("Amalfi apartment", trip, context, day: 0, at: (14, 0), point: (40.6340, 14.6027), kind: .lodging)
    #expect(!PlanCheck(trip: trip, asOf: beforeTrip).findings.contains { $0.kind == .tightTransfer })

    // Getting to the train is still a walk worth checking.
    let other = makeRome(in: context)
    stop("Vatican Museums", other, context, day: 0, at: (9, 0), minutes: 60, point: vatican)
    stop("Train to Naples", other, context, day: 0, at: (10, 5), minutes: 70, point: (41.9010, 12.5018), kind: .transit)
    #expect(PlanCheck(trip: other, asOf: beforeTrip).findings.contains { $0.kind == .tightTransfer })
}

@MainActor
@Test func aShortWalkWithinTheToleranceIsNotFlagged() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    // About 500 m, six or seven minutes, with two to spare — close enough.
    stop("Pantheon", trip, context, day: 0, at: (9, 0), minutes: 60, point: pantheon)
    stop("Trevi Fountain", trip, context, day: 0, at: (10, 2), minutes: 30, point: trevi)
    // Unplaced: nothing to measure.
    stop("Somewhere", trip, context, day: 0, at: (10, 32), minutes: 30)

    #expect(!PlanCheck(trip: trip, asOf: beforeTrip).findings.contains { $0.kind == .tightTransfer })
}

// MARK: - Load

@MainActor
@Test func moreThanSixStopsIsAnOverloadedDay() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    for index in 0..<7 {
        stop("Stop \(index)", trip, context, day: 0, at: (8 + index, 0), minutes: 45)
    }

    let check = PlanCheck(trip: trip, asOf: beforeTrip)
    let busy = try #require(check.findings.first { $0.kind == .overloaded })

    #expect(busy.message == "Day 1 has 7 stops, about 5 hr 15 min planned.")
    #expect(busy.fixes.first?.item.title == "Stop 6", "The last stop in the day's order moves")
    #expect(busy.fixes.first?.targetDay == 1)
}

@MainActor
@Test func moreThanNineHoursIsAnOverloadedDay() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    stop("Pompeii", trip, context, day: 2, at: (8, 0), minutes: 360)
    stop("Herculaneum", trip, context, day: 2, at: (14, 0), minutes: 240)

    let busy = try #require(PlanCheck(trip: trip, asOf: beforeTrip).findings.first { $0.kind == .overloaded })
    #expect(busy.dayIndex == 2)
    #expect(busy.message == "Day 3 has 2 stops, about 10 hr planned.")
}

@MainActor
@Test func aStayOrATransferIsNotAStop() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    for index in 0..<6 {
        stop("Stop \(index)", trip, context, day: 0, minutes: 30)
    }
    stop("Hotel check-in", trip, context, day: 0, kind: .lodging)
    stop("Train to Naples", trip, context, day: 0, kind: .transit)

    #expect(!PlanCheck(trip: trip, asOf: beforeTrip).findings.contains { $0.kind == .overloaded })
}

@MainActor
@Test func ideasAreNeverCountedAsStops() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    for index in 0..<6 {
        stop("Stop \(index)", trip, context, day: 0, minutes: 90)
    }
    for index in 0..<5 {
        stop("Idea \(index)", trip, context, day: SharedItineraryItem.unassignedDayIndex, minutes: 600)
    }
    // Any negative day is an idea, not just -1.
    stop("Stray", trip, context, day: -3, minutes: 600)

    let check = PlanCheck(trip: trip, asOf: beforeTrip)

    #expect(!check.findings.contains { $0.kind == .overloaded })
    #expect(!check.findings.contains { $0.dayIndex < 0 })
    #expect(!check.findings.contains { finding in finding.items.contains { $0.isUnassigned } && finding.kind != .emptyDay && finding.kind != .ideaNearby })
}

@MainActor
@Test func aFlightDayWithSeveralStopsIsBusy() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addFlight(("AZ", "610"), to: trip, in: context, day: 0, departs: day(6, 6, 7, 0), arrives: day(6, 6, 9, 0))
    for index in 0..<3 {
        stop("Stop \(index)", trip, context, day: 0)
    }

    let busy = try #require(PlanCheck(trip: trip, asOf: beforeTrip).findings.first { $0.kind == .busyFlightDay })
    #expect(busy.message == "Day 1 has a flight (AZ 610 · FCO → LHR) and 3 other stops.")
    #expect(busy.fixes.first?.item.title == "Stop 2")
}

@MainActor
@Test func aFlightDayWithTwoStopsIsFine() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addFlight(("AZ", "610"), to: trip, in: context, day: 0)
    stop("Stop 0", trip, context, day: 0)
    stop("Stop 1", trip, context, day: 0)

    #expect(!PlanCheck(trip: trip, asOf: beforeTrip).findings.contains { $0.kind == .busyFlightDay })
}

// MARK: - Weather

@MainActor
@Test func rainOnAnOutdoorPlanMovesItToADryDay() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    stop("Colosseum", trip, context, day: 0)
    let picnic = stop("Villa Borghese picnic", trip, context, day: 1, kind: .activity)
    stop("Capitoline Museums", trip, context, day: 1)
    let weather: [DayWeather?] = [sunny(), rain(), rain(day(6, 8)), sunny(day(6, 9))]

    let check = PlanCheck(trip: trip, weather: weather, asOf: beforeTrip)
    let clash = try #require(check.findings.first { $0.kind == .weatherClash })

    #expect(clash.dayIndex == 1)
    #expect(clash.message == "Day 2: Rain is forecast, and Villa Borghese picnic is outdoors.")
    #expect(clash.items == [picnic], "A museum on a wet day is fine")
    // Day 1 is sunny but has a stop; day 3 is wet; day 4 is sunny and free.
    #expect(clash.fixes.map(\.title) == ["Move Villa Borghese picnic to Day 4", "Send Villa Borghese picnic to Ideas"])
}

@MainActor
@Test func withNoDryDayKnownRainOnlyOffersIdeas() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    stop("Garden walk", trip, context, day: 0, kind: .sight)

    let check = PlanCheck(trip: trip, weather: [rain(day(6, 6))], asOf: beforeTrip)
    let clash = try #require(check.findings.first { $0.kind == .weatherClash })

    #expect(clash.items.map(\.title) == ["Garden walk"], "Its title puts a sight outdoors")
    #expect(clash.fixes.map(\.title) == ["Send Garden walk to Ideas"])
}

@Test func stormsAndSnowAreWetAndCloudIsNot() {
    let date = day(6, 6)
    #expect(PlanCheck.isWet(DayWeather(date: date, highCelsius: 20, lowCelsius: 10, symbolName: "cloud.bolt.rain.fill", summary: "Thunderstorms")))
    #expect(PlanCheck.isWet(DayWeather(date: date, highCelsius: 0, lowCelsius: -4, symbolName: "cloud.snow.fill", summary: "Snow")))
    #expect(PlanCheck.isWet(DayWeather(date: date, highCelsius: 18, lowCelsius: 12, symbolName: "cloud.fill", summary: "Scattered Showers")))
    #expect(!PlanCheck.isWet(DayWeather(date: date, highCelsius: 18, lowCelsius: 12, symbolName: "cloud.fill", summary: "Cloudy")))
}

// MARK: - Free days

@MainActor
@Test func aRunOfFreeDaysIsOneFinding() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    for index in 0..<4 {
        stop("Stop \(index)", trip, context, day: 0)
    }
    stop("Amalfi", trip, context, day: 4)
    stop("Pantheon", trip, context, day: SharedItineraryItem.unassignedDayIndex)

    let free = PlanCheck(trip: trip, asOf: beforeTrip).findings.filter { $0.kind == .emptyDay }

    #expect(free.map(\.message) == ["Days 2–4 have nothing planned.", "Days 6–9 have nothing planned."])
    #expect(free.map(\.dayIndex) == [1, 5])
    let fixes = try #require(free.first?.fixes)
    #expect(fixes.map(\.title) == ["Move Stop 3 from Day 1 to Day 2", "Add Pantheon to Day 2"])
}

@MainActor
@Test func aTripWithNothingPlannedHasNoFreeDayFindings() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    stop("Pantheon", trip, context, day: SharedItineraryItem.unassignedDayIndex)

    #expect(PlanCheck(trip: trip, asOf: beforeTrip).isEmpty)
}

// MARK: - Ideas nearby

@MainActor
@Test func anIdeaAShortWalkFromADaysStopIsSuggestedForThatDay() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    stop("Trevi Fountain", trip, context, day: 0, point: trevi)
    stop("Colosseum", trip, context, day: 1, point: colosseum)
    let idea = stop("Pantheon", trip, context, day: SharedItineraryItem.unassignedDayIndex, point: pantheon)
    stop("Ostia Antica", trip, context, day: SharedItineraryItem.unassignedDayIndex, point: (41.7556, 12.2918))

    let check = PlanCheck(trip: trip, asOf: beforeTrip)
    let nearby = check.findings.filter { $0.kind == .ideaNearby }

    #expect(nearby.count == 1, "Each idea is suggested for one day only, and a far one for none")
    let finding = try #require(nearby.first)
    #expect(finding.dayIndex == 0)
    #expect(finding.message.hasPrefix("Day 1: Pantheon, a saved idea, is a "))
    #expect(finding.message.hasSuffix("min walk from Trevi Fountain."))
    #expect(finding.fixes.map(\.title) == ["Add Pantheon to Day 1"])

    try #require(finding.fixes.first).apply()
    #expect(idea.dayIndex == 0)
}

// MARK: - Time and order

@MainActor
@Test func daysAlreadyGoneAreNotChecked() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    stop("Colosseum", trip, context, day: 0, at: (9, 0), minutes: 180)
    stop("Borghese Gallery", trip, context, day: 0, at: (11, 30), minutes: 120)
    stop("Forum", trip, context, day: 5, at: (9, 0), minutes: 180)
    stop("Palatine", trip, context, day: 5, at: (11, 30), minutes: 120)

    let midTrip = PlanCheck(trip: trip, asOf: day(6, 9))
    #expect(midTrip.firstOpenDay == 3)
    #expect(midTrip.findings.filter { $0.kind == .overlap }.map(\.dayIndex) == [5])
    #expect(!midTrip.findings.contains { $0.dayIndex < 3 })
    #expect(!midTrip.findings.flatMap(\.fixes).contains { $0.targetDay >= 0 && $0.targetDay < 3 }, "Nothing moves onto a day gone by")

    #expect(PlanCheck(trip: trip, asOf: day(7, 1)).isEmpty, "A finished trip has nothing to fix")
}

@MainActor
@Test func findingsRunInDayOrderAndCountPerDay() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    stop("A", trip, context, day: 3, at: (9, 0), minutes: 120)
    stop("B", trip, context, day: 3, at: (10, 0), minutes: 60)
    stop("C", trip, context, day: 1, at: (9, 0), minutes: 120)
    stop("D", trip, context, day: 1, at: (10, 0), minutes: 60)

    let check = PlanCheck(trip: trip, asOf: beforeTrip)

    #expect(check.findings.map(\.dayIndex) == check.findings.map(\.dayIndex).sorted())
    #expect(check.count(onDay: 1) == 1)
    #expect(check.count(onDay: 3) == 1)
    #expect(check.findings(onDay: 3).first?.kind == .overlap)
    #expect(Set(check.findings.map(\.id)).count == check.findings.count, "Ids are unique")
}

@MainActor
@Test func aMoveFixAvoidsADayAlreadyBookedAtThatTime() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    stop("Colosseum", trip, context, day: 1, at: (9, 0), minutes: 180)
    let later = stop("Borghese Gallery", trip, context, day: 1, at: (11, 30), minutes: 120)
    // Day 1 (index 0) is free all day but for a tour at the same time.
    stop("Food tour", trip, context, day: 0, at: (11, 0), minutes: 180, kind: .food)

    let overlap = try #require(PlanCheck(trip: trip, asOf: beforeTrip).findings.first { $0.kind == .overlap })
    let move = try #require(overlap.fixes.first { !$0.sendsToIdeas })

    #expect(move.targetDay == 2, "Day 1 has something at 11:30, so the next nearest empty day")
    move.apply()
    #expect(later.dayIndex == 2)
}
