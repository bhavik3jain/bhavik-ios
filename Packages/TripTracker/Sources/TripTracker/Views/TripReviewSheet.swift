import Core
import CoreData
import SwiftUI

/// Review Plan: `PlanCheck`'s findings with their one-tap fixes, always —
/// and, when "Apple Intelligence in Trips" is on and the model can run, a
/// streamed one-line verdict on top and the model's wording of each finding.
///
/// The check is worked out afresh on every redraw, so a fix applied here drops
/// its finding at once; the model's notes are tied to findings by number
/// through the brief they were written from (`PlanReview`), so a note whose
/// finding is gone goes with it. Nothing is stored: close the sheet and the
/// review is gone, and closing it cancels the stream.
struct TripReviewSheet: View {
    @ObservedObject var trip: SharedTrip
    let weather: [DayWeather]
    /// The day the plan was on — a trip longer than a week is reviewed by the
    /// model a week at a time, the week holding this day.
    let focusDay: Int
    let canEdit: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @Environment(\.tripAdvisor) private var advisor
    @Environment(\.tripAdvisorEnabled) private var isEnabled

    @State private var brief: TripBrief?
    @State private var draft: TripReviewDraft?
    @State private var phase: ReviewHeadline.Phase = .waiting

    private var byDay: [DayWeather?] { TripForecast.byDay(weather, dates: trip.dates) }

    var body: some View {
        let availability = advisor.availability(isEnabled: isEnabled)
        let check = PlanCheck(trip: trip, weather: byDay)
        let review = PlanReview(check: check, brief: brief, draft: draft)
        let headline = ReviewHeadline(availability: availability, phase: phase, verdict: review.verdict)

        NavigationStack {
            List {
                headlineSection(headline)

                if review.entries.isEmpty {
                    Section {
                        Label("Nothing to fix", systemImage: "checkmark.circle")
                            .foregroundStyle(TripTrackerModule.accent.color)
                    } footer: {
                        Text("No overlaps, no walks longer than the time between stops, no overloaded days, and nothing outdoors under a rainy forecast.")
                    }
                }

                ForEach(review.days, id: \.dayIndex) { day in
                    Section {
                        ForEach(day.entries) { entry in
                            ReviewRow(entry: entry, canEdit: canEdit, apply: apply)
                        }
                    } header: {
                        Text("Day \(day.dayIndex + 1) · \(IdeaDays.dayLabel(day.dayIndex, dates: trip.dates))")
                    }
                }

                if !canEdit, !review.entries.isEmpty {
                    Section {
                    } footer: {
                        Text("This trip is shared with you to view, so its fixes can't be applied from here.")
                    }
                }
            }
            .animation(.default, value: review.entries.map(\.id))
            .navigationTitle("Review Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Keyed on availability, so a model that finishes downloading while the
        // sheet is open starts writing, and one switched off mid-review clears.
        // Cancelled when the sheet closes, which ends the model's stream too.
        .task(id: availability) {
            await streamReview(availability: availability)
        }
    }

    @ViewBuilder
    private func headlineSection(_ headline: ReviewHeadline) -> some View {
        switch headline {
        case .none:
            EmptyView()
        case .footnote(let text):
            Section {
            } footer: {
                Text(text)
            }
        case .writing:
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Reading your plan…")
                        .foregroundStyle(.secondary)
                }
            }
        case .verdict(let text, let isFinal):
            Section {
                Label {
                    Text(text)
                        .fontWeight(.medium)
                } icon: {
                    Image(systemName: "sparkles")
                        .foregroundStyle(TripTrackerModule.accent.color)
                }
            } footer: {
                if isFinal {
                    Text("Written on this device by Apple Intelligence. The findings and fixes come from checking the plan itself.")
                }
            }
        }
    }

    private func streamReview(availability: TripAdvisorAvailability) async {
        guard availability == .available else {
            brief = nil
            draft = nil
            phase = .waiting
            return
        }
        let check = PlanCheck(trip: trip, weather: byDay)
        let brief = TripBrief(
            trip: trip,
            check: check,
            weather: byDay,
            days: TripBrief.reviewRange(dayCount: trip.dates.dayCount, focusDay: focusDay)
        )
        self.brief = brief
        draft = nil
        phase = .streaming
        do {
            for try await snapshot in advisor.review(brief) {
                guard !Task.isCancelled else { return }
                draft = snapshot
            }
            guard !Task.isCancelled else { return }
            phase = .finished
        } catch {
            // Any failure — guardrails, a context overflow, the model going
            // away — is the plan check's own words, never an alert.
            guard !Task.isCancelled else { return }
            draft = nil
            phase = .failed
        }
    }

    private func apply(_ fix: PlanCheck.Fix) {
        withAnimation { fix.apply() }
        try? context.saveIfNeeded()
        // Moving an item changes the item, which the trip never hears about;
        // without this the finding sat there after its fix until the sheet
        // was reopened.
        trip.objectWillChange.send()
    }
}

/// One finding: what kind, what's wrong, and the fixes Swift worked out.
private struct ReviewRow: View {
    let entry: PlanReview.Entry
    let canEdit: Bool
    let apply: (PlanCheck.Fix) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.finding.kind.symbolName)
                .font(.subheadline)
                .foregroundStyle(TripTrackerModule.accent.color)
                .frame(width: 30, height: 30)
                .background(TripTrackerModule.accent.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 6) {
                Text(entry.finding.kind.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text(entry.message)
                    .fixedSize(horizontal: false, vertical: true)

                if !entry.finding.fixes.isEmpty {
                    // Bordered, so each fix is its own tap target inside the
                    // row rather than the whole row firing the first one.
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(entry.finding.fixes) { fix in
                            Button {
                                apply(fix)
                            } label: {
                                Label(fix.title, systemImage: fix.sendsToIdeas ? "lightbulb" : "calendar.badge.plus")
                                    .multilineTextAlignment(.leading)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(TripTrackerModule.accent.color)
                            .disabled(!canEdit)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
