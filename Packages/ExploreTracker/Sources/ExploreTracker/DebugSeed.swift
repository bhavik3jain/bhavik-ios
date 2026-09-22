#if DEBUG
import Core
import CoreData
import Foundation

/// Fills a fresh simulator with three real-world guides so the list, the maps
/// and the weather have something to show. Debug builds only, only when
/// launched with `-ExploreSeed YES`, and never when any guide already exists.
public enum ExploreDebugSeed {
    public static var isRequested: Bool {
        // Never against a store `ExploreLegacyMigration` has already run
        // against — that device may be holding real, possibly-shared guides
        // (or simply have already decided there was nothing to migrate), and
        // stacking fake ones on top of either is never what `-ExploreSeed` is
        // asking for.
        UserDefaults.standard.bool(forKey: "ExploreSeed") && !ExploreLegacyMigration.hasRun
    }

    private struct Sample {
        let name: String
        let category: PlaceCategory
        let note: String
        let address: String
        let latitude: Double
        let longitude: Double
        /// `nil` for To try; 0 for tried without a rating.
        let rating: Int?
    }

    @MainActor
    public static func run(context: NSManagedObjectContext, asOf now: Date = .now) {
        guard (try? context.count(for: SharedGuide.fetchRequest())) == 0 else { return }

        // Oldest first, so Kyoto — the fullest — ends up newest and gets the
        // large card at the top of the list.
        let guides: [(name: String, area: String, places: [Sample])] = [
            ("Around the office — SoMa", "San Francisco", soma),
            ("Hudson Valley weekend", "New York", hudsonValley),
            ("Gion & Higashiyama", "Kyoto, Japan", kyoto),
        ]

        for (offset, entry) in guides.enumerated() {
            let guide = SharedGuide(context: context, name: entry.name, areaLabel: entry.area)
            guide.createdAt = now.addingTimeInterval(Double(offset - guides.count) * 86_400)
            for (index, sample) in entry.places.enumerated() {
                let place = SharedGuidePlace(
                    context: context,
                    name: sample.name,
                    category: sample.category,
                    note: sample.note,
                    address: sample.address,
                    latitude: sample.latitude,
                    longitude: sample.longitude
                )
                place.addedAt = guide.createdAt.addingTimeInterval(Double(index) * 60)
                place.guide = guide
                if let rating = sample.rating {
                    place.setTried(true, asOf: now)
                    place.rating = rating
                }
            }
        }
        try? context.saveIfNeeded()
    }

    private static let kyoto: [Sample] = [
        Sample(name: "Gion Duck Noodles", category: .foodAndDrinks, note: "Ramen · go before 11:30", address: "Gionmachi Kitagawa, Higashiyama-ku", latitude: 35.0047, longitude: 135.7745, rating: nil),
        Sample(name: "Kagizen Yoshifusa", category: .foodAndDrinks, note: "Sweets & matcha · kuzukiri", address: "264 Gionmachi Kitagawa, Higashiyama-ku", latitude: 35.0037, longitude: 135.7749, rating: 5),
        Sample(name: "% Arabica Higashiyama", category: .foodAndDrinks, note: "Coffee · on the Yasaka slope", address: "87-5 Hoshinocho, Higashiyama-ku", latitude: 34.9983, longitude: 135.7796, rating: nil),
        Sample(name: "Pontocho izakaya alley", category: .foodAndDrinks, note: "Dinner · book a riverside seat", address: "Pontocho, Nakagyo-ku", latitude: 35.0055, longitude: 135.7707, rating: 0),
        Sample(name: "Nishiki Market", category: .foodAndDrinks, note: "Snacks · closes early", address: "Nishikikoji-dori, Nakagyo-ku", latitude: 35.0050, longitude: 135.7649, rating: 4),
        Sample(name: "Gion Tanto", category: .foodAndDrinks, note: "Okonomiyaki by the canal", address: "Shirakawa-suji, Higashiyama-ku", latitude: 35.0058, longitude: 135.7752, rating: nil),
        Sample(name: "Yasaka Shrine", category: .places, note: "Lanterns lit after dark", address: "625 Gionmachi Kitagawa, Higashiyama-ku", latitude: 35.0036, longitude: 135.7786, rating: nil),
        Sample(name: "Kiyomizu-dera", category: .places, note: "Early, before the tour buses", address: "1-294 Kiyomizu, Higashiyama-ku", latitude: 34.9949, longitude: 135.7850, rating: 5),
        Sample(name: "Yasaka Pagoda (Hokan-ji)", category: .places, note: "Best from Yasaka-dori", address: "Yasakakamimachi, Higashiyama-ku", latitude: 34.9985, longitude: 135.7809, rating: nil),
        Sample(name: "Kennin-ji", category: .places, note: "Twin dragons ceiling", address: "584 Komatsucho, Higashiyama-ku", latitude: 35.0006, longitude: 135.7735, rating: nil),
        Sample(name: "Tea ceremony at Camellia", category: .activities, note: "Book ahead · 45 minutes", address: "349-12 Masuyacho, Higashiyama-ku", latitude: 34.9968, longitude: 135.7812, rating: nil),
        Sample(name: "Evening walk down Hanamikoji", category: .activities, note: "Around dusk", address: "Hanamikoji-dori, Higashiyama-ku", latitude: 35.0025, longitude: 135.7752, rating: nil),
    ]

