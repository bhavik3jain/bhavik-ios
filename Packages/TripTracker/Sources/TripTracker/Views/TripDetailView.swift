import Core // Only reached on macOS, where Core stands in for the iOS-only SwiftUI API below.
import CoreData
import SwiftUI

/// The three faces of one trip.
enum TripSection: String, CaseIterable, Identifiable {
    case plan
    case map
    case codes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plan: "Plan"
        case .map: "Map"
        case .codes: "Codes"
        }
    }
}

/// What the trip screen can present over itself.
enum TripSheet: Identifiable {
    case newItem(day: Int)
    case item(ItineraryItem)
    case newFlight(day: Int)
    case flight(Flight)
    case newBooking
    case booking(Booking)
    case editTrip

    var id: String {
        switch self {
        case .newItem(let day): "new-item-\(day)"
        case .item(let item): "item-\(item.objectID.hashValue)"
        case .newFlight(let day): "new-flight-\(day)"
        case .flight(let flight): "flight-\(flight.objectID.hashValue)"
        case .newBooking: "new-booking"
        case .booking(let booking): "booking-\(booking.objectID.hashValue)"
        case .editTrip: "edit-trip"
        }
    }
}

struct TripDetailView: View {
    // NSManagedObject conforms to `ObservableObject`, not the newer `Observable`
    // macro protocol `@Bindable` requires on this SDK (it's `unavailable` for
    // ObservableObject types here) — `@ObservedObject` is Core Data's actual
    // equivalent, and nothing below binds through `$trip` anyway.
    @ObservedObject var trip: Trip

    // A segmented control rather than a nested TabView: the module's tab bar is
    // already on screen, and a second bar of tabs inside a pushed screen reads as
    // somewhere else to go rather than another view of the same trip.
    @State private var section: TripSection = .plan
    @State private var selectedDay: Int
    @State private var weather: [DayWeather] = []
    @State private var sheet: TripSheet?

    init(trip: Trip) {
        self.trip = trip
        _selectedDay = State(initialValue: TripDates.initialDay(for: trip))
    }

    var body: some View {
        Group {
            switch section {
            case .plan:
                TripPlanView(trip: trip, selectedDay: $selectedDay, weather: weather) { sheet = $0 }
            case .map:
                TripMapView(trip: trip) { sheet = $0 }
            case .codes:
                TripCodesView(trip: trip) { sheet = $0 }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Pinned above whichever face is showing, so switching never scrolls the
        // header away and the map can still run edge to edge beneath it.
        .safeAreaInset(edge: .top, spacing: 0) {
            header
        }
        // The title is drawn big in the header, so the bar's copy is removed
        // rather than shown twice; it stays set for the back menu and the window.
        .navigationTitle(trip.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ShareLink(
                    item: ItineraryFile(document: ItineraryDocument(trip: trip)),
                    preview: SharePreview("\(trip.title) itinerary", image: Image(systemName: "doc.richtext"))
                ) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share trip as PDF")

                Menu {
                    Button {
                        sheet = .newItem(day: selectedDay)
                    } label: {
                        Label("Add to Plan", systemImage: "mappin.and.ellipse")
                    }
                    Button {
                        sheet = .newFlight(day: selectedDay)
                    } label: {
                        Label("Add Flight", systemImage: "airplane")
                    }
                    Button {
                        sheet = .newBooking
                    } label: {
                        Label("Add Booking", systemImage: "ticket")
                    }
                    Divider()
                    Button {
                        sheet = .editTrip
                    } label: {
                        Label("Edit Trip", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add to this trip")
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .newItem(let day):
                ItemEditorView(trip: trip, item: nil, day: day)
            case .item(let item):
                ItemEditorView(trip: trip, item: item, day: item.dayIndex)
            case .newFlight(let day):
                FlightEditorView(trip: trip, flight: nil, day: day)
            case .flight(let flight):
                FlightEditorView(trip: trip, flight: flight, day: flight.dayIndex)
            case .newBooking:
                BookingEditorView(trip: trip, booking: nil)
            case .booking(let booking):
                BookingEditorView(trip: trip, booking: booking)
            case .editTrip:
                TripEditorView(trip: trip)
            }
        }
        .loadsWeather(for: trip, into: $weather)
        .onChange(of: trip.dates.dayCount) { _, count in
            // A shortened trip must not leave the strip pointing past its end.
            selectedDay = min(selectedDay, count - 1)
        }
    }

    private var header: some View {
        let dates = trip.dates
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(trip.title)
                    .font(.title)
                    .fontWeight(.bold)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text([trip.destination, ItineraryFormat.dateRange(dates)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let dayOfTrip = TripOverview.dayOfTrip(dates) {
                        Text(dayOfTrip)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(TripTrackerModule.accent.color)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(TripTrackerModule.accent.color.opacity(0.14), in: Capsule())
                    }
                }
            }

            Picker("Section", selection: $section) {
                ForEach(TripSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}
