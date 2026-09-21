import SwiftData
import SwiftUI
import Core

public enum TripTrackerModule {
    public static let accent = ModuleAccent(name: "Trips", color: Color(red: 0.13, green: 0.52, blue: 0.93))

    public static var models: [any PersistentModel.Type] {
        [Trip.self, ItineraryItem.self, Flight.self, Booking.self]
    }

    @MainActor
    public static func rootView() -> some View {
        TripRootView()
    }

    /// The line under "Trips" on the home screen.
    public static func homeDetail(trips: [Trip], asOf now: Date = .now) -> String {
        TripOverview.homeDetail(trips: trips, asOf: now)
    }
}
