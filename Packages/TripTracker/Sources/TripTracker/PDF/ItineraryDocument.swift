import Core
import Foundation

/// A trip's shareable itinerary, as plain strings laid out into pages.
///
/// The renderer draws exactly what is here and reads nothing from the models,
/// which is what makes two guarantees testable without rendering a PDF: how
/// pages break, and that `Booking.secureNote` is never among the strings — it
/// is simply not read when this is built.
///
/// Pagination is by entry count, not measured height. That is the honest
/// limitation: an entry with a long note can still crowd its page. Measuring
/// would mean laying the views out twice, and a travel itinerary's entries are
/// short.
public struct ItineraryDocument: Sendable, Equatable {
    public struct Cover: Sendable, Equatable {
        public let title: String
        public let destination: String
        public let dateRange: String
        /// "9 days · 22 places · 2 flights".
        public let facts: String
    }

    public struct Line: Sendable, Equatable {
        /// "09:30", or "—" for anytime.
        public let time: String
        /// "1h 30m", or "".
        public let duration: String
        public let title: String
        public let detail: String
        public let symbolName: String
    }

    public struct DayPage: Sendable, Equatable {
        public let dayNumber: Int
        /// "Day 3 · Mon 8 June".
        public let heading: String
        public let lines: [Line]
        /// 1-based among this day's pages; `partCount` > 1 marks continuations.
        public let part: Int
        public let partCount: Int
    }

    public struct Confirmation: Sendable, Equatable {
        public let section: String
        public let title: String
        public let detail: String
        public let code: String
    }

    public enum Page: Sendable, Equatable {
        case cover(Cover)
        case day(DayPage)
        case confirmations([Confirmation], part: Int, partCount: Int)
    }

    public let title: String
    public let pages: [Page]

    public static let linesPerPage = 12
    public static let confirmationsPerPage = 16

    /// Splits `count` things into runs of at most `size`, keeping at least one
    /// (possibly empty) run — a day with nothing planned still gets its page.
    public static func chunks(_ count: Int, size: Int) -> [Range<Int>] {
        guard count > 0, size > 0 else { return [0..<0] }
        return stride(from: 0, to: count, by: size).map { $0..<min($0 + size, count) }
    }

    public init(title: String, pages: [Page]) {
        self.title = title
        self.pages = pages
    }

    /// Builds the document for `trip`: a cover, a page per day (more when a day
    /// runs long) and the confirmation codes.
    public init(trip: Trip, linesPerPage: Int = ItineraryDocument.linesPerPage, calendar: Calendar = .current) {
        let dates = TripDates(start: trip.startDate, end: trip.endDate, calendar: calendar)
        let flights = trip.flights ?? []
        var pages: [Page] = []

        let facts = [
            counted(dates.dayCount, "day"),
            counted(trip.places.count, "place"),
            flights.isEmpty ? nil : counted(flights.count, "flight"),
        ].compactMap(\.self).joined(separator: " · ")
        pages.append(.cover(Cover(
            title: trip.title,
            destination: trip.destination,
            dateRange: ItineraryFormat.dateRange(dates),
            facts: facts
        )))

        for index in 0..<dates.dayCount {
            let plan = DayPlan(dayIndex: index, items: trip.items ?? [], flights: flights, dates: dates)
            let lines = plan.entries.map { ItineraryFormat.line(for: $0, in: plan) }
            let runs = Self.chunks(lines.count, size: linesPerPage)
            for (offset, run) in runs.enumerated() {
                pages.append(.day(DayPage(
                    dayNumber: index + 1,
                    heading: "Day \(index + 1) · \(dates.date(forDay: index).formatted(.dateTime.weekday(.abbreviated).day().month(.wide)))",
                    lines: Array(lines[run]),
                    part: offset + 1,
                    partCount: runs.count
                )))
            }
        }

        let confirmations = Self.confirmations(for: trip, dates: dates)
        if !confirmations.isEmpty {
            let runs = Self.chunks(confirmations.count, size: Self.confirmationsPerPage)
            for (offset, run) in runs.enumerated() {
                pages.append(.confirmations(Array(confirmations[run]), part: offset + 1, partCount: runs.count))
            }
        }

        self.init(title: trip.title, pages: pages)
    }

    /// Flights, then bookings by kind. Reads `code` and never `secureNote`.
    static func confirmations(for trip: Trip, dates: TripDates) -> [Confirmation] {
        let flights = (trip.flights ?? [])
            .sorted { ($0.departsAt ?? dates.date(forDay: $0.dayIndex)) < ($1.departsAt ?? dates.date(forDay: $1.dayIndex)) }
            .map { flight in
                Confirmation(
                    section: "Flights",
                    title: flight.headline,
                    detail: ItineraryFormat.flightWhen(flight, dates: dates),
                    code: flight.confirmationCode
                )
            }
        let bookings = BookingGroups.ordered(trip.bookings ?? []).flatMap { group in
            group.bookings.map { booking in
                Confirmation(
                    section: group.kind.displayName,
                    title: booking.title,
                    detail: ItineraryFormat.bookingDetail(booking),
                    code: booking.code
                )
            }
        }
        return flights + bookings
    }
}

/// Bookings grouped by kind in a fixed order, then by date and `sortOrder` — the
/// Codes screen and the PDF both list them this way.
public enum BookingGroups {
    public struct Group {
        public let kind: BookingKind
        public let bookings: [Booking]
    }

    public static func ordered(_ bookings: [Booking]) -> [Group] {
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
    public static func flightWhen(_ flight: Flight, dates: TripDates) -> String {
        var parts: [String] = []
        let day = flight.departsAt ?? dates.date(forDay: flight.dayIndex)
        parts.append(day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
        if let departs = flight.departsAt {
            if let arrives = flight.arrivesAt {
                parts.append("\(time(departs))–\(time(arrives))")
            } else {
                parts.append(time(departs))
            }
        }
        if !flight.seat.isEmpty { parts.append("Seat \(flight.seat)") }
        return parts.joined(separator: " · ")
    }

    /// "Rome · in Sat 6 · out Wed 10".
    public static func bookingDetail(_ booking: Booking) -> String {
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

    static func line(for entry: DayPlan.Entry, in plan: DayPlan) -> ItineraryDocument.Line {
        let time = plan.start(of: entry).map(time) ?? "—"
        switch entry {
        case .item(let item):
            let detail = [item.address, item.detail].filter { !$0.isEmpty }.joined(separator: " · ")
            return ItineraryDocument.Line(
                time: time,
                duration: duration(minutes: item.durationMinutes),
                title: item.title,
                detail: detail,
                symbolName: item.kind.symbolName
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
                symbolName: "airplane"
            )
        }
    }
}
