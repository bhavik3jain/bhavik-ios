import Foundation
import Observation

/// What the review sheet, the Summary card, the finish screen and the Mac
/// inspector watch: one report's review — plain, streaming, or finished and
/// checked — and the "Ask about <month>" answer. Views hold one per report
/// and call `start` from a `.task`; everything they show is a value this
/// builds, so the rules stay out of the (untested) views.
///
/// The model's words go through `ReportReview` on every snapshot, so a note
/// that loses a figure is never on screen as final; a finished review is kept
/// in `ReportReviewCache` on this device only.
@MainActor
@Observable
public final class ReportReviewModel {
    public enum State: Equatable, Sendable {
        /// Not started — or a start was cancelled, so the next one runs again.
        case idle
        /// The model is writing: the headline so far and the notes it has
        /// finished, with no plain filling.
        case writing(ReportReview)
        /// The model's review, checked; findings it skipped are in the
        /// check's words.
        case ready(ReportReview)
        /// The check alone: the model is off, can't run, failed, or wrote
        /// nothing faithful.
        case plain(ReportReview)
    }

    public let data: FinanceReportData
    public let brief: ReportBrief
    public private(set) var state: State = .idle
    /// The availability the last `start` saw, setting included — the sheet's
    /// footnote and sparkle go by it.
    public private(set) var availability: FinanceAdvisorAvailability = .turnedOff
    /// The last question's answer, streaming or done.
    public private(set) var answer: AskReply?
    public private(set) var isAnswering = false

    /// The check on its own, worked out once.
    public let plainReview: ReportReview
    public let suggestedQuestions: [String]

    @ObservationIgnored private let cache: ReportReviewCache
    @ObservationIgnored private var reviewTask: Task<Void, Never>?
    @ObservationIgnored private var askTask: Task<Void, Never>?
    // Which run may still write: a cancelled stream can deliver one more
    // snapshot after "Write Again" or a new question has started the next,
    // and must not paint over it.
    @ObservationIgnored private var reviewGeneration = 0
    @ObservationIgnored private var askGeneration = 0

    public init(data: FinanceReportData, cache: ReportReviewCache = .shared) {
        self.data = data
        self.cache = cache
        brief = ReportBrief(data: data)
        plainReview = ReportReview.plain(data: data)
        suggestedQuestions = AskReply.suggestedQuestions(for: data)
    }

    public var scope: ReportScope { data.scope }

    /// Whatever is best to show now: the streaming or finished review, or the
    /// plain one before anything starts.
    public var review: ReportReview {
        switch state {
        case .idle: plainReview
        case .writing(let review), .ready(let review), .plain(let review): review
        }
    }

    public var isWriting: Bool {
        if case .writing = state { return true }
        return false
    }

    /// The model's review is done and checked — the finish screen's "Review
    /// is ready" row.
    public var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    /// The Summary card's chips: the plain review's counts, which every state
    /// shares — the model rewords findings, it never adds or drops one.
    public var counts: FinanceReportData.ToneCounts { plainReview.counts }

    /// "Writing from 14 figures…".
    public var factCount: Int { brief.facts.count }

    // MARK: - The review

    /// Shows the review: the cached one if the brief hasn't changed, else a
    /// fresh one streamed from `advisor`, else the plain check. Does nothing
    /// once started; call `writeAgain` to start over. Cancelling the calling
    /// task (a view's `.task` ending) stops the model.
    public func start(advisor: any FinanceAdvising, enabled: Bool) async {
        // A run already writing belongs to whoever started it. Wait for it
        // rather than return: when a view's `.task` id changed mid-review,
        // SwiftUI cancelled the old task and started the new one before the
        // old stream had wound down, so this saw `.writing`, returned, and the
        // cancelled run then set `.idle` with nobody left to start it — the
        // Summary card and the report sat on the plain check for good, the
        // review stopped at its first word. Once the run ends, a finished one
        // stands and a cancelled one is started again here.
        while case .writing = state, let inFlight = reviewTask {
            await inFlight.value
            if Task.isCancelled { return }
        }
        guard case .idle = state else { return }
        await run(advisor: advisor, enabled: enabled, useCache: true)
    }

