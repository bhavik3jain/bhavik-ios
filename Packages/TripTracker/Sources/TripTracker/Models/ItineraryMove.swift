import CoreData
import Foundation

// Moving one thing on the plan to another day — the editors' Day pickers, the
// timeline's "Move to…", and `ItineraryReschedule` when a trip's dates change
// all go through these and `SharedItineraryItem.move(toDay:)`, so an item
// always lands at the end of its new day and a flight's times always land on
// its new date.

extension SharedItineraryItem {
    /// One past the highest `sortOrder` on `dayIndex`. `move(toDay:)` works
    /// this out for itself but does nothing when the day doesn't change;
    /// `ItineraryReschedule` needs it for an item pulled back onto the day it
    /// was already on, which the rest of that day's plan has just moved onto
    /// around it.
    static func nextSortOrder(
        onDay dayIndex: Int,
        among items: some Sequence<SharedItineraryItem>,
        excluding moving: SharedItineraryItem? = nil
    ) -> Int {
        let existing = items.filter { $0 !== moving && $0.dayIndex == dayIndex }.map(\.sortOrder)
        return (existing.max() ?? -1) + 1
    }
}

public extension SharedFlight {
    /// Puts the flight on another day of the same trip, carrying its times
    /// along by the same number of days.
    ///
    /// A flight has both a day and real moments. Changing only the day left
    /// the timeline showing it on the new day while the next-flight card,
    /// Codes and the PDF — which read `departsAt` — still printed the old date.
    func move(toDay index: Int, in dates: TripDates) {
        move(toDay: index, shiftingTimesBy: index - dayIndex, calendar: dates.calendar)
    }

    /// Sets the day and moves both times by `days` calendar days, keeping
    /// their time of day and the flight's length.
    ///
    /// A shift rather than snapping the departure onto the new day's date: a
    /// flight's departure needn't fall on its own day — the overnight flight
    /// out, filed under the day it lands — and snapping would quietly rebook
    /// it for the wrong night.
    func move(toDay index: Int, shiftingTimesBy days: Int, calendar: Calendar) {
        if days != 0 {
            departsAt = departsAt.flatMap { calendar.date(byAdding: .day, value: days, to: $0) }
            arrivesAt = arrivesAt.flatMap { calendar.date(byAdding: .day, value: days, to: $0) }
        }
        dayIndex = index
    }
}
