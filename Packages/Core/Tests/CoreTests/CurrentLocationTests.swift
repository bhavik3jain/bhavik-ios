import Foundation
import Testing
@testable import Core

// MARK: - Distance

@Test func aDegreeOfLatitudeIsAboutAHundredAndElevenKilometres() {
    let south = GeoCoordinate(latitude: 41, longitude: 12.5)
    let north = GeoCoordinate(latitude: 42, longitude: 12.5)
    #expect(abs(south.distance(to: north) - 111_000) < 1_000)
    #expect(south.distance(to: north) == north.distance(to: south))
}

@Test func aPlaceIsNoDistanceFromItself() {
    let pantheon = GeoCoordinate(latitude: 41.8986, longitude: 12.4769)
    #expect(pantheon.distance(to: pantheon) == 0)
}

// MARK: - Centroid

@Test func theCentroidIsTheAverageOfThePoints() {
    let centre = GeoCoordinate.centroid(of: [
        GeoCoordinate(latitude: 41.0, longitude: 12.0),
        GeoCoordinate(latitude: 42.0, longitude: 13.0),
        GeoCoordinate(latitude: 43.0, longitude: 14.0),
    ])
    #expect(centre == GeoCoordinate(latitude: 42.0, longitude: 13.0))
}

@Test func nothingToAverageHasNoCentroid() {
    #expect(GeoCoordinate.centroid(of: []) == nil)
}

// MARK: - Stub

@Test func theStubAnswersWhatItWasGiven() async {
    let rome = GeoCoordinate(latitude: 41.9, longitude: 12.5)
    #expect(await StubLocationProvider(.located(rome)).currentLocation() == .located(rome))
    #expect(await StubLocationProvider(.denied).currentLocation() == .denied)
}

@Test func aCentroidIsTheSameToTheLastBitInAnyOrder() throws {
    // Day 1 of the Rome trip in Trips' SuggestionAsk tests: summed in some
    // orders these came to 12.480266666666667, in others …665.
    let points = [
        GeoCoordinate(latitude: 41.9065, longitude: 12.4536),
        GeoCoordinate(latitude: 41.8902, longitude: 12.4922),
        GeoCoordinate(latitude: 41.9005, longitude: 12.4950),
    ]
    let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
    let centres = orders.map { order in GeoCoordinate.centroid(of: order.map { points[$0] }) }
    let first = try #require(centres.first ?? nil)
    #expect(centres.allSatisfy { $0 == first })
    // And unsorted addition really does differ here, or this test proves nothing.
    let naive = Set(orders.map { order in order.map { points[$0].longitude }.reduce(0, +) })
    #expect(naive.count > 1)
}
