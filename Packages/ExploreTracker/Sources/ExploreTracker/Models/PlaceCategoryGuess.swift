import MapKit

public extension PlaceCategory {
    /// Which shelf an Apple Maps result most likely belongs on.
    ///
    /// Only a guess — the add sheet shows it preselected and the reader can
    /// change it. Anything Maps doesn't categorise, or categorises as a sight,
    /// a shop or a service, lands in Places: it is the shelf that reads least
    /// wrong for an unknown.
    static func guess(from category: MKPointOfInterestCategory?) -> PlaceCategory {
        guard let category else { return .places }
        if foodAndDrinkCategories.contains(category) { return .foodAndDrinks }
        if activityCategories.contains(category) { return .activities }
        return .places
    }

    private static let foodAndDrinkCategories: Set<MKPointOfInterestCategory> = [
        .restaurant, .cafe, .bakery, .brewery, .winery, .distillery, .foodMarket, .nightlife
    ]

    /// Things you go and *do*, rather than go and look at.
    private static let activityCategories: Set<MKPointOfInterestCategory> = [
        .amusementPark, .aquarium, .zoo, .fitnessCenter, .stadium, .theater, .movieTheater,
        .musicVenue, .marina, .spa, .fairground, .planetarium,
        .hiking, .kayaking, .surfing, .skiing, .skating, .skatePark, .rockClimbing, .swimming,
        .golf, .miniGolf, .goKart, .bowling, .fishing, .tennis, .soccer, .basketball, .baseball, .volleyball
    ]
}
