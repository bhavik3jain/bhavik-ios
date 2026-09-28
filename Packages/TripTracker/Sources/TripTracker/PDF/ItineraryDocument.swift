import Core
import Foundation

/// A trip's shareable itinerary, as plain strings: what goes in the PDF, before
/// anything is decided about pages.
///
/// The renderer draws exactly what is here and reads nothing from the models,
/// which is what makes one guarantee testable without rendering a PDF: that
/// `Booking.secureNote` is never among the strings — it is simply not read
/// when this is built. Where things fall on pages is `ItineraryLayout`'s job,
/// done only when the file is actually written — this is built on every redraw
/// of the trip screen, for its Share button.
public struct ItineraryDocument: Sendable, Equatable {
    public struct Cover: Sendable, Equatable {
        public let title: String
        public let destination: String
        /// "Saturday 6 – Sunday 14 June 2026".
        public let dateRange: String
        /// The stat tiles: 9 days, 22 places, 2 flights, 4 bookings. Days
        /// always; the others only when there are any — "0 Flights" on a
        /// road trip was a tile saying nothing.
        public let facts: [Fact]
    }

    public struct Fact: Sendable, Equatable {
        /// "9".
        public let value: String
        /// "Days" — or "Day", agreeing with the value.
        public let label: String
    }

    public struct Weather: Sendable, Equatable {
        public let symbolName: String
        /// "Partly cloudy".
        public let summary: String
        /// "28° / 19°", in the reader's own unit.
        public let temperatures: String
    }

    public struct Line: Sendable, Equatable {
        /// "09:30", or nil for anytime.
        public let time: String?
        /// "1h 30m", or "".
        public let duration: String
        public let title: String
        public let detail: String
        public let symbolName: String
        /// Drawn as a tinted row with a rule down its left edge, so it still
        /// stands out printed in black and white.
        public let isFlight: Bool
    }

    public struct Day: Sendable, Equatable {
        public let dayNumber: Int
        /// "Sat", "6", "Jun" — the date badge.
        public let weekday: String
        public let dayOfMonth: String
        public let month: String
        /// "Saturday 6 June".
        public let heading: String
        /// "Sat 6 Jun", for the cover's at-a-glance list.
        public let shortDate: String
        public let weather: Weather?
        public let lines: [Line]
    }

    public struct Confirmation: Sendable, Equatable {
        /// "Flights", "Lodging".
        public let section: String
        public let symbolName: String
        /// A flight's route, "LHR → FCO"; a booking's name.
        public let title: String
        /// "BA 548 · 07:15–10:45 · Terminal 5 · Seat 14A", "Airbnb · in Wed 10 · out Sun 14".
        public let detail: String
        /// A booking's phone number, or "".
        public let contact: String
        /// A flight's day above its route, "Sat 6 Jun"; "" for bookings, whose
        /// dates are in `detail`.
        public let date: String
        public let code: String
        public let isFlight: Bool
    }

    public let title: String
    /// "6–14 Jun 2026", for every page's footer.
    public let dateRange: String
    public let cover: Cover
    public let days: [Day]
    /// Flights, then bookings by kind.
    public let confirmations: [Confirmation]
    /// Ideas — items on no day yet — in the Ideas tab's order, for their own
    /// page at the end. No time: `Line.time` is always nil here.
    public let ideas: [Line]
    /// "27 Sep 2026" when any day carries weather: the pages that show it print
    /// the Apple Weather credit WeatherKit's terms require, and when it was
    /// fetched — a forecast printed today is stale by the trip. Nil otherwise.
    public let weatherAsOf: String?

    public init(
        title: String, dateRange: String, cover: Cover, days: [Day], confirmations: [Confirmation],
        ideas: [Line] = [], weatherAsOf: String?
    ) {
        self.title = title
        self.dateRange = dateRange
        self.cover = cover
        self.days = days
        self.confirmations = confirmations
        self.ideas = ideas
        self.weatherAsOf = weatherAsOf
    }

