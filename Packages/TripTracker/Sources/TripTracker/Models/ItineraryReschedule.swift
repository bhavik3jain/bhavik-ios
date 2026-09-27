import Core
import Foundation

/// What happens to a trip's plan when its dates change.
///
/// Items and flights are stored by day of the trip, not by date, so by default
/// moving the first day carries the whole plan along. The alternative keeps
/// everything on the calendar date it had. Either way, a range that no longer
/// covers every planned day strands what sits outside it; `SharedTrip.clampPlanToDates()`
/// used to pull those onto the last day without saying so, which read as the
/// plan having rearranged itself. This works out what falls off first, so the
/// editor can ask where it goes.
public struct ItineraryReschedule: Sendable, Equatable {
    public enum Anchor: String, Sendable, CaseIterable, Identifiable {
        /// Everything keeps its day of the trip, and the dates move with it.
        case moveWithTrip
        /// Everything keeps its date, so its day of the trip changes.
        case keepCalendarDates

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .moveWithTrip: "Move the plan with the trip"
            case .keepCalendarDates: "Keep items on their calendar dates"
            }
        }
    }

    /// Where things that fall outside the new dates go.
    public enum Overflow: Sendable, Equatable {
        /// The nearest day still in the trip: the last day for anything past
        /// the end, the first for anything before the start.
        case nearestDay
        /// Off the days entirely. Items only — a flight isn't an idea, so
        /// flights still go to the nearest day.
        case unassigned
    }

    /// How many things fall outside the new dates, and on which side.
    public struct Stranding: Sendable, Equatable {
        public var items = 0
        public var flights = 0
        public var beforeStart = false
        public var afterEnd = false

        public var isEmpty: Bool { items == 0 && flights == 0 }

        /// "2 items and 1 flight".
        public var summary: String {
            [items > 0 ? counted(items, "item") : nil, flights > 0 ? counted(flights, "flight") : nil]
                .compactMap(\.self)
                .joined(separator: " and ")
        }

        /// "2 items and 1 flight fall outside the new dates".
        public var title: String {
            "\(summary) \(items + flights == 1 ? "falls" : "fall") outside the new dates"
        }

        /// The `.unassigned` button's title. Flights still go to the nearest
        /// day, so with any among them it only promises the items.
        public var ideasTitle: String {
            if flights > 0 { return "Move Items to Ideas" }
            return items == 1 ? "Move It to Ideas" : "Move Them to Ideas"
        }

        /// The `.nearestDay` button's title.
        public var nearestDayTitle: String {
            let them = items + flights == 1 ? "It" : "Them"
            switch (beforeStart, afterEnd) {
            case (true, true): return "Move \(them) to the First or Last Day"
            case (true, false): return "Move \(them) to the First Day"
            default: return "Move \(them) to the Last Day"
            }
        }
    }

    public let old: TripDates
    public let new: TripDates
    public var anchor: Anchor

    public init(from old: TripDates, to new: TripDates, anchor: Anchor = .moveWithTrip) {
        self.old = old
        self.new = new
        self.anchor = anchor
    }

    /// Calendar days the first day moved: 3 is three days later.
    public var startShift: Int { old.offset(of: new.start) }

    /// Whether `anchor` makes any difference.
    public var startMoved: Bool { startShift != 0 }

    /// What `anchor` will do, in words: "Everything planned moves 3 days later
    /// with the trip."
    public var effect: String {
        guard startMoved else { return "" }
        switch anchor {
        case .moveWithTrip:
            let direction = startShift > 0 ? "later" : "earlier"
            return "Everything planned moves \(counted(abs(startShift), "day")) \(direction) with the trip."
        case .keepCalendarDates:
            return "Everything planned stays on its date, so its day of the trip changes."
        }
    }

    /// Where something now on `index` goes before anything is done about
    /// overflow. Ideas aren't on a day, so they stay put — any negative day,
    /// matching `SharedItineraryItem.isUnassigned`. A flight is never an idea.
    public func proposedDay(for index: Int, isFlight: Bool = false) -> Int {
        if !isFlight, index < 0 { return index }
        return anchor == .moveWithTrip ? index : index - startShift
    }

    public func isStranded(_ index: Int, isFlight: Bool = false) -> Bool {
        if !isFlight, index < 0 { return false }
        return !(0..<new.dayCount).contains(proposedDay(for: index, isFlight: isFlight))
    }

    /// Where something now on `index` ends up.
    public func resolvedDay(for index: Int, isFlight: Bool = false, overflow: Overflow) -> Int {
        let proposed = proposedDay(for: index, isFlight: isFlight)
        guard isStranded(index, isFlight: isFlight) else { return proposed }
        if overflow == .unassigned, !isFlight { return SharedItineraryItem.unassignedDayIndex }
        return min(max(proposed, 0), new.dayCount - 1)
    }

    public func stranding(itemDays: [Int], flightDays: [Int]) -> Stranding {
        var result = Stranding()
        func note(_ index: Int, isFlight: Bool) -> Bool {
            guard isStranded(index, isFlight: isFlight) else { return false }
            if proposedDay(for: index, isFlight: isFlight) < 0 {
                result.beforeStart = true
            } else {
                result.afterEnd = true
            }
            return true
        }
        result.items = itemDays.count { note($0, isFlight: false) }
        result.flights = flightDays.count { note($0, isFlight: true) }
        return result
    }

    public func stranding(of trip: SharedTrip) -> Stranding {
        stranding(itemDays: (trip.items ?? []).map(\.dayIndex), flightDays: (trip.flights ?? []).map(\.dayIndex))
    }

    /// Moves `trip`'s plan to fit the new dates. Doesn't set the trip's own
    /// dates or save.
    public func apply(to trip: SharedTrip, overflow: Overflow) {
        // Things that stay on the plan move all together, keeping their order
        // within each day. Stranded items then join the end of wherever they
        // land, in the order they were in — moving them one by one first would
        // have them jostling for sortOrder with items that hadn't moved yet.
        let items = (trip.items ?? []).sorted { ($0.dayIndex, $0.sortOrder, $0.title) < ($1.dayIndex, $1.sortOrder, $1.title) }
        let stranded = items.filter { isStranded($0.dayIndex) }
        for item in items where !isStranded(item.dayIndex) {
            item.dayIndex = proposedDay(for: item.dayIndex)
        }
        // Set by hand rather than through `move(toDay:)`, which does nothing
        // when the day doesn't change: keeping calendar dates can pull an item
        // back onto the very day it was stored on, and its old sortOrder would
        // then drop it among the items that just moved there.
        for item in stranded {
            let target = resolvedDay(for: item.dayIndex, overflow: overflow)
            item.sortOrder = SharedItineraryItem.nextSortOrder(onDay: target, among: items, excluding: item)
            item.dayIndex = target
        }

        // A flight's times move by however far its day moved on the calendar:
        // with the trip, that's the shift; kept on its dates, nothing, unless
        // it fell off an end and had to be pulled in.
        for flight in trip.flights ?? [] {
            let target = resolvedDay(for: flight.dayIndex, isFlight: true, overflow: overflow)
            flight.move(toDay: target, shiftingTimesBy: startShift + target - flight.dayIndex, calendar: new.calendar)
        }

        // Bookings carry real dates and no day, so they only move when the plan
        // moves with the trip — otherwise the hotel stayed on the old dates.
        if anchor == .moveWithTrip, startMoved {
            let calendar = new.calendar
            for booking in trip.bookings ?? [] {
                booking.startsAt = booking.startsAt.flatMap { calendar.date(byAdding: .day, value: startShift, to: $0) }
                booking.endsAt = booking.endsAt.flatMap { calendar.date(byAdding: .day, value: startShift, to: $0) }
            }
        }
    }
}
