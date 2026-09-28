import CoreData
import Foundation

public extension SharedItineraryItem {
    /// Turns a suggestion into an ordinary idea — or, given a `day`, straight
    /// into a stop at the end of that day — with the place's name, kind,
    /// address and coordinate, and the model's why as its detail. Nothing
    /// marks it as suggested: it syncs to a partner as any idea does, and a
    /// partner with no Apple Intelligence sees and uses it the same. No
    /// schema change: an idea is the `unassignedDayIndex` sentinel.
    ///
    /// Adding the same place twice — a double tap, or the same suggestion from
    /// two screens — gives back the item already there, moved onto `day` if it
    /// was an idea and a day was chosen. The caller saves.
    @discardableResult
    static func add(
        _ suggestion: PlaceSuggestion,
        to trip: SharedTrip,
        in context: NSManagedObjectContext,
        day: Int = unassignedDayIndex
    ) -> SharedItineraryItem {
        let place = suggestion.place
        if let existing = (trip.items ?? []).first(where: { SuggestionCandidates.isSame(place, title: $0.title, coordinate: $0.coordinate) }) {
            if day >= 0, existing.isUnassigned { existing.move(toDay: day) }
            return existing
        }
        let item = SharedItineraryItem(context: context, title: place.name, kind: place.kind, dayIndex: unassignedDayIndex)
        item.trip = trip
        item.address = place.address
        item.latitude = place.latitude
        item.longitude = place.longitude
        item.detail = suggestion.why
        // After the trip is set, so the new item lands after what's already
        // there — `move(toDay:)` works for a just-inserted item even on the
        // day it already has.
        item.move(toDay: day)
        return item
    }
}
