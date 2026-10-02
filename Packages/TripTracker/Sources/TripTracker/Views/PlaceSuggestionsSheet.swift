import Core
import CoreData
import SwiftUI

/// Suggest Places: a few real places from Apple Maps around the trip or one
/// day, not already on it — picked and explained by the on-device model when
/// it can run, otherwise simply the nearest. Each goes onto the trip in one
/// tap as an ordinary Idea, or straight onto a day.
///
/// Searches run only because someone opened this (or picked another place to
/// look around): at most `SuggestionRequest.maximumSearches` each time, never
/// per keystroke — MapKit throttles. Closing the sheet cancels the run.
///
/// While the model can run, a field on top takes a request in the person's own
/// words ("coffee near this afternoon's stops"); submitting it swaps the two
/// lists for one list of what was asked for (`SuggestionAsk`), clearing it
/// brings them back. With Apple Intelligence off the field isn't there at all.
struct PlaceSuggestionsSheet: View {
    @ObservedObject var trip: SharedTrip
    let weather: [DayWeather]
    let canEdit: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @Environment(\.tripAdvisor) private var advisor
    @Environment(\.tripAdvisorEnabled) private var isEnabled
    @Environment(\.placeSearcher) private var searcher

    @State private var scope: SuggestionScope
    /// What's being typed; nothing runs until it's submitted.
    @State private var askText = ""
    /// The submitted request, which the lists are for; nil for the usual two.
    @State private var ask: String?
    /// Under the field once a request has run: what was searched for, or that
    /// it couldn't be read and these are the usual lists.
    @State private var askNote: String?
    @State private var outcome: PlaceSuggester.Outcome?
    @State private var isSearching = false
    /// No destination and no placed stop: nowhere to search around.
    @State private var hasNowhereToSearch = false

    init(trip: SharedTrip, weather: [DayWeather], canEdit: Bool, scope: SuggestionScope) {
        self.trip = trip
        self.weather = weather
        self.canEdit = canEdit
        _scope = State(initialValue: scope)
    }