    /// Builds the document for `trip`: a cover, the codes, and every day.
    /// `weather` is whatever the trip screen has already fetched, matched to
    /// days the same way the Plan tab does it (`TripForecast.byDay`).
    ///
    /// Ideas — items on no day yet — get a page of their own at the end,
    /// headed as not on a day yet, and aren't counted among the cover's
    /// places. They were left out at first, on the thinking that a list of
    /// maybes reads as more plan; but the PDF is also the trip on paper for
    /// the people planning it, and a printed trip without its ideas lost half
    /// of what was saved for it. Their own page keeps them from reading as plan.
    public init(trip: SharedTrip, weather: [DayWeather] = [], asOf now: Date = .now, calendar: Calendar = .current) {
        let dates = TripDates(start: trip.startDate, end: trip.endDate, calendar: calendar)
        // Core Data's to-many relationships are `Set<T>?`, not `[T]?` — turned
        // into arrays once here rather than at every use below.
        let flights = Array(trip.flights ?? [])
        let items = Array(trip.items ?? [])
        let bookings = Array(trip.bookings ?? [])
        let forecast = TripForecast.byDay(weather, dates: dates, asOf: now)

        // Day by day from 0, so `DayPlan` never sees an idea's -1.
        let days = (0..<dates.dayCount).map { index in
            let plan = DayPlan(dayIndex: index, items: items, flights: flights, dates: dates)
            let date = dates.date(forDay: index)
            return Day(
                dayNumber: index + 1,
                weekday: date.formatted(.dateTime.weekday(.abbreviated)),
                dayOfMonth: date.formatted(.dateTime.day()),
                month: date.formatted(.dateTime.month(.abbreviated)),
                heading: date.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                shortDate: date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)),
                weather: forecast[index].map(ItineraryFormat.weather),
                lines: plan.entries.map { ItineraryFormat.line(for: $0, in: plan) }
            )
        }

        let cover = Cover(
            title: trip.title,
            destination: trip.destination,
            dateRange: ItineraryFormat.longDateRange(dates),
            facts: [Self.fact(dates.dayCount, "Day", "Days")] + [
                (trip.plannedPlaces.count, "Place", "Places"),
                (flights.count, "Flight", "Flights"),
                (bookings.count, "Booking", "Bookings"),
            ].filter { $0.0 > 0 }.map { Self.fact($0.0, $0.1, $0.2) }
        )

        self.init(
            title: trip.title,
            dateRange: (dates.start..<dates.end.addingTimeInterval(1)).formatted(.interval.day().month(.abbreviated).year()),
            cover: cover,
            days: days,
            confirmations: Self.confirmations(flights: flights, bookings: bookings, dates: dates),
            ideas: trip.ideas
                .sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                .map(ItineraryFormat.ideaLine),
            weatherAsOf: days.contains { $0.weather != nil } ? now.formatted(.dateTime.day().month(.abbreviated).year()) : nil
        )
    }

    private static func fact(_ count: Int, _ one: String, _ many: String) -> Fact {
        Fact(value: "\(count)", label: count == 1 ? one : many)
    }

    /// Flights, then bookings by kind. Reads `code` and never `secureNote`.
    static func confirmations(flights: [SharedFlight], bookings: [SharedBooking], dates: TripDates) -> [Confirmation] {
        let flightCards = flights
            .sorted { ($0.departsAt ?? dates.date(forDay: $0.dayIndex)) < ($1.departsAt ?? dates.date(forDay: $1.dayIndex)) }
            .map { flight in
                let day = flight.departsAt ?? dates.date(forDay: flight.dayIndex)
                return Confirmation(
                    section: "Flights",
                    symbolName: "airplane",
                    title: flight.route.isEmpty ? flight.headline : flight.route,
                    detail: ItineraryFormat.flightCardDetail(flight),
                    contact: "",
                    date: day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)),
                    code: flight.confirmationCode,
                    isFlight: true
                )
            }
        let bookingCards = BookingGroups.ordered(bookings).flatMap { group in
            group.bookings.map { booking in
                Confirmation(
                    section: group.kind.displayName,
                    symbolName: group.kind.symbolName,
                    title: booking.title,
                    detail: ItineraryFormat.bookingDetail(booking),
                    contact: booking.contactPhone,
                    date: "",
                    code: booking.code,
                    isFlight: false
                )
            }
        }
        return flightCards + bookingCards
    }
}

/// Bookings grouped by kind in a fixed order, then by date and `sortOrder` — the
/// Codes screen and the PDF both list them this way.
public enum BookingGroups {
    public struct Group {
        public let kind: BookingKind
        public let bookings: [SharedBooking]
    }

    public static func ordered(_ bookings: [SharedBooking]) -> [Group] {
        BookingKind.allCases.compactMap { kind in
            let matching = bookings
                .filter { $0.kind == kind }
                .sorted { lhs, rhs in
                    let left = lhs.startsAt ?? .distantFuture
                    let right = rhs.startsAt ?? .distantFuture
                    if left != right { return left < right }
                    if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
            return matching.isEmpty ? nil : Group(kind: kind, bookings: matching)
        }
    }
}

/// The strings the screens and the PDF share, so the two never disagree.
public enum ItineraryFormat {
    /// "6–14 Jun" in the locale's own shape.
    public static func dateRange(_ dates: TripDates) -> String {
        (dates.start..<dates.end.addingTimeInterval(1)).formatted(.interval.day().month(.abbreviated))
    }

