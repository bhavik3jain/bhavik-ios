import Core
import CoreData
import Foundation
import Testing
@testable import TripTracker

private let pantheon = GeoCoordinate(latitude: 41.8986, longitude: 12.4769)

// MARK: - Nearby: ranking

@MainActor
@Test func ideasRankNearestFirstInBuckets() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addPlace("Ostia Antica", to: trip, in: context, at: (41.7556, 12.2918))
    addPlace("Aventine keyhole", to: trip, in: context, at: (41.8833, 12.4787))
    addPlace("Giolitti", to: trip, in: context, at: (41.9010, 12.4776))
    addPlace("Sant'Ignazio", to: trip, in: context, at: (41.8990, 12.4797))
    addPlace("Appian Way", to: trip, in: context, at: (41.8580, 12.5160))
    addPlace("Pasta class", to: trip, in: context, at: nil)
    addPlace("Pantheon", to: trip, in: context, day: 3, at: (41.8986, 12.4769))

    let nearby = NearbyIdeas(trip: trip, from: pantheon)

    #expect(nearby.groups.map(\.bucket) == [.shortWalk, .worthTheTrip, .farther])
    #expect(nearby.groups[0].suggestions.map(\.item.title) == ["Sant'Ignazio", "Giolitti"])
    #expect(nearby.groups[1].suggestions.map(\.item.title) == ["Aventine keyhole"])
    #expect(nearby.groups[2].suggestions.map(\.item.title) == ["Appian Way", "Ostia Antica"])
    #expect(!nearby.suggestions.map(\.item.title).contains("Pantheon"), "Planned stops aren't ideas")
    #expect(nearby.unplaced.map(\.title) == ["Pasta class"])
}

@MainActor
@Test func emptyBucketsAreLeftOut() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addPlace("Ostia Antica", to: trip, in: context, at: (41.7556, 12.2918))

    #expect(NearbyIdeas(trip: trip, from: pantheon).groups.map(\.bucket) == [.farther])
}

@Test func bucketsBreakAtAQuarterHourAndFiveKilometres() {
    #expect(NearbyIdeas.Bucket.of(metres: 0) == .shortWalk)
    #expect(NearbyIdeas.Bucket.of(metres: 1_250) == .shortWalk)
    #expect(NearbyIdeas.Bucket.of(metres: 1_251) == .worthTheTrip)
    #expect(NearbyIdeas.Bucket.of(metres: 5_000) == .worthTheTrip)
    #expect(NearbyIdeas.Bucket.of(metres: 5_001) == .farther)
}

// MARK: - Nearby: walking

@Test func walkingTimeIsAtFiveKilometresAnHour() {
    #expect(WalkingEstimate(metres: 1_000).walkingMinutes == 12)
    #expect(WalkingEstimate(metres: 5_000).walkingMinutes == 60)
    #expect(WalkingEstimate(metres: 5).walkingMinutes == 1, "Never zero minutes")
}

@Test func walkingTextReadsNaturally() {
    #expect(WalkingEstimate(metres: 650).walkingText == "8 min walk")
    #expect(WalkingEstimate(metres: 5_000).walkingText == "1 hr walk")
    #expect(WalkingEstimate(metres: 5_400).walkingText == "1 hr 5 min walk")
    #expect(WalkingEstimate(metres: 25_000).walkingText == nil, "Past ten kilometres nobody walks")
}

@Test func theSummaryDropsTheWalkWhenItIsNone() {
    let metric = Locale(identifier: "en_GB")
    #expect(WalkingEstimate(metres: 650).summary(locale: metric).hasSuffix(" · 8 min walk"))
    #expect(!WalkingEstimate(metres: 25_000).summary(locale: metric).contains("walk"))
}

@Test func directionsWalkOnlyWhenItsAWalk() {
    #expect(WalkingEstimate(metres: 2_000).prefersWalkingDirections)
    #expect(!WalkingEstimate(metres: 4_000).prefersWalkingDirections)
}

// MARK: - Nearby: origins

