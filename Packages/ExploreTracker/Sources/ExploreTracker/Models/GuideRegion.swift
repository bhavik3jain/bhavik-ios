import CoreLocation
import Foundation
import MapKit

/// A latitude and longitude in degrees. Plain values rather than
/// `CLLocationCoordinate2D`, which is neither `Hashable` nor `Equatable` — and
/// the weather fetch is keyed on this.
public struct GeoPoint: Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Great-circle distance in metres — as the crow flies, not along streets.
    public func distance(to other: GeoPoint) -> Double {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }
}

/// The patch of map a guide covers, worked out from its places.
///
/// A guide has no centre of its own — the owner rejected one twice — so this is
/// the only answer to "where is this guide?": the map opens on it, the weather
/// is fetched for its centre, and place search is biased toward it.
public struct GuideRegion: Hashable, Sendable {
    public let center: GeoPoint
    public let latitudeDelta: Double
    public let longitudeDelta: Double

    /// Around a single place: a few streets either way, enough to see where it
    /// sits without zooming out to the whole city.
    public static let singlePlaceSpan = 0.02
    /// Two places across the street from each other would otherwise produce a
    /// map zoomed in to the doorsteps.
    public static let minimumSpan = 0.01
    /// Pins at the very edge of the frame sit under the map's own chrome.
    public static let padding = 1.4

    public init(center: GeoPoint, latitudeDelta: Double, longitudeDelta: Double) {
        self.center = center
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
    }

    /// The padded bounding box around `points`, or `nil` when there are none —
    /// an empty guide, or one whose places were all added by hand, is nowhere.
    ///
    /// A guide that straddles the 180th meridian would get a box spanning the
    /// rest of the globe; no guide the owner keeps is anywhere near it.
    public static func enclosing(_ points: [GeoPoint]) -> GuideRegion? {
        guard let first = points.first else { return nil }
        guard points.count > 1 else {
            return GuideRegion(center: first, latitudeDelta: singlePlaceSpan, longitudeDelta: singlePlaceSpan)
        }
        let latitudes = points.map(\.latitude)
        let longitudes = points.map(\.longitude)
        let minLat = latitudes.min()!, maxLat = latitudes.max()!
        let minLon = longitudes.min()!, maxLon = longitudes.max()!
        return GuideRegion(
            center: GeoPoint(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            latitudeDelta: min(180, max(minimumSpan, (maxLat - minLat) * padding)),
            longitudeDelta: min(360, max(minimumSpan, (maxLon - minLon) * padding))
        )
    }

    public var coordinateRegion: MKCoordinateRegion {
        MKCoordinateRegion(
            center: center.coordinate,
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }
}

/// How far a place is from the reader, and how long it is on foot.
public struct WalkingEstimate: Equatable, Sendable {
    /// A steady city pace, about 5 km/h.
    public static let metresPerMinute = 5_000.0 / 60
    /// Beyond this nobody is walking, and "about 150 min walk" is noise rather
    /// than information — the card shows the distance alone.
    public static let longestWalkMetres = 10_000.0
    /// Past this, Directions opens Maps in its default mode rather than walking.
    public static let walkingDirectionsLimitMetres = 3_000.0

    public let metres: Double

    public init(metres: Double) {
        self.metres = metres
    }

    public init(from origin: GeoPoint, to destination: GeoPoint) {
        self.metres = origin.distance(to: destination)
    }

    /// Whole minutes on foot, never fewer than one.
    public var walkingMinutes: Int {
        max(1, Int((metres / Self.metresPerMinute).rounded()))
    }

    public var isWalkable: Bool { metres <= Self.longestWalkMetres }

    public var prefersWalkingDirections: Bool { metres <= Self.walkingDirectionsLimitMetres }

    /// "650 m" or "1.2 km" where people use kilometres; "0.4 mi" or "300 ft"
    /// where they use miles — the US and the UK both do for distances on foot.
    public func distanceText(locale: Locale = .current) -> String {
        if locale.measurementSystem == .metric {
            if metres < 1_000 {
                // Tens of metres: "653 m" claims a precision a phone's fix doesn't have.
                let rounded = max(10, Int((metres / 10).rounded()) * 10)
                return "\(rounded) m"
            }
            return "\(oneDecimal(metres / 1_000, locale: locale)) km"
        }
        let miles = metres / 1_609.344
        if miles < 0.1 {
            let feet = metres * 3.280_84
            let rounded = max(50, Int((feet / 50).rounded()) * 50)
            return "\(rounded) ft"
        }
        return "\(oneDecimal(miles, locale: locale)) mi"
    }

    /// "8 min walk", "1 hr 5 min walk".
    public var walkingText: String {
        let minutes = walkingMinutes
        guard minutes >= 60 else { return "\(minutes) min walk" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) hr walk" : "\(hours) hr \(rest) min walk"
    }

    /// The bottom card's line: "650 m from you · about 8 min walk".
    public func summary(locale: Locale = .current) -> String {
        let distance = "\(distanceText(locale: locale)) from you"
        return isWalkable ? "\(distance) · about \(walkingText)" : distance
    }

    private func oneDecimal(_ value: Double, locale: Locale) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(locale))
    }
}