    var body: some View {
        let availability = advisor.availability(isEnabled: isEnabled)
        let scopes = SuggestionScope.choices(for: trip, keeping: scope)

        NavigationStack {
            List {
                if availability == .available {
                    askSection
                }

                if scopes.count > 1 {
                    Section {
                        Picker("Look", selection: $scope) {
                            ForEach(scopes) { choice in
                                Text(choice.title(for: trip)).tag(choice)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(TripTrackerModule.accent.color)
                    }
                }

                if isSearching {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(SuggestionsNote.progress(availability: availability))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if hasNowhereToSearch {
                    Section {
                        Text("Give this trip a destination, or a stop with a place, to find places around it.")
                            .foregroundStyle(.secondary)
                    }
                } else if let outcome {
                    if outcome.suggestions.isEmpty {
                        Section {
                            Text("Apple Maps found nothing new around here — everything nearby is already on the trip, or the search came back empty.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        // Food & Drink, then Places to Check Out: two lists,
                        // each picked on its own.
                        ForEach(outcome.sections) { section in
                            Section {
                                ForEach(section.suggestions) { suggestion in
                                    SuggestionRow(
                                        suggestion: suggestion,
                                        trip: trip,
                                        canEdit: canEdit,
                                        add: { add(suggestion, to: $0) }
                                    )
                                }
                            } header: {
                                Label(section.group.title, systemImage: section.group.symbolName)
                            } footer: {
                                if section.id == outcome.sections.last?.id {
                                    Text(SuggestionsNote.footer(usedModel: outcome.usedModel, availability: availability))
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Suggest Places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // A request only counts while the model can run: turning the setting
        // off with one showing goes back to the usual lists.
        .task(id: Run(scope: scope, ask: availability == .available ? ask : nil)) {
            await suggest(availability: availability)
        }
    }

    /// What a run depends on: changing either starts it again.
    private struct Run: Hashable {
        let scope: SuggestionScope
        let ask: String?
    }

    private var askSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(TripTrackerModule.accent.color)
                TextField(SuggestionsNote.askPlaceholder, text: $askText)
                    .submitLabel(.search)
                    .onSubmit(submitAsk)
                if ask != nil || !askText.isEmpty {
                    Button {
                        askText = ""
                        ask = nil
                        askNote = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear request")
                }
            }
        } footer: {
            if let askNote {
                Text(askNote)
            }
        }
    }

    private func submitAsk() {
        let trimmed = askText.trimmingCharacters(in: .whitespacesAndNewlines)
        ask = trimmed.isEmpty ? nil : trimmed
        if ask == nil { askNote = nil }
    }

    private func suggest(availability: TripAdvisorAvailability) async {
        let byDay = TripForecast.byDay(weather, dates: trip.dates)
        if availability == .available, let ask {
            isSearching = true
            // Any failure — the model refusing, an answer with nothing usable
            // in it — is the usual lists with a line saying so, never an error.
            let asked = await PlaceSuggester.suggest(
                asking: ask, trip: trip, openDay: scope.dayIndex, weather: byDay, searcher: searcher, advisor: advisor
            )
            guard !Task.isCancelled else { return }
            if let asked {
                hasNowhereToSearch = false
                askNote = asked.summary
                outcome = asked.outcome
                isSearching = false
                return
            }
            askNote = SuggestionsNote.unreadableAsk
        } else {
            askNote = nil
        }
        guard let request = SuggestionRequest(trip: trip, day: scope.dayIndex, weather: byDay) else {
            hasNowhereToSearch = true
            outcome = nil
            isSearching = false
            return
        }
        hasNowhereToSearch = false
        isSearching = true
        // The model only when it can run and the person hasn't turned it off:
        // otherwise nothing is sent to it and these are simply the nearest.
        let result = await PlaceSuggester.suggest(
            for: request,
            searcher: searcher,
            advisor: availability == .available ? advisor : nil
        )
        guard !Task.isCancelled else { return }
        outcome = result
        isSearching = false
    }

    private func add(_ suggestion: PlaceSuggestion, to day: Int) {
        withAnimation {
            _ = SharedItineraryItem.add(suggestion, to: trip, in: context, day: day)
        }
        try? context.saveIfNeeded()
        trip.objectWillChange.send()
    }
}

/// One suggested place: what and how far, the model's reason when it gave one,
/// and "Add to Ideas" with the Ideas screen's own day menu beside it. Once the
/// place is on the trip, where it went instead.
struct SuggestionRow: View {
    let suggestion: PlaceSuggestion
    @ObservedObject var trip: SharedTrip
    let canEdit: Bool
    /// A day, or `SharedItineraryItem.unassignedDayIndex` for Ideas.
    let add: (Int) -> Void

    var body: some View {
        let existing = SharedItineraryItem.existing(suggestion, in: trip)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                IdeaIcon(kind: suggestion.place.kind)
                VStack(alignment: .leading, spacing: 3) {
                    Text(suggestion.place.name)
                        .fontWeight(.semibold)
                    let detail = SuggestionsNote.detail(for: suggestion)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(TripTrackerModule.accent.color)
                    }
                    if suggestion.isModelPick {
                        Label(suggestion.why, systemImage: "sparkles")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                    if !suggestion.place.address.isEmpty {
                        Text(suggestion.place.address)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            if let existing {
                Label(existing.isUnassigned ? "In Ideas" : "On Day \(existing.dayIndex + 1)", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if canEdit {
                // Bordered, so each is its own tap target inside the row.
                HStack(spacing: 8) {
                    Button {
                        add(SharedItineraryItem.unassignedDayIndex)
                    } label: {
                        Label("Add to Ideas", systemImage: "lightbulb")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Menu {
                        Section("Add to") {
                            ForEach(IdeaDays.choices(for: trip.dates)) { choice in
                                Button(choice.title) { add(choice.dayIndex) }
                            }
                        }
                    } label: {
                        Label("Add to Day", systemImage: "calendar.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .font(.subheadline)
                .tint(TripTrackerModule.accent.color)
            }
        }
        .padding(.vertical, 4)
    }
}
