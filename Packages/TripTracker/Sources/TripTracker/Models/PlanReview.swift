import Foundation

/// What the Review Plan sheet lists: every `PlanCheck` finding, each worded by
/// the model when it said something useful about it and by `PlanCheck`
/// otherwise, in the model's order of importance and then the check's.
///
/// Built the same way whether there is a model or not — with no draft it is
/// simply the plain check — and rebuilt on every streamed snapshot.
public struct PlanReview {
    public struct Entry: Identifiable {
        public let finding: PlanCheck.Finding
        public let message: String
        /// Whether `message` came from the model rather than `PlanCheck`.
        public let isWrittenByModel: Bool
        public var id: String { finding.id }
    }

    /// The model's one-line take on the whole plan; nil without one.
    public let verdict: String?
    public let entries: [Entry]

    public init(check: PlanCheck, brief: TripBrief? = nil, draft: TripReviewDraft? = nil) {
        let verdict = draft?.verdict?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.verdict = (verdict?.isEmpty ?? true) ? nil : verdict

        // The model's notes, mapped back to findings by fact number: the
        // first note for a fact wins — the spike's model repeated one finding
        // three times — and numbers that aren't facts are dropped.
        var written: [(id: String, message: String)] = []
        var seen = Set<String>()
        if let brief, let draft {
            let everyTitle = Set(check.findings.flatMap { $0.items.map(\.title) })
            for note in draft.notes {
                guard let fact = brief.fact(numbered: note.fact), let finding = check.finding(id: fact.findingID),
                      !seen.contains(fact.findingID) else { continue }
                let message = note.message.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty, !Self.isDismissive(message),
                      Self.isFaithful(message, to: finding, titles: everyTitle) else { continue }
                seen.insert(fact.findingID)
                written.append((fact.findingID, message))
            }
        }

        let byModel = written.compactMap { pair in
            check.finding(id: pair.id).map { Entry(finding: $0, message: pair.message, isWrittenByModel: true) }
        }
        let rest = check.findings
            .filter { !seen.contains($0.id) }
            .map { Entry(finding: $0, message: $0.message, isWrittenByModel: false) }
        entries = byModel + rest
    }

    /// Whether a note still says what its finding says: every figure the
    /// finding gives (a day number aside), the place it's about when it's
    /// about particular places, and no place from somewhere else in the plan.
    /// The first run against the real model on a Mac turned "Colosseum runs
    /// 30 min into Borghese Gallery" into "Colosseum and Borghese Gallery on
    /// Day 1", filed "Day 3 has nothing planned" under the idea near Day 2, and
    /// tacked that idea onto the rain note — each of those falls back to the
    /// check's own words.
    static func isFaithful(_ note: String, to finding: PlanCheck.Finding, titles: Set<String>) -> Bool {
        let lowerNote = note.lowercased()
        let noteFigures = Set(figures(in: note))
        guard figures(in: finding.message, ignoringDays: true).allSatisfy(noteFigures.contains) else { return false }

        let lowerMessage = finding.message.lowercased()
        let own = Set(finding.items.map(\.title)).union(titles.filter { lowerMessage.contains($0.lowercased()) })
        // A stop's name is a place in the plan only when it's a real name:
        // "Lunch" inside "lunch break" says nothing.
        let named = titles.filter { $0.count >= 4 && lowerNote.contains($0.lowercased()) }
        guard named.isSubset(of: own) else { return false }
        if finding.kind.isAboutPlaces, !finding.items.isEmpty,
           !finding.items.contains(where: { lowerNote.contains($0.title.lowercased()) }) {
            return false
        }
        let words = vocabulary(for: finding.kind)
        return words.required.contains(where: lowerNote.contains) && !words.contradicting.contains(where: lowerNote.contains)
    }

    /// A note has to say what kind of problem it is, in one of these words,
    /// and never the opposite. With every name and figure kept, the second
    /// run on a Mac still wrote "Colosseum ends 30 min before Borghese
    /// Gallery starts" for a visit that runs 30 min into the next.
    static func vocabulary(for kind: PlanCheck.Kind) -> (required: [String], contradicting: [String]) {
        switch kind {
        case .overlap:
            (["overlap", "into", "clash", "same time", "conflict", "double-book", "overrun", "run over", "runs over"], ["before", "gap", "no overlap"])
        case .tightTransfer:
            (["walk", "on foot", "far", "apart", "get from", "getting from", "travel", "between"], ["plenty of time", "enough time"])
        case .overloaded, .busyFlightDay:
            (["stop", "hr", "hour", "busy", "packed", "full", "flight", "a lot", "too much"], ["light day", "relaxed"])
        case .weatherClash:
            (["rain", "storm", "snow", "wet", "weather", "forecast", "shower", "drizzle", "hail", "sleet", "thunder"], ["sunny", "dry day"])
        case .emptyDay:
            (["nothing", "free", "empty", "open", "no plans", "unplanned"], [])
        case .ideaNearby:
            (["walk", "near", "close", "idea", "around the corner", "min from"], ["far from"])
        }
    }

    /// "2.3", "44", "30" out of "Day 1: … is 2.3 mi, about 44 min on foot,
    /// with 30 min between them" — with `ignoringDays`, without the 1: the
    /// sheet already groups by day, so a note needn't repeat it.
    static func figures(in text: String, ignoringDays: Bool = false) -> [String] {
        var text = text
        if ignoringDays {
            text = text.replacingOccurrences(of: #"Days? \d+(–\d+)?"#, with: "", options: .regularExpression)
        }
        var found: [String] = []
        var current = ""
        for character in text + " " {
            if character.isNumber || (character == "." && !current.isEmpty && current.last?.isNumber == true) {
                current.append(character)
            } else if !current.isEmpty {
                found.append(current.hasSuffix(".") ? String(current.dropLast()) : current)
                current = ""
            }
        }
        return found
    }

    /// A note that waves a real problem away. The research spike's second run
    /// answered all six checked problems — rain on a bike ride, a 30-minute
    /// overlap — with "No change needed" and "outdoor plans solid"; such a
    /// note is dropped for the check's own words.
    static func isDismissive(_ message: String) -> Bool {
        let lower = message.lowercased()
        return ["no change", "no changes", "no adjustment", "stays intact", "unchanged", "nothing to change", "no action"]
            .contains(where: lower.contains)
    }
}
