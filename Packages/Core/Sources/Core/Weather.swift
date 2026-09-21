import CoreLocation
import SwiftUI
import WeatherKit

// Our two value types deliberately share names with WeatherKit's. Inside Core
// the unqualified names resolve to ours; WeatherKit's are always written
// `WeatherKit.DayWeather` / `WeatherKit.CurrentWeather`, so a feature package
// that imports Core never has to import WeatherKit or pick between the two.

/// One day's forecast — or, for a day already gone, what the weather was.
public struct DayWeather: Sendable, Equatable, Identifiable {
    public var id: Date { date }
    /// The start of that local day.
    public let date: Date
    public let highCelsius: Double
    public let lowCelsius: Double
    /// An SF Symbol name.
    public let symbolName: String
    /// A readable condition, "Partly cloudy".
    public let summary: String

    public init(date: Date, highCelsius: Double, lowCelsius: Double, symbolName: String, summary: String) {
        self.date = date
        self.highCelsius = highCelsius
        self.lowCelsius = lowCelsius
        self.symbolName = symbolName
        self.summary = summary
    }
}

/// The weather right now, with today's range alongside it.
public struct CurrentWeather: Sendable, Equatable {
    public let temperatureCelsius: Double
    public let highCelsius: Double
    public let lowCelsius: Double
    public let symbolName: String
    public let summary: String

    public init(temperatureCelsius: Double, highCelsius: Double, lowCelsius: Double, symbolName: String, summary: String) {
        self.temperatureCelsius = temperatureCelsius
        self.highCelsius = highCelsius
        self.lowCelsius = lowCelsius
        self.symbolName = symbolName
        self.summary = summary
    }
}

/// Where weather comes from. Views read one from the environment and treat
/// every throw as "no weather" — never an error banner, never a spinner left
/// running — because the live provider fails outright until the WeatherKit
/// capability is enabled for the app ID in the developer portal.
public protocol WeatherProviding: Sendable {
    func current(latitude: Double, longitude: Double) async throws -> CurrentWeather
    /// One entry per local day from `from` through `to`, both inclusive.
    func daily(latitude: Double, longitude: Double, from: Date, to: Date) async throws -> [DayWeather]
}

// MARK: - Live

/// Apple Weather, through `WeatherService.shared`. Anywhere its data is shown
/// must also show `WeatherAttributionView` — WeatherKit's terms require it.
public struct WeatherKitProvider: WeatherProviding {
    public init() {}

    public func current(latitude: Double, longitude: Double) async throws -> CurrentWeather {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let (now, days) = try await WeatherService.shared.weather(for: location, including: .current, .daily)
        // `.current` carries no high or low, so they come from today's entry in
        // the daily forecast; without one, the current reading stands in.
        let temperature = now.temperature.converted(to: .celsius).value
        let today = days.first { Calendar.current.isDate($0.date, inSameDayAs: now.date) } ?? days.first
        return CurrentWeather(
            temperatureCelsius: temperature,
            highCelsius: today?.highTemperature.converted(to: .celsius).value ?? temperature,
            lowCelsius: today?.lowTemperature.converted(to: .celsius).value ?? temperature,
            symbolName: now.symbolName,
            summary: now.condition.description
        )
    }

    public func daily(latitude: Double, longitude: Double, from: Date, to: Date) async throws -> [DayWeather] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: from)
        let lastDay = calendar.startOfDay(for: to)
        guard start <= lastDay, let end = calendar.date(byAdding: .day, value: 1, to: lastDay) else { return [] }
        let location = CLLocation(latitude: latitude, longitude: longitude)
        // The query runs to the start of the day after `to` so `to` itself is
        // included; anything WeatherKit returns either side is filtered out.
        let forecast = try await WeatherService.shared.weather(for: location, including: .daily(startDate: start, endDate: end))
        return forecast
            .map { day in
                DayWeather(
                    date: calendar.startOfDay(for: day.date),
                    highCelsius: day.highTemperature.converted(to: .celsius).value,
                    lowCelsius: day.lowTemperature.converted(to: .celsius).value,
                    symbolName: day.symbolName,
                    summary: day.condition.description
                )
            }
            .filter { $0.date >= start && $0.date <= lastDay }
    }
}

// MARK: - Stub

/// Made-up weather that is the same every time for the same place and day, and
/// different from one day to the next — for DEBUG builds, previews and tests,
/// where the live provider can't be reached.
public struct StubWeatherProvider: WeatherProviding {
    public init() {}

