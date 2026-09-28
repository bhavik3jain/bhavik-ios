import Core
import CoreData
import SwiftUI

/// The faces of one trip. Titles are one short word each: five of them share
/// a segmented control the width of an iPhone.
///
/// Public so the Mac sidebar and Overview can open a trip on a given face —
/// the Overview's nearby-ideas tile opens straight onto Nearby.
public enum TripSection: String, CaseIterable, Identifiable, Sendable {
    case plan
    case ideas
    case nearby
    case map
    case codes

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .plan: "Plan"
        case .ideas: "Ideas"
        case .nearby: "Nearby"
        case .map: "Map"
        case .codes: "Codes"
        }
    }
}

/// What the trip screen can present over itself.
enum TripSheet: Identifiable {
    case newItem(day: Int)
    case item(SharedItineraryItem)
    case newFlight(day: Int)
    case flight(SharedFlight)
    case newBooking
    case booking(SharedBooking)
    case editTrip
    /// Review Plan: the plan check, and the model's verdict when it's on.
    case review
    /// Suggest Places around a day's stops, or the whole trip when nil.
    case suggestions(day: Int?)

    var id: String {
        switch self {
        case .newItem(let day): "new-item-\(day)"
        case .item(let item): "item-\(item.objectID.hashValue)"
        case .newFlight(let day): "new-flight-\(day)"
        case .flight(let flight): "flight-\(flight.objectID.hashValue)"
        case .newBooking: "new-booking"
        case .booking(let booking): "booking-\(booking.objectID.hashValue)"
        case .editTrip: "edit-trip"
        case .review: "review"
        case .suggestions(let day): "suggestions-\(day ?? -1)"
        }
    }
}

struct TripDetailView: View {
    // NSManagedObject conforms to `ObservableObject`, not the newer `Observable`
    // macro protocol `@Bindable` requires on this SDK (it's `unavailable` for
    // ObservableObject types here) — `@ObservedObject` is Core Data's actual
    // equivalent, and nothing below binds through `$trip` anyway.
    @ObservedObject var trip: SharedTrip

    // A segmented control rather than a nested TabView: the module's tab bar is
    // already on screen, and a second bar of tabs inside a pushed screen reads as
    // somewhere else to go rather than another view of the same trip.
    //
    // Held outside when the Mac sidebar opened the trip, so the Overview can
    // open it on a given face; here otherwise.
    private let externalSection: Binding<TripSection>?
    @State private var ownSection: TripSection = .plan
    private var section: TripSection { externalSection?.wrappedValue ?? ownSection }
    private var sectionBinding: Binding<TripSection> { externalSection ?? $ownSection }
    @State private var selectedDay: Int
    @State private var weather: [DayWeather] = []
    @State private var sheet: TripSheet?

    @Environment(\.tripPersistentContainer) private var container
    @Environment(\.presentShareSheet) private var presentShareSheet
    @Environment(\.moduleLayout) private var layout
    @Environment(\.tripAdvisor) private var advisor
    @Environment(\.tripAdvisorEnabled) private var advisorEnabled
    /// The Mac's Ideas inspector beside Plan. On by default — the plan and
    /// what could still go on it are the two halves of deciding a day — and
    /// remembered once hidden with ⌥⌘I.
    @AppStorage("trips.showsIdeasInspector") private var showsIdeas = true
    // Sharing status is a cheap, synchronous CloudKit cache lookup (see
    // `SharingStatusResolver`'s own doc comment), not something worth a
    // round trip through `@State` plus a `.task` — read fresh on every body
    // evaluation, the same as `trip.dates` above.
    private var sharingStatus: SharingStatus {
        guard let container else { return .notShared }
        return SharingStatusResolver.status(for: trip, in: container)
    }
    private var canEdit: Bool {
        guard let container else { return true }
        return SharingStatusResolver.canEdit(trip, in: container)
    }

    init(trip: SharedTrip, section: Binding<TripSection>? = nil) {
        self.trip = trip
        externalSection = section
        _selectedDay = State(initialValue: TripDates.initialDay(for: trip))
    }

    /// Only on the Mac, only beside Plan: Ideas, Nearby and the rest are
    /// already about ideas or have no day to add them to.
    private var inspectorPresented: Binding<Bool> {
        Binding {
            layout == .sidebar && section == .plan && showsIdeas
        } set: { shown in
            // The inspector reports itself closed when switching away from
            // Plan hides it; that mustn't be remembered as a choice.
            if layout == .sidebar, section == .plan { showsIdeas = shown }
        }
    }

