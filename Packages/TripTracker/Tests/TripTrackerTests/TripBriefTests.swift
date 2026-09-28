import Core
import CoreData
import Foundation
import Testing
@testable import TripTracker

private let beforeTrip = day(6, 1)

/// Every private thing a trip can hold, each a string that can't turn up by
/// accident.
private let secrets = [
    "DOOR-4417", "BOOKING-CODE-ZX", "+39 555 0100", "BOOKING-NOTE-QQ",
    "FLIGHT-CONF-XY", "SEAT-14C-QQ", "TERMINAL-QQ", "FLIGHT-NOTE-QQ",
    "ITEM-DETAIL-QQ", "ITEM-ADDRESS-QQ", "TRIP-NOTE-QQ",
]

@MainActor
private func tripWithSecrets(in context: NSManagedObjectContext) -> SharedTrip {
    let trip = makeRome(in: context)
    trip.notes = "TRIP-NOTE-QQ"
    let booking = SharedBooking(context: context, title: "Hotel de Russie", kind: .lodging, code: "BOOKING-CODE-ZX", provider: "Rocco Forte")
    booking.secureNote = "DOOR-4417"
    booking.contactPhone = "+39 555 0100"
    booking.notes = "BOOKING-NOTE-QQ"
    booking.trip = trip
    let flight = addFlight(("BA", "286"), to: trip, in: context, day: 0, departs: day(6, 6, 7, 0), arrives: day(6, 6, 9, 0), code: "FLIGHT-CONF-XY")
    flight.seat = "SEAT-14C-QQ"
    flight.terminal = "TERMINAL-QQ"
    flight.notes = "FLIGHT-NOTE-QQ"
    let colosseum = addItem("Colosseum", to: trip, in: context, day: 0, at: (9, 0), minutes: 180)
    colosseum.detail = "ITEM-DETAIL-QQ"
    colosseum.address = "ITEM-ADDRESS-QQ"
    addItem("Borghese Gallery", to: trip, in: context, day: 0, at: (11, 30), minutes: 120)
    let idea = addItem("Pantheon", to: trip, in: context, day: SharedItineraryItem.unassignedDayIndex)
    idea.detail = "ITEM-DETAIL-QQ"
    return trip
}

@MainActor
@Test func theBriefNeverCarriesCodesNotesOrAddresses() throws {
    let context = try makeContext()
    let trip = tripWithSecrets(in: context)
    let check = PlanCheck(trip: trip, asOf: beforeTrip)
    let brief = TripBrief(trip: trip, check: check)

    let prompt = brief.prompt(maxTokens: 100_000)
    let everything = ([prompt, brief.header] + brief.ideas + brief.facts.map(\.text) + brief.days.flatMap { [$0.heading] + $0.lines })
        .joined(separator: "\n")

    for secret in secrets {
        #expect(!everything.contains(secret), "\(secret) reached the model's prompt")
    }
    // What it does carry.
    #expect(prompt.contains("Flight BA 286 · FCO → LHR"))
    #expect(prompt.contains("09:00 Colosseum (Sight, 3 hr)"))
    #expect(prompt.contains("Pantheon (Sight)"))
    #expect(!prompt.contains("Hotel de Russie"), "Bookings aren't part of the brief at all")
}

/// "Suggest Places" sends the model a line about the day, not the brief —
/// held to the same boundary.
@MainActor
@Test func theSuggestionContextNeverCarriesCodesNotesOrAddresses() throws {
    let context = try makeContext()
    let trip = tripWithSecrets(in: context)
    let wet = DayWeather(date: day(6, 6), highCelsius: 18, lowCelsius: 12, symbolName: "cloud.rain", summary: "Rain")

    let request = try #require(SuggestionRequest(trip: trip, day: 0, weather: [wet]))

    for secret in secrets {
        #expect(!request.context.contains(secret), "\(secret) reached the suggestion prompt")
    }
    #expect(request.context.contains("Colosseum (Sight)"))
    #expect(request.context.contains("Forecast: Rain"))
}