    /// The sheet's "Write Again": forgets the cached review and asks again.
    public func writeAgain(advisor: any FinanceAdvising, enabled: Bool) async {
        reviewTask?.cancel()
        cache.remove(for: brief)
        await run(advisor: advisor, enabled: enabled, useCache: false)
    }

    private func run(advisor: any FinanceAdvising, enabled: Bool, useCache: Bool) async {
        reviewGeneration += 1
        let generation = reviewGeneration
        let availability = advisor.availability(isEnabled: enabled)
        self.availability = availability
        guard availability == .available else {
            state = .plain(plainReview)
            return
        }
        if useCache, let cached = cache.review(for: brief, findings: data.findings, writer: advisor.cacheIdentity) {
            state = .ready(cached)
            return
        }
        // Writing from here, before the task runs, so a second `start` in
        // the meantime sees it isn't idle.
        state = .writing(ReportReview(findings: data.findings, scope: data.scope, brief: brief, draft: ReportReviewDraft(), fillingIn: false))
        let task = Task { [weak self] in
            guard let self else { return }
            await self.stream(from: advisor, generation: generation)
        }
        reviewTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func stream(from advisor: any FinanceAdvising, generation: Int) async {
        let findings = data.findings, scope = data.scope, brief = brief
        var last: ReportReviewDraft?
        do {
            for try await draft in advisor.review(brief) {
                if Task.isCancelled || generation != reviewGeneration { break }
                last = draft
                state = .writing(ReportReview(findings: findings, scope: scope, brief: brief, draft: draft, fillingIn: false))
            }
        } catch {
            // Any failure is the plain check's cue — never an alert. What the
            // model finished before failing still counts, checked as final.
        }
        guard generation == reviewGeneration else { return }
        if Task.isCancelled {
            if case .writing = state { state = .idle }
            return
        }
        let finished = last?.isComplete == true
        var final = last
        final?.isComplete = true
        let review = ReportReview(findings: findings, scope: scope, brief: brief, draft: final)
        if review.isWrittenByModel {
            state = .ready(review)
            if finished { cache.save(review, for: brief, writer: advisor.cacheIdentity) }
        } else {
            state = .plain(plainReview)
        }
    }

    // MARK: - Ask

    /// Asks the model about this report; the answer streams into `answer`,
    /// checked as it comes — the moment it quotes a number the brief doesn't
    /// have, it's replaced by the fallback. With the model unavailable the
    /// fallback answers at once.
    public func ask(_ question: String, advisor: any FinanceAdvising, enabled: Bool) async {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        askTask?.cancel()
        askGeneration += 1
        let generation = askGeneration
        guard advisor.availability(isEnabled: enabled) == .available else {
            answer = AskReply.fallback(question: question, brief: brief)
            isAnswering = false
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.streamAnswer(question, from: advisor, generation: generation)
        }
        askTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func streamAnswer(_ question: String, from advisor: any FinanceAdvising, generation: Int) async {
        let brief = brief
        answer = AskReply(question: question, text: "", isWrittenByModel: true, isComplete: false)
        isAnswering = true
        var last = ""
        var failed = false
        do {
            for try await text in advisor.answer(question: question, brief: brief) {
                guard !Task.isCancelled, generation == askGeneration else { return }
                last = text
                let reply = AskReply(question: question, answer: text, brief: brief, isComplete: false)
                guard reply.isWrittenByModel else {
                    failed = true
                    break
                }
                answer = reply
            }
        } catch {
            failed = true
        }
        guard generation == askGeneration else { return }
        if Task.isCancelled {
            isAnswering = false
            return
        }
        answer = failed ? AskReply.fallback(question: question, brief: brief) : AskReply(question: question, answer: last, brief: brief, isComplete: true)
        isAnswering = false
    }

    /// Clears the answer — a new question chip, or the field emptied.
    public func clearAnswer() {
        askTask?.cancel()
        askGeneration += 1
        answer = nil
        isAnswering = false
    }
}
