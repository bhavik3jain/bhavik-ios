import Core
import CryptoKit
import Foundation

/// Everything the on-device model is shown about a report, as plain strings:
/// a header naming the month and whose figures, the check's findings as
/// numbered facts, ranked and capped, and — for "Ask about a month" only —
/// a block of the report's own figures. The model answers by fact number (see
/// `ReportReview`), so Swift, not the model, decides what each note is about,
/// which group it sits in and which fix goes with it.
///
/// The same shape as Trips' `TripBrief`, for the same reason: the on-device
/// model's whole context measured 4,096 tokens on an M2, output included, so
/// the brief is cut to fit, least important first.
public struct ReportBrief: Sendable, Equatable {
    public struct Fact: Sendable, Equatable, Identifiable {
        /// 1-based, as the model sees it.
        public let number: Int
        /// `ReportFinding.id` — how a note finds its way back.
        public let findingID: String
        public let kind: ReportFinding.Kind
        /// Where the review lists it; nil for the facts the headline is made
        /// of (the net worth's move, the budgets' total).
        public let group: ReportReview.Group?
        /// The finding's `plainText`.
        public let text: String
        /// Copied from the finding: what a note about this fact must keep.
        public let figures: [String]
        public let names: [String]

        public var id: Int { number }
        public var isHeadline: Bool { group == nil }

        public init(number: Int, findingID: String, kind: ReportFinding.Kind, group: ReportReview.Group?, text: String, figures: [String], names: [String]) {
            self.number = number
            self.findingID = findingID
            self.kind = kind
            self.group = group
            self.text = text
            self.figures = figures
            self.names = names
        }
    }

    public let scope: ReportScope
    /// "Everyone", or an owner's name — part of the review cache's key.
    public let ownerLabel: String
    /// "Household finances: September 2026, Everyone's figures, compared
    /// with August."
    public let header: String
    /// The report's own figures, one per line, for answering questions:
    /// "Net worth $387,675 (+$5,565 · 1.5% on August)." Never in the review
    /// prompt — given figures beyond its fact, a note tends to quote them,
    /// and then fails `ReportReview.isFaithful`.
    public let figures: [String]
    public let facts: [Fact]
    /// "October", or "2027" — the "Try in …" group's heading.
    public let nextName: String

    /// Most facts the model is shown: the design's "Writing from 14
    /// figures…", and about what fits the context with room to answer.
    public static let factLimit = 14
    /// Facts kept from each group before the rest are filled by weight, so a
    /// month with one big overspend still hears what went well.
    public static let perGroupMinimum = 2
    /// Lines of figures given to Ask.
    public static let figureLimit = 48
    /// One finding's sentence is clipped past this — never in practice: the
    /// longest, stale balances, names at most four accounts.
    public static let factTextLimit = 400

    /// The kinds the review's headline is made of rather than listed.
    static let headlineKinds: Set<ReportFinding.Kind> = [.netWorthMove, .budgetsSummary, .yearNetWorth, .yearSpendingTotal]

    public init(scope: ReportScope, ownerLabel: String, header: String, figures: [String], facts: [Fact], nextName: String) {
        self.scope = scope
        self.ownerLabel = ownerLabel
        self.header = header
        self.figures = figures
        self.facts = facts
        self.nextName = nextName
    }

    public init(data: FinanceReportData, factLimit: Int = ReportBrief.factLimit) {
        scope = data.scope
        ownerLabel = data.header.ownerLabel
        nextName = Self.nextName(for: data.scope)

        var header = "Household finances: \(data.header.title), \(data.header.ownerLabel == "Everyone" ? "everyone's" : "\(data.header.ownerLabel)'s") figures"
        if let comparison = data.hero.comparisonName {
            header += ", compared with \(comparison)"
        }
        header += "."
        if data.header.isPartial {
            header += " \(data.period.monthName) isn't finished, so its figures are partial."
        }
        self.header = header

        facts = Self.rank(data.findings, limit: factLimit).enumerated().map { offset, finding in
            Fact(
                number: offset + 1,
                findingID: finding.id,
                kind: finding.kind,
                group: ReportReview.Group(finding: finding),
                text: Self.clip(finding.plainText, to: Self.factTextLimit),
                figures: finding.figures,
                names: finding.names
            )
        }
        figures = Array(Self.figureLines(data).prefix(Self.figureLimit))
    }

