import MapKit
import SwiftUI

/// Handing an item to Apple Maps — the map's place card and Nearby's rows both
/// come through here. The same approach as Explore's `PlaceDirections`, which
/// Trips can't import.
enum TripDirections {
    /// Walking directions when the place is a walk away, otherwise Maps'
    /// default mode. An idea typed in with an address but no pin has no
    /// coordinates, so Maps is asked to find the address instead.
    @MainActor
    static func open(_ item: SharedItineraryItem, walking: Bool, openURL: OpenURLAction) {
        if let point = item.coordinate {
            let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: point.clCoordinate))
            mapItem.name = item.title
            mapItem.openInMaps(launchOptions: [
                MKLaunchOptionsDirectionsModeKey: walking ? MKLaunchOptionsDirectionsModeWalking : MKLaunchOptionsDirectionsModeDefault
            ])
        } else if let url = searchURL(for: item) {
            openURL(url)
        }
    }

    static func canOpen(_ item: SharedItineraryItem) -> Bool {
        item.hasCoordinate || !item.address.isEmpty
    }

    private static func searchURL(for item: SharedItineraryItem) -> URL? {
        guard !item.address.isEmpty else { return nil }
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "daddr", value: "\(item.title), \(item.address)")]
        return components?.url
    }
}
