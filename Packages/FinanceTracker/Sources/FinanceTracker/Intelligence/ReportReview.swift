import Core
import Foundation

/// What the review sheet, the Summary card, the report's "in brief" section
/// and the Mac inspector show: a headline, then every finding of the check
/// under Went well, To watch and Try in <next month> — each worded by the
/// model when it said something faithful about it and by the check
/// otherwise, in the model's order and then the check's.
///
/// Built the same way whether there is a model or not — with no draft it is
/// simply the plain check (`plain(findings:scope:)`) — and rebuilt on every
/// streamed snapshot, the way Trips' `PlanReview` is.
public struct ReportReview: Sendable, Equatable {
    public enum Group: String, Sendable, CaseIterable, Codable {
        case wentWell
        case watch
        case tryNext

        /// Where a finding is listed: its tone's group. The net worth's move
        /// and the budgets' total (`.info` headline kinds) are the headline,
        /// not a line; any other `.info` finding — a typed metal value — is
        /// something to try when it has a fix, else something to watch.
        public init?(finding: ReportFinding) {
            switch finding.tone {
            case .wentWell: self = .wentWell
            case .watch: self = .watch
            case .tryNext: self = .tryNext
            case .info:
                if ReportBrief.headlineKinds.contains(finding.kind) { return nil }
                self = finding.fix != nil || finding.isWorthFixing ? .tryNext : .watch
            }
        }

        /// "Went well", "To watch", "Try in October".
        public func title(nextName: String) -> String {
            switch self {
            case .wentWell: "Went well"
            case .watch: "To watch"
            case .tryNext: "Try in \(nextName)"
            }
        }
    }

    public struct Item: Sendable, Equatable, Identifiable {
        public let findingID: String
        public let kind: ReportFinding.Kind
        public let group: Group
        /// The finding's short heading, for compact lists.
        public let title: String
        /// The model's note, or the finding's `plainText`.
        public let text: String
        public let fix: ReportFix?
        /// Whether `text` came from the model rather than the check.
        public let isWrittenByModel: Bool

        public var id: String { findingID }
        public var badge: String { kind.badge }
        public var symbolName: String { kind.symbolName }
    }

    public let scope: ReportScope
    /// The model's one or two sentences on the month, or the check's own
    /// (`plainHeadline`).
    public let headline: String
    public let isHeadlineWrittenByModel: Bool
    public let wentWell: [Item]
    public let watch: [Item]
    public let tryNext: [Item]

    /// Whether anything on the sheet came from the model — the sparkle and
    /// the "Apple Intelligence" caption go by this, not by the setting.
    public var isWrittenByModel: Bool {
        isHeadlineWrittenByModel || allItems.contains(where: \.isWrittenByModel)
    }

    public var allItems: [Item] { wentWell + watch + tryNext }

    public func items(in group: Group) -> [Item] {
        switch group {
        case .wentWell: wentWell
        case .watch: watch
        case .tryNext: tryNext
        }
    }

    /// The groups with something in them, in sheet order.
    public var groups: [Group] { Group.allCases.filter { !items(in: $0).isEmpty } }

    /// "Try in October", "Try in 2027".
    public var tryNextTitle: String { Group.tryNext.title(nextName: ReportBrief.nextName(for: scope)) }

    public func title(for group: Group) -> String { group.title(nextName: ReportBrief.nextName(for: scope)) }

    /// The Summary card's chips, counted off this review.
    public var counts: FinanceReportData.ToneCounts {
        FinanceReportData.ToneCounts(wentWell: wentWell.count, watch: watch.count, tryNext: tryNext.count)
    }

    public init(scope: ReportScope, headline: String, isHeadlineWrittenByModel: Bool, wentWell: [Item], watch: [Item], tryNext: [Item]) {
        self.scope = scope
        self.headline = headline
        self.isHeadlineWrittenByModel = isHeadlineWrittenByModel
        self.wentWell = wentWell
        self.watch = watch
        self.tryNext = tryNext
    }