    /// The findings the model is shown, in the order it sees them: the
    /// headline's own facts, then the rest by weight, after making sure each
    /// group keeps its best `perGroupMinimum`.
    static func rank(_ findings: [ReportFinding], limit: Int) -> [ReportFinding] {
        let byWeight = findings.sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.id < $1.id }
        let headline = byWeight.filter { ReportReview.Group(finding: $0) == nil }
        var chosen = Array(headline.prefix(limit))
        var chosenIDs = Set(chosen.map(\.id))
        for group in ReportReview.Group.allCases {
            for finding in byWeight.filter({ ReportReview.Group(finding: $0) == group }).prefix(perGroupMinimum)
            where chosen.count < limit && !chosenIDs.contains(finding.id) {
                chosen.append(finding)
                chosenIDs.insert(finding.id)
            }
        }
        for finding in byWeight where chosen.count < limit && !chosenIDs.contains(finding.id) {
            chosen.append(finding)
            chosenIDs.insert(finding.id)
        }
        let headlineIDs = Set(headline.map(\.id))
        return chosen.sorted { lhs, rhs in
            let lhsHeadline = headlineIDs.contains(lhs.id), rhsHeadline = headlineIDs.contains(rhs.id)
            if lhsHeadline != rhsHeadline { return lhsHeadline }
            return lhs.weight != rhs.weight ? lhs.weight > rhs.weight : lhs.id < rhs.id
        }
    }

    public func fact(numbered number: Int) -> Fact? {
        facts.indices.contains(number - 1) ? facts[number - 1] : nil
    }

    public func fact(findingID: String) -> Fact? {
        facts.first { $0.findingID == findingID }
    }

    /// "October" after September, "2027" after 2026.
    static func nextName(for scope: ReportScope) -> String {
        switch scope {
        case .month(let period): period.next.monthName
        case .year(let year): String(year + 1)
        }
    }

    // MARK: - The prompt

    /// Room kept for the answer: a review of eight notes and a headline is
    /// about 450 tokens.
    public static let reservedOutputTokens = 1_000
    /// The instructions and the output schema, when the model can't count
    /// them itself (before iOS/macOS 26.4).
    public static let estimatedOverheadTokens = 400
    /// The smallest context measured: an M2 on macOS 27.
    public static let fallbackContextSize = 4_096
    static let minimumPlausibleContextSize = 2_048

    /// What's left for the brief in a model with `contextSize` tokens. A
    /// size too small to be real counts as `fallbackContextSize`: Trips found
    /// the iOS 27 simulator's model answering `contextSize` with 0.
    public static func promptBudget(contextSize: Int, overhead: Int = estimatedOverheadTokens) -> Int {
        let context = contextSize >= minimumPlausibleContextSize ? contextSize : fallbackContextSize
        return max(64, context - reservedOutputTokens - overhead)
    }

    /// Two and a half bytes a token, as Trips measured: "$", "·" and "−"
    /// cost more than English words.
    public static func estimatedTokens(_ text: String) -> Int {
        (text.utf8.count * 2 + 4) / 5
    }

    /// The text the model reads, cut down until `tokenCount` says it fits in
    /// `maxTokens`: first the figures go, from the end (they're for Ask, and
    /// least useful last), then facts from the end — the least important,
    /// since they're ranked. At least one fact always stays.
    public func prompt(maxTokens: Int, includeFigures: Bool = false, tokenCount: (String) -> Int = ReportBrief.estimatedTokens) -> String {
        if includeFigures {
            var count = figures.count
            while count > 0 {
                let text = render(figureCount: count, factCount: facts.count)
                if tokenCount(text) <= maxTokens { return text }
                count -= 1
            }
        }
        var count = facts.count
        while count > 1 {
            let text = render(figureCount: 0, factCount: count)
            if tokenCount(text) <= maxTokens { return text }
            count -= 1
        }
        return render(figureCount: 0, factCount: min(1, facts.count))
    }

    /// The whole review prompt, uncut — what the cache fingerprints.
    public var fullPrompt: String { render(figureCount: 0, factCount: facts.count) }

    private func render(figureCount: Int, factCount: Int) -> String {
        var lines = [header]
        if figureCount > 0 {
            lines.append("Figures:")
            lines += figures.prefix(figureCount).map { "- \($0)" }
        }
        if facts.isEmpty {
            lines.append("The checks found nothing to note.")
        } else {
            lines.append("Facts (all worked out from the household's own figures, all true):")
            lines += facts.prefix(factCount).map { "\($0.number). [\(label(for: $0.group))] \($0.text)" }
        }
        return lines.joined(separator: "\n")
    }

    private func label(for group: ReportReview.Group?) -> String {
        switch group {
        case nil: "headline"
        case .wentWell: "went well"
        case .watch: "to watch"
        case .tryNext: "to try in \(nextName)"
        }
    }

    // MARK: - Fingerprint and numbers

    /// Changes whenever anything the review was written from changes — a
    /// figure, a fact's wording, its rank, whose report — so a cached review
    /// is never shown for figures it wasn't written about.
    public var fingerprint: String {
        let text = [scope.rawValue, ownerLabel, nextName, fullPrompt].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Every number anywhere in the brief, figures included, as
    /// `ReportNumbers` reads them — what an answer may quote.
    public var allowedNumbers: Set<String> {
        Set(ReportNumbers.numbers(in: render(figureCount: figures.count, factCount: facts.count)))
    }

    /// Every number in the facts and header — what a headline may quote.
    public var factNumbers: Set<String> {
        Set(ReportNumbers.numbers(in: fullPrompt))
    }

    // MARK: - Figures

    static func figureLines(_ data: FinanceReportData) -> [String] {
        var lines: [String] = []
        let hero = data.hero
        lines.append("Net worth \(hero.netWorthText) (\(hero.deltaLine)).")
        lines.append("Assets \(hero.assetsText), owed \(hero.owedText).")
        for kpi in data.kpis where kpi.id != "assets" {
            lines.append("\(kpi.label) \(kpi.valueText)\(kpi.detail.isEmpty ? "" : ": \(kpi.detail)").")
        }
        let spending = data.spending
        var spent = "Spent \(spending.totalText) in \(counted(spending.transactionCount, "transaction")): \(spending.onCardsText) on cards, \(spending.fromCashText) from cash accounts"
        if let average = spending.averageText { spent += "; 3-month average \(average)" }
        lines.append(spent + ".")
        for row in spending.budgets {
            lines.append("\(row.category) budget: \(row.label).")
        }
        if let year = data.year {
            for budget in year.budgets where budget.monthsOver > 0 {
                lines.append("\(budget.category) budget: over in \(budget.monthsOver) of \(budget.monthsBudgeted) months, \(FinanceFormat.money(budget.totalOver)) over in all.")
            }
        }
        for category in spending.categories.prefix(8) {
            var line = "\(category.name): \(category.totalText)"
            if let average = category.averageText { line += ", 3-month average \(average)" }
            lines.append(line + ".")
        }
        for row in spending.unbudgeted where row.spent > 0 {
            lines.append("\(row.category), no budget: \(row.spentText).")
        }
        for charge in spending.recurring {
            lines.append("Recurring: \(charge.merchant) \(charge.amountText) a month (\(charge.category))\(charge.isNew ? ", new" : "").")
        }
        if spending.recurring.count > 1 {
            lines.append("Recurring charges in all: \(spending.recurringMonthlyText) a month.")
        }
        for merchant in spending.topMerchants.prefix(5) {
            lines.append("\(merchant.name): \(merchant.totalText) over \(counted(merchant.visits, "visit")).")
        }
        if let year = data.year {
            for month in year.months {
                lines.append("\(month.period.title): net worth \(month.netWorthText)\(month.changeText.map { " (\($0))" } ?? ""), spent \(month.spendText).")
            }
        }
        for line in data.mix {
            var text = "\(line.name) \(line.valueText), \(line.shareText) of assets"
            if let delta = line.deltaText, let comparison = hero.comparisonName { text += ", \(delta) on \(comparison)" }
            lines.append(text + ".")
        }
        for moved in data.moved {
            lines.append("\(moved.name): \(moved.impactText) on net worth.")
        }
        for group in data.accountGroups {
            lines.append("\(group.title) accounts: \(group.totalText).")
        }
        if !data.metals.items.isEmpty {
            let metals = data.metals
            lines.append("Gold \(metals.gold.valueText) (\(metals.gold.detail)); silver \(metals.silver.valueText) (\(metals.silver.detail)); gold at \(metals.goldPriceText), silver at \(metals.silverPriceText), \(metals.pricesAreLive ? "today's prices" : "saved prices").")
        }
        for card in data.cards.cards {
            lines.append("\(card.name) card: \(card.spendText) spent, \(card.limitText) limit\(card.useText.map { ", \($0) used" } ?? "").")
        }
        return lines.map { clip($0, to: 240) }
    }

    static func clip(_ text: String, to limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }
}

/// The numbers in a piece of text, read the same way everywhere a model's
/// words are checked against Swift's: digits with their grouping commas
/// dropped and their decimals kept — "$5,565" is "5565", "1.5%" is "1.5",
/// "$9.99" is "9.99". Signs, currency and percent marks are ignored, so
/// "−$310" and "$310" agree.
enum ReportNumbers {
    static func numbers(in text: String, ignoringTrailing: Bool = false) -> [String] {
        var found: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if character.isASCII, character.isNumber {
                current.append(character)
            } else if (character == "," || character == "."), !current.isEmpty,
                      index + 1 < characters.count, characters[index + 1].isASCII, characters[index + 1].isNumber {
                // A grouping comma or a decimal point: only between digits,
                // so "$684, of" ends the number at the comma.
                if character == "." { current.append(".") }
            } else if !current.isEmpty {
                found.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            // A streamed answer may stop mid-number: "$5,5" of "$5,565".
            if !ignoringTrailing { found.append(current) }
        } else if ignoringTrailing, let last = characters.last, last == "," || last == ".", !found.isEmpty,
                  characters.dropLast().last?.isNumber == true {
            found.removeLast()
        }
        return found
    }
}
