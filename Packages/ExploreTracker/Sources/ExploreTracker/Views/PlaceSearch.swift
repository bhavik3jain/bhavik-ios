import MapKit
import Observation

/// Apple Maps autocomplete for the add sheet.
///
/// Biased toward the region the guide's places already cover — never toward
/// the reader's location — so a Kyoto guide can be filled in from anywhere. An
/// empty guide has nothing to lean on and searches unbiased.
@MainActor
@Observable
final class PlaceSearch: NSObject {
    struct Result: Identifiable, Equatable {
        let title: String
        let subtitle: String

        /// By content rather than position: the completer reorders its list
        /// on every keystroke, and a positional id would move the checkmark
        /// onto whichever result slid into the chosen one's slot.
        var id: String { "\(title)\n\(subtitle)" }
    }

    /// What resolving a result produced: everything a `SharedGuidePlace` stores.
    struct Resolved: Equatable {
        let name: String
        let address: String
        let point: GeoPoint
        let category: PlaceCategory
    }

    var query = "" {
        didSet { update() }
    }
    private(set) var results: [Result] = []

    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    @ObservationIgnored private var completions: [MKLocalSearchCompletion] = []
    @ObservationIgnored private let region: GuideRegion?

    init(region: GuideRegion?) {
        self.region = region
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
        if let region {
            completer.region = region.coordinateRegion
        }
    }

    private func update() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completer.cancel()
            completions = []
            results = []
            return
        }
        completer.queryFragment = trimmed
    }

    /// Looks the chosen suggestion up to get its coordinate and Maps' category.
    /// `nil` when the lookup fails, which the sheet turns into "add by hand".
    func resolve(_ result: Result) async -> Resolved? {
        guard let completion = completions.first(where: { $0.title == result.title && $0.subtitle == result.subtitle })
        else { return nil }
        let request = MKLocalSearch.Request(completion: completion)
        if let region { request.region = region.coordinateRegion }
        guard let response = try? await MKLocalSearch(request: request).start(),
              let item = response.mapItems.first
        else { return nil }
        let coordinate = item.placemark.coordinate
        return Resolved(
            name: item.name ?? result.title,
            address: result.subtitle,
            point: GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude),
            category: PlaceCategory.guess(from: item.pointOfInterestCategory)
        )
    }
}

extension PlaceSearch: @preconcurrency MKLocalSearchCompleterDelegate {
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        completions = completer.results
        var seen = Set<String>()
        results = completer.results
            .map { Result(title: $0.title, subtitle: $0.subtitle) }
            .filter { seen.insert($0.id).inserted }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        // Typing faster than the network answers fails the in-flight request;
        // the next keystroke asks again, so there is nothing to report.
        completions = []
        results = []
    }
}
