import Core
import CoreData
import SwiftUI

/// The Mac's inspector beside a trip's Plan: every idea not yet on a day, the
/// ones closest to the selected day's stops first, each one click (or one
/// drag) from going on it.
///
/// On the phone Ideas is its own face of the trip, because there's no room
/// for two; on a desktop the plan and what could still go on it are the two
/// halves of one decision and belong side by side.
struct TripIdeasInspector: View {
    @ObservedObject var trip: SharedTrip
    let day: Int
    let weather: [DayWeather]
    let canEdit: Bool
    let present: (TripSheet) -> Void

    @Environment(\.managedObjectContext) private var modelContext
    @Environment(\.tripAdvisor) private var advisor
    @Environment(\.tripAdvisorEnabled) private var advisorEnabled
    @Environment(\.placeSearcher) private var searcher

    // Fetched rather than read off `trip.items` alone, so an idea added or
    // moved on another device — or dropped here — re-ranks straight away: the
    // trip never hears about a change to one of its items' `dayIndex`.
    @FetchRequest private var items: FetchedResults<SharedItineraryItem>
    @State private var isDropTargeted = false
    /// The day "Suggest Places" was clicked for; nil until then. Searching
    /// only on a click — MapKit throttles — and a different day selected on
    /// the plan clears it, cancelling a run still going.
    @State private var suggestionsDay: Int?
    @State private var suggestions: PlaceSuggester.Outcome?
    /// The request field, as in the phone's Suggest Places sheet: what's
    /// typed, what was submitted (nil for the usual lists), and the line
    /// under it once a request has run. Only while the model can run.
    @State private var askText = ""
    @State private var ask: String?
    @State private var askNote: String?

    init(trip: SharedTrip, day: Int, weather: [DayWeather], canEdit: Bool, present: @escaping (TripSheet) -> Void) {
        self.trip = trip
        self.day = day
        self.weather = weather
        self.canEdit = canEdit
        self.present = present
        _items = FetchRequest(fetchRequest: SharedItineraryItem.fetchRequest(
            predicate: NSPredicate(format: "trip == %@", trip),
            sortDescriptors: [NSSortDescriptor(keyPath: \SharedItineraryItem.sortOrder, ascending: true)]
        ))
    }

    private var dayName: String {
        trip.dates.dayIndex(of: .now) == day ? "today" : "Day \(day + 1)"
    }

