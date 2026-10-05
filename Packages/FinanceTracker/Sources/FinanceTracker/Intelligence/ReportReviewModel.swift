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
///
/// Views get theirs from `shared(for:)`, so every screen showing the same
/// review shows one model. Whether a rebuilt report keeps it is
/// `ReportReviewRenewal`'s call, and a kept one is handed the new report
/// through `update(_:)`.
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

    /// The report the review is of: the latest one `update(_:)` was handed,
    /// once nothing is being written.
    public private(set) var data: FinanceReportData
    public private(set) var brief: ReportBrief
    public private(set) var state: State = .idle
    /// The availability the last `start` saw, setting included — the sheet's
    /// footnote and sparkle go by it.
    public private(set) var availability: FinanceAdvisorAvailability = .turnedOff
    /// The last question's answer, streaming or done.
    public private(set) var answer: AskReply?
    public private(set) var isAnswering = false
    /// When the model's review on screen was written: the cache entry's
    /// `savedAt`, or when it finished here. nil for the plain check and
    /// while writing — "Written today at 9:14" (`ReviewWrittenNote`).
    public private(set) var writtenAt: Date?
    /// Whether the review on screen was written about these figures at
    /// other gold and silver prices (`ReportReviewRenewal.carryOver`), so a
    /// note or two may be in the check's words until it's written again.
    public private(set) var isCarriedOver = false

    /// The check on its own, worked out once per report.
    public private(set) var plainReview: ReportReview
    public private(set) var suggestedQuestions: [String]

    @ObservationIgnored let cache: ReportReviewCache
    /// `brief.fingerprint`, worked out once per report.
    @ObservationIgnored private(set) var fingerprint: String
    /// The model's words behind the review on screen, and the brief they
    /// were written against — kept so a newer report can carry them.
    @ObservationIgnored private var written: Written?
    /// A newer report handed over while the model was writing, applied once
    /// it's done: the review is finished, and kept, against the figures it
    /// was asked about.
    @ObservationIgnored private var pending: Report?
    /// The report built again at other prices, from the screen that built it
    /// (`update(_:repricing:)`); nil until one does.
    @ObservationIgnored private var repricing: Repricing?
    @ObservationIgnored private var reviewTask: Task<Void, Never>?
    @ObservationIgnored private var askTask: Task<Void, Never>?
    // Which run may still write: a cancelled stream can deliver one more
    // snapshot after "Write Again" or a new question has started the next,
    // and must not paint over it.
    @ObservationIgnored private var reviewGeneration = 0
    @ObservationIgnored private var askGeneration = 0

    private struct Written {
        let brief: ReportBrief
        let fingerprint: String
        let draft: ReportReviewDraft
    }

    private struct Report {
        let data: FinanceReportData
        let brief: ReportBrief
        let fingerprint: String

        init(_ data: FinanceReportData, brief: ReportBrief? = nil) {
            self.data = data
            let brief = brief ?? ReportBrief(data: data)
            self.brief = brief
            fingerprint = brief.fingerprint
        }
    }

    /// What the model would be shown of its report with the open month valued
    /// at the given live gold and silver prices — nil: at the month's own
    /// saved ones. How a review written at other prices is told from one
    /// about other figures; screens make it from their `ReportRecipe`.
    public typealias Repricing = @MainActor (MetalPrices?) -> ReportBrief?

    public convenience init(data: FinanceReportData, cache: ReportReviewCache = .shared) {
        self.init(data: data, brief: ReportBrief(data: data), cache: cache)
    }

    init(data: FinanceReportData, brief: ReportBrief, cache: ReportReviewCache) {
        self.data = data
        self.cache = cache
        self.brief = brief
        fingerprint = brief.fingerprint
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

    /// What the review is written from — the report waiting to be applied,
    /// if one is — for `ReportReviewRenewal.decide`.
    public var basis: ReportReviewBasis {
        let report = pending ?? Report(data, brief: brief)
        return ReportReviewBasis(
            scope: report.data.scope,
            ownerLabel: report.brief.ownerLabel,
            fingerprint: report.fingerprint,
            livePrices: report.data.livePrices
        )
    }

    // MARK: - New figures

    /// Hands the model a newer build of its report — one `ReportReviewRenewal`
    /// said the review can stay with: the same facts, or the same figures at
    /// other gold and silver prices. Everything around the review follows it
    /// (Ask's figures, the fixes' months, the findings past the brief's cap),
    /// and the model's words are carried onto it, any that lost a figure
    /// falling back to the check's own. While the model is writing, the new
    /// report waits for it to finish.
    ///
    /// - Parameter repricing: the same report at other prices, so a review
    ///   kept from a launch when gold and silver stood elsewhere can be shown
    ///   rather than written again; nil keeps the one handed over before.
    public func update(_ data: FinanceReportData, repricing: Repricing? = nil) {
        if let repricing { self.repricing = repricing }
        guard data != (pending?.data ?? self.data) else { return }
        let report = Report(data)
        if isWriting {
            pending = report
        } else {
            apply(report)
        }
    }

    private func apply(_ report: Report) {
        pending = nil
        data = report.data
        brief = report.brief
        fingerprint = report.fingerprint
        plainReview = ReportReview.plain(data: report.data)
        suggestedQuestions = AskReply.suggestedQuestions(for: report.data)
        switch state {
        case .idle, .writing: break
        case .plain: state = .plain(plainReview)
        case .ready: showWritten()
        }
    }

    /// `written` against the current report — or the plain check when none
    /// of the model's words hold for it any more.
    private func showWritten() {
        if let written, let writtenAt, show(written, writtenAt: writtenAt) { return }
        showPlain()
    }

    /// Shows the model's words in `candidate`, carried onto the current
    /// report when they were written against another; false, changing
    /// nothing, when none of them hold for it.
    private func show(_ candidate: Written, writtenAt date: Date) -> Bool {
        let draft = candidate.draft.carried(from: candidate.brief, to: brief)
        let review = ReportReview(findings: data.findings, scope: data.scope, brief: brief, draft: draft)
        guard review.isWrittenByModel else { return false }
        written = candidate
        writtenAt = date
        isCarriedOver = candidate.fingerprint != fingerprint
        state = .ready(review)
        return true
    }

    /// The review kept on this device for this report: the one written about
    /// these very facts, else one written while gold and silver stood
    /// elsewhere about what are otherwise the same figures — the report
    /// rebuilt at the prices it was written at tells the model exactly what
    /// it was told then. Prices aren't kept between launches, so the open
    /// month reopened at its saved prices and then at a new fetch's: neither
    /// matched the review written at the last one, and it was written again
    /// every time Finance opened.
    private func keptReview(writer: String?) -> (written: Written, savedAt: Date)? {
        if let entry = cache.entry(for: brief, writer: writer) {
            return (Written(brief: brief, fingerprint: fingerprint, draft: entry.draft(in: brief)), entry.savedAt)
        }
        guard let entry = cache.latestEntry(scope: brief.scope, owner: brief.ownerLabel, writer: writer),
              entry.livePrices != data.livePrices,
              let then = repricing?(entry.livePrices),
              then.fingerprint == entry.fingerprint
        else { return nil }
        return (Written(brief: then, fingerprint: entry.fingerprint, draft: entry.draft(in: then)), entry.savedAt)
    }

    private func showPlain() {
        written = nil
        writtenAt = nil
        isCarriedOver = false
        state = .plain(plainReview)
    }

    // MARK: - The review

    /// Shows the review: the cached one if the brief hasn't changed, else a
    /// fresh one streamed from `advisor`, else the plain check. Does nothing
    /// once started, unless Apple Intelligence was switched on or off, or got
    /// ready, since; call `writeAgain` to start over. Cancelling the calling
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
        switch state {
        case .idle:
            break
        case .writing:
            return
        case .plain, .ready:
            // Shown already — but for the setting as it is now? The Summary
            // made a new model when the switch moved; the report window, whose
            // `.task` reruns on the switch into this, kept the review written
            // before it went off, or the check from before it came on.
            guard advisor.availability(isEnabled: enabled) != availability else { return }
        }
        await run(advisor: advisor, enabled: enabled, useCache: true)
    }

    /// "Write Again": forgets the cached review and asks again.
    public func writeAgain(advisor: any FinanceAdvising, enabled: Bool) async {
        reviewTask?.cancel()
        if let pending { apply(pending) }
        cache.remove(for: brief)
        await run(advisor: advisor, enabled: enabled, useCache: false)
    }

    private func run(advisor: any FinanceAdvising, enabled: Bool, useCache: Bool) async {
        reviewGeneration += 1
        let generation = reviewGeneration
        let availability = advisor.availability(isEnabled: enabled)
        self.availability = availability
        guard availability == .available else {
            showPlain()
            return
        }
        if useCache, let kept = keptReview(writer: advisor.cacheIdentity), show(kept.written, writtenAt: kept.savedAt) {
            return
        }
        // Writing from here, before the task runs, so a second `start` in
        // the meantime sees it isn't idle.
        written = nil
        writtenAt = nil
        isCarriedOver = false
        state = .writing(ReportReview(findings: data.findings, scope: data.scope, brief: brief, draft: ReportReviewDraft(), fillingIn: false))
        let startedAt = Date.now
        let task = Task { [weak self] in
            guard let self else { return }
            await self.stream(from: advisor, generation: generation, startedAt: startedAt)
        }
        reviewTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func stream(from advisor: any FinanceAdvising, generation: Int, startedAt: Date) async {
        // Fixed for the run: `update` holds a newer report back until it ends.
        let findings = data.findings, scope = data.scope, brief = brief, fingerprint = fingerprint, livePrices = data.livePrices
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
            if let pending { apply(pending) }
            return
        }
        let finished = last?.isComplete == true
        var final = last
        final?.isComplete = true
        let review = ReportReview(findings: findings, scope: scope, brief: brief, draft: final)
        if review.isWrittenByModel, let final {
            let savedAt = Date.now
            written = Written(brief: brief, fingerprint: fingerprint, draft: final)
            writtenAt = savedAt
            isCarriedOver = false
            state = .ready(review)
            if finished {
                cache.save(review, for: brief, writer: advisor.cacheIdentity, livePrices: livePrices, startedAt: startedAt, asOf: savedAt)
            }
        } else {
            showPlain()
        }
        if let pending { apply(pending) }
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

// MARK: - One model per review

extension ReportReviewModel {
    /// The model for `data`'s review: the one a view already holds for the
    /// same scope, person and facts, else a new one. The Summary's card, the
    /// report it opens, the review sheet and the finish screen then show one
    /// review, written once: the report opened while the card was still
    /// writing started a second run of its own, and "Write Again" in one left
    /// the others on the old words. The caller hands it `data` with
    /// `update(_:)`.
    public static func shared(for data: FinanceReportData, cache: ReportReviewCache = .shared) -> ReportReviewModel {
        let brief = ReportBrief(data: data)
        let basis = ReportReviewBasis(data: data, brief: brief)
        if let model = LiveReviewModels.all.first(where: { $0.cache == cache && $0.basis.isSameReview(as: basis) }) {
            return model
        }
        let model = ReportReviewModel(data: data, brief: brief, cache: cache)
        LiveReviewModels.add(model)
        return model
    }

    /// Every model from `shared(for:)` a view still holds for `scope`,
    /// whoever's figures it's of.
    static func live(for scope: ReportScope, cache: ReportReviewCache = .shared) -> [ReportReviewModel] {
        LiveReviewModels.all.filter { $0.cache == cache && $0.scope == scope }
    }

    /// Months' "Write Review Again": forgets every person's cached review of
    /// `scope` and has each one on screen written again. Whatever is opened
    /// next — the report, the Summary — finds no review to show and writes
    /// it, or takes up the one being written. The task ends once every one on
    /// screen is written; nothing needs to wait for it.
    @discardableResult
    public static func writeReviewsAgain(
        of scope: ReportScope,
        advisor: any FinanceAdvising,
        enabled: Bool,
        cache: ReportReviewCache = .shared
    ) -> Task<Void, Never> {
        // Before anything opens: a report opened first would read the old
        // review back from the cache.
        cache.removeAll(for: scope)
        let models = live(for: scope, cache: cache)
        return Task {
            await withTaskGroup(of: Void.self) { group in
                for model in models {
                    group.addTask { await model.writeAgain(advisor: advisor, enabled: enabled) }
                }
            }
        }
    }
}

extension ReportReviewBasis {
    /// The same review: scope, person and facts. Prices aside — a model
    /// carried onto a price tick is the review for the newer figures too.
    func isSameReview(as other: ReportReviewBasis) -> Bool {
        scope == other.scope && ownerLabel == other.ownerLabel && fingerprint == other.fingerprint
    }
}

/// The models `ReportReviewModel.shared(for:)` handed out, held weakly: a
/// review stays shared for as long as some view holds it, and goes with the
/// last one.
@MainActor
private enum LiveReviewModels {
    private final class Reference {
        weak var model: ReportReviewModel?

        init(_ model: ReportReviewModel) {
            self.model = model
        }
    }

    private static var references: [Reference] = []

    static var all: [ReportReviewModel] {
        references.removeAll { $0.model == nil }
        return references.compactMap(\.model)
    }

    static func add(_ model: ReportReviewModel) {
        references.removeAll { $0.model == nil }
        references.append(Reference(model))
    }
}