    private static let conditions: [(symbol: String, summary: String)] = [
        ("sun.max.fill", "Sunny"),
        ("cloud.sun.fill", "Partly cloudy"),
        ("cloud.fill", "Cloudy"),
        ("cloud.rain.fill", "Rain"),
    ]

    public func current(latitude: Double, longitude: Double) async throws -> CurrentWeather {
        let today = Self.day(Calendar.current.startOfDay(for: .now), latitude: latitude, longitude: longitude)
        return CurrentWeather(
            temperatureCelsius: (today.highCelsius + today.lowCelsius) / 2,
            highCelsius: today.highCelsius,
            lowCelsius: today.lowCelsius,
            symbolName: today.symbolName,
            summary: today.summary
        )
    }

    public func daily(latitude: Double, longitude: Double, from: Date, to: Date) async throws -> [DayWeather] {
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: from)
        let lastDay = calendar.startOfDay(for: to)
        var days: [DayWeather] = []
        while day <= lastDay {
            days.append(Self.day(day, latitude: latitude, longitude: longitude))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    /// Derived only from the day of the year and the coordinate — no randomness,
    /// so a test can call it twice and compare.
    private static func day(_ date: Date, latitude: Double, longitude: Double) -> DayWeather {
        let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: date) ?? 1
        let place = Int((abs(latitude) * 7 + abs(longitude) * 3).rounded())
        let seed = dayOfYear &* 31 &+ place
        // Warmer toward the equator, a gentle wave through the year on top.
        let base = 30 - abs(latitude) * 0.4
        let wave = sin(Double(dayOfYear) / 365 * 2 * .pi) * 6
        let high = (base + wave + Double(seed % 5)).rounded()
        let low = high - 6 - Double(seed % 4)
        let condition = conditions[seed % conditions.count]
        return DayWeather(date: date, highCelsius: high, lowCelsius: low, symbolName: condition.symbol, summary: condition.summary)
    }
}

// MARK: - Formatting and reach

public enum WeatherFormat {
    /// "83°" where people read Fahrenheit, "28°" where they read Celsius — the
    /// unit letter left off, as every weather app does.
    public static func temperature(_ celsius: Double, locale: Locale = .current) -> String {
        let unit = UnitTemperature(forLocale: locale, usage: .weather)
        let value = Measurement(value: celsius, unit: UnitTemperature.celsius).converted(to: unit).value
        // Through Int, so a reading that rounds to -0 prints "0°", not "-0°".
        return "\(Int(value.rounded()))°"
    }
}

/// How far ahead weather can be asked for. WeatherKit's daily forecast is ten
/// days counting today, so the last forecastable day is nine days out; asking
/// for a day beyond that returns nothing rather than failing. Days already gone
/// are always covered — WeatherKit answers those from its history.
public enum ForecastWindow {
    public static let days = 10

    public static func covers(_ day: Date, asOf now: Date = .now, calendar: Calendar = .current) -> Bool {
        let target = calendar.startOfDay(for: day)
        let today = calendar.startOfDay(for: now)
        guard let ahead = calendar.dateComponents([.day], from: today, to: target).day else { return false }
        return ahead < days
    }

    /// The first day on which a forecast for `day` exists — nine days before it.
    public static func firstForecastDate(for day: Date, calendar: Calendar = .current) -> Date {
        let target = calendar.startOfDay(for: day)
        return calendar.date(byAdding: .day, value: -(days - 1), to: target) ?? target
    }
}

extension EnvironmentValues {
    /// Live by default; the app swaps in `StubWeatherProvider` for DEBUG runs.
    @Entry public var weatherProvider: any WeatherProviding = WeatherKitProvider()
}

// MARK: - Attribution

/// The Apple Weather mark and a link to its legal page, which WeatherKit's terms
/// require wherever its data appears. While the attribution loads, or if it
/// never does, a plain "Apple Weather" line stands in so the credit is never
/// missing.
public struct WeatherAttributionView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var attribution: WeatherAttribution?

    public init() {}

    public var body: some View {
        Group {
            if let attribution {
                HStack(spacing: 8) {
                    AsyncImage(url: colorScheme == .dark ? attribution.combinedMarkDarkURL : attribution.combinedMarkLightURL) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Text(attribution.serviceName)
                    }
                    .frame(height: 12)
                    Link("Other data sources", destination: attribution.legalPageURL)
                }
            } else {
                Text("Apple Weather")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .task {
            attribution = try? await WeatherService.shared.attribution
        }
    }
}
