import Core
import CoreData
import CoreLocation
import MapKit
import SwiftUI

/// Every place in a guide on one map, with the reader's own position shown as
/// the standard blue dot so "what's near me" can be read off it.
///
/// This is the only screen in the module that uses location. Permission is
/// asked for when it first opens — not at launch, not when a guide is created —
/// and updates stop the moment it closes, because the `.task` that reads them
/// is cancelled with the view.
struct GuideMapView: View {
    let guide: SharedGuide

    @Environment(\.openURL) private var openURL
    @State private var filter: PlaceCategory?
    @State private var selectedID: NSManagedObjectID?
    @State private var position: MapCameraPosition = .automatic
    @State private var userPoint: GeoPoint?
    @State private var detailPlace: SharedGuidePlace?
    @State private var showsWeather = false
    @State private var locationManager = CLLocationManager()

    private var mapped: [SharedGuidePlace] {
        guide.allPlaces.filter { $0.point != nil }
    }

    private var visible: [SharedGuidePlace] {
        guard let filter else { return mapped }
        return mapped.filter { $0.category == filter }
    }

    private var selected: SharedGuidePlace? {
        guard let selectedID else { return nil }
        return mapped.first { $0.objectID == selectedID }
    }

    private var region: GuideRegion? {
        GuideRegion.enclosing(mapped.compactMap(\.point))
    }

    var body: some View {
        Map(position: $position, selection: $selectedID) {
            UserAnnotation()
            ForEach(visible) { place in
                if let point = place.point {
                    Marker(place.name, systemImage: place.category.symbolName, coordinate: point.coordinate)
                        .tint(place.category.tint)
                        .tag(place.objectID)
                }
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        // The user's dot takes the environment tint, which inside the module
        // is magenta — it read as one more pin rather than the standard blue
        // "you are here". Tinting `UserAnnotation` itself has no effect; the
        // pins carry their own tints, so resetting the map's is safe.
        .tint(.blue)
        .safeAreaInset(edge: .top) {
            filterChips
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if let selected {
                    PlaceMapCard(
                        place: selected,
                        estimate: estimate(to: selected),
                        directions: { openDirections(to: selected) },
                        details: { detailPlace = selected }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                // The toolbar chip's temperature needs Apple's credit on the
                // same screen; shown only while the chip has a reading, so a
                // failed fetch leaves no stray "Apple Weather" over the map.
                if showsWeather {
                    WeatherAttributionView()
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .animation(.snappy, value: selectedID)
        .navigationTitle(guide.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                GuideWeatherChip(point: region?.center, hasReading: $showsWeather)
            }
        }
        .navigationDestination(item: $detailPlace) { place in
            PlaceDetailView(place: place)
        }
        .onChange(of: filter) { _, _ in
            // A filter that hides the selected place must also close its card,
            // or the card describes a pin that is no longer on the map.
            if let selected, !visible.contains(selected) {
                selectedID = nil
            }
        }
        .onAppear {
            if let region {
                position = .region(region.coordinateRegion)
            }
        }
        .task {
            await followUser()
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip(title: "All \(mapped.count)", isSelected: filter == nil) { filter = nil }
                ForEach(PlaceCategory.allCases) { category in
                    chip(title: category.shortName, isSelected: filter == category) {
                        filter = filter == category ? nil : category
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
    }

    private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    isSelected ? AnyShapeStyle(ExploreTrackerModule.accent.color) : AnyShapeStyle(.regularMaterial),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Distance is worked out here, in Swift, from the latest fix — it depends
    /// on where the reader is standing, so it can never be a stored value or a
    /// query.
    private func estimate(to place: SharedGuidePlace) -> WalkingEstimate? {
        guard let userPoint, let point = place.point else { return nil }
        return WalkingEstimate(from: userPoint, to: point)
    }

    private func openDirections(to place: SharedGuidePlace) {
        PlaceDirections.open(place, walking: estimate(to: place)?.prefersWalkingDirections ?? false, openURL: openURL)
    }

    private func followUser() async {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        do {
            for try await update in CLLocationUpdate.liveUpdates() {
                if let location = update.location {
                    userPoint = GeoPoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                }
            }
        } catch {
            // Denied, restricted or unavailable: the map simply has no blue dot
            // and the card no walking time.
        }
    }
}

/// The card that rises from the bottom when a pin is tapped.
struct PlaceMapCard: View {
    let place: SharedGuidePlace
    let estimate: WalkingEstimate?
    let directions: () -> Void
    let details: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: place.category.symbolName)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(place.category.tint, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(place.note.isEmpty ? place.category.displayName : "\(place.category.displayName) · \(place.note)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                PlaceStatusBadge(place: place)
            }

            if let estimate {
                Label(estimate.summary(), systemImage: "figure.walk")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(action: directions) {
                    Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .frame(maxWidth: .infinity)
                }
                .primaryActionStyle(tint: ExploreTrackerModule.accent.color)
                .controlSize(.large)

                Button("Details", action: details)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

extension PlaceCategory {
    var tint: Color {
        switch self {
        case .foodAndDrinks: .orange
        case .places: ExploreTrackerModule.accent.color
        case .activities: .teal
        }
    }
}
