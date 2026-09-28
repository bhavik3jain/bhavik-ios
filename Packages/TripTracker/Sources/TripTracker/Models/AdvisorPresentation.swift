import Core
import Foundation

// What the Review Plan and Suggest Places screens show about the on-device
// model, decided here rather than in the views so the rules are tested: views
// are untested by policy, and "the switch is off, so nothing of the model
// shows" is exactly the kind of rule that quietly breaks in a view.

public extension TripAdvisorAvailability {
    /// Whether the model's parts of the screen appear at all: "Suggest
    /// Places", and the verdict or its quiet footnote on Review Plan. Yes
    /// where the model runs or soon could — Apple Intelligence off in
    /// Settings, or still downloading — and no where it never will (older
    /// system, ineligible hardware, a language it doesn't speak) or where the
    /// person turned "Apple Intelligence in Trips" off. There the plain plan
    /// check is all there is, with no nagging.
    var offersAssistant: Bool {
        switch self {
        case .available, .notEnabled, .notReady: true
        case .deviceNotEligible, .unsupportedOS, .unsupportedLanguage, .turnedOff: false
        }
    }

    /// Whether Settings shows the "Apple Intelligence in Trips" switch — read
    /// off the advisor's own availability, never the switch's: hidden only
    /// where the system or the hardware can never run the model, since a
    /// switch that can't do anything there is just a nag. An unsupported
    /// language keeps it: that can change in Settings.
    var showsSetting: Bool {
        switch self {
        case .deviceNotEligible, .unsupportedOS: false
        case .available, .notEnabled, .notReady, .unsupportedLanguage, .turnedOff: true
        }
    }
}

/// The line at the top of Review Plan: the model's streamed verdict, a
/// placeholder while it reads the plan, a quiet footnote when it can't run
/// yet, or nothing. Any failure is nothing — the plan check below is complete
/// on its own, the same rule as weather: never an alert.
public enum ReviewHeadline: Equatable, Sendable {
    case none
    /// "Turn on Apple Intelligence…", "Getting ready…".
    case footnote(String)
    /// Asked, nothing written yet.
    case writing
    case verdict(String, isFinal: Bool)

    public enum Phase: Equatable, Sendable {
        /// Not asked yet — or not going to be.
        case waiting
        case streaming
        case finished
        case failed
    }

    public init(availability: TripAdvisorAvailability, phase: Phase, verdict: String?) {
        guard availability == .available else {
            self = availability.footnote.map(ReviewHeadline.footnote) ?? .none
            return
        }
        let verdict = verdict?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch phase {
        case .failed:
            self = .none
        case .finished:
            self = verdict.isEmpty ? .none : .verdict(verdict, isFinal: true)
        case .waiting, .streaming:
            self = verdict.isEmpty ? .writing : .verdict(verdict, isFinal: false)
        }
    }
}

/// Where "Suggest Places" looks: around the trip's destination, or around one
/// day's planned stops.
public enum SuggestionScope: Hashable, Sendable, Identifiable {
    case trip
    case day(Int)

    public var id: Int {
        switch self {
        case .trip: -1
        case .day(let day): day
        }
    }

    /// For `SuggestionRequest(trip:day:)`.
    public var dayIndex: Int? {
        switch self {
        case .trip: nil
        case .day(let day): day
        }
    }

    /// The whole trip, then every day with a placed stop to search around —
    /// and `keeping` (the scope a screen opened on) even if its day has since
    /// lost its places, so a picker never shows a blank row.
    public static func choices(for trip: SharedTrip, keeping current: SuggestionScope? = nil) -> [SuggestionScope] {
        var days = NearbyIdeas.daysWithStops(in: trip)
        if case .day(let day)? = current, !days.contains(day) {
            days.append(day)
            days.sort()
        }
        return [.trip] + days.map(SuggestionScope.day)
    }

    /// "Around Rome, Italy", "Near Day 2 · Sat 10 Oct".
    public func title(for trip: SharedTrip) -> String {
        switch self {
        case .trip:
            let place = trip.destination.isEmpty ? trip.title : trip.destination
            return place.isEmpty ? "Around the trip" : "Around \(place)"
        case .day(let day):
            return "Near Day \(day + 1) · \(IdeaDays.dayLabel(day, dates: trip.dates))"
        }
    }
}

/// The small print under the suggestions: where the places came from and who
/// chose them. The model's "why" is its opinion — the research spike's
/// invented "free visit" and a "less-touristy vibe" nothing supported — so
/// the note says so, and never promises hours or prices.
public enum SuggestionsNote {
    public static func footer(usedModel: Bool, availability: TripAdvisorAvailability) -> String {
        if usedModel {
            return "Places from Apple Maps, picked on this device by Apple Intelligence. Its reasons are suggestions — check opening hours before you go."
        }
        switch availability {
        case .notEnabled:
            return "The nearest places from Apple Maps. Turn on Apple Intelligence in Settings to have them picked for the day."
        case .notReady:
            return "The nearest places from Apple Maps. Apple Intelligence is still getting ready to pick them for the day."
        case .available, .deviceNotEligible, .unsupportedOS, .unsupportedLanguage, .turnedOff:
            return "The nearest places from Apple Maps."
        }
    }

    /// While the searches run — and the model reads, when it will.
    public static func progress(availability: TripAdvisorAvailability) -> String {
        availability == .available ? "Finding places and picking the best…" : "Finding places…"
    }

    /// "Museum · 650 m".
    public static func detail(for suggestion: PlaceSuggestion, locale: Locale = .current) -> String {
        [suggestion.place.category, suggestion.metres.map { WalkingEstimate(metres: $0).distanceText(locale: locale) }]
            .compactMap(\.self)
            .joined(separator: " · ")
    }
}

public extension PlanReview {
    /// The entries a day at a time, days in order — the model's ranking kept
    /// within each day. A flat list in the model's order reshuffled itself
    /// under the reader's thumb on every streamed snapshot.
    var days: [(dayIndex: Int, entries: [Entry])] {
        let grouped = Dictionary(grouping: entries, by: \.finding.dayIndex)
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }
}
