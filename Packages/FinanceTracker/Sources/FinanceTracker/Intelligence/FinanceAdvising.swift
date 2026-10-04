import Foundation
import SwiftUI

/// Whether the month review and "Ask about a month" can use the on-device
/// model here, and if not, why — which decides what, if anything, the screen
/// says about it. The same cases as Trips' `TripAdvisorAvailability`, kept
/// separate because no feature package imports another.
public enum FinanceAdvisorAvailability: Sendable, Equatable {
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
    /// The person turned "Apple Intelligence in Finance" off in Settings.
    case turnedOff

    public var isAvailable: Bool { self == .available }

    /// The one quiet line a screen shows under the plain check instead of the
    /// model's text, or nil for no line at all. Nothing on hardware or systems
    /// that can never run it, and nothing when the person turned it off.
    public var footnote: String? {
        switch self {
        case .notEnabled: "Turn on Apple Intelligence in Settings to get a written review."
        case .notReady: "Getting ready…"
        case .available, .deviceNotEligible, .unsupportedOS, .unsupportedLanguage, .turnedOff: nil
        }
    }

    /// Which "<Month> in brief" card the Summary shows under the net-worth
    /// card. Decided here so the rule is tested: views are untested by policy.
    public enum ReviewCardStyle: Sendable, Equatable {
        /// "<Month> in brief", with the sparkle, the model's headline, the
        /// counts, Read Review and Open Report.
        case assistant
        /// "<Month> check": the same counts and buttons in the check's words,
        /// no sparkle.
        case plainCheck
        /// No card: the person switched Apple Intelligence in Finance off.
        case hidden
    }

    public var reviewCardStyle: ReviewCardStyle {
        switch self {
        case .available: .assistant
        case .turnedOff: .hidden
        case .notEnabled, .notReady, .deviceNotEligible, .unsupportedOS, .unsupportedLanguage: .plainCheck
        }
    }

    /// Whether Settings shows the "Apple Intelligence in Finance" switch —
    /// read off the advisor's own availability, never the switch's: hidden
    /// only where the system or hardware can never run the model, the same
    /// rule as Trips' switch. An unsupported language keeps it: that can
    /// change in Settings.
    public var showsSetting: Bool {
        switch self {
        case .deviceNotEligible, .unsupportedOS: false
        case .available, .notEnabled, .notReady, .unsupportedLanguage, .turnedOff: true
        }
    }
}

/// One snapshot of a streamed review: the headline and notes so far. Each
/// note points at a `ReportBrief.Fact` by number; `ReportReview` turns them
/// back into findings with Swift's own fixes attached and Swift's own group.
public struct ReportReviewDraft: Sendable, Equatable {
    public struct Note: Sendable, Equatable {
        /// 1-based, `ReportBrief.Fact.number`. May be out of range — the
        /// model's word isn't trusted; `ReportReview` drops it.
        public var fact: Int
        /// The group the brief showed the model for that fact. Informational:
        /// `ReportReview` files each note under its finding's own group, so a
        /// model calling an over-budget category "went well" changes nothing.
        public var group: ReportReview.Group?
        public var message: String

        public init(fact: Int, group: ReportReview.Group? = nil, message: String) {
            self.fact = fact
            self.group = group
            self.message = message
        }
    }

    public var headline: String?
    /// Most important first, as the model ranked them.
    public var notes: [Note]
    /// False on every partial snapshot, true on the last.
    public var isComplete: Bool

    public init(headline: String? = nil, notes: [Note] = [], isComplete: Bool = false) {
        self.headline = headline
        self.notes = notes
        self.isComplete = isComplete
    }
}

public enum FinanceAdvisorError: Error, Equatable, Sendable {
    case unavailable(FinanceAdvisorAvailability)
}

/// Words a month's review and answers questions about it — the only way the
/// Finance module reaches a language model. Nothing in its signature is a
/// FoundationModels type, so views and tests depend on this alone, iOS 18
/// included, and tests run against `StubFinanceAdvisor` with no model.
///
/// Swift decides every fact (`MonthCheck`, `YearCheck`) and every fix; the
/// model only ranks and rewords the numbered facts of a `ReportBrief`. Every
/// failure is the caller's cue to fall back to the check's own words — never
/// an alert, the same rule as Trips and weather.
public protocol FinanceAdvising: Sendable {
    /// Read it in a view's body: the Foundation Models implementation reads
    /// `SystemLanguageModel.default.availability`, which is `Observable`.
    var availability: FinanceAdvisorAvailability { get }

