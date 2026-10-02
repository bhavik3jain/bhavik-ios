import Foundation
import FoundationModels

// FoundationModels is weak-linked on its own — the app's iOS 18 / macOS 15
// targets launch fine without it (checked in the research spike: the binary
// carries it as LC_LOAD_WEAK_DYLIB, no linker flags) — as long as every use
// sits behind `#available(iOS 26.0, macOS 26.0, *)`. Both platforms, always:
// `*` alone matches macOS 15 too.

// MARK: - What the model writes

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedNote {
    @Guide(description: "The number of the problem this note rewrites, from the numbered list")
    var fact: Int
    @Guide(description: "That problem rewritten as one short sentence to the traveller, keeping its place names and numbers exactly as written")
    var message: String
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedReview {
    @Guide(description: "One honest sentence about the plan as a whole")
    var verdict: String
    @Guide(description: "One note per problem, most important first", .maximumCount(5))
    var notes: [GeneratedNote]
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedPick {
    @Guide(description: "The candidate's number from the list")
    var number: Int
    @Guide(description: "Why it suits this traveller and day, one sentence under 20 words")
    var why: String
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedPicks {
    @Guide(description: "Different candidates, best first", .count(1...5))
    var picks: [GeneratedPick]
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedAsk {
    @Guide(description: "The number of a day the traveller names, such as 3 for Day 3 or the third day; 0 when they don't name one")
    var day: Int
    @Guide(description: "Numbers of the stops they want to be near, from the numbered stops; empty for the whole day", .maximumCount(4))
    var stops: [Int]
    @Guide(description: "The kind of place to search a map for, one or two plain words each, such as coffee, bookshop, rooftop bar or museum", .count(1...3))
    var searches: [String]
}

// MARK: - The advisor

/// Apple's on-device model, through Foundation Models. It only ranks and
/// words: the facts come from `PlanCheck` and the places from
/// `SuggestionCandidates`, and answers refer to them by number. Nothing leaves
/// the device.
///
/// Thin and untested like `WeatherKitProvider` — everything worth testing is
/// in the value types either side of it. `-TripAdvisorProbe YES` (Debug) runs
/// it on a made-up trip at launch.
@available(iOS 26.0, macOS 26.0, *)
public struct FoundationModelsTripAdvisor: TripAdvising {
    // The first run on a Mac, told only to "keep the problem's numbers",
    // wrote "Colosseum and Borghese Gallery on Day 1." for a 30-minute
    // overlap and filed one problem's words under another's number —
    // `PlanReview.isFaithful` now throws such notes out, and this asks for
    // every name and number outright.
    static let reviewInstructions = """
        You help a traveller fix problems in their trip plan before they go. \
        Every numbered problem was checked and is real, so never say a problem needs no change. \
        Write at most one note per problem, most important first, each with the number of the problem it rewrites. \
        A note rewrites only its own problem, as one short, friendly sentence: keep every place name and every number \
        from that problem exactly as written, and bring in nothing from other problems. \
        Use only what you are given: never invent opening hours, prices, places or travel times. \
        The verdict is one honest sentence about the whole plan.
        """

    static let pickInstructions = """
        You pick up to five places for a traveller to save as ideas for their trip, only from the numbered candidates. \
        Use only numbers from the list, each at most once. \
        Prefer places that add something the day doesn't have yet. \
        For each pick, say in one sentence under 20 words why it suits this traveller and day, \
        and give every pick a different reason — what the place is and what it adds — mentioning the weather for at most one. \
        Never invent opening hours, prices or facts about a place beyond its name and kind.
        """

    // Numbers and kinds only, never names: asked for searches, a model will
    // happily write "Colosseum coffee" or "Rome museums", and Apple Maps
    // treats every extra word as something the place must match.
    static let askInstructions = """
        You turn a traveller's request for places into a map search. Answer only with numbers from the lists you are given. \
        Day: the number of a day they name; 0 when they say this day, today, or name no day. \
        Stops: the numbers of stops they want to be near — for example the afternoon's stops when they say afternoon, \
        or a stop they name; leave it empty to search around the whole day. \
        Searches: what kind of place they want, as one to three plain search words of one or two words each, \
        such as coffee, bakery, bookshop, rooftop bar, museum, viewpoint. \
        Never put a city, a stop's name, a time or a description in a search.
        """

    public init() {}

    public var availability: TripAdvisorAvailability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.supportsLocale() ? .available : .unsupportedLanguage
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .notEnabled
            case .modelNotReady: return .notReady
            case .deviceNotEligible: return .deviceNotEligible
            @unknown default: return .deviceNotEligible
            }
        }
    }

    public func prewarm() {
        guard availability == .available else { return }
        LanguageModelSession(instructions: Instructions(Self.reviewInstructions)).prewarm()
    }

    public func review(_ brief: TripBrief) -> AsyncThrowingStream<TripReviewDraft, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let prompt = await Self.fittedPrompt(for: brief).text
                    let session = LanguageModelSession(instructions: Instructions(Self.reviewInstructions))
                    let stream = session.streamResponse(
                        to: Prompt(prompt),
                        generating: GeneratedReview.self,
                        options: GenerationOptions(temperature: 0.2)
                    )
                    var last = TripReviewDraft()
                    for try await snapshot in stream {
                        last = TripReviewDraft(
                            verdict: snapshot.content.verdict,
                            notes: (snapshot.content.notes ?? []).compactMap { note in
                                guard let fact = note.fact, let message = note.message, !message.isEmpty else { return nil }
                                return TripReviewDraft.Note(fact: fact, message: message)
                            }
                        )
                        continuation.yield(last)
                    }
                    last.isComplete = true
                    continuation.yield(last)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func pickPlaces(candidates: SuggestionCandidates, context: String) async throws -> [PlacePick] {
        guard !candidates.isEmpty else { return [] }
        let session = LanguageModelSession(instructions: Instructions(Self.pickInstructions))
        let prompt = "\(context)\n\nCandidates:\n\(candidates.promptList)"
        let picks = try await session.respond(
            to: Prompt(prompt),
            generating: GeneratedPicks.self,
            options: GenerationOptions(temperature: 0.3)
        ).content
        return picks.picks.map { PlacePick(number: $0.number, why: $0.why) }
    }

    public func readAsk(_ ask: SuggestionAsk) async throws -> AskReading {
        let session = LanguageModelSession(instructions: Instructions(Self.askInstructions))
        let reading = try await session.respond(
            to: Prompt(ask.prompt),
            generating: GeneratedAsk.self,
            options: GenerationOptions(temperature: 0)
        ).content
        return AskReading(day: reading.day, stops: reading.stops, searches: reading.searches)
    }

    // MARK: - Fitting the context

    /// The brief cut to fit what the model can read with room to answer — see
    /// `TripBrief.promptBudget`. From 26.4 the model counts the instructions,
    /// schema and prompt itself, and the brief is cut again if the estimate
    /// was short; before that, `TripBrief.estimatedTokens` stands alone.
    static func fittedPrompt(for brief: TripBrief) async -> (text: String, budget: Int) {
        let model = SystemLanguageModel.default
        var budget = TripBrief.promptBudget(contextSize: model.contextSize)
        var text = brief.prompt(maxTokens: budget)
        if #available(iOS 26.4, macOS 26.4, *) {
            if let instructions = try? await model.tokenCount(for: Instructions(reviewInstructions)),
               let schema = try? await model.tokenCount(for: GeneratedReview.generationSchema) {
                budget = TripBrief.promptBudget(contextSize: model.contextSize, overhead: instructions + schema)
                text = brief.prompt(maxTokens: budget)
            }
            // `prompt(maxTokens:)` trims by the estimate; when the real count
            // runs over, aim the estimate lower by however far off it was.
            var target = budget
            for _ in 0..<3 {
                guard let counted = try? await model.tokenCount(for: Prompt(text)), counted > budget else { break }
                let estimated = TripBrief.estimatedTokens(text)
                target = max(64, target * estimated / max(counted, 1) - 32)
                text = brief.prompt(maxTokens: target)
            }
        }
        return (text, budget)
    }

    /// "431 tokens counted by the model, … budget 2,580", for the Debug probe:
    /// what `review` would actually send for `brief`.
    static func fittedPromptReport(for brief: TripBrief) async -> String {
        let model = SystemLanguageModel.default
        let (text, budget) = await fittedPrompt(for: brief)
        var counted = "not counted (before 26.4)"
        if #available(iOS 26.4, macOS 26.4, *), let tokens = try? await model.tokenCount(for: Prompt(text)) {
            counted = "\(tokens) tokens counted by the model"
        }
        let facts = text.split(separator: "\n").count { $0.first?.isNumber == true }
        return "\(counted), ~\(TripBrief.estimatedTokens(text)) estimated, \(facts) of \(brief.facts.count) facts kept, budget \(budget)"
    }

    /// "available · AFM 3 Core · 4096 tokens", for the Debug probe.
    public static var modelDescription: String {
        let model = SystemLanguageModel.default
        var parts = ["\(model.availability)"]
        if #available(iOS 27.0, macOS 27.0, *) {
            parts.append(model.variant.displayName)
        }
        parts.append("\(model.contextSize) tokens")
        parts.append("supportsLocale: \(model.supportsLocale())")
        return parts.joined(separator: " · ")
    }
}