    var body: some View {
        Group {
            switch section {
            case .plan:
                TripPlanView(trip: trip, selectedDay: $selectedDay, weather: weather) { sheet = $0 }
            case .ideas:
                TripIdeasView(trip: trip) { sheet = $0 }
            case .nearby:
                if layout == .sidebar {
                    // A desktop has the width for both: where the ideas are
                    // beside how far each one is. On the phone Map is its own
                    // face, a tap away.
                    HStack(spacing: 0) {
                        TripMapView(trip: trip) { sheet = $0 }
                        Divider()
                        TripNearbyView(trip: trip) { sheet = $0 }
                            .frame(width: 380)
                    }
                } else {
                    TripNearbyView(trip: trip) { sheet = $0 }
                }
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
            // The Mac has no header: the toolbar carries the title, the
            // subtitle and the section picker, and a second title under the
            // toolbar's own read as a double.
            if layout == .tabs {
                header
            }
        }
        // The title is drawn big in the header, so the bar's copy is removed
        // rather than shown twice; it stays set for the back menu and the window.
        .navigationTitle(trip.title)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(TripTitleChrome(subtitle: subtitle))
        .modifier(IdeasInspectorChrome(isPresented: inspectorPresented) {
            TripIdeasInspector(trip: trip, day: selectedDay, weather: weather, canEdit: canEdit) { sheet = $0 }
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        })
        .toolbar {
            if layout == .sidebar {
                ToolbarItem(placement: .principal) {
                    Picker("Section", selection: sectionBinding) {
                        ForEach(TripSection.allCases) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if section == .plan {
                    ToolbarItem(placement: .primaryAction) {
                        reviewButton
                            .help("Check this trip's plan for overlaps, tight walks and busy days")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            withAnimation { showsIdeas.toggle() }
                        } label: {
                            Label(showsIdeas ? "Hide Ideas" : "Show Ideas", systemImage: "sidebar.trailing")
                        }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                        .help("Show or hide this trip's ideas (⌥⌘I)")
                    }
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                ShareLink(
                    item: ItineraryFile(document: ItineraryDocument(trip: trip)),
                    preview: SharePreview("\(trip.title) itinerary", image: Image(systemName: "doc.richtext"))
                ) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share trip as PDF")

                Button {
                    if let container {
                        presentShareSheet(ShareSheetRequest(object: trip, container: container))
                    }
                } label: {
                    Image(systemName: "person.crop.circle.badge.plus")
                }
                .disabled(container == nil)
                .accessibilityLabel("Share trip")

                // The phone keeps Review Plan in the add menu, beside the
                // other things done to the plan; someone who can only view the
                // trip has no add menu, so it gets a button of its own.
                if layout == .tabs, section == .plan, !canEdit {
                    reviewButton
                }

                if canEdit {
                    Menu {
                        if layout == .tabs, section == .plan {
                            reviewButton
                            Divider()
                        }
                        Button {
                            sheet = .newItem(day: selectedDay)
                        } label: {
                            Label("Add to Plan", systemImage: "mappin.and.ellipse")
                        }
                        Button {
                            sheet = .newItem(day: SharedItineraryItem.unassignedDayIndex)
                        } label: {
                            Label("Add Idea", systemImage: "lightbulb")
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
            case .review:
                TripReviewSheet(trip: trip, weather: weather, focusDay: selectedDay, canEdit: canEdit)
            case .suggestions(let day):
                PlaceSuggestionsSheet(trip: trip, weather: weather, canEdit: canEdit, scope: day.map(SuggestionScope.day) ?? .trip)
            }
        }
        // Loads the model while the plan is being read, so a Review Plan tap
        // gets its first words sooner (the research spike: first text in 1.4 s
        // prewarmed against 3.4 s cold). Only when the setting is on and the
        // model can run — off means nothing reaches the model at all.
        .task(id: section == .plan && advisor.availability(isEnabled: advisorEnabled) == .available) {
            if section == .plan, advisor.availability(isEnabled: advisorEnabled) == .available {
                advisor.prewarm()
            }
        }
        .loadsWeather(for: trip, into: $weather)
        .onChange(of: trip.dates.dayCount) { _, count in
            // A shortened trip must not leave the strip pointing past its end.
            selectedDay = min(selectedDay, count - 1)
        }
    }

    /// Sparkles only when the model is part of it: with the setting off, or
    /// no Apple Intelligence here, Review Plan is the plain check and says so
    /// with a plain checklist.
    private var reviewButton: some View {
        Button {
            sheet = .review
        } label: {
            Label(
                "Review Plan",
                systemImage: advisor.availability(isEnabled: advisorEnabled).offersAssistant ? "sparkles" : "checklist"
            )
        }
        .accessibilityLabel("Review Plan")
    }

    /// "Italy · 6–14 Jun · Day 3 of 9 · Shared with Saloni" — what the phone's
    /// header says under the title, as one line for the Mac's toolbar.
    private var subtitle: String {
        let dates = trip.dates
        return [trip.destination, ItineraryFormat.dateRange(dates), TripOverview.dayOfTrip(dates) ?? "", sharingStatus.tripBadgeLabel ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
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
                    if let label = sharingStatus.tripBadgeLabel {
                        Label(label, systemImage: "person.2.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Picker("Section", selection: sectionBinding) {
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

/// The phone draws the trip's title big in its own header, so the navigation
/// bar's copy goes; the Mac keeps the toolbar's title and puts the header's
/// second line under it as a subtitle.
/// The Ideas inspector exists only in the Mac's sidebar layout. Attached on the
/// phone too, even never presented, it froze every trip: opening one re-ran
/// TripDetailView's body in a loop at 100% CPU until the watchdog killed the
/// app (0x8BADF00D), on TestFlight build 14.
private struct IdeasInspectorChrome<Inspector: View>: ViewModifier {
    let isPresented: Binding<Bool>
    @ViewBuilder let inspector: () -> Inspector
    @Environment(\.moduleLayout) private var layout

    func body(content: Content) -> some View {
        switch layout {
        case .tabs: content
        case .sidebar: content.inspector(isPresented: isPresented, content: inspector)
        }
    }
}

private struct TripTitleChrome: ViewModifier {
    let subtitle: String
    @Environment(\.moduleLayout) private var layout

    func body(content: Content) -> some View {
        switch layout {
        case .tabs: content.toolbar(removing: .title)
        case .sidebar: content.moduleSubtitle(subtitle)
        }
    }
}