    /// Loads the model ahead of a likely review — when the Summary appears,
    /// and only when the setting is on. Cheap to call again.
    func prewarm()

    /// A streamed review of `brief`: snapshots as the model writes, the last
    /// with `isComplete`. Ends by throwing on any failure.
    func review(_ brief: ReportBrief) -> AsyncThrowingStream<ReportReviewDraft, any Error>

    /// A streamed answer of one to three sentences to `question`, from
    /// `brief`'s figures only: each element is the whole answer so far.
    /// `AskReply` checks it before anything is shown as final.
    func answer(question: String, brief: ReportBrief) -> AsyncThrowingStream<String, any Error>
}

public extension FinanceAdvising {
    /// Who wrote a cached review: the advisor's type, so the stub's reviews
    /// and the model's never stand in for each other (`ReportReviewCache`).
    var cacheIdentity: String { String(describing: type(of: self)) }

    /// What the screen goes by: the advisor's own answer, unless the person
    /// turned the feature off — in which case nothing of it shows and nothing
    /// is sent to the model.
    func availability(isEnabled: Bool) -> FinanceAdvisorAvailability {
        isEnabled ? availability : .turnedOff
    }
}

/// For systems and devices with no model — below iOS 26 / macOS 26, and in
/// tests. Says why, does nothing, and throws if asked.
public struct UnavailableFinanceAdvisor: FinanceAdvising {
    public let availability: FinanceAdvisorAvailability

    public init(availability: FinanceAdvisorAvailability = .unsupportedOS) {
        self.availability = availability
    }

    public func prewarm() {}

    public func review(_ brief: ReportBrief) -> AsyncThrowingStream<ReportReviewDraft, any Error> {
        AsyncThrowingStream { $0.finish(throwing: FinanceAdvisorError.unavailable(availability)) }
    }

    public func answer(question: String, brief: ReportBrief) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { $0.finish(throwing: FinanceAdvisorError.unavailable(availability)) }
    }
}

public enum FinanceAdvisors {
    /// The on-device model where the system has Foundation Models, otherwise
    /// the unavailable one. Both platforms are named: `*` alone would let the
    /// check pass on a macOS 15 Mac, where the framework isn't there.
    public static func makeDefault() -> any FinanceAdvising {
        if #available(iOS 26.0, macOS 26.0, *) {
            return FoundationModelsFinanceAdvisor()
        }
        return UnavailableFinanceAdvisor(availability: .unsupportedOS)
    }
}

/// The person's "Finance reports" settings, synced like the Apple
/// Intelligence switches and set at the app root as
/// `\.financeReportPreferences` — the module never reads the store itself.
public struct FinanceReportPreferences: Sendable, Equatable {
    /// Write the review when a month is finished, so the finish screen can
    /// say "Review is ready".
    public var reviewOnFinish: Bool
    /// Tell this device when a month is finished on another one.
    public var notifyWhenReady: Bool
    /// The "Table view" under each chart in a shared or saved report.
    public var includeTables: Bool
    /// Whose figures a report opens on; nil is Everyone. Matched to an
    /// owner by name, since owner objects don't leave the store.
    public var defaultOwnerName: String?

    public init(
        reviewOnFinish: Bool = true,
        notifyWhenReady: Bool = true,
        includeTables: Bool = true,
        defaultOwnerName: String? = nil
    ) {
        self.reviewOnFinish = reviewOnFinish
        self.notifyWhenReady = notifyWhenReady
        self.includeTables = includeTables
        self.defaultOwnerName = defaultOwnerName
    }

    public static let standard = FinanceReportPreferences()
}

extension EnvironmentValues {
    /// The on-device model by default; the app swaps in `StubFinanceAdvisor`
    /// for `-FinanceAdvisorStub YES` runs, the way `-TripAdvisorStub YES`
    /// swaps Trips'.
    @Entry public var financeAdvisor: any FinanceAdvising = FinanceAdvisors.makeDefault()
    /// The person's "Apple Intelligence in Finance" setting, set at the app
    /// root from the synced preference. Off means no model UI anywhere, no
    /// prewarm and nothing sent to the model; the plain month check stays.
    @Entry public var financeAdvisorEnabled: Bool = true
    /// The "Finance reports" section of Settings, set at the app root.
    @Entry public var financeReportPreferences: FinanceReportPreferences = .standard
}