    /// - Parameters:
    ///   - brief: what the model was shown; the draft's fact numbers are
    ///     read against it. Without one, the draft is ignored.
    ///   - fillingIn: list the findings the model hasn't written about in the
    ///     check's words. Off while a review streams in, so the sheet shows
    ///     only what the model has finished.
    public init(findings: [ReportFinding], scope: ReportScope, brief: ReportBrief? = nil, draft: ReportReviewDraft? = nil, fillingIn: Bool = true) {
        self.scope = scope
        let isPartial = !(draft?.isComplete ?? true)

        let plain = Self.plainHeadline(findings: findings, scope: scope)
        if let brief, let written = draft?.headline?.trimmingCharacters(in: .whitespacesAndNewlines), !written.isEmpty,
           Self.isFaithfulHeadline(written, brief: brief, partial: isPartial) {
            headline = written
            isHeadlineWrittenByModel = true
        } else {
            headline = plain
            isHeadlineWrittenByModel = false
        }

        var items: [Item] = []
        var seen = Set<String>()
        let byID = Dictionary(findings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let brief, let draft {
            // The last note of a partial snapshot may stop mid-sentence, and
            // would fail the check only for being unfinished.
            let notes = isPartial ? Array(draft.notes.dropLast()) : draft.notes
            for note in notes {
                // The first note for a fact wins — Trips' spike saw one
                // finding written up three times — and numbers that aren't
                // facts, or are the headline's, are dropped.
                guard let fact = brief.fact(numbered: note.fact), let finding = byID[fact.findingID],
                      let group = Group(finding: finding), !seen.contains(finding.id) else { continue }
                let message = note.message.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty, Self.isFaithful(message, to: fact, in: brief) else { continue }
                seen.insert(finding.id)
                items.append(Item(findingID: finding.id, kind: finding.kind, group: group, title: finding.title, text: message, fix: finding.fix, isWrittenByModel: true))
            }
        }
        if fillingIn {
            let rest = findings
                .filter { !seen.contains($0.id) }
                .sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.id < $1.id }
            for finding in rest {
                guard let group = Group(finding: finding) else { continue }
                items.append(Item(findingID: finding.id, kind: finding.kind, group: group, title: finding.title, text: finding.plainText, fix: finding.fix, isWrittenByModel: false))
            }
        }
        // A short take, not the whole check: the seeded month gave the
        // Summary card "5 went well · 4 to watch · 8 to try" and a sheet of
        // seventeen notes. The model's picks come first, in its order, then
        // the heaviest findings; everything stays in the report's Worth fixing.
        wentWell = Array(items.filter { $0.group == .wentWell }.prefix(Self.perGroupLimit))
        watch = Array(items.filter { $0.group == .watch }.prefix(Self.perGroupLimit))
        tryNext = Array(items.filter { $0.group == .tryNext }.prefix(Self.perGroupLimit))
    }

    /// The most notes a group shows on the card, sheet and the report's brief.
    public static let perGroupLimit = 3

    /// The check on its own: what the sheet, card and report show when the
    /// model is off, can't run, fails, or writes nothing faithful.
    public static func plain(findings: [ReportFinding], scope: ReportScope) -> ReportReview {
        ReportReview(findings: findings, scope: scope)
    }

    public static func plain(data: FinanceReportData) -> ReportReview {
        plain(findings: data.findings, scope: data.scope)
    }

    /// The check's own headline: the net worth's move, then the budgets' or
    /// the year's spending total — "Net worth rose $5,565 since August, to
    /// $387,675 (1.5%). Spending ran $100 over budget in 2 of 5 categories:
    /// Food and Subscriptions."
    public static func plainHeadline(findings: [ReportFinding], scope: ReportScope) -> String {
        let order: [ReportFinding.Kind] = [.netWorthMove, .yearNetWorth, .budgetsSummary, .yearSpendingTotal]
        let parts = order.compactMap { kind in
            findings.first { $0.kind == kind && $0.tone == .info }?.plainText
        }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        switch scope {
        case .month(let period): return "Nothing stood out in \(period.monthName)."
        case .year(let year): return "Nothing stood out in \(year)."
        }
    }

