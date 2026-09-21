import Core
import SwiftUI

// Weather for a guide is always for the centre of its places — never for where
// the reader is. Every view here fetches in `.task(id:)` keyed on that point and
// treats any throw as "no weather": the live provider fails outright until the
// WeatherKit capability is enabled for the app ID, and a banner or a spinner
// left running would then be on every screen.
//
// Both views wrap their content in a `ZStack` rather than a `Group`: a `Group`
// whose `if` is false has no children, so the `.task` attached to it never
// runs and the weather never arrives — which is exactly the state it starts in.

/// The small "72°" chip on a guide card and on the map's title bar. Draws
/// nothing at all until there is a reading.
struct GuideWeatherChip: View {
    let point: GeoPoint?
    var compact = false
    /// Sitting on a map, the chip needs its own backing to stay legible. It is
    /// applied here, inside the reading, so a failed fetch leaves no empty
    /// capsule floating over the map.
    var onMap = false
    /// Tells the host whether there is a reading, so a screen with no other
    /// weather on it can show Apple's attribution only while the chip does —
    /// the map's toolbar chip once showed temperatures with no credit at all.
    var hasReading: Binding<Bool> = .constant(false)

    @Environment(\.weatherProvider) private var provider
    @State private var weather: CurrentWeather?

    var body: some View {
        ZStack {
            if let weather {
                HStack(spacing: 4) {
                    Image(systemName: weather.symbolName)
                        .symbolRenderingMode(.multicolor)
                    Text(WeatherFormat.temperature(weather.temperatureCelsius))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .font(compact ? .caption : .subheadline)
                .padding(.horizontal, onMap ? 9 : 0)
                .padding(.vertical, onMap ? 4 : 0)
                .background(onMap ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.clear), in: Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(WeatherFormat.temperature(weather.temperatureCelsius)), \(weather.summary)")
            }
        }
        .task(id: point) {
            guard let point else {
                weather = nil
                hasReading.wrappedValue = false
                return
            }
            weather = try? await provider.current(latitude: point.latitude, longitude: point.longitude)
            hasReading.wrappedValue = weather != nil
        }
    }
}

/// The guide screen's weather: now, today's range, and the next three days.
/// Absent entirely — attribution included — when the provider can't answer.
struct GuideWeatherCard: View {
    let point: GeoPoint?
    let caption: String

    @Environment(\.weatherProvider) private var provider
    @State private var current: CurrentWeather?
    @State private var upcoming: [DayWeather] = []

    var body: some View {
        ZStack {
            if let current {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: current.symbolName)
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 30))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(WeatherFormat.temperature(current.temperatureCelsius))
                                .font(.system(size: 30, weight: .semibold))
                                .monospacedDigit()
                            Text("\(current.summary) · H \(WeatherFormat.temperature(current.highCelsius)) L \(WeatherFormat.temperature(current.lowCelsius))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        HStack(spacing: 14) {
                            ForEach(upcoming) { day in
                                VStack(spacing: 4) {
                                    Text(day.date, format: .dateTime.weekday(.abbreviated))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Image(systemName: day.symbolName)
                                        .symbolRenderingMode(.multicolor)
                                        .font(.subheadline)
                                        .frame(height: 20)
                                    Text(WeatherFormat.temperature(day.highCelsius))
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                    HStack(spacing: 4) {
                        Text("\(caption) ·")
                        WeatherAttributionView()
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .task(id: point) { await load() }
    }

    private func load() async {
        guard let point else {
            current = nil
            upcoming = []
            return
        }
        current = try? await provider.current(latitude: point.latitude, longitude: point.longitude)
        guard current != nil else {
            upcoming = []
            return
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        guard let first = calendar.date(byAdding: .day, value: 1, to: today),
              let last = calendar.date(byAdding: .day, value: 3, to: today)
        else { return }
        let days = (try? await provider.daily(latitude: point.latitude, longitude: point.longitude, from: first, to: last)) ?? []
        upcoming = Array(days.prefix(3))
    }
}
