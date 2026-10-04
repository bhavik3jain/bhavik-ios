import Foundation
import FoundationModels

// FoundationModels is weak-linked on its own — the app's iOS 18 / macOS 15
// targets launch fine without it, as Trips found — as long as every use sits
// behind `#available(iOS 26.0, macOS 26.0, *)`. Both platforms, always: `*`
// alone matches macOS 15 too.

// MARK: - What the model writes

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedFinanceNote {
    @Guide(description: "The number of the fact this note rewrites, from the numbered list")
    var fact: Int
    @Guide(description: "That fact rewritten as one short, friendly sentence, keeping every amount, percentage, count and name exactly as written")
    var message: String
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedFinanceReview {
    @Guide(description: "One or two sentences on the period as a whole, using only amounts written in the facts")
    var headline: String
    @Guide(description: "One note per fact that isn't marked headline, most important first", .maximumCount(10))
    var notes: [GeneratedFinanceNote]
}

// MARK: - The advisor

/// Apple's on-device model, through Foundation Models. It only ranks and
/// words: every fact comes from `MonthCheck`/`YearCheck` through
/// `ReportBrief`, and answers refer to them by number. Nothing leaves the
/// device.
///
/// Thin and untested like Trips' `FoundationModelsTripAdvisor` — everything
/// worth testing is in the value types either side of it.
/// `-FinanceAdvisorProbe YES` (Debug) runs it on the seeded household.
@available(iOS 26.0, macOS 26.0, *)
public struct FoundationModelsFinanceAdvisor: FinanceAdvising {
    // Written from Trips' lessons with the same model: told only to "keep
    // the numbers", it dropped some and mixed others between facts, and left
    // to judge it called real problems fine — so every figure and name is
    // asked for outright, each note stays inside its own fact, and nothing
    // is to be waved away. `ReportReview.isFaithful` throws out what slips.
    static let reviewInstructions = """
        You help a household understand its own finances for one period. \
        Every numbered fact was worked out from the household's figures and is true, so never say a fact doesn't matter. \
        The headline is one or two plain sentences on the period as a whole, built from the facts marked headline and the most important others, \
        using only amounts written in the facts. \
        Then write at most one note per fact not marked headline, most important first, each with the number of the fact it rewrites. \
        A note rewrites only its own fact as one short, friendly sentence: keep every amount, percentage, count and name from that fact \
        exactly as written, and bring in nothing from other facts. Word facts marked "to try" as a suggestion for next time. \
        Never invent numbers or work out new ones. \
        Never give investment advice: never suggest buying, selling or moving money between investments.
        """

    static let answerInstructions = """
        You answer a household's question about its own finances for one period, in one to three short sentences, \
        using only the figures and facts you are given. Quote amounts exactly as written; never work out new numbers. \
        If the figures don't answer the question, say that the report doesn't show it. \
        Never give investment advice: never suggest buying, selling or moving money between investments.
        """

    public init() {}

    public var availability: FinanceAdvisorAvailability {
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

    public func review(_ brief: ReportBrief) -> AsyncThrowingStream<ReportReviewDraft, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let prompt = await Self.fittedPrompt(for: brief, includeFigures: false).text
                    let session = LanguageModelSession(instructions: Instructions(Self.reviewInstructions))
                    let stream = session.streamResponse(
                        to: Prompt(prompt),
                        generating: GeneratedFinanceReview.self,
                        options: GenerationOptions(temperature: 0.2)
                    )
                    var last = ReportReviewDraft()
                    for try await snapshot in stream {
                        last = ReportReviewDraft(
                            headline: snapshot.content.headline,
                            notes: (snapshot.content.notes ?? []).compactMap { note in
                                guard let fact = note.fact, let message = note.message, !message.isEmpty else { return nil }
                                return ReportReviewDraft.Note(fact: fact, group: brief.fact(numbered: fact)?.group, message: message)
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

    public func answer(question: String, brief: ReportBrief) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let facts = await Self.fittedPrompt(for: brief, includeFigures: true, question: question).text
                    let session = LanguageModelSession(instructions: Instructions(Self.answerInstructions))
                    let stream = session.streamResponse(
                        to: Prompt("\(facts)\n\nQuestion: \(Self.clip(question))"),
                        options: GenerationOptions(temperature: 0.2)
                    )
                    for try await snapshot in stream {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A pasted paragraph as a question shouldn't crowd out the figures.
    static func clip(_ question: String) -> String {
        let flat = question.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > 300 ? String(flat.prefix(299)) + "…" : flat
    }

    // MARK: - Fitting the context

    /// The brief cut to fit what the model can read with room to answer — see
    /// `ReportBrief.promptBudget`. From 26.4 the model counts the
    /// instructions, schema and prompt itself, and the brief is cut again if
    /// the estimate was short; before that, `ReportBrief.estimatedTokens`
    /// stands alone. The same steps as Trips' `fittedPrompt`.
    static func fittedPrompt(for brief: ReportBrief, includeFigures: Bool, question: String = "") async -> (text: String, budget: Int) {
        let model = SystemLanguageModel.default
        let questionTokens = ReportBrief.estimatedTokens(question) + 8
        var budget = ReportBrief.promptBudget(contextSize: model.contextSize) - questionTokens
        var text = brief.prompt(maxTokens: budget, includeFigures: includeFigures)
        if #available(iOS 26.4, macOS 26.4, *) {
            let instructions = includeFigures ? answerInstructions : reviewInstructions
            if let instructionTokens = try? await model.tokenCount(for: Instructions(instructions)) {
                var overhead = instructionTokens
                if !includeFigures, let schema = try? await model.tokenCount(for: GeneratedFinanceReview.generationSchema) {
                    overhead += schema
                }
                budget = ReportBrief.promptBudget(contextSize: model.contextSize, overhead: overhead) - questionTokens
                text = brief.prompt(maxTokens: budget, includeFigures: includeFigures)
            }
            // `prompt(maxTokens:)` trims by the estimate; when the real count
            // runs over, aim the estimate lower by however far off it was.
            var target = budget
            for _ in 0..<3 {
                guard let counted = try? await model.tokenCount(for: Prompt(text)), counted > budget else { break }
                let estimated = ReportBrief.estimatedTokens(text)
                target = max(64, target * estimated / max(counted, 1) - 32)
                text = brief.prompt(maxTokens: target, includeFigures: includeFigures)
            }
        }
        return (text, budget)
    }

    /// "512 tokens counted by the model, … budget 2,696", for the Debug
    /// probe: what `review` would actually send for `brief`.
    static func fittedPromptReport(for brief: ReportBrief) async -> String {
        let model = SystemLanguageModel.default
        let (text, budget) = await fittedPrompt(for: brief, includeFigures: false)
        var counted = "not counted (before 26.4)"
        if #available(iOS 26.4, macOS 26.4, *), let tokens = try? await model.tokenCount(for: Prompt(text)) {
            counted = "\(tokens) tokens counted by the model"
        }
        let facts = text.split(separator: "\n").count { $0.first?.isNumber == true }
        return "\(counted), ~\(ReportBrief.estimatedTokens(text)) estimated, \(facts) of \(brief.facts.count) facts kept, budget \(budget)"
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