    // MARK: - Faithfulness

    /// Whether a note still says what its fact says: every figure and name
    /// the fact gives, no number the fact doesn't have, no name from another
    /// fact, nothing that waves the fact away and nothing that sounds like
    /// investment advice. Anything else falls back to the check's own words —
    /// the rule Trips learned from its first runs on a Mac, where the model
    /// turned an overlap into two stops "on Day 1" and filed one problem's
    /// words under another's number.
    public static func isFaithful(_ note: String, to fact: ReportBrief.Fact, in brief: ReportBrief) -> Bool {
        let lower = note.lowercased()
        // Whole words and whole figures: on bare substrings the category
        // "Car" was satisfied by "card", and "$84" by "$840".
        guard fact.figures.allSatisfy({ containsWhole(lower, $0.lowercased()) }),
              fact.names.allSatisfy({ containsWhole(lower, $0.lowercased()) })
        else { return false }

        // The same direction as the fact. Figures and names alone let "Food
        // came in $84 under its $600 budget" stand for an over-budget fact,
        // and "Net worth fell $5,565" for a rise — sparkled, and the page
        // says the brief was checked against the figures.
        guard keepsDirection(note, of: fact.text) else { return false }

        // No new numbers, even true ones from elsewhere in the brief: the
        // model doing its own arithmetic ("about $1,200 a year") is exactly
        // what can't be checked.
        let own = Set(ReportNumbers.numbers(in: fact.text))
        guard ReportNumbers.numbers(in: note).allSatisfy(own.contains) else { return false }

        // Another fact's account, category or merchant in this note means
        // facts got mixed. Names the header carries (the month, the one it's
        // compared with) are anyone's.
        let lowerText = fact.text.lowercased()
        let lowerHeader = brief.header.lowercased()
        let ownNames = Set(fact.names.map { $0.lowercased() })
        let foreign = brief.facts
            .filter { $0.number != fact.number }
            .flatMap(\.names)
            .map { $0.lowercased() }
            .filter { $0.count >= 4 && !ownNames.contains($0) && !lowerText.contains($0) && !lowerHeader.contains($0) }
        guard !foreign.contains(where: { containsWhole(lower, $0) }) else { return false }

        return !isDismissive(note) && !soundsLikeAdvice(note, brief: brief)
    }

    /// A headline may quote any number from the facts, and nothing else. A
    /// partial one is read without its last, maybe unfinished, number.
    static func isFaithfulHeadline(_ headline: String, brief: ReportBrief, partial: Bool) -> Bool {
        let allowed = brief.factNumbers
        guard ReportNumbers.numbers(in: headline, ignoringTrailing: partial).allSatisfy(allowed.contains),
              !soundsLikeAdvice(headline, brief: brief)
        else { return false }
        // A sentence about net worth goes the way the net-worth fact does: a
        // headline saying it fell when it rose passed on numbers alone.
        guard let netWorth = brief.facts.first(where: { $0.kind == .netWorthMove || $0.kind == .yearNetWorth }) else { return true }
        let sentences = headline.split(whereSeparator: { ".!?;\n".contains($0) })
        return sentences
            .filter { $0.lowercased().contains("net worth") }
            .allSatisfy { keepsDirection(String($0), of: netWorth.text) }
    }

    // MARK: Direction

    /// Words that say which way something went, in opposed pairs: up or
    /// down, over or under. A word may sit on one side of both pairs.
    static let directions: [(Set<String>, Set<String>)] = [
        (["rose", "rise", "rises", "risen", "rising", "up", "increase", "increased", "increases", "grew", "grow", "grown",
          "higher", "gain", "gained", "gains", "climbed", "more", "above", "jumped"],
         ["fell", "fall", "falls", "fallen", "falling", "down", "decrease", "decreased", "decreases", "dropped", "drop",
          "declined", "decline", "lower", "lost", "loss", "shrank", "less", "below", "slipped"]),
        (["over", "above", "exceeded", "exceeds", "overspent", "beyond"],
         ["under", "below", "within"]),
    ]

