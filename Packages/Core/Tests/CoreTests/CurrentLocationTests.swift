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
