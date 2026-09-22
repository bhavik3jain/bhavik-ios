import Core
import CoreData
import SwiftData
import SwiftUI

public enum TripTrackerModule {
    public static let accent = ModuleAccent(name: "Trips", color: Color(red: 0.13, green: 0.52, blue: 0.93))

    /// The original SwiftData models (`Trip`, `ItineraryItem`, `Flight`,
    /// `Booking` — see `Trip`'s own doc comment in `SwiftDataTrip.swift`), not
    /// the new Core Data ones (`SharedTrip` and friends) — this is what keeps
    /// them registered in `AppSchema.models` in `BhavikApp.swift`, so
    /// `TripLegacyMigration` still has a store to read real trips from. Do NOT
    /// change this to the new Core Data types, and do NOT drop it from
    /// `AppSchema.models` — both are a later, human-gated step.
    public static var models: [any PersistentModel.Type] {
        [Trip.self, ItineraryItem.self, Flight.self, Booking.self]
    }

    /// `context` is the module's own Core Data context — see
    /// `CloudSharedStore.makeContainer` and `BhavikApp.init()`, which builds it
    /// and passes it to this call at `HomeView.swift`'s `moduleContent(for:)`.
    /// Set on the environment here, at the top of the module's own view tree,
    /// rather than relying on the app shell having set it globally — every
    /// view below this one that reads `@Environment(\.managedObjectContext)`
    /// gets it from here.
    @MainActor
    public static func rootView(context: NSManagedObjectContext) -> some View {
        TripRootView()
            .environment(\.managedObjectContext, context)
    }

    /// The line under "Trips" on the home screen.
    public static func homeDetail(trips: [SharedTrip], asOf now: Date = .now) -> String {
        TripOverview.homeDetail(trips: trips, asOf: now)
    }
}
