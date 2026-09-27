import Foundation

/// Where on a trip's plan something can sit: one of its days, or — for an
/// itinerary item only — no day yet. What the editors' Day pickers and the
/// timeline's "Move to…" menu offer.
public enum DayChoice: Hashable, Sendable, Identifiable {
    case day(Int)
    case unassigned

    /// Whether pickers and menus offer `.unassigned`. It was off until the trip
    /// screen had an Ideas list: an item moved there before then dropped off
    /// every day with no way to reach it again. Flights still pass `false`
    /// explicitly — they are always on a day.
    public static let offersUnassigned = true

    /// Every negative day is an idea (see `SharedItineraryItem.isUnassigned`),
    /// but pickers only have a tag for -1: a stray -3 would open on no row.
    public init(dayIndex: Int) {
        self = dayIndex < 0 ? .unassigned : .day(dayIndex)
    }

    public var id: Int { dayIndex }

    /// What gets stored in an item's or flight's `dayIndex`.
    public var dayIndex: Int {
        switch self {
        case .day(let index): index
        case .unassigned: SharedItineraryItem.unassignedDayIndex
        }
    }

    /// "Mon 8 Jun · Day 3" — the date first, since that's what people plan by;
    /// the day number is how the rest of the trip screen counts.
    public func label(in dates: TripDates) -> String {
        switch self {
        case .day(let index):
            let date = dates.date(forDay: index).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            return "\(date) · Day \(index + 1)"
        case .unassigned:
            return "No day yet · Ideas"
        }
    }

    /// The same "Mon 8 Jun · Day 3" for a real moment — a booking's check-in —
    /// so the booking editor reads like the Day pickers beside it. Outside the
    /// trip it says so instead of a day number: "Fri 5 Jun · Before the trip".
    public static func label(for date: Date, in dates: TripDates) -> String {
        let offset = dates.offset(of: date)
        if (0..<dates.dayCount).contains(offset) {
            return DayChoice.day(offset).label(in: dates)
        }
        let day = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return "\(day) · \(offset < 0 ? "Before" : "After") the trip"
    }

    /// "Today" or "Tomorrow" while the trip is under way, otherwise nil.
    public func relativeName(in dates: TripDates, asOf now: Date = .now) -> String? {
        guard case .day(let index) = self, let today = dates.dayIndex(of: now) else { return nil }
        switch index - today {
        case 0: return "Today"
        case 1: return "Tomorrow"
        default: return nil
        }
    }

    /// Every day of the trip in order, then `.unassigned` when offered.
    ///
    /// `keeping` is the choice something already has: it's included even when
    /// it isn't otherwise on offer — a day past the end that synced in from
    /// another device, or `.unassigned` while that isn't offered — because a
    /// `Picker` whose selection matches no tag shows a blank row.
    public static func all(
        in dates: TripDates,
        includingUnassigned: Bool = offersUnassigned,
        keeping current: DayChoice? = nil
    ) -> [DayChoice] {
        var choices = (0..<dates.dayCount).map(DayChoice.day)
        if let current, case .day(let index) = current, !(0..<dates.dayCount).contains(index) {
            choices.insert(current, at: index < 0 ? 0 : choices.endIndex)
        }
        if includingUnassigned || current == .unassigned {
            choices.append(.unassigned)
        }
        return choices
    }

    /// Where the timeline's "Move to…" can send something now on `current`:
    /// every other day, with tomorrow pulled to the front while the trip is
    /// under way — the usual reason to move something mid-trip is "not today".
    public static func moveTargets(
        from current: DayChoice,
        in dates: TripDates,
        includingUnassigned: Bool = offersUnassigned,
        asOf now: Date = .now
    ) -> [DayChoice] {
        var targets = all(in: dates, includingUnassigned: includingUnassigned).filter { $0 != current }
        if let today = dates.dayIndex(of: now),
           let tomorrow = targets.firstIndex(of: .day(today + 1)) {
            targets.insert(targets.remove(at: tomorrow), at: 0)
        }
        return targets
    }
}
