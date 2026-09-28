import Core
import CoreData
import MapKit
import SwiftUI

struct GuideDetailView: View {
    @Environment(\.moduleLayout) private var layout
    let guide: SharedGuide

    @Environment(\.managedObjectContext) private var modelContext
    @Environment(\.explorePersistentContainer) private var container
    @Environment(\.presentShareSheet) private var presentShareSheet
    /// Every pin, not just this guide's: there are only ever a handful, and a
    /// fetch keyed on the guide would need building in `init`. Fetched rather
    /// than asked for once so the button follows a pin synced in meanwhile.
    @FetchRequest(sortDescriptors: [])
    private var pinResults: FetchedResults<GuidePin>
    @State private var category: PlaceCategory = .foodAndDrinks
    @State private var showingAddPlace = false
    @State private var showingEdit = false
    @State private var showingMap = false

    private var summary: GuideSummary { GuideSummary.summarize(guide) }
    private var shown: [SharedGuidePlace] { guide.places(in: category) }
    private var isPinned: Bool {
        GuidePins.earliestPinDates(pinResults)[GuidePins.key(for: guide)] != nil
    }

    // Read through `badgeStatus`: this device's last known answer at once,
    // looked up again off the main thread (`SharingStatusCache`). It was a
    // synchronous `fetchShares` on every body evaluation, thought cheap, but it
    // waits on the container's executor — the wait that deadlocked Share.
    private var sharingStatus: SharingStatus {
        guard let container else { return .notShared }
        return SharingStatusResolver.badgeStatus(for: guide, in: container)
    }
    private var canEdit: Bool {
        guard let container else { return true }
        return SharingStatusResolver.canEdit(guide, in: container)
    }

    var body: some View {
        let summary = summary
        List {
            Section {
                if let region = summary.region {
                    VStack(alignment: .leading, spacing: 12) {
                        GuideWeatherCard(point: region.center, caption: summary.weatherCaption)
                        mapPreview(region: region)
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    Text(summary.detailLine)
                    if let label = sharingStatus.guideBadgeLabel {
                        Label(label, systemImage: "person.2.fill")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .textCase(nil)
            }

            Section {
                Picker("Category", selection: $category) {
                    ForEach(PlaceCategory.allCases) { option in
                        Text("\(option.displayName) \(summary.count(of: option))").tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                if shown.isEmpty {
                    // A read-only participant can't add a place either
                    // (AddPlaceView's own Save is gated the same way) — no
                    // point opening a sheet that can't be saved.
                    if canEdit {
                        Button {
                            showingAddPlace = true
                        } label: {
                            Label("Add \(category.displayName.lowercased())", systemImage: "plus")
                        }
                    }
                } else {
                    ForEach(shown) { place in
                        NavigationLink {
                            PlaceDetailView(place: place)
                        } label: {
                            PlaceRow(place: place)
                        }
                        .swipeActions(edge: .leading) {
                            // A read-only participant can't tick a place off
                            // either — same gate as the Add/Edit/Delete
                            // affordances above.
                            if canEdit {
                                Button(place.isTried ? "To try" : "Tried", systemImage: place.isTried ? "arrow.uturn.backward" : "checkmark") {
                                    place.setTried(!place.isTried)
                                    try? modelContext.saveIfNeeded()
                                }
                                .tint(ExploreTrackerModule.accent.color)
                            }
                        }
                    }
                    .onDelete { offsets in
                        // A read-only participant's swipe is silently dropped
                        // rather than hidden — `onDelete` offers the same
                        // gesture to every row, so filtering here (the same
                        // pattern `ArchivedTripsView`/`GarageView` use) is the
                        // only per-row way to withhold it.
                        guard canEdit else { return }
                        let places = shown
                        for index in offsets {
                            modelContext.delete(places[index])
                        }
                        try? modelContext.saveIfNeeded()
                    }
                }
            }
        }
        .navigationTitle(guide.name)
        .toolbar {
            // A read-only participant can't add a place — same reasoning as
            // hiding the empty-state "Add" button above.
            if canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddPlace = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add a place")
                }
            }
            // Out on the bar, as Trips has it. In the ••• menu nobody found it:
            // guide sharing shipped and was asked for again as a new feature.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if let container {
                        presentShareSheet(ShareSheetRequest(object: guide, container: container))
                    }
                } label: {
                    Image(systemName: "person.crop.circle.badge.plus")
                }
                .disabled(container == nil)
                .accessibilityLabel("Share guide")
            }
            if canEdit {
                ToolbarItem(placement: layout.secondaryToolbarPlacement) {
                    Button("Edit Guide", systemImage: "pencil") { showingEdit = true }
                }
            }
            // Deliberately outside the `canEdit` gate: a pin is this person's
            // own private record, so a read-only participant can pin too.
            ToolbarItem(placement: layout.secondaryToolbarPlacement) {
                Button(
                    isPinned ? "Unpin Guide" : "Pin to Top",
                    systemImage: isPinned ? "pin.slash" : "pin"
                ) {
                    GuidePins(context: modelContext, container: container).setPinned(!isPinned, guide)
                    try? modelContext.saveIfNeeded()
                }
            }
        }
        .sheet(isPresented: $showingAddPlace) {
            AddPlaceView(guide: guide, initialCategory: category)
        }
        .navigationDestination(isPresented: $showingMap) {
            GuideMapView(guide: guide)
        }
        .sheet(isPresented: $showingEdit) {
            GuideFormView(guide: guide)
        }
        .onAppear {
            // Open on the first shelf that has anything on it, rather than an
            // empty Food & Drinks in a guide that is all sights.
            if summary.count(of: category) == 0,
               let first = PlaceCategory.allCases.first(where: { summary.count(of: $0) > 0 }) {
                category = first
            }
        }
    }

