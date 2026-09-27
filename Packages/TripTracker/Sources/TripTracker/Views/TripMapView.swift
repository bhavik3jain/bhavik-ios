import Core
import CoreData
import MapKit
import SwiftUI

/// This trip's places, and only this trip's. The chips are its days, plus
/// Ideas when it has any with a place.
struct TripMapView: View {
    let trip: SharedTrip
    let present: (TripSheet) -> Void

    @State private var filter: MapDayFilter
    @State private var selection: NSManagedObjectID?
    @State private var position: MapCameraPosition = .automatic

    init(trip: SharedTrip, present: @escaping (TripSheet) -> Void) {
        self.trip = trip
        self.present = present
        _filter = State(initialValue: MapDayFilter.initial(for: trip.dates))
    }

    private var visible: [SharedItineraryItem] {
        (trip.items ?? [])
            .filter(filter.shows)
            .sorted { ($0.dayIndex, $0.sortOrder) < ($1.dayIndex, $1.sortOrder) }
    }

    private var hasPlacedIdeas: Bool {
        trip.ideas.contains(where: \.hasCoordinate)
    }

    private var selectedItem: SharedItineraryItem? {
        guard let selection else { return nil }
        return visible.first { $0.objectID == selection }
    }

    var body: some View {
        if trip.places.isEmpty {
            ContentUnavailableView {
                Label("Nothing on the map yet", systemImage: "map")
            } description: {
                Text("Places you add to the plan by searching for them get a pin here.")
            } actions: {
                Button("Add a Place") {
                    present(.newItem(day: TripDates.initialDay(for: trip)))
                }
            }
        } else {
            Map(position: $position, selection: $selection) {
                ForEach(visible) { item in
                    if let latitude = item.latitude, let longitude = item.longitude {
                        // An idea is a lightbulb in orange, so under All days a
                        // maybe never reads as one more stop on the plan.
                        Marker(item.title, systemImage: item.isUnassigned ? "lightbulb.fill" : item.kind.symbolName, coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
                            .tint(item.isUnassigned ? Color.orange : (item.isDone ? Color.gray : TripTrackerModule.accent.color))
                            .tag(item.objectID)
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                filterChips
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let item = selectedItem {
                    PlaceCard(item: item, dates: trip.dates) {
                        present(.item(item))
                    }
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: selection)
            .onChange(of: filter) {
                // Re-frame on the new set of pins, and drop a selection the
                // filter has just hidden.
                withAnimation { position = .automatic }
                if selectedItem == nil { selection = nil }
            }
        }
    }

    private var filterChips: some View {
        let dates = trip.dates
        let today = dates.dayIndex(of: .now)
        return ScrollView(.horizontal) {
            HStack(spacing: 6) {
                chip("All days", value: .allDays)
                if hasPlacedIdeas || filter == .ideas {
                    chip("Ideas", value: .ideas)
                }
                ForEach(0..<dates.dayCount, id: \.self) { index in
                    chip(index == today ? "Today · Day \(index + 1)" : "Day \(index + 1)", value: .day(index))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ title: String, value: MapDayFilter) -> some View {
        let isSelected = filter == value
        return Button {
            filter = value
        } label: {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isSelected ? AnyShapeStyle(TripTrackerModule.accent.color) : AnyShapeStyle(.regularMaterial),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The card under a tapped pin.
struct PlaceCard: View {
    let item: SharedItineraryItem
    let dates: TripDates
    let details: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.headline)
                        .strikethrough(item.isDone)
                    Text(when)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: item.kind.symbolName)
                    .foregroundStyle(TripTrackerModule.accent.color)
            }
            HStack(spacing: 8) {
                Button {
                    openInMaps()
                } label: {
                    Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(TripTrackerModule.accent.color)

                Button("Details", action: details)
                    .buttonStyle(.bordered)

                Button {
                    withAnimation { item.toggleDone() }
                    // No @Environment context here — PlaceCard is presented
                    // standalone off the map's pin, not through the plan list —
                    // so this saves through the object's own context instead.
                    try? item.managedObjectContext?.saveIfNeeded()
                } label: {
                    Image(systemName: item.isDone ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(item.isDone ? "Mark not visited" : "Mark visited")
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var when: String {
        // An idea has no day to name or to put its time on — "Day 0" and a
        // time on the day before the trip were what -1 produced here.
        if item.isUnassigned {
            return (["Idea · no day yet"] + [item.address].filter { !$0.isEmpty }).joined(separator: " · ")
        }
        var parts = [IdeaDays.shortName(forDay: item.dayIndex, dates: dates)]
        if let start = item.startTime {
            parts.append(ItineraryFormat.time(dates.moment(day: item.dayIndex, time: start)))
        }
        if !item.address.isEmpty { parts.append(item.address) }
        return parts.joined(separator: " · ")
    }

    private func openInMaps() {
        // Only pinned items reach this card, so the URL fallback never runs.
        TripDirections.open(item, walking: false, openURL: openURL)
    }
}
