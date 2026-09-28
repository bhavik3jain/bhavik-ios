import Core
import CoreData
import SwiftUI

/// The trip's ideas that have a place, nearest first, measured from the person
/// or from one day's plan — "we've got an hour, what's close?".
struct TripNearbyView: View {
    let trip: SharedTrip
    let present: (TripSheet) -> Void

    @Environment(\.managedObjectContext) private var modelContext
    @Environment(\.tripPersistentContainer) private var container
    @Environment(\.locationProvider) private var locationProvider
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.tripAdvisor) private var advisor
    @Environment(\.tripAdvisorEnabled) private var advisorEnabled

    // All of the trip's items, not just its ideas: a day's stops are what
    // "Near Day N" measures from. Fetched rather than read off `trip.items` so
    // an idea added to a day here drops out of the list straight away — the
    // trip never hears about a change to one of its items' `dayIndex`.
    @FetchRequest private var items: FetchedResults<SharedItineraryItem>

    /// Nil until the first lookup finishes.
    @State private var lookup: LocationLookup?
    @State private var isLocating = false
    /// What the person picked; nil follows `NearbyIdeas.suggestedOrigin`.
    @State private var chosen: NearbyOrigin?

    init(trip: SharedTrip, present: @escaping (TripSheet) -> Void) {
        self.trip = trip
        self.present = present
        _items = FetchRequest(fetchRequest: SharedItineraryItem.fetchRequest(
            predicate: NSPredicate(format: "trip == %@", trip),
            sortDescriptors: [NSSortDescriptor(keyPath: \SharedItineraryItem.sortOrder, ascending: true)]
        ))
    }

    private var canEdit: Bool {
        guard let container else { return true }
        return SharingStatusResolver.canEdit(trip, in: container)
    }

    /// "Find more around Day N" only where the model runs or soon could, with
    /// the setting on — and only for someone who can add what it finds.
    private var offersSuggestions: Bool {
        canEdit && advisor.availability(isEnabled: advisorEnabled).offersAssistant
    }

    private var location: GeoCoordinate? {
        if case .located(let point) = lookup { return point }
        return nil
    }

    private var ideas: [SharedItineraryItem] {
        items.filter(\.isUnassigned)
    }

    /// Whether any idea has a place to measure to — the only time a location
    /// fix is worth asking for.
    private var hasPlacedIdea: Bool {
        ideas.contains(where: \.hasCoordinate)
    }

    var body: some View {
        let ideas = self.ideas
        Group {
            if ideas.isEmpty {
                ContentUnavailableView {
                    Label("No ideas to rank", systemImage: "location.magnifyingglass")
                } description: {
                    Text("Ideas you save for this trip show up here, closest first, with how long each is on foot.")
                } actions: {
                    if canEdit {
                        Button("Add an Idea") { present(.newItem(day: SharedItineraryItem.unassignedDayIndex)) }
                    }
                    if offersSuggestions {
                        Button {
                            present(.suggestions(day: nil))
                        } label: {
                            Label("Suggest Places", systemImage: "sparkles")
                        }
                    }
                }
            } else {
                TimelineView(.everyMinute) { context in
                    list(ideas: ideas, now: context.date)
                }
            }
        }
        // Only asks for location once there's an idea with a place to rank.
        // A plain `.task` fired on "No ideas to rank" too, so the one-time
        // When-In-Use prompt could appear with nothing on screen to justify it
        // — and the permission is app-wide, so refusing it there also cost
        // Explore's map its blue dot and distances. Keyed on the flag so the
        // first placed idea (added here or synced in) starts the lookup.
        .task(id: hasPlacedIdea) {
            if hasPlacedIdea { await locate() }
        }
        // `.task` runs once per appearance, and going to Settings and back
        // isn't one: someone who followed the "allow it in Settings" footer
        // came back to "Location is off" until they left the section. Coming
        // back to the foreground retries a denied lookup instead.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, lookup == .denied, hasPlacedIdea {
                Task { await locate() }
            }
        }
    }

    // MARK: - List

    private func list(ideas: [SharedItineraryItem], now: Date) -> some View {
        let days = NearbyIdeas.daysWithStops(in: trip)
        let origin = effectiveOrigin(days: days, now: now)
        let point = origin.flatMap { NearbyIdeas.point(for: $0, in: trip, location: location) }
        let nearby = point.map { NearbyIdeas(ideas: ideas, from: $0) }
        let unplaced = ideas.filter { !$0.hasCoordinate }
        let target = origin.flatMap { NearbyIdeas.targetDay(for: $0, dates: trip.dates, asOf: now) }
        let choices = IdeaDays.choices(for: trip.dates, asOf: now)

        return List {
            Section {
                originPicker(origin: origin, days: days)
            } footer: {
                locationNote(origin: origin)
            }

            // Around the day being measured from — or today, measuring from
            // the person mid-trip. Measuring from the person any other time
            // has no day, so it looks around the whole trip.
            if offersSuggestions {
                Section {
                    Button {
                        present(.suggestions(day: target))
                    } label: {
                        Label(target.map { "Find More Around Day \($0 + 1)" } ?? "Find More Places", systemImage: "sparkles")
                    }
                }
            }

            if let nearby {
                ForEach(nearby.groups) { group in
                    Section(group.bucket.title) {
                        ForEach(group.suggestions) { suggestion in
                            NearbyRow(
                                item: suggestion.item,
                                estimate: suggestion.estimate,
                                target: target,
                                choices: canEdit ? choices : [],
                                isToday: target != nil && target == trip.dates.dayIndex(of: now),
                                add: { add(suggestion.item, to: $0) },
                                directions: {
                                    TripDirections.open(suggestion.item, walking: suggestion.estimate.prefersWalkingDirections, openURL: openURL)
                                },
                                open: { present(.item(suggestion.item)) }
                            )
                        }
                    }
                }
                if nearby.groups.isEmpty {
                    Section {
                        Text("None of this trip's ideas has a place yet, so there's nothing to measure.")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if unplaced.count < ideas.count {
                Section {
                    Text(isLocating
                         ? "Finding where you are…"
                         : "Nothing to measure from yet. Allow location, or give one of this trip's days a place from the search.")
                        .foregroundStyle(.secondary)
                }
            }

            if !unplaced.isEmpty {
                Section {
                    ForEach(unplaced) { item in
                        Button {
                            present(.item(item))
                        } label: {
                            HStack {
                                Label(item.title, systemImage: "mappin.slash")
                                    .foregroundStyle(.primary)
                                Spacer()
                                if canEdit {
                                    Text("Add place")
                                        .font(.caption)
                                        .foregroundStyle(TripTrackerModule.accent.color)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("No place yet")
                } footer: {
                    Text("Search for a place in the idea's editor to rank it here.")
                }
            }
        }
    }

    // MARK: - Origin

    /// The person's choice while it still makes sense — a fix for "Near me", a
    /// day that still has placed stops — and the suggestion otherwise.
    private func effectiveOrigin(days: [Int], now: Date) -> NearbyOrigin? {
        switch chosen {
        case .me where location != nil:
            return .me
        case .day(let day) where days.contains(day):
            return .day(day)
        default:
            return NearbyIdeas.suggestedOrigin(for: trip, location: location, asOf: now)
        }
    }

    @ViewBuilder
    private func originPicker(origin: NearbyOrigin?, days: [Int]) -> some View {
        if location != nil || !days.isEmpty {
            Picker("Measure from", selection: Binding(
                get: { origin ?? .me },
                set: { chosen = $0 }
            )) {
                if location != nil {
                    Label("Near me", systemImage: "location.fill").tag(NearbyOrigin.me)
                }
                ForEach(days, id: \.self) { day in
                    Text("Near Day \(day + 1) · \(IdeaDays.dayLabel(day, dates: trip.dates))").tag(NearbyOrigin.day(day))
                }
            }
            .pickerStyle(.menu)
            .tint(TripTrackerModule.accent.color)
        }
        HStack {
            if isLocating {
                ProgressView()
                    .controlSize(.small)
                Text("Finding you…")
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await locate() }
                } label: {
                    Label(location == nil ? "Try My Location Again" : "Update My Location", systemImage: "location")
                }
                // Never disabled, even after `.denied`: the provider re-reads
                // the authorization on every call, so this is how a lookup
                // recovers once location is allowed in Settings. Disabling it
                // left no way back short of leaving the section.
            }
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private func locationNote(origin: NearbyOrigin?) -> some View {
        switch lookup {
        case .denied:
            Text("Location is off for Multitrack, so distances are from a day's plan. You can allow it in Settings.")
        case .unavailable:
            Text("Couldn't find where you are just now, so distances are from a day's plan.")
        case .located(let point):
            if case .day = origin, !NearbyIdeas.isAtTrip(point, trip: trip) {
                Text("You're not near this trip yet, so distances are from a day's plan. Straight-line distances; walking times at an easy pace.")
            } else {
                Text("Straight-line distances; walking times at an easy pace.")
            }
        case nil:
            EmptyView()
        }
    }

    private func locate() async {
        guard !isLocating else { return }
        isLocating = true
        lookup = await locationProvider.currentLocation()
        isLocating = false
    }

    private func add(_ item: SharedItineraryItem, to day: Int) {
        withAnimation { item.move(toDay: day) }
        try? modelContext.saveIfNeeded()
    }
}

/// One ranked idea: how far, how long on foot, and what to do about it.
struct NearbyRow: View {
    @ObservedObject var item: SharedItineraryItem
    let estimate: WalkingEstimate
    /// The day "Add" puts it on; nil offers a menu of days instead.
    let target: Int?
    /// Empty for a read-only participant, which hides adding altogether.
    let choices: [IdeaDays.Choice]
    let isToday: Bool
    let add: (Int) -> Void
    let directions: () -> Void
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: open) {
                HStack(alignment: .top, spacing: 12) {
                    IdeaIcon(kind: item.kind)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .fontWeight(.semibold)
                        Text(estimate.summary())
                            .font(.subheadline)
                            .foregroundStyle(TripTrackerModule.accent.color)
                            .monospacedDigit()
                        let parts = [item.detail, item.address].filter { !$0.isEmpty }
                        if !parts.isEmpty {
                            Text(parts.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            // Bordered buttons, so each is its own tap target inside the row
            // rather than the whole row firing the first one.
            HStack(spacing: 8) {
                if !choices.isEmpty {
                    if let target {
                        Button {
                            add(target)
                        } label: {
                            Label(isToday ? "Add to Today" : "Add to Day \(target + 1)", systemImage: "calendar.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Menu {
                            ForEach(choices) { choice in
                                Button(choice.title) { add(choice.dayIndex) }
                            }
                        } label: {
                            Label("Add to Day", systemImage: "calendar.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                Button(action: directions) {
                    Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .frame(maxWidth: choices.isEmpty ? .infinity : nil)
                }
                .buttonStyle(.bordered)
            }
            .font(.subheadline)
            .tint(TripTrackerModule.accent.color)
        }
        .padding(.vertical, 4)
    }
}
