import Core
import CoreData
import SwiftUI

/// A trip's ideas: places it might get to that aren't on a day yet — the
/// game-time decisions. Each can be moved onto a day, and back again from the
/// item editor.
struct TripIdeasView: View {
    let trip: SharedTrip
    let present: (TripSheet) -> Void

    @Environment(\.managedObjectContext) private var modelContext
    @Environment(\.tripPersistentContainer) private var container

    // Fetched, not read off `trip.items`: moving an idea onto a day changes
    // the item's `dayIndex`, which the trip — the only object this screen
    // would otherwise be watching — never hears about, so the row stayed put
    // until something else redrew the screen.
    @FetchRequest private var ideas: FetchedResults<SharedItineraryItem>

    init(trip: SharedTrip, present: @escaping (TripSheet) -> Void) {
        self.trip = trip
        self.present = present
        _ideas = FetchRequest(fetchRequest: SharedItineraryItem.fetchRequest(
            predicate: NSPredicate(format: "trip == %@ AND dayIndex < 0", trip),
            sortDescriptors: [
                NSSortDescriptor(keyPath: \SharedItineraryItem.sortOrder, ascending: true),
                NSSortDescriptor(keyPath: \SharedItineraryItem.title, ascending: true),
            ]
        ))
    }

    // A read-only shared participant sees the ideas but can't add, move, edit
    // or delete them — the same gate as the plan's rows and the add menu.
    private var canEdit: Bool {
        guard let container else { return true }
        return SharingStatusResolver.canEdit(trip, in: container)
    }

    /// In kind order, the same order the editor's Kind picker lists them.
    private var groups: [(kind: ItemKind, items: [SharedItineraryItem])] {
        ItemKind.allCases.compactMap { kind in
            let matching = ideas.filter { $0.kind == kind }
            return matching.isEmpty ? nil : (kind, matching)
        }
    }

    var body: some View {
        if ideas.isEmpty {
            ContentUnavailableView {
                Label("No ideas yet", systemImage: "lightbulb")
            } description: {
                Text("Somewhere you might go but haven't given a day — a restaurant a friend mentioned, a museum for if it rains. Keep them here, see which are close by in Nearby, and move one onto a day when you decide.")
            } actions: {
                if canEdit {
                    Button("Add an Idea") { present(.newItem(day: SharedItineraryItem.unassignedDayIndex)) }
                }
            }
        } else {
            TimelineView(.everyMinute) { context in
                list(now: context.date)
            }
        }
    }

    private func list(now: Date) -> some View {
        let dates = trip.dates
        let choices = IdeaDays.choices(for: dates, asOf: now)
        let today = dates.dayIndex(of: now)

        return List {
            if canEdit {
                Section {
                    Button {
                        present(.newItem(day: SharedItineraryItem.unassignedDayIndex))
                    } label: {
                        Label("Add an idea", systemImage: "plus.circle")
                    }
                } footer: {
                    Text("Not on any day yet. Move one onto a day when you decide, or see which are close by in Nearby.")
                }
            }

            ForEach(groups, id: \.kind) { group in
                Section(group.kind.displayName) {
                    ForEach(group.items) { item in
                        IdeaRow(item: item, choices: canEdit ? choices : [], move: { move(item, to: $0) }) {
                            present(.item(item))
                        }
                        .swipeActions(edge: .leading) {
                            if canEdit, let today {
                                Button {
                                    move(item, to: today)
                                } label: {
                                    Label("Today", systemImage: "calendar.badge.plus")
                                }
                                .tint(TripTrackerModule.accent.color)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            if canEdit {
                                Button(role: .destructive) {
                                    delete(item)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .contextMenu {
                            if canEdit {
                                moveMenu(for: item, choices: choices)
                                Button {
                                    present(.item(item))
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    delete(item)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func moveMenu(for item: SharedItineraryItem, choices: [IdeaDays.Choice]) -> some View {
        Menu {
            ForEach(choices) { choice in
                Button(choice.title) { move(item, to: choice.dayIndex) }
            }
        } label: {
            Label("Move to Day", systemImage: "calendar.badge.plus")
        }
    }

    private func move(_ item: SharedItineraryItem, to day: Int) {
        withAnimation { item.move(toDay: day) }
        try? modelContext.saveIfNeeded()
    }

    private func delete(_ item: SharedItineraryItem) {
        modelContext.delete(item)
        try? modelContext.saveIfNeeded()
    }
}

/// One idea: what it is, where, and a menu to put it on a day.
struct IdeaRow: View {
    @ObservedObject var item: SharedItineraryItem
    /// Empty for a read-only participant, which hides the menu.
    let choices: [IdeaDays.Choice]
    let move: (Int) -> Void
    let open: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: open) {
                HStack(alignment: .center, spacing: 12) {
                    IdeaIcon(kind: item.kind)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .fontWeight(.semibold)
                        subtitle
                    }
                    Spacer(minLength: 6)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if !choices.isEmpty {
                Menu {
                    Section("Move to") {
                        ForEach(choices) { choice in
                            Button(choice.title) { move(choice.dayIndex) }
                        }
                    }
                } label: {
                    Image(systemName: "calendar.badge.plus")
                        .font(.body)
                        .foregroundStyle(TripTrackerModule.accent.color)
                        .frame(width: 36, height: 36)
                        .contentShape(.rect)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .accessibilityLabel("Move \(item.title) to a day")
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var subtitle: some View {
        let parts = [item.detail, item.address].filter { !$0.isEmpty }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        if !item.hasCoordinate {
            Label("No place yet", systemImage: "mappin.slash")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// The kind's symbol on a tinted tile — the ideas' and Nearby's leading mark.
struct IdeaIcon: View {
    let kind: ItemKind

    var body: some View {
        Image(systemName: kind.symbolName)
            .font(.subheadline)
            .foregroundStyle(TripTrackerModule.accent.color)
            .frame(width: 34, height: 34)
            .background(TripTrackerModule.accent.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
    }
}
