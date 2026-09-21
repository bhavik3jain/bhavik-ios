import MapKit
import SwiftUI

/// A place picked from search: a name to show, an address line and the
/// coordinate that weather and the map need — nil if the lookup failed, in
/// which case the name and address are still worth keeping.
struct PickedPlace: Equatable {
    var name: String
    var address: String
    var latitude: Double?
    var longitude: Double?
}

/// Type-ahead place search over `MKLocalSearchCompleter`.
///
/// The completer only returns titles; a pick is then resolved through
/// `MKLocalSearch` to get its coordinate. A place typed and never picked keeps
/// no coordinate, which is honest — the app would otherwise be guessing where
/// "the bakery" is.
@MainActor
@Observable
final class PlaceSearch: NSObject, MKLocalSearchCompleterDelegate {
    private(set) var results: [MKLocalSearchCompletion] = []
    private(set) var isResolving = false

    var query = "" {
        didSet {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                completer.cancel()
                results = []
            } else {
                completer.queryFragment = trimmed
            }
        }
    }

    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    /// - Parameters:
    ///   - kinds: `.address` for a destination — cities and regions — and
    ///     `[.address, .pointOfInterest]` for somewhere to go within one.
    ///   - near: biases results towards the trip, so "Da Enzo" finds the one in
    ///     Rome rather than the nearest to wherever the phone is.
    init(kinds: MKLocalSearchCompleter.ResultType, near center: CLLocationCoordinate2D? = nil) {
        super.init()
        completer.resultTypes = kinds
        if let center {
            completer.region = MKCoordinateRegion(center: center, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        }
        completer.delegate = self
    }

    // The completer calls back on the main thread, where it was created. Its
    // results are read from our own reference inside the hop rather than from
    // the parameter, which is not Sendable.
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            results = Array(self.completer.results.prefix(6))
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            results = []
        }
    }

    /// Looks the completion up for its coordinate, which stays nil if the
    /// lookup fails.
    func resolve(_ completion: MKLocalSearchCompletion) async -> PickedPlace {
        isResolving = true
        defer { isResolving = false }
        var place = PickedPlace(name: completion.title, address: completion.subtitle)
        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
        if let item = try? await search.start().mapItems.first {
            let coordinate = item.placemark.coordinate
            place.latitude = coordinate.latitude
            place.longitude = coordinate.longitude
        }
        return place
    }

    func clear() {
        query = ""
        results = []
    }
}

/// The search field and its suggestions, as form rows.
struct PlaceSearchRows: View {
    let prompt: String
    @Bindable var search: PlaceSearch
    let onPick: (PickedPlace) -> Void

    var body: some View {
        TextField(prompt, text: $search.query)
            .autocorrectionDisabled()
        ForEach(search.results, id: \.self) { completion in
            Button {
                Task {
                    let place = await search.resolve(completion)
                    onPick(place)
                    search.clear()
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(completion.title)
                        .foregroundStyle(.primary)
                    if !completion.subtitle.isEmpty {
                        Text(completion.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(search.isResolving)
        }
    }
}