    /// "Saturday 6 – Sunday 14 June 2026", for the PDF's cover.
    public static func longDateRange(_ dates: TripDates) -> String {
        (dates.start..<dates.end.addingTimeInterval(1)).formatted(.interval.weekday(.wide).day().month(.wide).year())
    }

    public static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    /// "1h 30m", "45m", "2h".
    public static func duration(minutes: Int) -> String {
        guard minutes > 0 else { return "" }
        let hours = minutes / 60
        let rest = minutes % 60
        switch (hours, rest) {
        case (0, _): return "\(rest)m"
        case (_, 0): return "\(hours)h"
        default: return "\(hours)h \(rest)m"
        }
    }

    /// "Sun 14 Jun · 18:40–20:25 · Seat 32K".
    public static func flightWhen(_ flight: SharedFlight, dates: TripDates) -> String {
        var parts: [String] = []
        let day = flight.departsAt ?? dates.date(forDay: flight.dayIndex)
        parts.append(day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
        if let times = times(flight) { parts.append(times) }
        if !flight.seat.isEmpty { parts.append("Seat \(flight.seat)") }
        return parts.joined(separator: " · ")
    }

    /// "BA 548 · 07:15–10:45 · Terminal 5 · Seat 14A" — under a flight card's
    /// route, which already says where, while the card's own label says when.
    public static func flightCardDetail(_ flight: SharedFlight) -> String {
        var parts: [String] = []
        // The designator only when the route took the title; without a route
        // the title is already the headline, designator and all.
        if !flight.route.isEmpty, !flight.designator.isEmpty { parts.append(flight.designator) }
        if let times = times(flight) { parts.append(times) }
        if !flight.terminal.isEmpty { parts.append("Terminal \(flight.terminal)") }
        if !flight.seat.isEmpty { parts.append("Seat \(flight.seat)") }
        return parts.joined(separator: " · ")
    }

    /// "18:40–20:25", "18:40", or nil with no departure time.
    private static func times(_ flight: SharedFlight) -> String? {
        guard let departs = flight.departsAt else { return nil }
        guard let arrives = flight.arrivesAt else { return time(departs) }
        return "\(time(departs))–\(time(arrives))"
    }

    /// "Rome · in Sat 6 · out Wed 10".
    public static func bookingDetail(_ booking: SharedBooking) -> String {
        var parts: [String] = []
        if !booking.provider.isEmpty { parts.append(booking.provider) }
        let day = Date.FormatStyle().weekday(.abbreviated).day()
        let words: (String, String) = switch booking.kind {
        case .lodging: ("in", "out")
        case .car: ("pick up", "drop off")
        default: ("from", "until")
        }
        if let starts = booking.startsAt { parts.append("\(words.0) \(starts.formatted(day))") }
        if let ends = booking.endsAt { parts.append("\(words.1) \(ends.formatted(day))") }
        return parts.joined(separator: " · ")
    }

    static func weather(_ day: DayWeather) -> ItineraryDocument.Weather {
        ItineraryDocument.Weather(
            symbolName: day.symbolName,
            summary: day.summary,
            temperatures: "\(WeatherFormat.temperature(day.highCelsius)) / \(WeatherFormat.temperature(day.lowCelsius))"
        )
    }

    /// An idea on the Ideas page: like a day's row, never with a time.
    static func ideaLine(_ item: SharedItineraryItem) -> ItineraryDocument.Line {
        ItineraryDocument.Line(
            time: nil,
            duration: duration(minutes: item.durationMinutes),
            title: item.title,
            detail: [item.address, item.detail].filter { !$0.isEmpty }.joined(separator: " · "),
            symbolName: item.kind.symbolName,
            isFlight: false
        )
    }

    static func line(for entry: DayPlan.Entry, in plan: DayPlan) -> ItineraryDocument.Line {
        let time = plan.start(of: entry).map(time)
        switch entry {
        case .item(let item):
            let detail = [item.address, item.detail].filter { !$0.isEmpty }.joined(separator: " · ")
            return ItineraryDocument.Line(
                time: time,
                duration: duration(minutes: item.durationMinutes),
                title: item.title,
                detail: detail,
                symbolName: item.kind.symbolName,
                isFlight: false
            )
        case .flight(let flight):
            var detail: [String] = []
            if let arrives = flight.arrivesAt { detail.append("arrives \(self.time(arrives))") }
            if !flight.terminal.isEmpty { detail.append("Terminal \(flight.terminal)") }
            if !flight.seat.isEmpty { detail.append("Seat \(flight.seat)") }
            return ItineraryDocument.Line(
                time: time,
                duration: "",
                title: flight.headline,
                detail: detail.joined(separator: " · "),
                symbolName: "airplane",
                isFlight: true
            )
        }
    }
}
