import Foundation
import SwiftUI

/// Whether the plan reviewer and place picker can run here, and if not, why —
/// which decides what, if anything, the screen says about it.
public enum TripAdvisorAvailability: Sendable, Equatable {
    case available
    /// The device could, but Apple Intelligence is off in Settings.
    case notEnabled
    /// No Apple Intelligence on this hardware.
    case deviceNotEligible
    /// Switched on, still downloading or preparing the model.
    case notReady
    /// Below iOS 26 / macOS 26: no Foundation Models at all.
    case unsupportedOS
    /// The model doesn't speak the device's language; asking it anything throws.
    case unsupportedLanguage
    /// The person turned "Apple Intelligence in Trips" off in Settings.
    case turnedOff

    public var isAvailable: Bool { self == .available }

    /// The one quiet line a screen shows instead of the model's text, or nil
    /// for no line at all. Nothing on hardware or systems that can never run
    /// it — no nagging about a phone someone already owns — and nothing when
    /// the person turned it off themselves.
    public var footnote: String? {
        switch self {
        case .notEnabled: "Turn on Apple Intelligence in Settings to get a written review."
        case .notReady: "Getting ready…"
        case .available, .deviceNotEligible, .unsupportedOS, .unsupportedLanguage, .turnedOff: nil
        }
    }
}

/// One snapshot of a streamed review: the verdict and notes so far. Each note
/// points at a `TripBrief.Fact` by number; `PlanReview` turns them back into
/// findings with Swift's own fixes attached.
public struct TripReviewDraft: Sendable, Equatable {
    public struct Note: Sendable, Equatable {
        /// 1-based, `TripBrief.Fact.number`.
        public var fact: Int
        public var message: String

        public init(fact: Int, message: String) {
            self.fact = fact
            self.message = message
        }
    }

    public var verdict: String?
    /// Most important first, as the model ranked them.
    public var notes: [Note]
    /// False on every partial snapshot, true on the last.
    public var isComplete: Bool

    public init(verdict: String? = nil, notes: [Note] = [], isComplete: Bool = false) {
        self.verdict = verdict
        self.notes = notes
        self.isComplete = isComplete
    }
}

/// The model's choice from a numbered `SuggestionCandidates` list, and why.
public struct PlacePick: Sendable, Equatable {
    /// 1-based, `SuggestionCandidates.Candidate.number`. May be out of range —
    /// the model's word isn't trusted; `SuggestionCandidates.resolve` drops it.
    public var number: Int
    public var why: String

    public init(number: Int, why: String) {
        self.number = number
        self.why = why
    }
}

public enum TripAdvisorError: Error, Equatable, Sendable {
    case unavailable(TripAdvisorAvailability)
}

/// Reviews a plan and picks places — the only way the Trips module reaches a
/// language model. Nothing in its signature is a FoundationModels type, so
/// views and tests depend on this alone, iOS 18 included, and tests run
/// against `StubTripAdvisor` with no model at all.
///
/// Every failure is the caller's cue to fall back to `PlanCheck`'s own text or
/// the nearest candidates — never an alert, the same rule as weather.
public protocol TripAdvising: Sendable {
    /// Read it in a view's body: the Foundation Models implementation reads
    /// `SystemLanguageModel.default.availability`, which is `Observable`, so the
    /// view updates when the model finishes downloading or is switched on.
    var availability: TripAdvisorAvailability { get }

    /// Loads the model ahead of a likely review — call when the Plan tab
    /// opens, and only when the setting is on. Cheap to call again.
    func prewarm()

    /// A streamed review of `brief`: snapshots as the model writes, the last
    /// with `isComplete`. Ends by throwing on any failure.
    func review(_ brief: TripBrief) -> AsyncThrowingStream<TripReviewDraft, any Error>

    /// Up to five of `candidates`, by number, with a one-line why each — for
    /// one list (`SuggestionGroup`), which `context` ends by naming.
    /// `context` is `SuggestionRequest.context`: the destination, the day, its
    /// weather and what's already on it.
    func pickPlaces(candidates: SuggestionCandidates, context: String) async throws -> [PlacePick]
}

public extension TripAdvising {
    /// What the screen goes by: the advisor's own answer, unless the person
    /// turned the feature off — in which case nothing of it shows and nothing
    /// is sent to the model.
    func availability(isEnabled: Bool) -> TripAdvisorAvailability {
        isEnabled ? availability : .turnedOff
    }
}

/// For systems and devices with no model — below iOS 26 / macOS 26, and in
/// tests. Says why, does nothing, and throws if asked.
public struct UnavailableTripAdvisor: TripAdvising {
    public let availability: TripAdvisorAvailability

    public init(availability: TripAdvisorAvailability = .unsupportedOS) {
        self.availability = availability
    }

    public func prewarm() {}

    public func review(_ brief: TripBrief) -> AsyncThrowingStream<TripReviewDraft, any Error> {
        AsyncThrowingStream { $0.finish(throwing: TripAdvisorError.unavailable(availability)) }
    }

    public func pickPlaces(candidates: SuggestionCandidates, context: String) async throws -> [PlacePick] {
        throw TripAdvisorError.unavailable(availability)
    }
}

public enum TripAdvisors {
    /// The on-device model where the system has Foundation Models, otherwise
    /// the unavailable one. Both platforms are named: `*` alone would let the
    /// check pass on a macOS 15 Mac, where the framework isn't there.
    public static func makeDefault() -> any TripAdvising {
        if #available(iOS 26.0, macOS 26.0, *) {
            return FoundationModelsTripAdvisor()
        }
        return UnavailableTripAdvisor(availability: .unsupportedOS)
    }

    /// Whether this system could ever run the model — for Settings, which
    /// hides the "Apple Intelligence in Trips" switch where it never could.
    public static var isSupportedBySystem: Bool {
        if #available(iOS 26.0, macOS 26.0, *) { return true }
        return false
    }
}

extension EnvironmentValues {
    /// The on-device model by default; the app swaps in `StubTripAdvisor` for
    /// `-TripAdvisorStub YES` runs, the way `-WeatherStub YES` swaps weather.
    @Entry public var tripAdvisor: any TripAdvising = TripAdvisors.makeDefault()
    /// Apple Maps by default; `-TripAdvisorStub YES` swaps in `StubPlaceSearcher`.
    @Entry public var placeSearcher: any PlaceSearching = MapKitPlaceSearcher()
    /// The person's "Apple Intelligence in Trips" setting, set at the app root
    /// from the synced preference — the module never reads the store itself.
    /// Off means no model UI anywhere, no prewarm and nothing sent to the
    /// model; the plain `PlanCheck` stays.
    @Entry public var tripAdvisorEnabled: Bool = true
}
