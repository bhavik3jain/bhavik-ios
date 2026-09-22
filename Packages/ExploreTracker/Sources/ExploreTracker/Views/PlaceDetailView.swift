import Core // Only reached on macOS, where Core stands in for the iOS-only SwiftUI API below.
import CoreData
import MapKit
import SwiftUI

/// One place, edited in place: everything the add sheet asked for, plus
/// whether it's been tried and how it was.
struct PlaceDetailView: View {
    // NSManagedObject conforms to `ObservableObject`, not the newer
    // `Observable` macro protocol `@Bindable` requires on this SDK (it's
    // `unavailable` for ObservableObject types here) — `@ObservedObject` is
    // Core Data's actual equivalent.
    @ObservedObject var place: GuidePlace

    @Environment(\.openURL) private var openURL

    private var triedBinding: Binding<Bool> {
        Binding(get: { place.isTried }, set: { place.setTried($0) })
    }

    var body: some View {
        Form {
            if let point = place.point {
                Section {
                    Map(position: .constant(.region(GuideRegion(center: point, latitudeDelta: 0.008, longitudeDelta: 0.008).coordinateRegion)), interactionModes: []) {
                        Marker(place.name, systemImage: place.category.symbolName, coordinate: point.coordinate)
                            .tint(ExploreTrackerModule.accent.color)
                    }
                    .mapStyle(.standard(pointsOfInterest: .excludingAll))
                    .frame(height: 140)
                    .listRowInsets(EdgeInsets())
                    .allowsHitTesting(false)
                }
            }

            Section {
                TextField("Name", text: $place.name)
                Picker("Category", selection: $place.categoryRaw) {
                    ForEach(PlaceCategory.allCases) { category in
                        Label(category.displayName, systemImage: category.symbolName).tag(category.rawValue)
                    }
                }
                TextField("Note", text: $place.note, axis: .vertical)
                    .lineLimit(1...4)
            }

            Section {
                Toggle("Tried", isOn: triedBinding)
                if place.isTried {
                    LabeledContent("Rating") {
                        RatingPicker(rating: $place.rating)
                    }
                    if let triedAt = place.triedAt {
                        LabeledContent("Tried on") {
                            Text(triedAt, format: .dateTime.month().day().year())
                        }
                    }
                }
            }

            Section {
                TextField("Address", text: $place.address, axis: .vertical)
                    .lineLimit(1...3)
                if PlaceDirections.canOpen(place) {
                    Button {
                        PlaceDirections.open(place, walking: false, openURL: openURL)
                    } label: {
                        Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    }
                }
            } footer: {
                if place.point == nil {
                    Text("Added by hand, so it isn't on the guide's map.")
                }
            }
        }
        .navigationTitle(place.name.isEmpty ? "Place" : place.name)
        .navigationBarTitleDisplayMode(.inline)
        // Every field above is bound straight to the object — there is no
        // save button, the way SwiftData's autosave made unnecessary before.
        // Core Data never autosaves, so this is the one point that persists
        // whatever changed while the screen was open.
        .onDisappear {
            try? place.managedObjectContext?.saveIfNeeded()
        }
    }
}

/// Five tappable stars. Tapping the current rating again clears it, so a
/// rating given by mistake can be taken back without un-trying the place.
struct RatingPicker: View {
    @Binding var rating: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    rating = rating == star ? 0 : star
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .foregroundStyle(star <= rating ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(counted(star, "star"))
            }
        }
        .font(.title3)
    }
}
