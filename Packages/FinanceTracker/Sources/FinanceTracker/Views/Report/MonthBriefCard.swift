import Core
import SwiftUI

/// The Summary's "<Month> in brief", under the net-worth card: the review's
/// headline, how many things went well, are worth watching and are worth
/// trying, and the way into the review and the full report — with a ••• menu
/// to write the review again, saying when it was written.
///
/// Which card, if any, is `FinanceAdvisorAvailability.reviewCardStyle`'s
/// call (tested there): Apple Intelligence's card with its sparkle where the
/// model can run, the plain "<Month> check" — same counts, same buttons, the
/// check's own headline — where it can't, and nothing where the person
/// turned it off.
struct MonthBriefCard: View {
    let model: ReportReviewModel
    let availability: FinanceAdvisorAvailability
    let readReview: () -> Void
    let openReport: () -> Void

    var body: some View {
        switch availability.reviewCardStyle {
        case .hidden:
            EmptyView()
        case .assistant:
            content(isAssistant: true)
        case .plainCheck:
            content(isAssistant: false)
        }
    }

    private func content(isAssistant: Bool) -> some View {
        let name = model.scope.shortTitle
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if isAssistant {
                    Image(systemName: "sparkles")
                        .foregroundStyle(ReviewStyle.intelligence)
                }
                Text(isAssistant ? "\(name) in brief" : "\(name) check")
                    .font(.headline)
                Spacer()
                if isAssistant {
                    Text("Apple Intelligence")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // A menu, not a third button beside Read Review and Open
                    // Report. Borderless, so in a list row it's its own tap
                    // target rather than the row's.
                    Menu {
                        WriteReviewAgainSection(model: model)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .imageScale(.large)
                            .foregroundStyle(.secondary)
                            .contentShape(.rect)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Review Options")
                }
            }

            if let headline = headline(isAssistant: isAssistant) {
                Text(headline)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            } else {
                ReviewPlaceholderRow(lines: [0.95, 0.85, 0.4])
            }

            let counts = model.counts
            if counts.total > 0 {
                HStack(spacing: 6) {
                    chip(counts.wentWell, "went well", color: ReviewStyle.color(for: .wentWell))
                    chip(counts.watch, "to watch", color: ReviewStyle.color(for: .watch))
                    chip(counts.tryNext, "to try", color: ReviewStyle.color(for: .tryNext))
                }
            }

            // Bordered styles, so in a list row each button is its own tap
            // target instead of the row firing both.
            HStack(spacing: 10) {
                Button(action: readReview) {
                    Text("Read Review")
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(action: openReport) {
                    // One line: at large sizes the label wrapped under its
                    // icon and the button stood taller than Read Review.
                    Label("Open Report", systemImage: "doc.text")
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .tint(FinanceTrackerModule.accent.color)
        }
        .animation(.default, value: model.review.headline)
    }

    /// The model's headline once it has one, the check's otherwise; nil —
    /// placeholders — only while the model is writing its first words.
    private func headline(isAssistant: Bool) -> String? {
        guard isAssistant else { return model.plainReview.headline }
        let review = model.review
        if model.isWriting, !review.isHeadlineWrittenByModel { return nil }
        return review.headline
    }

    @ViewBuilder
    private func chip(_ count: Int, _ label: String, color: Color) -> some View {
        if count > 0 {
            Text("\(count) \(label)")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(color.opacity(0.14), in: Capsule())
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}