    /// Whether `note` keeps `factText`'s direction: a note may not use a
    /// direction word whose opposite the fact uses while the fact never uses
    /// that side itself. A fact with no direction words binds nothing.
    static func keepsDirection(_ note: String, of factText: String) -> Bool {
        let noteWords = words(in: note)
        let factWords = words(in: factText)
        for (one, other) in directions {
            let factOne = !factWords.isDisjoint(with: one)
            let factOther = !factWords.isDisjoint(with: other)
            if !noteWords.isDisjoint(with: one), factOther, !factOne { return false }
            if !noteWords.isDisjoint(with: other), factOne, !factOther { return false }
        }
        return true
    }

    static func words(in text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
    }

    /// `needle` in `haystack` with no letter or digit either side of it.
    static func containsWhole(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: searchRange) {
            let before = found.lowerBound == haystack.startIndex ? nil : haystack[haystack.index(before: found.lowerBound)]
            let after = found.upperBound == haystack.endIndex ? nil : haystack[found.upperBound]
            let clearBefore = before.map { !($0.isLetter || $0.isNumber) } ?? true
            let clearAfter = after.map { !($0.isLetter || $0.isNumber) } ?? true
            if clearBefore, clearAfter { return true }
            searchRange = haystack.index(after: found.lowerBound)..<haystack.endIndex
        }
        return false
    }

    /// A note that waves a real finding away. Trips' spike answered six real
    /// problems with "No change needed".
    static func isDismissive(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["no change needed", "nothing to change", "no action", "nothing to worry", "not a concern", "no need to worry", "nothing to do"]
            .contains(where: lower.contains)
    }

    /// Buying, selling or moving money between investments: never the
    /// app's place to say, and the instructions forbid it, so a note that
    /// does it anyway is dropped. Names from the brief are taken out first —
    /// a merchant called "Best Buy" isn't advice.
    static func soundsLikeAdvice(_ text: String, brief: ReportBrief) -> Bool {
        var lower = " " + text.lowercased() + " "
        for name in brief.facts.flatMap(\.names) where !name.isEmpty {
            lower = lower.replacingOccurrences(of: name.lowercased(), with: " ")
        }
        let phrases = [
            " buy ", " buying ", " sell ", " selling ", "rebalanc", "reallocat", " allocate", "allocation",
            "diversif", "invest more", "invest in ", "investing in ", "move money into", "move your money",
            "shift money", "put more into", "put more money", " stocks", " shares", "crypto", " bonds",
            "index fund", "market timing", "financial advice", "investment advice",
        ]
        return phrases.contains(where: lower.contains)
    }
}

// MARK: - Ask about a month

/// One answer to "Ask about <month>": the model's words when every number in
/// them is one of the brief's (or the question's) and none of it is advice;
/// otherwise "I can only answer from this report's figures." and the facts
/// nearest the question, in the check's own words.
public struct AskReply: Sendable, Equatable {
    public let question: String
    public let text: String
    public let isWrittenByModel: Bool
    /// False while the answer is still streaming in.
    public let isComplete: Bool
    /// The facts a fallback answer quotes, for the view to list; empty for a
    /// model answer.
    public let facts: [ReportBrief.Fact]

    public static let fallbackLead = "I can only answer from this report's figures."

    public init(question: String, text: String, isWrittenByModel: Bool, isComplete: Bool, facts: [ReportBrief.Fact] = []) {
        self.question = question
        self.text = text
        self.isWrittenByModel = isWrittenByModel
        self.isComplete = isComplete
        self.facts = facts
    }