    var body: some View {
        let ideas = PlanIdeas(ideas: Array(items), stops: items.filter { $0.dayIndex == day })
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header(count: ideas.count)

                if ideas.count == 0 {
                    Text("No ideas yet. Save somewhere you might go, and decide on the day.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                if !ideas.closest.isEmpty {
                    caption(day == trip.dates.dayIndex(of: .now) ? "Closest to today's plan" : "Closest to Day \(day + 1)'s plan")
                    VStack(spacing: 8) {
                        ForEach(ideas.closest) { match in
                            card(match)
                        }
                    }
                }

                if !ideas.elsewhere.isEmpty || !ideas.unplaced.isEmpty {
                    caption(ideas.isMeasured ? "Elsewhere" : "Ideas")
                        .padding(.top, ideas.closest.isEmpty ? 0 : 6)
                    if !ideas.isMeasured, !ideas.elsewhere.isEmpty {
                        Text("Nothing on \(dayName) has a place yet, so there's nothing to measure from.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 2) {
                        ForEach(ideas.elsewhere) { match in
                            compactRow(match.item, trailing: match.estimate?.distanceText())
                        }
                        ForEach(ideas.unplaced) { item in
                            compactRow(item, trailing: "No address", isWarning: true)
                        }
                    }
                }

                if canEdit, advisor.availability(isEnabled: advisorEnabled).offersAssistant {
                    suggestionsSection
                        .padding(.top, 6)
                }

                if canEdit {
                    Text("Drag an idea onto the plan to schedule it, or drag a planned stop here to take it off its day.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(isDropTargeted ? AnyShapeStyle(TripTrackerModule.accent.color.opacity(0.08)) : AnyShapeStyle(.clear))
        .onChange(of: day) {
            suggestionsDay = nil
            suggestions = nil
            ask = nil
            askNote = nil
        }
        // A request only counts while the model can run: turning the setting
        // off with one showing goes back to the usual lists.
        .task(id: SuggestionsRun(day: suggestionsDay, ask: advisor.availability(isEnabled: advisorEnabled) == .available ? ask : nil)) {
            await suggest()
        }
        .dropDestination(for: ItineraryItemDrag.self) { drags, _ in
            guard canEdit else { return false }
            return drop(drags)
        } isTargeted: {
            isDropTargeted = canEdit && $0
        }
    }

    // MARK: - Suggestions

    @ViewBuilder
    private var suggestionsSection: some View {
        let availability = advisor.availability(isEnabled: advisorEnabled)
        caption("Suggestions")
        if availability == .available {
            HStack(spacing: 6) {
                TextField(SuggestionsNote.askPlaceholder, text: $askText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
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
                    .help("Clear request")
                }
            }
            if let askNote {
                Text(askNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        if suggestionsDay == nil {
            Button {
                suggestionsDay = day
            } label: {
                Label("Suggest Places near \(dayName)", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(TripTrackerModule.accent.color)
        } else if let suggestions {
            if suggestions.suggestions.isEmpty {
                Text("Apple Maps found nothing new near \(dayName).")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(suggestions.sections) { section in
                    Label(section.group.title, systemImage: section.group.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    VStack(spacing: 8) {
                        ForEach(section.suggestions) { suggestion in
                            suggestionCard(suggestion)
                        }
                    }
                }
                Text(SuggestionsNote.footer(usedModel: suggestions.usedModel, availability: availability))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(SuggestionsNote.progress(availability: availability))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func suggestionCard(_ suggestion: PlaceSuggestion) -> some View {
        let accent = TripTrackerModule.accent.color
        let existing = SharedItineraryItem.existing(suggestion, in: trip)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: suggestion.place.kind.symbolName)
                    .font(.system(size: 13))
                    .foregroundStyle(accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.place.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    let detail = SuggestionsNote.detail(for: suggestion)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    if suggestion.isModelPick {
                        Text(suggestion.why)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            if let existing {
                Label(existing.isUnassigned ? "In Ideas" : "On Day \(existing.dayIndex + 1)", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    suggestionButton("Add to Ideas") { add(suggestion, to: SharedItineraryItem.unassignedDayIndex) }
                    suggestionButton("Add to Day \(day + 1)") { add(suggestion, to: day) }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.7)))
    }

    private func suggestionButton(_ title: String, action: @escaping () -> Void) -> some View {
        let accent = TripTrackerModule.accent.color
        return Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(accent)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    /// What a run depends on: changing either starts it again.
    private struct SuggestionsRun: Hashable {
        let day: Int?
        let ask: String?
    }

    /// Submitting a request runs it straight away, no "Suggest Places" click
    /// needed; an empty one goes back to the usual lists.
    private func submitAsk() {
        let trimmed = askText.trimmingCharacters(in: .whitespacesAndNewlines)
        ask = trimmed.isEmpty ? nil : trimmed
        if ask == nil {
            askNote = nil
        } else {
            suggestionsDay = day
        }
    }

    private func suggest() async {
        guard let requested = suggestionsDay else { return }
        suggestions = nil
        let availability = advisor.availability(isEnabled: advisorEnabled)
        let byDay = TripForecast.byDay(weather, dates: trip.dates)
        if availability == .available, let ask {
            // Any failure is the usual lists with a line saying so.
            let asked = await PlaceSuggester.suggest(
                asking: ask, trip: trip, openDay: requested, weather: byDay, searcher: searcher, advisor: advisor
            )
            guard !Task.isCancelled, suggestionsDay == requested else { return }
            if let asked {
                askNote = asked.summary
                suggestions = asked.outcome
                return
            }
            askNote = SuggestionsNote.unreadableAsk
        } else {
            askNote = nil
        }
        guard let request = SuggestionRequest(trip: trip, day: requested, weather: byDay) else {
            suggestions = PlaceSuggester.Outcome(sections: [])
            return
        }
        // The model only when it can run and the setting is on; otherwise
        // nothing is sent to it and these are the nearest places.
        let outcome = await PlaceSuggester.suggest(
            for: request,
            searcher: searcher,
            advisor: availability == .available ? advisor : nil
        )
        guard !Task.isCancelled, suggestionsDay == requested else { return }
        suggestions = outcome
    }

    private func add(_ suggestion: PlaceSuggestion, to target: Int) {
        withAnimation {
            _ = SharedItineraryItem.add(suggestion, to: trip, in: modelContext, day: target)
        }
        try? modelContext.saveIfNeeded()
        trip.objectWillChange.send()
    }

    // MARK: - Pieces

    private func header(count: Int) -> some View {
        HStack(spacing: 8) {
            Text("Ideas")
                .font(.system(size: 14, weight: .bold))
            Text("\(count) not on a day")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            if canEdit {
                Button {
                    present(.newItem(day: SharedItineraryItem.unassignedDayIndex))
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add an idea")
                .help("Add an idea")
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(.secondary)
    }

    private func card(_ match: PlanIdeas.Match) -> some View {
        let accent = TripTrackerModule.accent.color
        return HStack(spacing: 10) {
            Button {
                present(.item(match.item))
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: match.item.kind.symbolName)
                        .font(.system(size: 13))
                        .foregroundStyle(accent)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(match.item.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if let detail = match.detail() {
                            Text(detail)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if canEdit {
                Button("Add to Day \(day + 1)") {
                    withAnimation { match.item.move(toDay: day) }
                    try? modelContext.saveIfNeeded()
                    trip.objectWillChange.send()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(accent)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.7)))
        .draggableItinerary(match.item, enabled: canEdit)
    }

    private func compactRow(_ item: SharedItineraryItem, trailing: String?, isWarning: Bool = false) -> some View {
        Button {
            present(.item(item))
        } label: {
            HStack {
                Text(item.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 12))
                        .foregroundStyle(isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .draggableItinerary(item, enabled: canEdit)
    }

    private func drop(_ drags: [ItineraryItemDrag]) -> Bool {
        let moved = withAnimation {
            ItineraryDrop.move(drags, toDay: SharedItineraryItem.unassignedDayIndex, in: trip)
        }
        guard moved else { return false }
        try? modelContext.saveIfNeeded()
        trip.objectWillChange.send()
        return true
    }
}

extension View {
    /// Lets a stop or idea be dragged between the plan and the Ideas
    /// inspector. Only on the Mac: on the phone a long press already opens the
    /// row's menu, and there is no second pane to drag to.
    func draggableItinerary(_ item: SharedItineraryItem, enabled: Bool = true) -> some View {
        modifier(ItineraryDraggable(item: item, enabled: enabled))
    }
}

private struct ItineraryDraggable: ViewModifier {
    let item: SharedItineraryItem
    let enabled: Bool
    @Environment(\.moduleLayout) private var layout

    func body(content: Content) -> some View {
        if enabled, layout == .sidebar {
            content.draggable(ItineraryItemDrag(item)) {
                Label(item.title, systemImage: item.kind.symbolName)
                    .padding(8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
            }
        } else {
            content
        }
    }
}
