import Core
import SwiftUI

/// What a weather fetch depends on. The `.task` below is keyed on it, so moving
/// the trip, changing its destination or crossing midnight fetches again — and
/// nothing else does.
struct WeatherRequest: Hashable {
    let latitude: Double
    let longitude: Double
    let from: Date
    let to: Date

    init?(trip: Trip, asOf now: Date = .now) {
        guard let latitude = trip.latitude, let longitude = trip.longitude,
              let range = TripForecast.requestRange(for: trip.dates, asOf: now)
        else { return nil }
        self.latitude = latitude
        self.longitude = longitude
        self.from = range.lowerBound
        self.to = range.upperBound
    }
}

private struct TripWeatherLoader: ViewModifier {
    let request: WeatherRequest?
    @Binding var weather: [DayWeather]
    @Environment(\.weatherProvider) private var provider

    func body(content: Content) -> some View {
        content.task(id: request) {
            guard let request else {
                weather = []
                return
            }
            // Any failure is "no weather", never an error or a spinner: the live
            // provider throws outright until the WeatherKit capability is on for
            // the app ID, and the screen has to be complete without it.
            weather = (try? await provider.daily(
                latitude: request.latitude,
                longitude: request.longitude,
                from: request.from,
                to: request.to
            )) ?? []
        }
    }
}

extension View {
    /// Fetches the trip's daily weather into `weather`, off the critical path.
    func loadsWeather(for trip: Trip, into weather: Binding<[DayWeather]>) -> some View {
        modifier(TripWeatherLoader(request: WeatherRequest(trip: trip), weather: weather))
    }
}