    /// The model's `answer` checked against `brief`; nil or empty, or
    /// anything unfaithful, is the fallback.
    public init(question: String, answer: String?, brief: ReportBrief, isComplete: Bool) {
        let trimmed = answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, Self.isFaithful(trimmed, question: question, brief: brief, partial: !isComplete) {
            self.init(question: question, text: trimmed, isWrittenByModel: true, isComplete: isComplete)
        } else {
            self = Self.fallback(question: question, brief: brief)
        }
    }

    /// "I can only answer from this report's figures." and up to two facts
    /// nearest the question.
    public static func fallback(question: String, brief: ReportBrief) -> AskReply {
        let facts = closestFacts(to: question, in: brief)
        let text = ([fallbackLead] + facts.map(\.text)).joined(separator: " ")
        return AskReply(question: question, text: text, isWrittenByModel: false, isComplete: true, facts: facts)
    }

    /// Every number the answer quotes is in the brief or the question, and
    /// it isn't advice. The model is told the same; this is what makes it so.
    static func isFaithful(_ answer: String, question: String, brief: ReportBrief, partial: Bool) -> Bool {
        let allowed = brief.allowedNumbers.union(ReportNumbers.numbers(in: question))
        return ReportNumbers.numbers(in: answer, ignoringTrailing: partial).allSatisfy(allowed.contains)
            && !ReportReview.soundsLikeAdvice(answer, brief: brief)
    }

    /// The facts sharing the most words with the question; the first two
    /// facts (the headline's) when none do.
    static func closestFacts(to question: String, in brief: ReportBrief, limit: Int = 2) -> [ReportBrief.Fact] {
        let stopwords: Set<String> = ["the", "and", "did", "does", "how", "what", "why", "was", "were", "this", "that", "with", "for", "our", "much", "many", "about", "month", "year", "from", "have", "has", "are", "its", "it's", "what's", "go", "get"]
        let words = Set(question.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init))
            .filter { $0.count >= 3 && !stopwords.contains($0) }
        let scored = brief.facts.map { fact -> (fact: ReportBrief.Fact, score: Int) in
            let text = fact.text.lowercased()
            let names = fact.names.map { $0.lowercased() }
            let score = words.reduce(0) { total, word in
                total + (names.contains(where: { $0.contains(word) }) ? 2 : 0) + (text.contains(word) ? 1 : 0)
            }
            return (fact, score)
        }
        let matched = scored.filter { $0.score > 0 }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.fact.number < $1.fact.number }
            .map(\.fact)
        return Array((matched.isEmpty ? brief.facts : matched).prefix(limit))
    }

    /// The chips under the Ask box, made from what the check found: "Why did
    /// Food go over?", "What's recurring?", "How does this compare with
    /// August?". Each is a question the brief can answer.
    public static func suggestedQuestions(for data: FinanceReportData, limit: Int = 4) -> [String] {
        let findings = data.findings.sorted { $0.weight > $1.weight }
        func first(_ kinds: ReportFinding.Kind...) -> ReportFinding? {
            findings.first { kinds.contains($0.kind) }
        }
        var questions: [String] = []
        if let over = first(.overBudget, .yearOverBudget), let category = over.names.first {
            questions.append("Why did \(category) go over?")
        }
        if first(.newRecurring, .recurringTotal, .yearRecurring) != nil {
            questions.append("What's recurring?")
        }
        switch data.scope {
        case .month:
            if let comparison = data.hero.comparisonName {
                questions.append("How does this compare with \(comparison)?")
            }
        case .year(let year):
            if first(.yearBestMonth) != nil { questions.append("Which was the best month?") }
            questions.append("Where did the money go in \(year)?")
        }
        if let spike = first(.categorySpike, .yearSpendingIncrease), let category = spike.names.first {
            questions.append("What pushed \(category) up?")
        }
        if first(.staleBalances) != nil { questions.append("Which balances look stale?") }
        if first(.debtPaidDown, .yearDebtPaidDown) != nil { questions.append("How much debt was paid down?") }
        questions.append("Where did the money go?")
        var seen = Set<String>()
        return Array(questions.filter { seen.insert($0).inserted }.prefix(limit))
    }
}
