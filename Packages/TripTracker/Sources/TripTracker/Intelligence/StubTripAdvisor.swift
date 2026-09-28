#if DEBUG
import Core
import Foundation

/// A made-up advisor that answers the same way every time — for tests, and
/// for `-TripAdvisorStub YES` runs: quick, the same on every run, and working
/// on a simulator or Mac with no Apple Intelligence. (The research spike saw
/// generation fail in guardrails from a command-line tool on a simulator; the
/// app itself, via `-TripAdvisorProbe`, got real answers on the iOS 27 iPhone
/// 18 Pro simulator.)
public struct StubTripAdvisor: TripAdvising {
    public var availability: TripAdvisorAvailability
    /// Thrown from `review` and `pickPlaces` instead of answering, to test the
    /// fallbacks.
    public var failure: TripAdvisorError?
    /// Between streamed snapshots, so a simulator shows the review arriving.
    public var delay: Duration

    public init(availability: TripAdvisorAvailability = .available, failure: TripAdvisorError? = nil, delay: Duration = .zero) {
        self.availability = availability
        self.failure = failure
        self.delay = delay
    }

    public func prewarm() {}

    /// A verdict, then a note per fact in reverse order — so a test can tell
    /// the model's ranking from `PlanCheck`'s — each "Stub: " and the fact.
    public func review(_ brief: TripBrief) -> AsyncThrowingStream<TripReviewDraft, any Error> {
        let failure = failure, delay = delay
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let failure {
                    continuation.finish(throwing: failure)
                    return
                }
                let verdict = brief.facts.isEmpty
                    ? "Stub review: the plan looks workable."
                    : "Stub review: \(counted(brief.facts.count, "thing")) to look at."
                var draft = TripReviewDraft(verdict: verdict)
                continuation.yield(draft)
                for fact in brief.facts.reversed() {
                    if delay > .zero { try? await Task.sleep(for: delay) }
                    draft.notes.append(.init(fact: fact.number, message: "Stub: \(fact.text)"))
                    continuation.yield(draft)
                }
                draft.isComplete = true
                continuation.yield(draft)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The first three candidates.
    public func pickPlaces(candidates: SuggestionCandidates, context: String) async throws -> [PlacePick] {
        if let failure { throw failure }
        if delay > .zero { try? await Task.sleep(for: delay) }
        return candidates.candidates.prefix(PlaceSuggester.suggestionCount).map { PlacePick(number: $0.number, why: "Stub pick: \($0.place.name) fits the day.") }
    }
}

/// Made-up places around wherever it's asked, the same every time: for each
/// query, `perQuery` places a few hundred metres apart, named after it —
/// "Museum 1", "Museum 2". Or exactly `results` for a query, when given.
public struct StubPlaceSearcher: PlaceSearching {
    public var results: [String: [FoundPlace]]?
    public var perQuery: Int
    /// Called with each query as it runs, so a test can count the searches.
    public var onSearch: (@Sendable (String) -> Void)?

    public init(results: [String: [FoundPlace]]? = nil, perQuery: Int = 4, onSearch: (@Sendable (String) -> Void)? = nil) {
        self.results = results
        self.perQuery = perQuery
        self.onSearch = onSearch
    }

    public func search(_ query: String, near center: GeoCoordinate, radiusMetres: Double) async throws -> [FoundPlace] {
        onSearch?(query)
        if let results { return results[query] ?? [] }
        let name = query.prefix(1).uppercased() + query.dropFirst()
        // Each query fans out from its own bearing, so two queries' places
        // never land within `SuggestionCandidates.duplicateMetres` of each
        // other; each place is about 600 m further out than the last.
        let bearing = Double(query.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 360) * .pi / 180
        return (0..<perQuery).map { index in
            let step = Double(index + 1) * 0.006
            let angle = bearing + Double(index) * 1.3
            return FoundPlace(
                name: "\(name) \(index + 1)",
                category: FoundPlace.kind(forCategory: name) == .other ? nil : name,
                latitude: center.latitude + step * sin(angle),
                longitude: center.longitude + step * cos(angle),
                address: "\(index + 1) Stub Street"
            )
        }
    }
}
#endif