@MainActor
@Test func factsAreNumberedFindingsInOrder() throws {
    let context = try makeContext()
    let trip = tripWithSecrets(in: context)
    let check = PlanCheck(trip: trip, asOf: beforeTrip)
    let brief = TripBrief(trip: trip, check: check)

    #expect(brief.facts.map(\.number) == Array(1...check.findings.count))
    #expect(brief.facts.map(\.findingID) == check.findings.map(\.id))
    #expect(brief.fact(numbered: 1)?.text == check.findings.first?.message)
    #expect(brief.fact(numbered: 0) == nil)
    #expect(brief.fact(numbered: check.findings.count + 1) == nil)
    #expect(brief.prompt(maxTokens: 100_000).contains("1. Day 1: Colosseum runs 30 min into Borghese Gallery."))
}

@MainActor
@Test func ideasAreListedApartFromTheDays() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Colosseum", to: trip, in: context, day: 0)
    addItem("Pantheon", to: trip, in: context, day: SharedItineraryItem.unassignedDayIndex)
    addItem("Giolitti", to: trip, in: context, day: -4, kind: .food)

    let brief = TripBrief(trip: trip, check: PlanCheck(trip: trip, asOf: beforeTrip))

    #expect(brief.ideas == ["Giolitti (Food & drink)", "Pantheon (Sight)"])
    #expect(!brief.days.flatMap(\.lines).contains { $0.contains("Pantheon") || $0.contains("Giolitti") })
    #expect(brief.days.first?.lines == ["Anytime: Colosseum (Sight)"])
}

@MainActor
@Test func theForecastGoesInTheDayHeading() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let rain = DayWeather(date: day(6, 7), highCelsius: 19, lowCelsius: 14, symbolName: "cloud.rain.fill", summary: "Rain")

    let brief = TripBrief(trip: trip, check: PlanCheck(trip: trip, asOf: beforeTrip), weather: [nil, rain], locale: Locale(identifier: "en_GB"))

    #expect(brief.days[1].heading.hasPrefix("Day 2 ("))
    #expect(brief.days[1].heading.hasSuffix("; Rain, 19°/14°)"))
    #expect(!brief.days[0].heading.contains(";"))
}

// MARK: - Budget

/// A fortnight with eighty stops, most of them clashing — far more than the
/// on-device model can read at once.
@MainActor
private func bigTrip(in context: NSManagedObjectContext) -> SharedTrip {
    let trip = SharedTrip(context: context, title: "Grand tour", destination: "Italy", startDate: day(6, 6), endDate: day(6, 19))
    for index in 0..<80 {
        let dayIndex = index % 14
        addItem("A rather long stop name number \(index)", to: trip, in: context, day: dayIndex, at: (8 + index / 14, 30), minutes: 90)
    }
    for index in 0..<20 {
        addItem("Idea \(index)", to: trip, in: context, day: SharedItineraryItem.unassignedDayIndex)
    }
    return trip
}

/// The iOS 27 simulator's model said its context was 0 tokens.
@Test func anImplausibleContextSizeGetsTheMeasuredOne() {
    let measured = TripBrief.promptBudget(contextSize: TripBrief.fallbackContextSize)
    #expect(measured == 4_096 - TripBrief.reservedOutputTokens - TripBrief.estimatedOverheadTokens)
    #expect(TripBrief.promptBudget(contextSize: 0) == measured)
    #expect(TripBrief.promptBudget(contextSize: -1) == measured)
    #expect(TripBrief.promptBudget(contextSize: 8_192) > measured)
    #expect(TripBrief.promptBudget(contextSize: 8_192, overhead: 7_900) == 64)
}

@MainActor
@Test func aBigTripsBriefFitsTheOnDeviceBudget() throws {
    let context = try makeContext()
    let trip = bigTrip(in: context)
    let check = PlanCheck(trip: trip, asOf: beforeTrip)
    let brief = TripBrief(trip: trip, check: check)
    // What the advisor leaves for the prompt on a 4,096-token model.
    let budget = TripBrief.promptBudget(contextSize: 4_096)

    let prompt = brief.prompt(maxTokens: budget)

    #expect(budget == 2_696)
    #expect(check.findings.count > 20, "The fixture should be too big for the budget")
    #expect(TripBrief.estimatedTokens(prompt) <= budget)
    #expect(prompt.count <= budget * 3 + 3)
    #expect(prompt.contains("1. "), "Facts are what's kept")
    #expect(!prompt.contains("Saved ideas"), "Ideas go first")
}

