import Core
import Foundation
import MapKit

/// A real place a search returned, as a plain value. `MKMapItem` is not
/// `Sendable`, so it can't cross from a search into an actor — Swift 6 rejects
/// it at compile time — and nothing past the searcher needs more than this.
public struct FoundPlace: Sendable, Hashable, Identifiable {
    public let name: String
    /// "Museum", "National Park" — Apple Maps' point-of-interest category, or
    /// nil when it has none.
    public let category: String?
    public let latitude: Double
    public let longitude: Double
    public let address: String

    public init(name: String, category: String?, latitude: Double, longitude: Double, address: String = "") {
        self.name = name
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
    }

    public var id: String { "\(name)|\(latitude)|\(longitude)" }

    public var coordinate: GeoCoordinate { GeoCoordinate(latitude: latitude, longitude: longitude) }

    /// What the new idea's kind is.
    public var kind: ItemKind { Self.kind(forCategory: category) }

    /// True for a museum or a restaurant, false for a park or a beach, nil
    /// when the category doesn't say — what the model reads to prefer indoor
    /// places on a wet day.
    public var isIndoor: Bool? { Self.isIndoor(category: category) }

    /// "MKPOICategoryNationalPark" → "National Park".
    public static func categoryName(fromRawValue raw: String) -> String {
        let bare = raw.hasPrefix("MKPOICategory") ? String(raw.dropFirst("MKPOICategory".count)) : raw
        var words: [String] = []
        var current = ""
        for character in bare {
            if character.isUppercase, !current.isEmpty, !(current.last?.isUppercase ?? false) {
                words.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words.joined(separator: " ")
    }

    private static func key(_ category: String?) -> String {
        (category ?? "").lowercased().filter(\.isLetter)
    }

    static let sightCategories: Set<String> = [
        "museum", "landmark", "nationalmonument", "castle", "fortress", "planetarium", "aquarium", "library", "university",
    ]
    static let foodCategories: Set<String> = [
        "restaurant", "cafe", "bakery", "brewery", "winery", "distillery", "foodmarket", "nightlife",
    ]
    static let activityCategories: Set<String> = [
        "park", "nationalpark", "beach", "marina", "zoo", "amusementpark", "stadium", "theater", "movietheater",
        "musicvenue", "hiking", "skiing", "golf", "campground", "spa", "bowling", "kayaking", "surfing", "swimming",
        "rockclimbing", "fairground", "minigolf", "gokart", "skating", "skatepark", "scenicview", "picnicarea",
    ]
    static let indoorCategories: Set<String> = [
        "museum", "planetarium", "aquarium", "library", "theater", "movietheater", "musicvenue", "restaurant", "cafe",
        "bakery", "brewery", "winery", "distillery", "foodmarket", "nightlife", "spa", "bowling", "store",
    ]
    static let outdoorCategories: Set<String> = [
        "park", "nationalpark", "beach", "marina", "zoo", "amusementpark", "hiking", "skiing", "golf", "campground",
        "kayaking", "surfing", "fairground", "minigolf", "skatepark", "scenicview", "picnicarea", "landmark",
        "nationalmonument", "castle", "fortress",
    ]

    public static func kind(forCategory category: String?) -> ItemKind {
        let key = key(category)
        if sightCategories.contains(key) { return .sight }
        if foodCategories.contains(key) { return .food }
        if activityCategories.contains(key) { return .activity }
        return .other
    }

    public static func isIndoor(category: String?) -> Bool? {
        let key = key(category)
        if indoorCategories.contains(key) { return true }
        if outdoorCategories.contains(key) { return false }
        return nil
    }
}

/// Finds real places around a point. Behind a protocol so tests and the
/// simulator run on made-up places, never the network.
public protocol PlaceSearching: Sendable {
    /// Points of interest for `query` within `radiusMetres` of `center`. May
    /// return nothing; throws only when the search itself failed.
    func search(_ query: String, near center: GeoCoordinate, radiusMetres: Double) async throws -> [FoundPlace]
}

/// Apple Maps, through `MKLocalSearch`. Queries are one or two plain words —
/// "museum", "gelato" — chosen in Swift by `SuggestionRequest`: the spike's
/// "indoor activities Rome rainy afternoon" came back `MKErrorDomain 4` /
/// `GEOError -8`, no results at all.
public struct MapKitPlaceSearcher: PlaceSearching {
    public static let resultLimit = 8

    public init() {}

    public func search(_ query: String, near center: GeoCoordinate, radiusMetres: Double) async throws -> [FoundPlace] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = .pointOfInterest
        request.region = MKCoordinateRegion(
            center: center.clCoordinate,
            latitudinalMeters: radiusMetres * 2,
            longitudinalMeters: radiusMetres * 2
        )
        // Without `.required` the region is only a hint: "museum" for Rome came
        // back with museums in Boston, near the Mac running the search, and
        // "restaurant" with a town on another continent.
        request.regionPriority = .required
        let items = try await MKLocalSearch(request: request).start().mapItems
        return items.prefix(Self.resultLimit).compactMap { item -> FoundPlace? in
            guard let name = item.name, !name.isEmpty else { return nil }
            let point = Self.coordinate(of: item)
            let place = FoundPlace(
                name: name,
                category: item.pointOfInterestCategory.map { FoundPlace.categoryName(fromRawValue: $0.rawValue) },
                latitude: point.latitude,
                longitude: point.longitude,
                address: Self.address(of: item)
            )
            // `.required` has still let the odd far-off result through; past
            // the radius it isn't "near" anything on the plan.
            return place.coordinate.distance(to: center) <= radiusMetres * 1.5 ? place : nil
        }
    }

    private static func coordinate(of item: MKMapItem) -> CLLocationCoordinate2D {
        if #available(iOS 26.0, macOS 26.0, *) {
            return item.location.coordinate
        }
        return item.placemark.coordinate
    }

    private static func address(of item: MKMapItem) -> String {
        if #available(iOS 26.0, macOS 26.0, *) {
            return item.address?.shortAddress ?? item.address?.fullAddress ?? ""
        }
        return item.placemark.title ?? ""
    }
}
