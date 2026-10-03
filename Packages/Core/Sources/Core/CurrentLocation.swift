import CoreLocation
import SwiftUI

/// A latitude and longitude in degrees, as plain values: `CLLocationCoordinate2D`
/// is neither `Equatable` nor `Sendable`, and a feature package comparing or
/// handing one across an `await` would otherwise have to wrap it itself.
public struct GeoCoordinate: Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Great-circle distance in metres — as the crow flies, not along streets.
    public func distance(to other: GeoCoordinate) -> Double {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }

    /// The plain average of `points`, or nil when there are none. Fine for the
    /// few streets or few miles a day's plan spans; nothing here straddles the
    /// 180th meridian or a pole, where averaging degrees goes wrong.
    ///
    /// The same points in any order give the same answer to the last bit:
    /// each axis is summed in sorted order. Callers pass points straight from
    /// a Core Data set, whose order changes run to run, and floating-point
    /// addition isn't associative — a day's centre came out as
    /// 12.480266666666667 one time and …665 the next, which failed Trips'
    /// `stopsAloneSayWhichDayButANamedDayWins` on about half of CI's runs
    /// and kept `main` red from #32 on.
    public static func centroid(of points: [GeoCoordinate]) -> GeoCoordinate? {
        guard !points.isEmpty else { return nil }
        let count = Double(points.count)
        return GeoCoordinate(
            latitude: points.map(\.latitude).sorted().reduce(0, +) / count,
            longitude: points.map(\.longitude).sorted().reduce(0, +) / count
        )
    }
}

/// The answer to one "where am I?".
public enum LocationLookup: Sendable, Equatable {
    case located(GeoCoordinate)
    /// The person said no, location services are off, or a parent/MDM
    /// restriction forbids it — there is nothing to retry until they change it
    /// in Settings.
    case denied
    /// Allowed, but no fix arrived in time: indoors, airplane mode, a simulator
    /// with no simulated location.
    case unavailable
}

/// Where the device is, asked for once rather than followed. Views read one
/// from the environment, the same way they read `weatherProvider`, so a
/// preview or a DEBUG run can swap in `StubLocationProvider`.
///
/// Main-actor, because the live one needs a `CLLocationManager`, which has to
/// be made and asked on a thread with a run loop.
public protocol LocationProviding: Sendable {
    @MainActor func currentLocation() async -> LocationLookup
}

/// Core Location: a `CLLocationManager` to ask for When-In-Use — the same way
/// Explore's map asks — then `CLLocationUpdate.liveUpdates()` for the first
/// fix. Both exist on iOS and macOS, so there is no platform conditional here
/// and none in the modules that call it. (`CLServiceSession`, the newer way to
/// ask, is unavailable on macOS: using it broke the Mac build.)
///
/// The prompt needs `NSLocationWhenInUseUsageDescription` in **both** targets'
/// `info.properties` in `project.yml`, and the Mac needs
/// `com.apple.security.personal-information.location` in
/// `App-macOS.entitlements`; without either, the request is dropped silently
/// and this reports `.unavailable` after the timeout rather than `.denied`.
public struct DeviceLocationProvider: LocationProviding {
    /// Long enough to cover the person reading the permission prompt; after it,
    /// a view offers "Try again" rather than a spinner that never stops.
    public let timeout: Duration

    public init(timeout: Duration = .seconds(20)) {
        self.timeout = timeout
    }

    @MainActor
    public func currentLocation() async -> LocationLookup {
        let manager = CLLocationManager()
        switch manager.authorizationStatus {
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
        // Kept alive until the lookup ends: a manager released while its
        // prompt is up takes the request with it.
        let lookup = await firstFix()
        withExtendedLifetime(manager) {}
        return lookup
    }

    private func firstFix() async -> LocationLookup {
        let timeout = timeout
        return await withTaskGroup(of: LocationLookup.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
                            return .denied
                        }
                        if let location = update.location {
                            return .located(GeoCoordinate(
                                latitude: location.coordinate.latitude,
                                longitude: location.coordinate.longitude
                            ))
                        }
                        // `locationUnavailable` is often momentary (a cold GPS
                        // start), so it waits for the next update or the timeout
                        // rather than giving up on the first one.
                    }
                } catch {
                    return .unavailable
                }
                return .unavailable
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .unavailable
            }
            let first = await group.next() ?? .unavailable
            group.cancelAll()
            return first
        }
    }
}

/// A fixed answer, for previews and DEBUG runs on a simulator with no simulated
/// location.
public struct StubLocationProvider: LocationProviding {
    public let lookup: LocationLookup

    public init(_ lookup: LocationLookup) {
        self.lookup = lookup
    }

    @MainActor
    public func currentLocation() async -> LocationLookup { lookup }
}

extension EnvironmentValues {
    /// Live by default.
    @Entry public var locationProvider: any LocationProviding = DeviceLocationProvider()
}
