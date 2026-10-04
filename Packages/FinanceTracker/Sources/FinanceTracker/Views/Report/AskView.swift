import Core
import SwiftUI

/// "Ask about <month>": a question box, the questions the check can answer
/// as chips, and the answer streaming in under them.
///
/// The model answers from the brief's figures alone, and `AskReply` checks
/// every snapshot as it arrives: the moment an answer quotes a number the
/// report doesn't have, or reads like investment advice, it's replaced by "I
/// can only answer from this report's figures." and the nearest facts in the
/// check's own words. So nothing this view shows was made up — the view only
/// lays out what `ReportReviewModel.answer` holds.
///
/// Callers show it only where `advisor.availability(isEnabled:)` is
/// `.available`; anywhere else the model would only ever give the fallback.
struct AskView: View {
    let model: ReportReviewModel
    /// The "Ask about September" heading; off where a navigation title
    /// already says it.
    var showsTitle = true

    @Environment(\.financeAdvisor) private var advisor
    @Environment(\.financeAdvisorEnabled) private var isEnabled

    @State private var question = ""
    @State private var asking: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsTitle {
                Text("Ask about \(model.scope.shortTitle)")
                    .font(.headline)
            }

            HStack(spacing: 8) {
                // One line: a vertical field takes Return as a new line, and
                // Return here is "ask".
                TextField("Ask a question", text: $question)
                    .focused($isFocused)
                    .submitLabel(.send)
                    .onSubmit { ask(question) }
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.background.secondary, in: .rect(cornerRadius: 12))
                Button {
                    ask(question)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(trimmed.isEmpty || model.isAnswering)
                .accessibilityLabel("Ask")
            }

            if !model.suggestedQuestions.isEmpty {
                ChipFlow(spacing: 6) {
                    ForEach(model.suggestedQuestions, id: \.self) { suggestion in
                        Button {
                            ask(suggestion)
                        } label: {
                            Text(suggestion)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(FinanceTrackerModule.accent.color.opacity(0.12), in: Capsule())
                                .foregroundStyle(FinanceTrackerModule.accent.color)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isAnswering)
                    }
                }
            }

            if let answer = model.answer {
                AnswerView(answer: answer, isAnswering: model.isAnswering)
            }

            Text("Answers come only from \(model.scope.isYear ? "this year's" : "this month's") figures, worked out by the app. Not investment advice.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Leaving the screen stops the model mid-answer.
        .onDisappear { asking?.cancel() }
    }

    private var trimmed: String { question.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func ask(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isFocused = false
        // The answer card repeats the question, so the field is cleared for
        // the next one rather than left holding this.
        question = ""
        asking?.cancel()
        asking = Task { await model.ask(text, advisor: advisor, enabled: isEnabled) }
    }
}

/// The question asked and its answer: the model's, with its sparkle, or the
/// check's fallback.
private struct AnswerView: View {
    let answer: AskReply
    let isAnswering: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(answer.question)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if answer.text.isEmpty, isAnswering {
                ReviewPlaceholderRow(lines: [0.9, 0.55])
            } else if answer.isWrittenByModel {
                Text(answer.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                // The fallback: its lead, then each fact on its own line
                // rather than run together.
                Text(AskReply.fallbackLead)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(answer.facts, id: \.number) { fact in
                    Label {
                        Text(fact.text)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            if answer.isWrittenByModel {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(ReviewStyle.intelligence)
                    Text(isAnswering ? "Writing…" : "Apple Intelligence, from this report's figures")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .animation(.default, value: answer)
    }
}

/// Chips laid out left to right, wrapping onto new lines — the suggested
/// questions in a narrow inspector as on a phone.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
