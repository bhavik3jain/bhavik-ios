#if DEBUG
import Core
import Foundation

/// A made-up advisor that answers the same way every time — for tests, and
/// for `-FinanceAdvisorStub YES` runs: quick, the same on every run, and
/// working on a simulator or Mac with no Apple Intelligence, the way Trips'
/// `StubTripAdvisor` does.
///
/// Every note it writes is "Stub: " and the fact's own sentence, so each one
/// passes `ReportReview.isFaithful` and a screenshot shows the model's path,
/// not the plain fallback.
public struct StubFinanceAdvisor: FinanceAdvising {
    public var availability: FinanceAdvisorAvailability
    /// Thrown from `review` and `answer` instead of answering, to test the
    /// fallbacks.
    public var failure: FinanceAdvisorError?
    /// Between streamed snapshots, so a simulator shows the review arriving.
    public var delay: Duration

    /// `-FinanceAdvisorStub YES`: the app root injects this advisor.
    public static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "FinanceAdvisorStub")
    }

    public init(availability: FinanceAdvisorAvailability = .available, failure: FinanceAdvisorError? = nil, delay: Duration = .zero) {
        self.availability = availability
        self.failure = failure
        self.delay = delay
    }

    public func prewarm() {}

    /// The headline facts as the headline, then a note per other fact in
    /// reverse order — so a test can tell the model's ranking from the
    /// brief's — streamed a word at a time for the headline.
    public func review(_ brief: ReportBrief) -> AsyncThrowingStream<ReportReviewDraft, any Error> {
        let failure = failure, delay = delay
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let failure {
                    continuation.finish(throwing: failure)
                    return
                }
                let headlineFacts = brief.facts.filter(\.isHeadline).map(\.text)
                let headline = headlineFacts.isEmpty
                    ? "Stub review: \(counted(brief.facts.count, "thing")) to look at."
                    : "Stub: " + headlineFacts.joined(separator: " ")
                var draft = ReportReviewDraft()
                var words: [Substring] = []
                for word in headline.split(separator: " ") {
                    words.append(word)
                    draft.headline = words.joined(separator: " ")
                    continuation.yield(draft)
                    if delay > .zero { try? await Task.sleep(for: delay / 4) }
                }
                for fact in brief.facts.reversed() where !fact.isHeadline {
                    if delay > .zero { try? await Task.sleep(for: delay) }
                    draft.notes.append(.init(fact: fact.number, group: fact.group, message: "Stub: \(fact.text)"))
                    continuation.yield(draft)
                }
                draft.isComplete = true
                continuation.yield(draft)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The fact nearest the question, "Stub: " first, a word at a time.
    public func answer(question: String, brief: ReportBrief) -> AsyncThrowingStream<String, any Error> {
        let failure = failure, delay = delay
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let failure {
                    continuation.finish(throwing: failure)
                    return
                }
                let fact = AskReply.closestFacts(to: question, in: brief, limit: 1).first
                let answer = fact.map { "Stub: \($0.text)" } ?? "Stub: the report doesn't show that."
                var words: [Substring] = []
                for word in answer.split(separator: " ") {
                    words.append(word)
                    continuation.yield(words.joined(separator: " "))
                    if delay > .zero { try? await Task.sleep(for: delay / 4) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