@MainActor
@Test func trimmingDropsIdeasThenQuietDaysThenThePlanThenLateFacts() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addItem("Colosseum", to: trip, in: context, day: 0, at: (9, 0), minutes: 180)
    addItem("Borghese Gallery", to: trip, in: context, day: 0, at: (11, 30), minutes: 120)
    addItem("Trastevere", to: trip, in: context, day: 5)
    addItem("Pantheon", to: trip, in: context, day: SharedItineraryItem.unassignedDayIndex)
    let brief = TripBrief(trip: trip, check: PlanCheck(trip: trip, asOf: beforeTrip))
    let full = brief.prompt(maxTokens: 100_000)
    // Count in characters, so each step's size is exact.
    let characters: (String) -> Int = { $0.count }

    #expect(full.contains("Saved ideas"))
    let noIdeas = brief.prompt(maxTokens: full.count - 1, tokenCount: characters)
    #expect(!noIdeas.contains("Saved ideas"))
    #expect(noIdeas.contains("Trastevere"))

    let busyDaysOnly = brief.prompt(maxTokens: noIdeas.count - 1, tokenCount: characters)
    #expect(busyDaysOnly.contains("Colosseum (Sight"))
    #expect(!busyDaysOnly.contains("Trastevere"), "Day 6 has no finding of its own")

    let factsOnly = brief.prompt(maxTokens: busyDaysOnly.count - 1, tokenCount: characters)
    #expect(!factsOnly.contains("Plan:"))
    #expect(factsOnly.contains("1. Day 1: Colosseum runs"))

    let fewer = brief.prompt(maxTokens: factsOnly.count - 1, tokenCount: characters)
    #expect(fewer.contains("1. "))
    #expect(!fewer.contains("\(brief.facts.count). "))
}

@Test func longTripsAreReviewedAWeekAtATime() {
    #expect(TripBrief.reviewRange(dayCount: 5, focusDay: 3) == 0..<5)
    #expect(TripBrief.reviewRange(dayCount: 7, focusDay: 6) == 0..<7)
    #expect(TripBrief.reviewRange(dayCount: 21, focusDay: 0) == 0..<7)
    #expect(TripBrief.reviewRange(dayCount: 21, focusDay: 9) == 7..<14)
    #expect(TripBrief.reviewRange(dayCount: 17, focusDay: 16) == 14..<17)
    #expect(TripBrief.reviewRange(dayCount: 17, focusDay: 99) == 14..<17)
    #expect(TripBrief.reviewRange(dayCount: 17, focusDay: -2) == 0..<7)
}

@MainActor
@Test func aWeeksBriefHoldsOnlyThatWeeksDaysAndFacts() throws {
    let context = try makeContext()
    let trip = bigTrip(in: context)
    let check = PlanCheck(trip: trip, asOf: beforeTrip)

    let brief = TripBrief(trip: trip, check: check, days: TripBrief.reviewRange(dayCount: 14, focusDay: 10))

    #expect(brief.dayRange == 7..<14)
    #expect(brief.days.map(\.dayIndex) == Array(7..<14))
    #expect(brief.facts.allSatisfy { (7..<14).contains($0.dayIndex) })
    #expect(brief.facts.first?.number == 1, "Numbering starts again in each brief")
    #expect(brief.header.contains("this covers Day 8"))
}

@Test func longTitlesAreClipped() {
    let clipped = TripBrief.clip(String(repeating: "a", count: 500))
    #expect(clipped.count == TripBrief.titleLimit)
    #expect(clipped.hasSuffix("…"))
    #expect(TripBrief.clip("Two\nlines") == "Two lines")
}