    private func mapPreview(region: GuideRegion) -> some View {
        GuideMapThumbnail(region: region, points: guide.allPlaces.compactMap(\.point))
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .bottomTrailing) {
                // A button, not a NavigationLink: a link inside a list row turns
                // the whole row — map included — into the link, and draws a
                // disclosure chevron over the map's corner.
                Button {
                    showingMap = true
                } label: {
                    Label("Open map", systemImage: "map")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(10)
            }
    }
}

/// A place in a guide's list: what it is, why it's there, and whether it's
/// been tried.
struct PlaceRow: View {
    let place: SharedGuidePlace

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: place.category.symbolName)
                .font(.subheadline)
                .foregroundStyle(ExploreTrackerModule.accent.color)
                .frame(width: 30, height: 30)
                .background(ExploreTrackerModule.accent.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if !place.note.isEmpty {
                    Text(place.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            PlaceStatusBadge(place: place)
        }
        .padding(.vertical, 2)
    }
}

/// "To try", or once tried its stars — or "Tried" when no rating was given.
struct PlaceStatusBadge: View {
    let place: SharedGuidePlace

    var body: some View {
        if place.isTried, place.rating > 0 {
            RatingStars(rating: place.rating)
                .font(.caption2)
        } else {
            Text(place.isTried ? "Tried" : "To try")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(place.isTried ? AnyShapeStyle(.green) : AnyShapeStyle(ExploreTrackerModule.accent.color))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(place.isTried ? AnyShapeStyle(.green.opacity(0.12)) : AnyShapeStyle(ExploreTrackerModule.accent.color.opacity(0.12)), in: Capsule())
        }
    }
}

struct RatingStars: View {
    let rating: Int

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .foregroundStyle(star <= rating ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(counted(rating, "star"))
    }
}

/// Handing a place to Apple Maps.
enum PlaceDirections {
    /// Walking directions when the place is a walk away, otherwise Maps'
    /// default mode. A place added by hand has no coordinates, so Maps is asked
    /// to find its address instead.
    @MainActor
    static func open(_ place: SharedGuidePlace, walking: Bool, openURL: OpenURLAction) {
        if let point = place.point {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: point.coordinate))
            item.name = place.name
            item.openInMaps(launchOptions: [
                MKLaunchOptionsDirectionsModeKey: walking ? MKLaunchOptionsDirectionsModeWalking : MKLaunchOptionsDirectionsModeDefault
            ])
        } else if let url = searchURL(for: place) {
            openURL(url)
        }
    }

    static func canOpen(_ place: SharedGuidePlace) -> Bool {
        place.point != nil || !place.address.isEmpty
    }

    private static func searchURL(for place: SharedGuidePlace) -> URL? {
        guard !place.address.isEmpty else { return nil }
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "daddr", value: "\(place.name), \(place.address)")]
        return components?.url
    }
}