    private static let hudsonValley: [Sample] = [
        Sample(name: "Dia Beacon", category: .places, note: "Allow three hours", address: "3 Beekman St, Beacon", latitude: 41.5003, longitude: -73.9819, rating: 5),
        Sample(name: "Storm King Art Center", category: .places, note: "Rent a bike at the gate", address: "1 Museum Rd, New Windsor", latitude: 41.4253, longitude: -74.0597, rating: nil),
        Sample(name: "Walkway Over the Hudson", category: .activities, note: "Sunset from the middle", address: "61 Parker Ave, Poughkeepsie", latitude: 41.7106, longitude: -73.9443, rating: nil),
        Sample(name: "Breakneck Ridge", category: .activities, note: "Steep scramble · go early", address: "Route 9D, Cold Spring", latitude: 41.4460, longitude: -73.9785, rating: 4),
        Sample(name: "Blue Hill at Stone Barns", category: .foodAndDrinks, note: "Special occasion", address: "630 Bedford Rd, Tarrytown", latitude: 41.1003, longitude: -73.8290, rating: nil),
        Sample(name: "Culinary Institute of America", category: .foodAndDrinks, note: "Student-run restaurants", address: "1946 Campus Dr, Hyde Park", latitude: 41.7457, longitude: -73.9337, rating: nil),
        Sample(name: "Cold Spring Main Street", category: .places, note: "Antiques and river views", address: "Main St, Cold Spring", latitude: 41.4201, longitude: -73.9546, rating: nil),
        Sample(name: "Kingston Stockade District", category: .places, note: "Oldest streets in the valley", address: "Wall St, Kingston", latitude: 41.9340, longitude: -74.0190, rating: nil),
        Sample(name: "Hudson Valley Hot-Air Balloons", category: .activities, note: "Weather permitting", address: "Red Hook", latitude: 41.9951, longitude: -73.8757, rating: nil),
    ]

    private static let soma: [Sample] = [
        Sample(name: "Sightglass Coffee", category: .foodAndDrinks, note: "The roastery on 7th", address: "270 7th St", latitude: 37.7771, longitude: -122.4086, rating: 4),
        Sample(name: "Salesforce Park", category: .places, note: "Lunch on the roof", address: "425 Mission St", latitude: 37.7897, longitude: -122.3966, rating: nil),
        Sample(name: "SFMOMA", category: .places, note: "Free ground-floor galleries", address: "151 3rd St", latitude: 37.7857, longitude: -122.4011, rating: 5),
        Sample(name: "Yerba Buena Gardens", category: .places, note: "Waterfall behind the MLK memorial", address: "750 Howard St", latitude: 37.7850, longitude: -122.4024, rating: 0),
        Sample(name: "Oracle Park", category: .activities, note: "Giants game · walk along the bay", address: "24 Willie Mays Plaza", latitude: 37.7786, longitude: -122.3893, rating: nil),
        Sample(name: "The Chieftain", category: .foodAndDrinks, note: "Friday team pint", address: "198 5th St", latitude: 37.7801, longitude: -122.4037, rating: nil),
        Sample(name: "Tartine at the Manufactory", category: .foodAndDrinks, note: "Morning buns", address: "595 Alabama St", latitude: 37.7619, longitude: -122.4117, rating: nil),
        Sample(name: "Climbing at Mission Cliffs", category: .activities, note: "Day pass after work", address: "2295 Harrison St", latitude: 37.7607, longitude: -122.4125, rating: nil),
    ]
}
#endif