@MainActor
@Test func aDaysCentreIsItsPlacedStopsAverage() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addPlace("A", to: trip, in: context, day: 2, at: (41.0, 12.0))
    addPlace("B", to: trip, in: context, day: 2, at: (42.0, 13.0))
    addPlace("No place", to: trip, in: context, day: 2, at: nil)
    addPlace("Idea", to: trip, in: context, at: (50.0, 20.0))
    addPlace("Other day", to: trip, in: context, day: 3, at: (45.0, 15.0))

    #expect(NearbyIdeas.centroid(ofDay: 2, in: trip) == GeoCoordinate(latitude: 41.5, longitude: 12.5))
    #expect(NearbyIdeas.centroid(ofDay: 4, in: trip) == nil)
    #expect(NearbyIdeas.centroid(ofDay: -1, in: trip) == nil, "Ideas are no day to measure from")
    #expect(NearbyIdeas.daysWithStops(in: trip) == [2, 3])
}

@MainActor
@Test func atTheTripNearbyMeasuresFromYou() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addPlace("Pantheon", to: trip, in: context, day: 2, at: (41.8986, 12.4769))

    #expect(NearbyIdeas.suggestedOrigin(for: trip, location: pantheon, asOf: day(6, 8)) == .me)
}

@MainActor
@Test func awayFromTheTripNearbyMeasuresFromTodaysPlan() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addPlace("Vatican", to: trip, in: context, day: 1, at: (41.9065, 12.4536))
    addPlace("Borghese", to: trip, in: context, day: 2, at: (41.9142, 12.4921))
    addPlace("Amalfi", to: trip, in: context, day: 5, at: (40.6340, 14.6027))
    let london = GeoCoordinate(latitude: 51.5, longitude: -0.12)

    #expect(NearbyIdeas.suggestedOrigin(for: trip, location: london, asOf: day(6, 8)) == .day(2), "Today, day 3")
    #expect(NearbyIdeas.suggestedOrigin(for: trip, location: nil, asOf: day(6, 9)) == .day(5), "The next day with stops")
    #expect(NearbyIdeas.suggestedOrigin(for: trip, location: nil, asOf: day(5, 1)) == .day(1), "Before it starts, the first")
    #expect(NearbyIdeas.suggestedOrigin(for: trip, location: nil, asOf: day(7, 1)) == .day(5), "After it ends, the last")
}

@MainActor
@Test func withNoPlacedDaysAFarFixIsStillSomewhereToMeasureFrom() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    trip.latitude = nil
    trip.longitude = nil
    let london = GeoCoordinate(latitude: 51.5, longitude: -0.12)

    #expect(NearbyIdeas.suggestedOrigin(for: trip, location: london, asOf: day(6, 8)) == .me)
    #expect(NearbyIdeas.suggestedOrigin(for: trip, location: nil, asOf: day(6, 8)) == nil)
}

@MainActor
@Test func theTripsDestinationCountsAsBeingThere() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    #expect(NearbyIdeas.isAtTrip(pantheon, trip: trip))
    #expect(!NearbyIdeas.isAtTrip(GeoCoordinate(latitude: 51.5, longitude: -0.12), trip: trip))
}

@MainActor
@Test func thePointForAnOriginIsTheFixOrTheDaysCentre() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    addPlace("Borghese", to: trip, in: context, day: 2, at: (41.9142, 12.4921))

    #expect(NearbyIdeas.point(for: .me, in: trip, location: pantheon) == pantheon)
    #expect(NearbyIdeas.point(for: .me, in: trip, location: nil) == nil)
    #expect(NearbyIdeas.point(for: .day(2), in: trip, location: nil) == GeoCoordinate(latitude: 41.9142, longitude: 12.4921))
}

@Test func addingGoesToTheChosenDayOrToday() {
    let dates = TripDates(start: day(6, 6), end: day(6, 14), calendar: current)
    #expect(NearbyIdeas.targetDay(for: .day(5), dates: dates, asOf: day(6, 8)) == 5)
    #expect(NearbyIdeas.targetDay(for: .me, dates: dates, asOf: day(6, 8)) == 2)
    #expect(NearbyIdeas.targetDay(for: .me, dates: dates, asOf: day(5, 1)) == nil, "No today before the trip — pick a day")
}
