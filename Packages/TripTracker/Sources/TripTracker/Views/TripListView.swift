import Core
import CoreData
import SwiftUI

struct TripListView: View {
    @Environment(\.managedObjectContext) private var modelContext
    @Environment(\.tripPersistentContainer) private var container

    // Only the archive flag is filtered in the fetch. The phase can't be: an
    // `NSPredicate` on dates captures "today" when the view is built, so a list
    // left open across midnight would keep a finished trip in progress. The
    // grouping happens in Swift below, fresh on every redraw.
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \SharedTrip.startDate, ascending: true)],
        predicate: NSPredicate(format: "isArchived == NO")
    )
    private var trips: FetchedResults<SharedTrip>
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \SharedTrip.startDate, ascending: false)],
        predicate: NSPredicate(format: "isArchived == YES")
    )
    private var archived: FetchedResults<SharedTrip>

    @State private var showingAdd = false
    @State private var pendingDelete: SharedTrip?

    var body: some View {
        NavigationStack {
            // Re-read the clock once a minute, so "In progress" moves on at
            // midnight without anyone touching the screen.
            TimelineView(.everyMinute) { context in
                content(groups: TripGroups(Array(trips), asOf: context.date), now: context.date)
            }
            .refreshesFromCloud()
            .navigationTitle("Trips")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New trip")
                }
            }
            .sheet(isPresented: $showingAdd) {
                TripEditorView(trip: nil)
            }
            .navigationDestination(for: SharedTrip.self) { trip in
                TripDetailView(trip: trip)
            }
            .confirmationDialog(
                "Delete \(pendingDelete?.title ?? "trip")?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Trip", role: .destructive) {
                    if let trip = pendingDelete {
                        modelContext.delete(trip)
                        try? modelContext.saveIfNeeded()
                    }
                    pendingDelete = nil
                }
            } message: {
                Text("Its plan, flights and codes are deleted with it, on every device. Archive it instead to keep them.")
            }
        }
    }

    @ViewBuilder
    private func content(groups: TripGroups, now: Date) -> some View {
        if groups.isEmpty && archived.isEmpty {
            ContentUnavailableView {
                Label("No trips", systemImage: "suitcase")
            } description: {
                Text("Add a trip and plan its days, pin its places and keep its booking codes in one place.")
            } actions: {
                Button("Add Trip") { showingAdd = true }
                    .primaryActionStyle(tint: TripTrackerModule.accent.color)
            }
        } else {
            List {
                if !groups.inProgress.isEmpty {
                    Section {
                        ForEach(groups.inProgress) { trip in
                            row(for: trip) { InProgressTripCard(trip: trip, now: now) }
                        }
                    } header: {
                        Text("In progress")
                    } footer: {
                        if groups.inProgress.contains(where: \.hasCoordinate) {
                            WeatherAttributionView()
                        }
                    }
                }
                if !groups.upcoming.isEmpty {
                    Section("Upcoming") {
                        ForEach(groups.upcoming) { trip in
                            row(for: trip) { UpcomingTripRow(trip: trip, now: now) }
                        }
                    }
                }
                if !groups.finished.isEmpty {
                    Section("Finished") {
                        ForEach(groups.finished) { trip in
                            row(for: trip) { FinishedTripRow(trip: trip) }
                        }
                    }
                }
                if !archived.isEmpty {
                    Section {
                        NavigationLink {
                            ArchivedTripsView()
                        } label: {
                            LabeledContent("Archived", value: "\(archived.count)")
                        }
                    }
                }
            }
        }
    }

    private func row(for trip: SharedTrip, @ViewBuilder label: () -> some View) -> some View {
        NavigationLink(value: trip) {
            label()
        }
        .swipeActions(edge: .trailing) {
            // Read-only participants get no destructive or archiving swipe at
            // all — same reasoning as hiding the "+" menu in TripDetailView.
            if canEdit(trip) {
                Button(role: .destructive) {
                    pendingDelete = trip
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button {
                    trip.isArchived = true
                    try? modelContext.saveIfNeeded()
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(.indigo)
            }
        }
    }

    private func canEdit(_ trip: SharedTrip) -> Bool {
        guard let container else { return true }
        return SharingStatusResolver.canEdit(trip, in: container)
    }
}

// MARK: - Rows

struct InProgressTripCard: View {
    let trip: SharedTrip
    let now: Date

    @State private var weather: [DayWeather] = []
    @Environment(\.tripPersistentContainer) private var container
    private var sharingLabel: String? {
        guard let container else { return nil }
        return SharingStatusResolver.status(for: trip, in: container).tripBadgeLabel
    }

    var body: some View {
        let dates = trip.dates
        let plan = DayPlan(trip: trip, dayIndex: dates.offset(of: now))
        let today = TripForecast.byDay(weather, dates: dates, asOf: now)[safe: dates.offset(of: now)] ?? nil

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(TripTrackerModule.accent.color)
                    .frame(width: 4)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(trip.title)
                            .font(.headline)
                        if let sharingLabel {
                            Label(sharingLabel, systemImage: "person.2.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(subtitle(dates))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        if let today {
                            Image(systemName: today.symbolName)
                                .symbolRenderingMode(.multicolor)
                                .font(.footnote)
                            Text(WeatherFormat.temperature(today.highCelsius))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                    }

                    ProgressView(value: dates.progress(asOf: now))
                        .tint(TripTrackerModule.accent.color)
                        .padding(.top, 8)

                    HStack(spacing: 0) {
                        Text(TripOverview.dayOfTrip(dates, asOf: now) ?? "")
                            .fontWeight(.semibold)
                            .foregroundStyle(TripTrackerModule.accent.color)
                        if plan.itemCount > 0 {
                            Text(" · \(plan.doneCount) of \(plan.itemCount) done today")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .padding(.top, 4)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            if let next = plan.upNext(asOf: now) {
                Divider()
                    .padding(.leading, 16)
                    .padding(.vertical, 10)
                HStack(spacing: 10) {
                    Text("UP NEXT")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(TripTrackerModule.accent.color)
                    if let start = plan.start(of: next) {
                        Text(ItineraryFormat.time(start))
                            .monospacedDigit()
                    }
                    Text(next.title)
                        .lineLimit(1)
                }
                .font(.subheadline)
                .padding(.leading, 16)
            }
        }
        .padding(.vertical, 6)
        .loadsWeather(for: trip, into: $weather)
    }

    private func subtitle(_ dates: TripDates) -> String {
        [trip.destination, ItineraryFormat.dateRange(dates)].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct UpcomingTripRow: View {
    let trip: SharedTrip
    let now: Date

    @Environment(\.tripPersistentContainer) private var container
    private var sharingLabel: String? {
        guard let container else { return nil }
        return SharingStatusResolver.status(for: trip, in: container).tripBadgeLabel
    }

    var body: some View {
        let dates = trip.dates
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(trip.title)
                        .fontWeight(.semibold)
                    if let sharingLabel {
                        Label(sharingLabel, systemImage: "person.2.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                }
                Text([trip.destination, ItineraryFormat.dateRange(dates), counted(dates.dayCount, "day")]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if trip.hasCoordinate, let from = TripForecast.availableFrom(for: dates, asOf: now) {
                    Text("Forecast from \(from.formatted(.dateTime.day().month(.abbreviated)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                let days = dates.daysUntilStart(asOf: now)
                Text(days == 1 ? "starts" : "starts in")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(days == 1 ? "tomorrow" : counted(days, "day"))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(TripTrackerModule.accent.color)
            }
        }
        .padding(.vertical, 2)
    }
}

struct FinishedTripRow: View {
    let trip: SharedTrip

    @Environment(\.tripPersistentContainer) private var container
    private var sharingLabel: String? {
        guard let container else { return nil }
        return SharingStatusResolver.status(for: trip, in: container).tripBadgeLabel
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(trip.title)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    if let sharingLabel {
                        Label(sharingLabel, systemImage: "person.2.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                }
                Text([trip.destination, trip.startDate.formatted(.dateTime.year())]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !trip.places.isEmpty {
                Text(counted(trip.places.count, "place"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ArchivedTripsView: View {
    @Environment(\.managedObjectContext) private var modelContext
    @Environment(\.tripPersistentContainer) private var container
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \SharedTrip.startDate, ascending: false)],
        predicate: NSPredicate(format: "isArchived == YES")
    )
    private var trips: FetchedResults<SharedTrip>

    var body: some View {
        List {
            ForEach(trips) { trip in
                NavigationLink(value: trip) {
                    FinishedTripRow(trip: trip)
                }
                .swipeActions(edge: .leading) {
                    if canEdit(trip) {
                        Button {
                            trip.isArchived = false
                            try? modelContext.saveIfNeeded()
                        } label: {
                            Label("Unarchive", systemImage: "tray.and.arrow.up")
                        }
                        .tint(TripTrackerModule.accent.color)
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets where canEdit(trips[index]) {
                    modelContext.delete(trips[index])
                }
                try? modelContext.saveIfNeeded()
            }
        }
        .overlay {
            if trips.isEmpty {
                ContentUnavailableView("Nothing archived", systemImage: "archivebox")
            }
        }
        .navigationTitle("Archived")
    }

    private func canEdit(_ trip: SharedTrip) -> Bool {
        guard let container else { return true }
        return SharingStatusResolver.canEdit(trip, in: container)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
