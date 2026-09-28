import Core
import Foundation

/// Everything the on-device model is shown about a trip, as plain strings: a
/// header, each day's plan in one line per entry, the saved ideas' names, and
/// `PlanCheck`'s findings as numbered facts. The model answers by fact number
/// (see `PlanReview`), so Swift, not the model, decides what each note is about
/// and which fix goes with it.
///
/// What is never read, so can never be sent: a booking's `secureNote` (door
/// codes, key-safe PINs) and `code`, a flight's `confirmationCode`, `seat` and
/// `terminal`, contact phones, and every free-text `notes`/`detail` and
/// address. The same boundary `ItineraryDocument` keeps for the PDF — and it
/// keeps the prompt small, which matters more: the on-device model's whole
/// context measured 4,096 tokens on an M2, output included.
public struct TripBrief: Sendable, Equatable {
    public struct Fact: Sendable, Equatable {
        /// 1-based, as the model sees it.
        public let number: Int
        /// `PlanCheck.Finding.id` — how an answer finds its way back.
        public let findingID: String
        public let dayIndex: Int
        public let kind: PlanCheck.Kind
        public let text: String
    }

    public struct Day: Sendable, Equatable {
        public let dayIndex: Int
        /// "Day 2 (Sat 10 Oct; Rain, 19°/14°)".
        public let heading: String
        /// "09:00 Colosseum (Sight, 3 hr)", "Anytime: Trastevere wander (Activity)".
        public let lines: [String]
    }

    public let header: String
    public let days: [Day]
    /// "Pantheon (Sight)".
    public let ideas: [String]
    public let facts: [Fact]
    /// Which of the trip's days this brief covers.
    public let dayRange: Range<Int>

    /// A trip longer than this is reviewed a week at a time: three weeks of
    /// plan doesn't fit a 4,096-token context with room left to answer.
    public static let daysPerChunk = 7
    /// Long titles are clipped: one pasted paragraph shouldn't crowd out the
    /// plan.
    public static let titleLimit = 60
    public static let factLimit = 240
    public static let ideaLimit = 15

    public init(header: String, days: [Day], ideas: [String], facts: [Fact], dayRange: Range<Int>) {
        self.header = header
        self.days = days
        self.ideas = ideas
        self.facts = facts
        self.dayRange = dayRange
    }

    /// - Parameters:
    ///   - range: the days to cover; the whole trip when nil. See
    ///     `reviewRange(dayCount:focusDay:)`.
    ///   - weather: one slot per trip day, as `TripForecast.byDay` returns it.
    public init(
        trip: SharedTrip,
        check: PlanCheck,
        weather: [DayWeather?] = [],
        days range: Range<Int>? = nil,
        locale: Locale = .current
    ) {
        let dates = trip.dates
        let all = 0..<dates.dayCount
        let covered = range.map { $0.clamped(to: all) } ?? all
        dayRange = covered

        let first = IdeaDays.dayLabel(covered.lowerBound, dates: dates)
        let last = IdeaDays.dayLabel(max(covered.lowerBound, covered.upperBound - 1), dates: dates)
        var header = "Trip: \(Self.clip(trip.title))"
        if !trip.destination.isEmpty { header += ", \(Self.clip(trip.destination))" }
        header += ". \(dates.dayCount) \(dates.dayCount == 1 ? "day" : "days")"
        if covered == all {
            header += ", \(first) to \(last)."
        } else {
            header += "; this covers Day \(covered.lowerBound + 1) (\(first)) to Day \(covered.upperBound) (\(last))."
        }
        self.header = header

        let items = Array(trip.items ?? [])
        let flights = Array(trip.flights ?? [])
        days = covered.map { index in
            let plan = DayPlan(dayIndex: index, items: items, flights: flights, dates: dates)
            var heading = "Day \(index + 1) (\(IdeaDays.dayLabel(index, dates: dates))"
            if weather.indices.contains(index), let forecast = weather[index] {
                heading += "; \(forecast.summary), \(WeatherFormat.temperature(forecast.highCelsius, locale: locale))/\(WeatherFormat.temperature(forecast.lowCelsius, locale: locale))"
            }
            heading += ")"
            let lines = plan.timed.map { Self.line(for: $0, in: plan, timed: true) }
                + plan.untimed.map { Self.line(for: $0, in: plan, timed: false) }
            return Day(dayIndex: index, heading: heading, lines: lines)
        }

        ideas = trip.ideas
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .prefix(Self.ideaLimit)
            .map { "\(Self.clip($0.title)) (\($0.kind.displayName))" }

        facts = check.findings
            .filter { covered.contains($0.dayIndex) }
            .enumerated()
            .map { offset, finding in
                Fact(
                    number: offset + 1,
                    findingID: finding.id,
                    dayIndex: finding.dayIndex,
                    kind: finding.kind,
                    text: Self.clip(finding.message, to: Self.factLimit)
                )
            }
    }

    /// The whole trip when it fits in one chunk, otherwise the week holding
    /// `focusDay` — weeks counted from the first day, so days 8–14 are always
    /// reviewed together.
    public static func reviewRange(dayCount: Int, focusDay: Int) -> Range<Int> {
        guard dayCount > daysPerChunk else { return 0..<max(0, dayCount) }
        let day = min(max(0, focusDay), dayCount - 1)
        let start = (day / daysPerChunk) * daysPerChunk
        return start..<min(dayCount, start + daysPerChunk)
    }

    public func fact(numbered number: Int) -> Fact? {
        facts.indices.contains(number - 1) ? facts[number - 1] : nil
    }

    // MARK: - The prompt

    /// Room kept for the answer. A structured review measured 309–347 output
    /// tokens in the spike; this leaves plenty.
    public static let reservedOutputTokens = 1_000
    /// The instructions and the output schema, when the model can't count
    /// them itself (before iOS/macOS 26.4).
    public static let estimatedOverheadTokens = 400

    /// What's left for the brief in a model with `contextSize` tokens. The
    /// context is input and output together, and measured 4,096 on an M2
    /// (WWDC26 said 8,192 on 27.0), so it's read at run time, not assumed.
    ///
    /// A size too small to be real counts as `fallbackContextSize`: the model
    /// on the iPhone 18 Pro simulator (iOS 27) answered `contextSize` with 0,
    /// which left a budget of 64 tokens — the header and one fact — while the
    /// model itself took a full-size prompt.
    public static func promptBudget(contextSize: Int, overhead: Int = estimatedOverheadTokens) -> Int {
        let context = contextSize >= minimumPlausibleContextSize ? contextSize : fallbackContextSize
        return max(64, context - reservedOutputTokens - overhead)
    }

    /// The smallest context measured: an M2 on macOS 27.
    public static let fallbackContextSize = 4_096
    static let minimumPlausibleContextSize = 2_048

    /// Two and a half bytes a token. Three looked safe for English, but the
    /// probe's Rome brief — times, "°", "→", "·" — came to 1,098 bytes and
    /// the model counted 431 tokens where three a token had said 366. Used
    /// where the model's own `tokenCount(for:)` (iOS/macOS 26.4) isn't
    /// there, and to trim before asking it.
    public static func estimatedTokens(_ text: String) -> Int {
        (text.utf8.count * 2 + 4) / 5
    }

    /// The text the model reads, cut down until `tokenCount` says it fits in
    /// `maxTokens`: first the ideas go, then the plan of days with nothing to
    /// say, then the plan altogether, then facts from the end — the facts are
    /// the point, and the first ones are the earliest days.
    public func prompt(maxTokens: Int, tokenCount: (String) -> Int = TripBrief.estimatedTokens) -> String {
        let withFacts = Set(facts.map(\.dayIndex))
        let levels: [(ideas: Bool, days: (Day) -> Bool)] = [
            (true, { _ in true }),
            (false, { _ in true }),
            (false, { withFacts.contains($0.dayIndex) }),
            (false, { _ in false }),
        ]
        for level in levels {
            let text = render(ideas: level.ideas, days: level.days, factCount: facts.count)
            if tokenCount(text) <= maxTokens { return text }
        }
        var count = facts.count
        while count > 1 {
            count -= 1
            let text = render(ideas: false, days: { _ in false }, factCount: count)
            if tokenCount(text) <= maxTokens { return text }
        }
        return render(ideas: false, days: { _ in false }, factCount: min(1, facts.count))
    }

    private func render(ideas includeIdeas: Bool, days include: (Day) -> Bool, factCount: Int) -> String {
        var lines = [header]
        let shown = days.filter(include)
        if !shown.isEmpty {
            lines.append("Plan:")
            for day in shown {
                lines.append("\(day.heading):")
                lines += day.lines.isEmpty ? ["  nothing planned"] : day.lines.map { "  \($0)" }
            }
        }
        if includeIdeas, !ideas.isEmpty {
            lines.append("Saved ideas, not on any day yet: \(ideas.joined(separator: "; ")).")
        }
        if facts.isEmpty {
            lines.append("No problems were found in this plan.")
        } else {
            lines.append("Problems found (all checked, all real):")
            lines += facts.prefix(factCount).map { "\($0.number). \($0.text)" }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Pieces

    static func clip(_ text: String, to limit: Int = titleLimit) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }

    /// Title, kind, time and length only. A flight is its designator and
    /// route — `headline` — and nothing else of it.
    static func line(for entry: DayPlan.Entry, in plan: DayPlan, timed: Bool) -> String {
        let time: String
        if timed, let start = plan.start(of: entry) {
            let minute = plan.dates.minuteOfDay(start)
            time = String(format: "%02d:%02d ", minute / 60, minute % 60)
        } else {
            time = "Anytime: "
        }
        switch entry {
        case .item(let item):
            var about = item.kind.displayName
            if item.durationMinutes > 0 { about += ", \(PlanCheck.duration(item.durationMinutes))" }
            if item.isDone { about += ", done" }
            return "\(time)\(clip(item.title)) (\(about))"
        case .flight(let flight):
            return "\(time)Flight \(flight.headline)"
        }
    }
}
